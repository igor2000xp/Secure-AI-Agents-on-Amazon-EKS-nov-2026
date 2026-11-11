# agent-sandbox MCP server

Upstream `kubernetes-sigs/agent-sandbox` MCP server
(`clients/integrations/mcp-server`), which exposes the sandbox lifecycle to the
agent as MCP tools. Deployed by the **Agents using a sandbox** lab.

There is no source here — only `k8s.yaml`. The image is built from a shallow
clone of the upstream repo at the version pinned in
`terraform/manifests/vendor/sources.yaml`, by `terraform/codebuild-images.tf`.

| Image                            | Built from                                            |
| -------------------------------- | ----------------------------------------------------- |
| `agent-sandbox-mcp-server:<ver>` | upstream `clients/integrations/mcp-server/Dockerfile` |

## Rebuilding

Only needed to try a different upstream version. Bump `version` for
`agent-sandbox` in `sources.yaml`, run `scripts/vendor-manifests.sh sync` (so
the control-plane manifest matches), then:

```bash
git clone --depth 1 --branch <ver> https://github.com/kubernetes-sigs/agent-sandbox.git /tmp/as
REG=$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com
docker build --push -t $REG/agent-sandbox-mcp-server:<ver> /tmp/as/clients/integrations/mcp-server
```

The MCP server, the vendored control-plane manifest and the mirrored controller
image must all be the same version, which is why the version lives in one file.

After pushing, update the image tag in `k8s.yaml` and
`kubectl rollout restart deployment/agent-sandbox-mcp-server`.

## Configuration

Set via `K8S_SANDBOX_*` env vars in `k8s.yaml`. The connection is
`sandboxd-in-cluster` + `in-cluster-service`: the server resolves
`Sandbox.status.serviceFQDN` and talks to sandboxd's REST (8080) and gRPC (9090)
listeners directly. agent-sandbox v1 removed the sandbox-router, and the router
could not proxy gRPC anyway.

## Security

**This server has no authentication of its own.** Per upstream's README, any
client that reaches its port gets full access to every tool across every
namespace its ServiceAccount can touch. Two things contain it here:

1. The Service is ClusterIP and the only route is through agentgateway, which
   terminates the Cognito JWT and applies `policies/sandbox-tools-authz.yaml`.
2. Its Role is namespaced to sandbox objects in `agent-sandbox` — no
   `pods/exec`, no `pods/portforward`, no Secrets.

Do not add a NodePort/LoadBalancer Service or an Ingress to this Deployment.
