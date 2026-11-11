# mcp-server

MCP server that serves the order tools over the network.

Deployed by the **Agent tools with MCP** lab.

| Image           | Dockerfile   |
| --------------- | ------------ |
| `mcp-server:v2` | `Dockerfile` |

## Rebuilding this image

Every module image is built and pushed to Amazon ECR by a CodeBuild job at
provisioning time (`terraform/codebuild-images.tf`), so no lab waits on a
container build. You only need what follows if you have **changed the source in
this directory** and want the cluster to run your version.

The IDE is already set up for it: Docker is installed, every new shell refreshes
an ECR login (so there is no `docker login` step), and `$ACCOUNT_ID` and
`$AWS_REGION` are exported.

```bash
cd ~/environment/modules/500-agent-tools-mcp/mcp-server
REG=$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com
docker build --push --cache-from $REG/mcp-server:v2 -t $REG/mcp-server:v2 .
```

`--cache-from` reuses the layers already in ECR — the provisioning build
publishes an inline cache — so an unchanged `pip install` is not repeated. Drop
the flag to force a cold build.

Pushing over the same tag is enough: its Deployment sets `imagePullPolicy: Always`, so
restart it to pick the new image up.

```bash
kubectl rollout restart deployment/mcp-server
```

If you change a tag here, change it in `terraform/codebuild-images.tf` as well,
or the provisioning build and the manifests will disagree about which image to
use.
