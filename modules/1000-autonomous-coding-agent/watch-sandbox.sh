#!/usr/bin/env bash
# Follow a coding-agent run live.
#
# WHY THIS IS NOW ONE LINE OF kubectl. Before agent-sandbox, the run happened
# inside an ephemeral pod that the dispatcher created and deleted, so following
# it meant racing to attach to a pod that existed for only a couple of minutes
# — this script used to poll for that pod, wait for Running, then follow it, and
# participants still missed runs.
#
# The dispatcher now streams the session back over sandboxd's ProcessService and
# prints it to its OWN stdout, prefixed with the issue number. That log belongs
# to a long-lived Deployment, so there is nothing to race: start this before or
# after you file the issue, and you see the run either way. It also survives the
# sandbox being released, which the pod log did not.
#
# Deliberately NOT `set -e`: a transient disconnect from `kubectl logs -f`
# should reconnect rather than kill the watch.
set -uo pipefail

# Ctrl+C must end the script, not the inner `kubectl logs -f`. Without this,
# kubectl exits 1 (not the 130 the loop below checks for), the loop decides the
# stream dropped, prints "reconnecting in 3s" and then swallows whatever the
# participant pastes next.
trap 'echo; echo "watch stopped."; exit 0' INT

DEPLOYMENT="${DISPATCHER_DEPLOYMENT:-coding-agent-dispatcher}"
NAMESPACE="${DISPATCHER_NAMESPACE:-default}"

echo "Following ${DEPLOYMENT} in ns ${NAMESPACE}. Ctrl+C to stop."
echo "Lines tagged [issue-N] are the coding agent's session for issue N."
echo

if ! kubectl get "deployment/${DEPLOYMENT}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  echo "error: deployment/${DEPLOYMENT} not found in ns ${NAMESPACE}." >&2
  echo "Deploy the dispatcher first (Step 2 of the lab)." >&2
  exit 1
fi

# Reconnect loop: `kubectl logs -f` ends when the dispatcher pod is replaced
# (a rollout, an eviction), which should not end the watch.
while true; do
  kubectl logs -f "deployment/${DEPLOYMENT}" -n "${NAMESPACE}" --tail=20 --prefix=false
  rc=$?
  # 130 = SIGINT (the participant pressed Ctrl+C); anything else is a dropped
  # stream worth retrying.
  if [ "$rc" = "130" ]; then
    echo
    echo "watch stopped."
    exit 0
  fi
  echo
  echo "[watch] log stream ended (rc=$rc); reconnecting in 3s..." >&2
  sleep 3
done
