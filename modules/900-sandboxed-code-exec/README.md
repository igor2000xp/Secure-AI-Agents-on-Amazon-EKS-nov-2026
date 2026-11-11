# 900 — Sandboxed code execution (agent-sandbox on Nitro Sandboxes)

Let the agent run untrusted, model-generated Python inside a **single-use,
hardware-isolated micro-VM** — by giving it the **agent-sandbox** MCP tools
rather than a bespoke execution tool.

## Why

For analytical questions over many orders ("Q1 sales by region"), the agent
should _write code_, not ask for raw rows. Running that code is untrusted, so it
runs hardware-isolated and air-gapped: no network, no credentials.

The sandbox lifecycle itself is generic, so it is not ours to write.
[agent-sandbox](https://agent-sandbox.sigs.k8s.io/) (kubernetes-sigs, pinned in
`terraform/manifests/vendor/sources.yaml`) supplies the CRDs, controller and an
MCP server; we supply only the SandboxTemplate that decides what a sandbox _is_.

## Architecture

```
UI (sales-analyst) -> agent -> agentgateway
   [authz: sandbox tools + get_orders -> sales-analyst only]
     |
     |-- /mcp          -> orders mcp-server (module 500): get_orders
     |                     scoped Query on the period-index GSI
     |
     `-- /sandbox-mcp  -> agent-sandbox MCP server (upstream image)
                           create_sandbox  -> SandboxClaim -> warm pool
                           upload_file     -> orders.json + main.py
                           execute_command -> python3 main.py   (over sandboxd gRPC)
                           download_file   -> chartN.png
                           delete_sandbox  -> allowed, but the agent is told
                                              NOT to call it (see below)
```

The agent orchestrates the sequence itself. Sandboxes are claimed from a
`SandboxWarmPool` in ns `agent-sandbox`, so a claim usually attaches to an
already-booted guest.

## Sandbox lifetime: per conversation, not per question

The agent's system prompt (`modules/500-agent-tools-mcp/customer-agent/agent.py`)
tells it to **reuse** the sandbox it already claimed for the rest of the chat
session, and not to call `delete_sandbox` at all. A follow-up question therefore
pays no claim, no re-upload of `orders.json` and no micro-VM boot.

Cleanup is the platform's, not the model's: the MCP server stamps a shutdown
time on each sandbox it claims, so an abandoned one is reaped without anyone
asking. `delete_sandbox` stays authorized only as the agent's escape hatch for a
sandbox it can no longer drive.

Two consequences worth knowing:

- Each chart goes to a **new filename** (`chart1.png`, `chart2.png`, …). With a
  reused guest and a fixed name, a failed run would leave the previous chart in
  place and `download_file` would return the wrong image.
- A live session now **holds** a sandbox, and usable concurrency is roughly one
  sandbox per sandbox-capable node. Fine for one team per cluster; raise
  `replicas` on the warm pool before putting many concurrent analysts on one.

## Where the isolation lives

`terraform/manifests/agent-sandbox-template.yaml`, not in any code here:

- `runtimeClassName: isolated-sandbox` — a Nitro Sandbox micro-VM with its own
  guest kernel. VM size comes from `resources.requests`, not limits.
- `overhead: {eks.amazonaws.com/nitro-sandbox: "1", memory: 256Mi}` — claims the
  node's sandbox slot and the guest memory.
- `automountServiceAccountToken: false` — no Kubernetes credentials inside, and
  no AWS role is associated with the sandbox.
- `networkPolicy.ingress` admitting only the MCP server on sandboxd's ports
  8080/9090. **Supplying `networkPolicy` replaces the controller's secure
  defaults, and an omitted egress list denies all outbound** — the air gap here
  is a rule that is deliberately absent.
- `terminationGracePeriodSeconds: 0` — a lingering sandbox holds a scarce
  per-node slot.

## Images

| Image                            | Built from                                                                  |
| -------------------------------- | --------------------------------------------------------------------------- |
| `agent-sandbox-mcp-server:<ver>` | upstream `clients/integrations/mcp-server`                                  |
| `python-runtime-sandbox:v2`      | `python-runtime-sandbox/` — `FROM registry.k8s.io/.../sandboxd`, adds python3/pandas/matplotlib |

The MCP server is built from a shallow clone of the upstream repo at the pinned
version by `terraform/codebuild-images.tf`, because it is the one image upstream
does not publish. The runtime image's `FROM` base, `sandboxd`, IS published, so
it is pulled from `registry.k8s.io` at build time rather than mirrored.

`execute_command` runs in **sandboxd's own container**, so anything the
generated code imports has to be in `python-runtime-sandbox` — a neighbouring
container's tools are not reachable.

## Authorization

`policies/sandbox-tools-authz.yaml` gates every sandbox tool to the
sales-analyst persona, and module 700's `step3-differentiate.yaml` gates
`get_orders` the same way. Both rely on module 700's gateway-wide `mcp-authn`
policy for the JWT, so apply module 700 first or there is no `jwt` to read:

    kubectl apply -f policies/sandbox-tools-authz.yaml

**This is load-bearing, not lab decoration.** The upstream MCP server ships with
no authentication of its own — anything that reaches its port can create
sandboxes, run arbitrary commands and read/write files in every namespace its
ServiceAccount can touch. The ClusterIP-only Service and this policy are what
stand in front of that. Do not add a NodePort/LoadBalancer or an Ingress.

## Try it

Log into the chat UI as **sales-analyst** and ask:

> "Chart total sales by region for 2026-Q1."

As **support-associate**, agentgateway hides the sandbox tools from the
session's tool list, so the agent replies that it cannot run that analysis (no
visible error).

## Verify isolation

```bash
# A SandboxClaim appears on the first analysis and stays for the session.
kubectl get sandboxclaims,pods -n agent-sandbox -w

# The guest kernel differs from the node kernel (proof it is a real micro-VM):
kubectl exec -n agent-sandbox <sandbox-pod> -- uname -r
kubectl get node <node> -o jsonpath='{.status.nodeInfo.kernelVersion}'

# The node advertises the sandbox slot resource.
kubectl get node <node> -o jsonpath='{.status.allocatable.eks\.amazonaws\.com/nitro-sandbox}'
```

The air gap is best tested from inside, with code: ask the agent to reach
`https://aws.amazon.com` and watch DNS resolution fail.
