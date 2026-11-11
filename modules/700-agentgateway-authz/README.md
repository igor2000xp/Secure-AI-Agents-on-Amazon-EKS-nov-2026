# 700 — Persona authn/authz at agentgateway

Enforce **which MCP tool each Cognito persona may call**, at the agentgateway
layer. Builds on the MCP routing (`500` MCP server behind agentgateway) — the
policies here target the `mcp-backend` `AgentgatewayBackend` and the
`agentgateway` Gateway created there.

Prerequisite: the token must reach the gateway. The Chainlit UI forwards the
user's Cognito **access token** as `Authorization: Bearer`, and the agent
forwards it on its MCP call. agentgateway validates the JWT
(`jwtAuthentication`) and authorizes each `call_tool` by the `cognito:groups`
claim (`backend.mcp.authorization`).

## Before applying: substitute this event's Cognito values

The policies contain placeholders. Fill them from Terraform outputs:

`terraform -chdir` does NOT expand `~`, so use `$HOME` (a literal `~` fails with
"no such file or directory").

```bash
TFDIR="$HOME/environment/terraform"

ISSUER=$(terraform -chdir="$TFDIR" output -raw cognito_issuer)
JWKS_HOST=$(terraform -chdir="$TFDIR" output -raw cognito_jwks_host)
JWKS_PATH=$(terraform -chdir="$TFDIR" output -raw cognito_jwks_path)
CLIENT=$(terraform -chdir="$TFDIR" output -raw cognito_client_id)

render() {  # render <step-file>
  sed -e "s|__COGNITO_ISSUER__|$ISSUER|g" \
      -e "s|__COGNITO_JWKS_HOST__|$JWKS_HOST|g" \
      -e "s|__COGNITO_JWKS_PATH__|$JWKS_PATH|g" \
      -e "s|__COGNITO_CLIENT_ID__|$CLIENT|g" "$1"
}
```

Each step file also creates a `cognito-jwks` `AgentgatewayBackend` (a static
host for the Cognito JWKS endpoint) — agentgateway fetches the JWKS through that
backend, not a bare URL.

## The 4-step arc

Each step's file is the **cumulative** policy state — applying step N replaces
step N-1. Test after each by logging into the chat UI as each persona and
asking the agent to use a tool.

| Step | Apply | Expected |
|---|---|---|
| 1. Deny-by-default | `render policies/step1-deny-all.yaml \| kubectl apply -f -` | ALL tool calls fail (403) for both personas |
| 2. Allow shared tool | `render policies/step2-allow-lookup.yaml \| kubectl apply -f -` | `lookup_order` works for BOTH; other tools still 403 |
| 3. Differentiate | `render policies/step3-differentiate.yaml \| kubectl apply -f -` | `initiate_return` works only for **support-associate**; sales-analyst denied |

- **How denial manifests:** a *missing/invalid* token is rejected by
  `jwtAuthentication` (401) before authz. A *valid token lacking the right
  persona* has the disallowed tool **hidden from `tools/list`** (verified) — the
  agent never sees it, so the LLM just reports it can't do that, rather than a
  visible 403. Step 2 succeeding proves the token propagates end to end (else
  every tool, including lookup_order, would 401).
- **Persona semantics:** `lookup_order` is universal; `initiate_return` is a
  customer-service (mutating) action → support-associate only.

## Files
- `policies/step1-deny-all.yaml` — jwtAuthentication + deny-by-default authz
- `policies/step2-allow-lookup.yaml` — + allow `lookup_order` (any persona)
- `policies/step3-differentiate.yaml` — + `initiate_return` for support-associate

## NOTE (participant-facing content)
The step-by-step narrative belongs in the workshop content markdown alongside
the other module labs. Those live outside this repo (only intro/summary content
is here), so this README carries the end-state + commands. Move/adapt into the
lab content location when authoring the participant guide.

## Verified live (2026-07-06, agentgateway v1.3.1)
- **Token forwarding works end to end** — the UI forwards the Cognito access
  token, and the agent (session-scoped MCP client, `build_session_agent`) carries
  it on each MCP call. Confirmed via the chat UI: sales-analyst and
  support-associate get different tool sets.
- **CEL colon-claim access** (`jwt["cognito:groups"]`) works — the rule
  discriminates correctly, no custom-claim fallback needed.
- **Authz filters at `tools/list`** — an unauthorized tool is *hidden* from the
  persona (0 tools discovered), not merely blocked on call. So a denied persona's
  agent never sees the tool (the LLM reports it lacks that capability), rather
  than getting a 403 mid-call. A *missing/invalid* token is still rejected 401 by
  `jwtAuthentication` before any tool logic.
