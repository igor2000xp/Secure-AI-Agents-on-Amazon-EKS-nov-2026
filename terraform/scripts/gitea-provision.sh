#!/usr/bin/env bash
# Provision Gitea for module 1000. Idempotent (safe to re-run).
# Args via env: NS, ADMIN_USER, ADMIN_PASS, BOT_USER, BOT_PASS, PARTICIPANT_USER,
# PARTICIPANT_PASS, WEBHOOK_SECRET, DISPATCHER_WEBHOOK_URL, SEED_REPO, TRIGGER_LABEL.
set -euo pipefail

NS="${NS:-gitea}"
POD="$(kubectl get pod -n "$NS" -l app.kubernetes.io/name=gitea -o jsonpath='{.items[0].metadata.name}')"
API="http://gitea-http.${NS}.svc.cluster.local:3000/api/v1"

exec_gitea() { kubectl exec -n "$NS" "$POD" -c gitea -- "$@"; }
# curl runs inside the gitea pod so it can reach the ClusterIP API.
api() { # api METHOD PATH [json]
  local method="$1" path="$2" body="${3:-}"
  kubectl exec -n "$NS" "$POD" -c gitea -- curl -sS -X "$method" \
    -u "${ADMIN_USER}:${ADMIN_PASS}" -H 'content-type: application/json' \
    ${body:+-d "$body"} "${API}${path}"
}

# 1. Bot + participant users (idempotent: `|| true` on "already exists").
exec_gitea gitea admin user create --username "$BOT_USER" --password "$BOT_PASS" \
  --email "bot@example.com" --must-change-password=false || true
exec_gitea gitea admin user create --username "$PARTICIPANT_USER" --password "$PARTICIPANT_PASS" \
  --email "participant@example.com" --must-change-password=false || true

# 2. Create the repo (owned by participant), EMPTY — we push the starter app next.
api POST "/admin/users/${PARTICIPANT_USER}/repos" \
  "{\"name\":\"${SEED_REPO}\",\"auto_init\":false,\"private\":false,\"default_branch\":\"main\"}" || true

# 2b. Seed the starter FastAPI app so participants have real code to file issues
# against. Copy the seed into the pod and git-push it as the repo owner. Gitea's
# image is Alpine (sh, not bash). Tolerant of re-runs: if the repo already has
# content the push is a rejected no-op.
kubectl exec -n "$NS" "$POD" -c gitea -- rm -rf /tmp/sample-app
kubectl cp "$SEED_DIR" "$NS/$POD:/tmp/sample-app" -c gitea
kubectl exec -n "$NS" "$POD" -c gitea -- sh -c "
  set -e
  cd /tmp/sample-app
  git init -q
  git config user.email 'workshop-user@example.com'
  git config user.name 'workshop-user'
  git add -A
  git commit -q -m 'Initial sample app'
  git branch -M main
  git remote add origin 'http://${PARTICIPANT_USER}:${PARTICIPANT_PASS}@gitea-http.${NS}.svc.cluster.local:3000/${PARTICIPANT_USER}/${SEED_REPO}.git'
  git push -u origin main
" || echo 'seed push skipped (repo may already have content)'

# 3. Give the bot write collaborator access to the repo (so it can push/PR).
api PUT "/repos/${PARTICIPANT_USER}/${SEED_REPO}/collaborators/${BOT_USER}" \
  '{"permission":"write"}' || true

# 4. Ensure the trigger label exists on the repo.
api POST "/repos/${PARTICIPANT_USER}/${SEED_REPO}/labels" \
  "{\"name\":\"${TRIGGER_LABEL}\",\"color\":\"#0e8a16\"}" || true

# 5. Register the issues webhook -> dispatcher, HMAC-signed.
api POST "/repos/${PARTICIPANT_USER}/${SEED_REPO}/hooks" \
  "{\"type\":\"gitea\",\"active\":true,\"events\":[\"issues\"],\"config\":{\"url\":\"${DISPATCHER_WEBHOOK_URL}\",\"content_type\":\"json\",\"secret\":\"${WEBHOOK_SECRET}\"}}" || true

echo "gitea provisioning complete"
