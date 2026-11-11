# customer-agent

Customer-service agent: the Strands loop with the `lookup_order` tool.

Deployed by the **Building your first agent** lab.

| Image                    | Dockerfile   |
| ------------------------ | ------------ |
| `customer-agent:strands` | `Dockerfile` |

## Rebuilding this image

Every module image is built and pushed to Amazon ECR by a CodeBuild job at
provisioning time (`terraform/codebuild-images.tf`), so no lab waits on a
container build. You only need what follows if you have **changed the source in
this directory** and want the cluster to run your version.

The IDE is already set up for it: Docker is installed, every new shell refreshes
an ECR login (so there is no `docker login` step), and `$ACCOUNT_ID` and
`$AWS_REGION` are exported.

```bash
cd ~/environment/modules/200-strands-agents/customer-agent
REG=$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com
docker build --push --cache-from $REG/customer-agent:strands -t $REG/customer-agent:strands .
```

`--cache-from` reuses the layers already in ECR — the provisioning build
publishes an inline cache — so an unchanged `pip install` is not repeated. Drop
the flag to force a cold build.

Pushing over the same tag is enough: its Deployment sets `imagePullPolicy: Always`, so
restart it to pick the new image up.

```bash
kubectl rollout restart deployment/customer-agent
```

If you change a tag here, change it in `terraform/codebuild-images.tf` as well,
or the provisioning build and the manifests will disagree about which image to
use.
