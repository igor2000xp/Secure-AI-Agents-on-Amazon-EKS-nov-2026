# 800 — Multi-agent (A2A) persona propagation + authn

Carry the Cognito persona identity through the **full multi-agent chain** and
authenticate it at agentgateway on the A2A hop:

```
UI → orchestrator → [agentgateway A2A] → order-agent → [agentgateway MCP] → mcp-server
```

Builds on:
- **700** — the gateway-wide `jwtAuthentication` (Cognito) already authenticates
  ALL routes, including the A2A ones; and the MCP per-tool authz.
- the routing phase — the `order-agent-a2a` / `product-agent-a2a` HTTPRoutes +
  A2A `AgentgatewayBackend`s these policies target.

**Authn-only** at the A2A layer: any authenticated persona may reach both
specialists. Differentiated (per-tool) authz stays at the MCP layer (700). The
point here is that identity **propagates across agent hops** and is enforced.

## What makes the chain work (code)

- **orchestrator** reads the forwarded `Authorization: Bearer` per request and
  attaches it on each A2A call (`A2AClient.send_message(http_kwargs={headers})`).
  The token reaches the tool functions via a `contextvars.ContextVar` (Strands
  propagates context into tool execution — verified).
- **order-agent** reads the incoming bearer from the a2a `ServerCallContext`
  (`call_context.state['headers']['authorization']` — populated by the default
  a2a context builder, no custom builder needed) and forwards it on its
  session-scoped MCP client (same pattern as the 500 agent).
- **product-agent** has no MCP call — it only receives an authenticated A2A call
  (gateway-enforced); nothing to forward.
- **mcp-server** stays auth-unaware (enforcement is all at agentgateway).

## Apply

```bash
kubectl apply -f policies/a2a-authn.yaml
```

(No placeholder substitution — the JWT provider is inherited from the 700
gateway-wide `jwtAuthentication`; these policies only add the authz gate.)

## Test (after image rebuild + apply)

| Case | Expected |
|---|---|
| Multi-agent query WITHOUT a logged-in persona (no token) | A2A call denied at the gateway (401 authn) — orchestrator surfaces a tool error |
| Logged-in persona (either) asks a multi-agent order question | flows UI→orchestrator→order-agent→MCP end to end; `lookup_order` allowed (per 700) |
| Distinguish 401 vs 403 | 401 = A2A authn (this module); 403 = MCP per-tool authz (700) |

## Files
- `policies/a2a-authn.yaml` — two `AgentgatewayPolicy` (one per specialist route),
  `authorization: action Require, has(jwt.sub)`.

## Notes / production deltas (same as 700)
- Token is forwarded as-is (no RFC 8693 exchange) — teach as the production
  delta. `has(jwt.sub)` is scalar, so no colon-claim CEL uncertainty here.
- Participant-facing lab markdown belongs with the other modules' content
  (outside this repo); this README carries the end-state + commands.
