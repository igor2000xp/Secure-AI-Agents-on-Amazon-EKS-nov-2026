#!/usr/bin/env bash
#
# Starts the image pre-build CodeBuild project and waits for completion.
# Used by terraform/codebuild-images.tf via a null_resource local-exec.
#
# Usage: run-codebuild.sh <project-name> <region>
#
# Requires only the AWS CLI (already a hard dependency of this Terraform
# config, see base.tf which shells out to `aws eks get-token`). No local
# Docker daemon is needed because the build runs inside CodeBuild.
#
# IAM propagation retry: the service role's inline policy is written moments
# before this script runs, and IAM is eventually consistent. A build that starts
# inside that window fails on its very first action — creating its CloudWatch
# log group/stream — with an authorization error, even though the policy is
# present and correct. codebuild-images.tf waits 30s to cover the usual case;
# this retry covers the unusual one. Only authorization failures are retried, so
# a genuine build break (bad Dockerfile, ECR push denied by something real)
# still fails on the first attempt.

set -eu

PROJECT="${1:?project name required}"
REGION="${2:?region required}"
POLL_SECONDS="${POLL_SECONDS:-15}"
AUTH_RETRIES="${AUTH_RETRIES:-2}"
AUTH_RETRY_WAIT="${AUTH_RETRY_WAIT:-30}"

# Prints the failure messages CodeBuild recorded for the failed phases.
phase_failure_messages() {
  aws codebuild batch-get-builds \
    --ids "$1" \
    --region "${REGION}" \
    --query "builds[0].phases[?phaseStatus!='SUCCEEDED'].contexts[].message" \
    --output text 2>/dev/null || true
}

# Starts one build and polls to a terminal state.
# Echoes the build id on stdout; returns 0 on success, 1 on failure.
run_build() {
  local build_id status
  build_id="$(aws codebuild start-build \
    --project-name "${PROJECT}" \
    --region "${REGION}" \
    --query 'build.id' \
    --output text)"

  echo "CodeBuild started: ${build_id}" >&2
  echo "Logs: https://${REGION}.console.aws.amazon.com/codesuite/codebuild/projects/${PROJECT}/build/${build_id}" >&2

  while true; do
    status="$(aws codebuild batch-get-builds \
      --ids "${build_id}" \
      --region "${REGION}" \
      --query 'builds[0].buildStatus' \
      --output text)"

    case "${status}" in
      SUCCEEDED)
        echo "${build_id}"
        return 0
        ;;
      FAILED | FAULT | STOPPED | TIMED_OUT)
        echo "${build_id}"
        LAST_STATUS="${status}"
        return 1
        ;;
      *)
        echo "  build status: ${status} (polling every ${POLL_SECONDS}s)..." >&2
        sleep "${POLL_SECONDS}"
        ;;
    esac
  done
}

echo "Starting CodeBuild project: ${PROJECT} (region ${REGION})"

attempt=0
while :; do
  LAST_STATUS="FAILED"
  if BUILD_ID="$(run_build)"; then
    echo "Image pre-build SUCCEEDED."
    exit 0
  fi

  MESSAGES="$(phase_failure_messages "${BUILD_ID}")"

  # Retry only when the failure looks like IAM propagation rather than a real
  # build problem.
  if printf '%s' "${MESSAGES}" | grep -qiE 'not authorized to perform|AccessDenied|UnrecognizedClient|InvalidClientTokenId' &&
    [ "${attempt}" -lt "${AUTH_RETRIES}" ]; then
    attempt=$((attempt + 1))
    echo "Build failed on an authorization error, which is usually IAM propagation." >&2
    echo "  ${MESSAGES}" >&2
    echo "Retrying in ${AUTH_RETRY_WAIT}s (attempt ${attempt} of ${AUTH_RETRIES})..." >&2
    sleep "${AUTH_RETRY_WAIT}"
    continue
  fi

  echo "Image pre-build ${LAST_STATUS}. See CodeBuild logs above." >&2
  if [ -n "${MESSAGES}" ]; then
    echo "Reported failure: ${MESSAGES}" >&2
  fi
  exit 1
done
