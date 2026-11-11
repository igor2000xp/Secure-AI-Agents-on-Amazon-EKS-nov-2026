# Module 1000 — Autonomous Coding Agent (git issue → Claude Code in a sandbox → PR)

A labelled git issue on an in-cluster **Gitea** repo triggers a dispatcher that runs
**Claude Code** inside a per-execution **Nitro Sandbox** micro-VM. Claude Code
implements the change against Claude-on-Bedrock (via the Envoy AI Gateway), pushes
a branch, and opens a PR back on the issue — with **no human ever handling a git
credential**.

This is the capstone: it composes the sandbox platform (module 900), the
Envoy AI Gateway → Bedrock seam, and Langfuse tracing.

## Request flow

```
Human → Gitea (own CloudFront/HTTPS; local auth): file issue + label `agent`
Gitea → coding-agent-dispatcher (in-cluster webhook, HMAC-verified): issues event
dispatcher: mint per-run Gitea token; create coding sandbox Pod (isolated-sandbox)
dispatcher → sandbox (kubectl exec stdin): git-credentials + task.md  [out-of-band, not via LLM]
sandbox: claude -p  → clone (in-cluster Gitea) → edit → test → commit → push → open PR
         model calls → Envoy AI Gateway /anthropic/v1/messages → Bedrock (Claude)  [Langfuse-traced]
dispatcher: verify PR → comment link on the issue → terminate sandbox → revoke token
            (no PR: the agent posts /work/BLOCKED.md to the issue via
             report-blocked.sh; run.sh posts the transcript tail if it did not)
```

## Components

**Platform (Terraform):**
- `terraform/gitea.tf`, `terraform/gitea-cloudfront.tf`, `terraform/gitea-provision.tf`
  + `terraform/scripts/gitea-provision.sh` — Gitea (Helm, SQLite, local auth), its
  own CloudFront+ALB, and provisioning (accounts, `sample-app` repo, `coding-agent-bot`,
  `agent` label, `issues` webhook, and the `coding-agent-creds` Secret). The repo
  is created empty and seeded by pushing the starter app from
  `terraform/seed/sample-app/` (a tiny FastAPI service + test) so participants have
  real code to file issues against.
- `terraform/manifests/envoy-ai-gateway-anthropic.yaml` + `terraform/aigateway-anthropic-route.tf`
  — Anthropic-input route to the existing Bedrock backend.
- Nitro Sandboxes ship with EKS Auto Mode, so the `isolated-sandbox` RuntimeClass
  needs no Terraform of its own. The sandbox egress lock lives with the module, in
  `coding-agent-dispatcher/k8s.yaml`.

**Application (this module):**
- `coding-agent-dispatcher/` — FastAPI webhook receiver + async orchestrator
  (`server.py`, `webhook.py`, `gitea_client.py`, `sandbox_runner.py`, tests,
  `Dockerfile`, `k8s.yaml`).
- `coding-runtime-sandbox/` — the sandbox runtime image: git, Node, and the
  Claude Code CLI, pre-installed so the egress-locked sandbox never needs
  npm/pip at run time.

## Security model

- No human PAT anywhere; the agent uses a dispatcher-held bot account.
- The microVM holds no AWS creds and only a short-lived, per-run git token
  (minted and revoked by the dispatcher).
- Sandbox egress is locked to the AI-gateway and Gitea namespaces only — no
  internet, no direct Bedrock.
- Untrusted, model-generated code runs in a Nitro Sandbox microVM (its own kernel,
  isolated by the AWS Nitro hypervisor rather than by shared-kernel namespaces).
- Model calls flow through the gateway (Bedrock identity via Pod Identity) and
  are traced in Langfuse.

## Deferred live-cluster verification (no cluster available at authoring)

Run these at deploy and record results:

1. **Anthropic model path** — `kubectl explain aigatewayroute.spec | grep -i schema`;
   if the route takes a `schema` field, uncomment `schema: {name: Anthropic}` in
   `envoy-ai-gateway-anthropic.yaml` and re-apply. Then from a debug pod:
   `curl -sS http://ai-gateway.envoy-gateway-system.svc.cluster.local/anthropic/v1/messages
   -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01'
   -H 'x-api-key: not-needed' -d '{"model":"claude-sonnet","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}'`
   expects an Anthropic JSON response; confirm the span in Langfuse.
   **Fallback:** if the gateway's Anthropic endpoint is unavailable on the pinned
   build, point the dispatcher's `MODEL_BASE_URL` at any other endpoint that serves
   the Anthropic Messages API (e.g. `https://api.anthropic.com` with a real
   `ANTHROPIC_API_KEY`, or a self-hosted OpenAI-compatible proxy you deploy
   yourself). LiteLLM is no longer part of this workshop.
2. **Gitea** — chart `12.1.3` (appVersion `1.24.3`) / app image `1.24.3` exist (adjust if not); the
   CloudFront URL serves Gitea over HTTPS; `sample-app` repo + `agent` label +
   `issues` webhook exist; the `coding-agent-creds` Secret is present in `default`.
3. **Gitea provisioning** — confirm `gitea admin user create --must-change-password=false`
   and the API endpoints (`/admin/users/{u}/repos`, `/repos/{o}/{r}/collaborators/{u}`,
   `/repos/{o}/{r}/labels`, `/repos/{o}/{r}/hooks`) behave as expected on the pinned
   Gitea version; confirm the StatefulSet is named `gitea`.
4. **micro-VM proof** — a coding sandbox lands on a sandbox-capable node;
   `uname -r` shows a guest kernel that differs from the node's.
5. **Egress lock** — from inside a coding sandbox: internet + Bedrock blocked;
   AI-gateway + Gitea ClusterIPs reachable.
6. **Claude Code** — `claude -p` honors `ANTHROPIC_BASE_URL`/`ANTHROPIC_API_KEY`/
   `ANTHROPIC_MODEL` against the gateway and completes clone→edit→commit→push→PR
   with the injected per-run token.
7. **End-to-end** — label an issue `agent` → dispatcher comments "Working…" → branch +
   PR appear referencing the issue → PR-link comment posted → sandbox terminated
   (no residual SandboxClaim in `agent-sandbox`) → per-run token revoked.
8. **Loop guard** — a bot-authored issue does not re-trigger a run.

## Note on Gitea token scoping

Gitea access-token scopes are per-**category** (`write:repository`, `write:issue`),
not per-single-repo, and Gitea tokens have no native expiry. The dispatcher mints a
per-run token with those scopes and revokes it after the run (a `finally`); its blast
radius is contained by the sandbox being ephemeral and egress-locked to in-cluster
Gitea, and by the bot being a collaborator on only the seed repo.

As a TTL backstop for a missed revoke (dispatcher crash / transient error), a
background sweep (`server.py`, every `TOKEN_SWEEP_INTERVAL`, default 5m) revokes any
`run-*` token older than `TOKEN_TTL_SECONDS` (default 1h). The TTL MUST exceed the max
run duration (`SANDBOX_READY_TIMEOUT` + `SANDBOX_RUN_TIMEOUT`, ~30m) so a token for an
in-flight run is never revoked.
