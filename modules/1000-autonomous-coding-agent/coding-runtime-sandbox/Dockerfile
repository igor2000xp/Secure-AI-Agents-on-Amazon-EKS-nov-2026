# Coding sandbox runtime image: sandboxd + git, Node and the Claude Code CLI.
#
# Built FROM the upstream sandboxd image, pulled straight from registry.k8s.io.
# It is a BUILD-time base, so the pull happens in CodeBuild (or on the IDE for a
# manual rebuild), never on a cluster node — the image the sandboxes actually
# run is this derived one, which lives in ECR. This is upstream's
# recommended "topology A": sandboxd IS the
# execution environment, so the command the dispatcher starts over
# ProcessService runs in THIS image's filesystem. Everything the coding agent
# invokes — git, node, claude, python3, pytest — has to be here; a neighbouring
# container's tools are not reachable, because a shared volume shares files,
# not binaries.
#
# The toolchain is baked in because the sandbox's egress is an allowlist, so
# `npm install` cannot reach a registry at run time. Python packages are the
# exception: pypi.org is allowlisted, so the agent installs the target repo's
# requirements.txt itself rather than finding them pre-staged here.
#
# The ARG has a DEFAULT so `docker build` works with no arguments, while
# codebuild-images.tf still overrides it from the agent-sandbox version in
# manifests/vendor/sources.yaml — which stays the single source of truth for the
# provisioned path. Keep this default in step with that file when bumping.
ARG SANDBOXD_IMAGE=registry.k8s.io/agent-sandbox/sandboxd:v1.0.10
FROM ${SANDBOXD_IMAGE}

# The base runs as UID 1000 (sandboxd's non-root user); drop to root for the
# install, then go back.
USER root

# git + curl + Node + npm for the Claude Code CLI, and python3 + pytest so the
# agent can run the sample app's tests.
#
# python3-pip is here because the sample app ships a requirements.txt and Claude
# Code reasonably tries to install from it. Without pip the agent reports itself
# blocked on "there is no pip in the sandbox", which is a confusing failure for
# a participant.
#
# The repo's own dependencies are DELIBERATELY NOT baked in. The agent installs
# them itself from requirements.txt, which is why pypi.org and
# files.pythonhosted.org are on the egress allowlist (see the
# ApplicationNetworkPolicy in the dispatcher's k8s.yaml). Pre-installing them
# would hide whether that path actually works.
#
# Install nodejs AND npm straight from Debian's repos rather than adding the
# NodeSource apt repo. NodeSource's signing-key fetch is an external network
# call that flakes intermittently, and its setup script exits 0 even when the
# key import fails, so the build silently fell back to Debian's nodejs WITHOUT
# npm (a separate Debian package) and then died at `npm install -g` with
# "npm: not found" (exit 127) on whichever accounts hit the flake. Claude Code
# prints an EBADENGINE warning (it prefers Node >= 22) but runs correctly on
# Debian's Node — verified with `claude --version`. curl stays: run.sh uses it
# to open the PR and to post a blocker report via the Gitea API.
RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl ca-certificates nodejs npm \
      python3 python3-pip python3-pytest python3-httpx && \
    npm install -g @anthropic-ai/claude-code && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# /workspace is sandboxd's root (--root-dir), owned 1000:1000 by the base image,
# and it is where files.write() puts uploads. Point HOME there so git config,
# ~/.git-credentials and Claude Code's ~/.claude all land somewhere writable.
# run.sh re-exports HOME too, belt and suspenders.
ENV HOME=/workspace

# Let the agent's own `pip install` work without it having to discover the
# PEP 668 flag (see the install note above).
ENV PIP_BREAK_SYSTEM_PACKAGES=1

USER 1000

# ENTRYPOINT and WORKDIR are inherited from the sandboxd base deliberately:
# /usr/local/bin/sandboxd serving REST on :8080 and gRPC on :9090, rooted at
# /workspace. Overriding either leaves the dispatcher with nothing to talk to.
# There is no uvicorn server here any more — the FastAPI app on :8888 that this
# image used to run was replaced by sandboxd.
