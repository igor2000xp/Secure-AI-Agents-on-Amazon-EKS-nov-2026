# Vendored upstream manifests

Upstream Kubernetes CRDs, committed to this repo instead of downloaded during
provisioning.

## Why

`null_resource.gateway_crds` (gateways.tf) used to `kubectl apply -f <url>` these
11 files directly from `github.com` and `raw.githubusercontent.com`. GitHub rate
limits by source IP, and a Workshop Studio provision runs from CodeBuild behind a
shared NAT egress address, so a real event failed mid-apply:

```
error: unable to read URL "https://raw.githubusercontent.com/envoyproxy/ai-gateway/
v1.0.0/manifests/charts/ai-gateway-crds-helm/templates/
aigateway.envoyproxy.io_aigatewayroutes.yaml",
server reported 429 Too Many Requests, status code=429
```

Eleven sequential fetches meant eleven chances to trip a 429 on every provision,
and the failure lands early enough to take the whole apply with it. These files
now ship inside `terraform.zip` and apply from disk, so GitHub is not in the
provisioning path at all.

## Layout

```
sources.yaml                  # single source of truth: repo, version, files, URL template
sources.lock                  # sha256 of every vendored file (generated)
<project>/<version>/<file>    # e.g. gateway-api/v1.5.1/experimental-install.yaml
```

The version is in the directory path, so the tree is self-documenting and two
versions can sit side by side during an upgrade. `gateways.tf` reads the versions
out of `sources.yaml` with `yamldecode`, which makes `sources.yaml` the only place
a version is written down — bumping one needs no `.tf` edit.

`kubectl apply -f <dir>` applies every YAML in a directory, so each project is one
apply command regardless of how many files it ships.

## Updating a version

```bash
# 1. edit the `version:` for the project in sources.yaml
# 2. re-download and refresh the lock
scripts/vendor-manifests.sh sync
# 3. commit the new files, the removed old-version directory, and sources.lock
```

`sync` deletes other versions of a project it re-vendors, so a bump cannot leave a
stale directory behind (which would otherwise still get applied — `kubectl apply`
takes whole directories).

Other commands:

```bash
scripts/vendor-manifests.sh list     # show the pinned version of each project
scripts/vendor-manifests.sh verify   # re-hash local files against sources.lock, no network
```

`verify` is the one to run in CI or after a merge: it catches hand-edited or
truncated vendored files, and files on disk that the lock does not know about.

## Adding a project

Add an entry to `sources.yaml` with `repo`, `version`, `url_template` (using the
`{repo}` / `{version}` / `{file}` placeholders) and `files`, then run `sync`. To
have Terraform apply it, add a `local` for the directory in `gateways.tf`
alongside the existing four and a `kubectl apply` line for it.

## Not vendored (still fetched at runtime)

One GitHub download remains, outside the Terraform apply path. It carries the
same per-IP 429 exposure and is worth knowing about:

- **crane** (`codebuild-images.tf`) — the image-prebuild CodeBuild job pulls the
  `go-containerregistry` release tarball. Now wrapped in `curl --retry 5
  --retry-all-errors`, which covers 429, but it is still a GitHub dependency.

The sandbox runtime adds no GitHub dependency of its own: Nitro Sandboxes ship
with EKS Auto Mode, so no node downloads a runtime tarball at boot.
