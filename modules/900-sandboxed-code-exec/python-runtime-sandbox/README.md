# python-runtime-sandbox

The runtime that runs INSIDE the Nitro Sandbox micro-VM — pandas, matplotlib,
and nothing that needs a network. The broker creates a pod from this image per
analysis run and releases it afterwards.

Deployed by the **Agents using a sandbox** lab.

| Image                       | Dockerfile   |
| --------------------------- | ------------ |
| `python-runtime-sandbox:v2` | `Dockerfile` |

## Rebuilding this image

Every module image is built and pushed to Amazon ECR by a CodeBuild job at
provisioning time (`terraform/codebuild-images.tf`), so no lab waits on a
container build. You only need what follows if you have **changed the source in
this directory** and want the cluster to run your version.

The IDE is already set up for it: Docker is installed, every new shell refreshes
an ECR login (so there is no `docker login` step), and `$ACCOUNT_ID` and
`$AWS_REGION` are exported.

```bash
cd ~/environment/modules/900-sandboxed-code-exec/python-runtime-sandbox
REG=$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com
# No --build-arg needed: the Dockerfile defaults SANDBOXD_IMAGE to the
# published registry.k8s.io/agent-sandbox/sandboxd image. Pass one only to pin a
# different agent-sandbox version than the Dockerfile's default.
docker build --push \
  --cache-from $REG/python-runtime-sandbox:v2 \
  -t $REG/python-runtime-sandbox:v2 .
```

`--cache-from` reuses the layers already in ECR — the provisioning build
publishes an inline cache — so an unchanged `pip install` is not repeated. Drop
the flag to force a cold build.

Nothing long-running uses this image, so there is nothing to restart. The next
sandbox created after your push uses the new layers — the pod spec sets
`imagePullPolicy: Always`, so pushing over the same tag is enough.

If you change a tag here, change it in `terraform/codebuild-images.tf` as well,
or the provisioning build and the manifests will disagree about which image to
use.
