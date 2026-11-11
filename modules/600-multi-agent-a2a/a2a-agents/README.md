# a2a-agents

Three A2A specialist agents, one Dockerfile each. Module only — no lab deploys
these yet, so they exist in ECR but nothing in the cluster runs them.

| Image                   | Dockerfile                |
| ----------------------- | ------------------------- |
| `orchestrator-agent:v1` | `Dockerfile.orchestrator` |
| `order-agent:v1`        | `Dockerfile.order`        |
| `product-agent:v1`      | `Dockerfile.product`      |

## Rebuilding this image

Every module image is built and pushed to Amazon ECR by a CodeBuild job at
provisioning time (`terraform/codebuild-images.tf`), so no lab waits on a
container build. You only need what follows if you have **changed the source in
this directory** and want the cluster to run your version.

The IDE is already set up for it: Docker is installed, every new shell refreshes
an ECR login (so there is no `docker login` step), and `$ACCOUNT_ID` and
`$AWS_REGION` are exported.

```bash
cd ~/environment/modules/600-multi-agent-a2a/a2a-agents
REG=$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com
docker build --push --cache-from $REG/orchestrator-agent:v1 -t $REG/orchestrator-agent:v1 -f Dockerfile.orchestrator .
docker build --push --cache-from $REG/order-agent:v1 -t $REG/order-agent:v1 -f Dockerfile.order .
docker build --push --cache-from $REG/product-agent:v1 -t $REG/product-agent:v1 -f Dockerfile.product .
```

`--cache-from` reuses the layers already in ECR — the provisioning build
publishes an inline cache — so an unchanged `pip install` is not repeated. Drop
the flag to force a cold build.

Pushing over the same tag is enough: their Deployments set `imagePullPolicy: Always`, so
restart it to pick the new image up.

```bash
kubectl rollout restart deployment/orchestrator-agent
kubectl rollout restart deployment/order-agent
kubectl rollout restart deployment/product-agent
```

If you change a tag here, change it in `terraform/codebuild-images.tf` as well,
or the provisioning build and the manifests will disagree about which image to
use.
