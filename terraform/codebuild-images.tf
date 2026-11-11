################################################################################
# Pre-build module container images via CodeBuild
#
# Motivation: every lab has participants run essentially the same
# `docker build --push` against the customer-agent / mcp-server / *-agent ECR
# repos, just with a different module tag. After the first lab that build step is
# repetitive friction, and a fresh event has NO images in ECR until someone
# builds them (the kubectl-apply manifests reference tags like
# customer-agent:mcp / mcp-server:v1 that would not exist yet). This builds all
# module images up front so the labs are turnkey (kubectl apply just pulls),
# while the lab content keeps the build step as an optional exercise.
#
# Why CodeBuild (not local docker / null_resource): the Terraform host (the CDK
# Terraform Runner / browser IDE) may not have a usable Docker daemon. CodeBuild
# runs the builds in AWS with a privileged Docker environment, so provisioning
# only needs the AWS CLI, which is already a hard dependency.
#
# The matrix below MUST stay in sync with the `image:` refs in the module
# k8s manifests (modules/**/k8s*.yaml).
################################################################################

variable "prebuild_images" {
  description = "Build and push all module container images into ECR at provision time via CodeBuild."
  type        = bool
  default     = true
}

variable "modules_zip_s3_uri" {
  description = <<-EOT
    S3 URI (s3://bucket/key) of the published modules.zip. In the real workshop
    this is injected by the CDK Terraform Runner (TF_VAR_modules_zip_s3_uri) and
    points at the assets bucket. When empty (e.g. local `terraform apply`),
    Terraform zips ../modules and uploads it to a bucket it creates instead.
  EOT
  type        = string
  default     = ""
}

locals {
  # The directory containing all module source (Dockerfiles + app code).
  modules_dir = "${path.module}/../modules"

  ecr_registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${local.region}.amazonaws.com"

  # When a modules.zip S3 URI is supplied (workshop runner), the CodeBuild job
  # pulls it from S3. Otherwise (local dev) we zip ../modules and upload it.
  use_s3_source = var.modules_zip_s3_uri != ""

  # Final S3 URI the buildspec downloads module source from.
  modules_zip_uri = local.use_s3_source ? var.modules_zip_s3_uri : try("s3://${aws_s3_bucket.image_build_source[0].bucket}/${aws_s3_object.modules_src[0].key}", "")

  # Bucket name + ARN parsed from the URI, used to scope the CodeBuild read
  # permission for either source mode.
  modules_src_bucket     = local.use_s3_source ? split("/", replace(var.modules_zip_s3_uri, "s3://", ""))[0] : try(aws_s3_bucket.image_build_source[0].bucket, "")
  modules_src_bucket_arn = "arn:${data.aws_partition.current.partition}:s3:::${local.modules_src_bucket}"

  # Image build matrix: one entry per `docker build --push` in the lab content.
  # context    = path under modules/ holding the Dockerfile + sources
  # repo       = ECR repository (must exist in ecr.tf)
  # tag        = module-specific image tag
  # dockerfile = filename when not the default "Dockerfile"
  #
  # Every tag here MUST match the `image:` refs in the module k8s manifests.
  image_builds = {
    "customer-agent:strands" = {
      context = "200-strands-agents/customer-agent"
      repo    = "customer-agent"
      tag     = "strands"
    }
    "customer-agent:langfuse" = {
      context = "300-observability-langfuse/customer-agent"
      repo    = "customer-agent"
      tag     = "langfuse"
    }
    "mcp-server:v2" = {
      context = "500-agent-tools-mcp/mcp-server"
      repo    = "mcp-server"
      tag     = "v2"
    }
    "customer-agent:mcp" = {
      context = "500-agent-tools-mcp/customer-agent"
      repo    = "customer-agent"
      tag     = "mcp"
    }
    "order-agent:v1" = {
      context    = "600-multi-agent-a2a/a2a-agents"
      repo       = "order-agent"
      tag        = "v1"
      dockerfile = "Dockerfile.order"
    }
    "product-agent:v1" = {
      context    = "600-multi-agent-a2a/a2a-agents"
      repo       = "product-agent"
      tag        = "v1"
      dockerfile = "Dockerfile.product"
    }
    "orchestrator-agent:v1" = {
      context    = "600-multi-agent-a2a/a2a-agents"
      repo       = "orchestrator-agent"
      tag        = "v1"
      dockerfile = "Dockerfile.orchestrator"
    }
    # Tag bumped v0.5.3 -> v1 to match the migrated module 900 manifest
    # (referenced by terraform/manifests/agent-sandbox-template.yaml as the
    # = .../python-runtime-sandbox:v1). v0.5.3 set MPLCONFIGDIR so matplotlib
    # stops warning about the unwritable /.config; v0.5.2 added matplotlib so
    # LLM-written analysis code can render charts to /app/chart.png, read back
    # and shown inline in the UI; v0.5.1 added tabulate (pandas to_markdown dep).
    # Bump the tag on runtime changes: sandbox pods pull IfNotPresent, so an
    # overwritten tag never reaches nodes that have the old image cached.
    # v2: rebuilt FROM the sandboxd image instead of python:3.11-slim. The
    # FastAPI server on :8888 is gone — the agent-sandbox MCP server drives
    # sandboxd's REST/gRPC listeners instead, and exec'd commands run in this
    # image, so it carries python3 + pandas + matplotlib and nothing else.
    # SANDBOXD_IMAGE is overridden here so the base tracks the agent-sandbox
    # version in manifests/vendor/sources.yaml rather than the Dockerfile's
    # default.
    "python-runtime-sandbox:v2" = {
      context = "900-sandboxed-code-exec/python-runtime-sandbox"
      repo    = "python-runtime-sandbox"
      tag     = "v2"
      build_args = {
        SANDBOXD_IMAGE = "registry.k8s.io/agent-sandbox/sandboxd:${local.vendor_sources["agent-sandbox"].version}"
      }
    }
    "customer-agent:code-exec" = {
      context = "500-agent-tools-mcp/customer-agent"
      repo    = "customer-agent"
      tag     = "code-exec"
    }
    # module 1000: coding runtime (sandboxd + Claude Code) + the dispatcher.
    # The runtime tag has to match terraform/manifests/agent-sandbox-coding-template.yaml
    # (the SandboxTemplate names the image now, not a dispatcher SANDBOX_IMAGE
    # env var); the dispatcher tag has to match
    # modules/1000-autonomous-coding-agent/coding-agent-dispatcher/k8s.yaml.
    # runtime v2: pre-bakes pytest+httpx. dispatcher v7: run.sh gained the global
    # gitignore guard, pytest-summary-in-PR, the </dev/null stdin fix for headless
    # Claude Code, a push gate that works whether Claude commits its own work or
    # the wrapper commits, plus two further dispatcher bug fixes (v6, v7).
    # dispatcher v7: blocker reporting — the task prompt tells the agent to write
    # /work/BLOCKED.md and post it to the issue via the injected
    # report-blocked.sh, run.sh posts the transcript tail if the agent did not,
    # and the dispatcher's own fallback comment now tails stdout instead of
    # stderr (it was reliably showing git clone progress). The two images version
    # independently.
    "coding-runtime-sandbox:v5" = {
      context = "1000-autonomous-coding-agent/coding-runtime-sandbox"
      repo    = "coding-runtime-sandbox"
      tag     = "v5"
      build_args = {
        SANDBOXD_IMAGE = "registry.k8s.io/agent-sandbox/sandboxd:${local.vendor_sources["agent-sandbox"].version}"
      }
    }
    "coding-agent-dispatcher:v7" = {
      context = "1000-autonomous-coding-agent/coding-agent-dispatcher"
      repo    = "coding-agent-dispatcher"
      tag     = "v7"
    }
  }
}

################################################################################
# Source bundle (local-dev fallback only): zip modules/ and upload to S3.
# Skipped when modules_zip_s3_uri is provided (the workshop runner path), since
# the runner has no ../modules directory next to the Terraform code.
################################################################################

resource "aws_s3_bucket" "image_build_source" {
  count = var.prebuild_images && !local.use_s3_source ? 1 : 0

  bucket        = "${local.name}-image-build-src-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = local.tags
}

resource "aws_s3_bucket_public_access_block" "image_build_source" {
  count = var.prebuild_images && !local.use_s3_source ? 1 : 0

  bucket                  = aws_s3_bucket.image_build_source[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Zip the modules directory. archive_file recomputes the hash on every plan,
# so edits to module source produce a new object and re-trigger the build.
data "archive_file" "modules" {
  count = var.prebuild_images && !local.use_s3_source ? 1 : 0

  type        = "zip"
  source_dir  = local.modules_dir
  output_path = "${path.module}/.terraform/tmp/modules-src.zip"
}

resource "aws_s3_object" "modules_src" {
  count = var.prebuild_images && !local.use_s3_source ? 1 : 0

  bucket = aws_s3_bucket.image_build_source[0].id
  key    = "modules-src-${data.archive_file.modules[0].output_md5}.zip"
  source = data.archive_file.modules[0].output_path
  etag   = data.archive_file.modules[0].output_md5
  tags   = local.tags
}

################################################################################
# IAM role for CodeBuild: ECR push + CloudWatch Logs + read source bucket
################################################################################

data "aws_iam_policy_document" "codebuild_assume" {
  count = var.prebuild_images ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codebuild_images" {
  count = var.prebuild_images ? 1 : 0

  name               = "${local.name}-image-prebuild"
  assume_role_policy = data.aws_iam_policy_document.codebuild_assume[0].json
  tags               = local.tags
}

data "aws_iam_policy_document" "codebuild_images" {
  count = var.prebuild_images ? 1 : 0

  # ECR auth token is account-wide (no resource scoping possible).
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # Push/pull scoped to the workshop repos created in ecr.tf.
  statement {
    sid    = "EcrPushPull"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [for r in aws_ecr_repository.this : r.arn]
  }

  statement {
    sid    = "Logs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:${data.aws_partition.current.partition}:logs:${local.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${local.name}-image-prebuild*"]
  }

  statement {
    sid       = "SourceBucket"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${local.modules_src_bucket_arn}/*"]
  }
}

resource "aws_iam_role_policy" "codebuild_images" {
  count = var.prebuild_images ? 1 : 0

  name   = "image-prebuild"
  role   = aws_iam_role.codebuild_images[0].id
  policy = data.aws_iam_policy_document.codebuild_images[0].json
}

# IAM is eventually consistent. PutRolePolicy returns as soon as the API accepts
# the document, but the permissions are not immediately visible to the service
# that evaluates the assumed-role session. `depends_on` orders the API calls; it
# cannot order propagation.
#
# This bites here specifically because the FIRST thing a CodeBuild build does is
# create its log group and stream, so a propagation lag surfaces as
#
#   AccessDeniedException: ... not authorized to perform: logs:CreateLogStream
#
# which reads as a missing policy even though the policy is present and correct.
# The build then fails immediately and takes the apply down with it.
#
# A short wait between writing the policy and starting the build is the standard
# remedy. 30s is well past the propagation times observed in practice, and it is
# paid once per apply (only when prebuild_images is on), not per image.
resource "time_sleep" "codebuild_iam_propagation" {
  count = var.prebuild_images ? 1 : 0

  create_duration = "30s"

  depends_on = [aws_iam_role_policy.codebuild_images]
}

################################################################################
# CodeBuild project: builds + pushes every image in local.image_builds
################################################################################

resource "aws_codebuild_project" "images" {
  count = var.prebuild_images ? 1 : 0

  name         = "${local.name}-image-prebuild"
  description  = "Pre-builds all workshop module container images and pushes them to ECR."
  service_role = aws_iam_role.codebuild_images[0].arn

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type    = "BUILD_GENERAL1_MEDIUM"
    image           = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true # required for Docker builds

    environment_variable {
      name  = "ECR_REGISTRY"
      value = local.ecr_registry
    }
    environment_variable {
      name  = "AWS_DEFAULT_REGION"
      value = local.region
    }
    environment_variable {
      name  = "MODULES_ZIP_URI"
      value = local.modules_zip_uri
    }
  }

  source {
    type      = "NO_SOURCE"
    buildspec = local.image_buildspec
  }

  tags = local.tags
}

# Buildspec generated from the image matrix. The module source is pulled from
# S3 (aws s3 cp works cross-region, unlike a native CodeBuild S3 source) and
# unzipped to /tmp/modules. Each image is then built + pushed from there.
locals {
  # Every build and mirror is RETRIED. These commands pull from public networks
  # (PyPI, npm, Debian, Docker Hub, registry.k8s.io), and a single transient
  # upstream hiccup otherwise fails the whole provision: an observed run died on
  # "Could not install packages due to an OSError ... too many 502 error responses"
  # from files.pythonhosted.org, which took down the entire apply because
  # agent_sandbox and gitea both depend on this resource. pip's own --retries did
  # not help (PyPI kept 502ing), so the retry has to wrap the whole build.
  image_retry_prefix = "for attempt in 1 2 3; do "
  image_retry_suffix = " && break; if [ \"$attempt\" = 3 ]; then echo 'FAILED after 3 attempts'; exit 1; fi; echo \"attempt $attempt failed, retrying in 20s...\"; sleep 20; done"

  # `--cache-to type=inline` embeds the build-cache manifest in the pushed image.
  # The labs have participants rebuild these same images on the IDE, and their
  # `docker build --cache-from <ref>` can only reuse layers if the image in ECR
  # carries that manifest. Without it the participant pays a full `pip install`
  # (pandas/matplotlib, and the fastembed model download) on every build.
  #
  # Inline cache only records the final stage, which is all the labs need. It
  # costs nothing at provision time and does not change the image's runtime
  # contents, only its metadata.
  #
  # `docker buildx build` rather than `docker build`: the pre_build phase runs
  # `docker buildx create --use`, so this already went through BuildKit, but
  # naming buildx explicitly keeps `--cache-to` valid regardless of whether the
  # CodeBuild image aliases the legacy `docker build` CLI to buildx.
  image_build_lines = [
    for name, b in local.image_builds :
    "${local.image_retry_prefix}docker buildx build --push --cache-to type=inline -t $ECR_REGISTRY/${b.repo}:${b.tag}${join("", [for k, v in lookup(b, "build_args", {}) : " --build-arg ${k}=${v}"])} -f /tmp/modules/${b.context}/${lookup(b, "dockerfile", "Dockerfile")} /tmp/modules/${b.context}${local.image_retry_suffix}"
  ]

  ##############################################################################
  # Images built FROM UPSTREAM SOURCE (agent-sandbox), not from modules/
  #
  # Only ONE image needs this: the agent-sandbox MCP server
  # (clients/integrations/mcp-server), which upstream does not publish — the
  # release carries only sandbox.yaml / extensions.yaml /
  # sandbox-with-extensions.yaml, and registry.k8s.io has no mcp-server image.
  #
  # sandboxd used to be built here too. It is published as
  # registry.k8s.io/agent-sandbox/sandboxd:<version> from v1.0.10, so the two
  # runtime images just use it as their FROM base and the clone no longer has to
  # produce it. That also removes the ordering constraint that the sandboxd build
  # had to finish before the modules/ builds started.
  #
  # Version comes from manifests/vendor/sources.yaml, the single place an
  # agent-sandbox version is written down, so the clone, the vendored manifest,
  # the mirrored controller and the sandboxd base can never drift apart.
  ##############################################################################
  agent_sandbox_clone_dir = "/tmp/agent-sandbox-src"

  agent_sandbox_source_builds = [
    # rm -rf first: the retry wrapper re-runs this command, and `git clone` into
    # a non-empty directory fails, so a transient network error on attempt 1
    # would otherwise turn into three guaranteed failures.
    "rm -rf ${local.agent_sandbox_clone_dir} && git clone --depth 1 --branch ${local.agent_sandbox_version} https://github.com/kubernetes-sigs/agent-sandbox.git ${local.agent_sandbox_clone_dir}",
    # MCP server: context = its own directory.
    "docker buildx build --push --cache-to type=inline -t $ECR_REGISTRY/agent-sandbox-mcp-server:${local.agent_sandbox_version} ${local.agent_sandbox_clone_dir}/clients/integrations/mcp-server",
  ]

  agent_sandbox_source_lines = [
    for c in local.agent_sandbox_source_builds :
    "${local.image_retry_prefix}${c}${local.image_retry_suffix}"
  ]

  # Upstream images to mirror into ECR (pinned tags), so runtime pulls never hit
  # registry.k8s.io / GCP / Docker Hub. crane copies without a local daemon.
  image_mirror_commands = [
    # agent-sandbox control plane. The vendored manifest points at
    # registry.k8s.io; agent-sandbox.tf rewrites it to this mirror so no node
    # pulls from registry.k8s.io at runtime. Only ONE image in v1.x — the
    # sandbox-router that v0.5.0 needed no longer exists.
    #
    # Tag read straight from manifests/vendor/sources.yaml, so a version bump
    # cannot leave this mirroring a tag the manifest no longer references.
    "crane copy registry.k8s.io/agent-sandbox/agent-sandbox-controller:${local.vendor_sources["agent-sandbox"].version} $ECR_REGISTRY/agent-sandbox-controller:${local.vendor_sources["agent-sandbox"].version}",
    # module 1000: mirror the Gitea image so the Helm release pulls from ECR.
    # Both tags: the chart default (rootless=true) pulls the "-rootless" variant;
    # the plain tag is kept for rootless=false setups.
    "crane copy docker.io/gitea/gitea:1.24.3 $ECR_REGISTRY/gitea:1.24.3",
    "crane copy docker.io/gitea/gitea:1.24.3-rootless $ECR_REGISTRY/gitea:1.24.3-rootless",
  ]

  image_mirror_lines = [
    for c in local.image_mirror_commands :
    "${local.image_retry_prefix}${c}${local.image_retry_suffix}"
  ]

  image_buildspec = yamlencode({
    version = "0.2"
    phases = {
      pre_build = {
        commands = [
          "echo Logging in to ECR...",
          "aws ecr get-login-password --region $AWS_DEFAULT_REGION | docker login --username AWS --password-stdin $ECR_REGISTRY",
          # crane comes from a GitHub release, so it is exposed to the same
          # per-IP 429 that broke the CRD fetches (this runs from CodeBuild's
          # shared NAT egress). --retry-all-errors covers 429/5xx, not just
          # connection failures.
          "curl -sSL --fail --retry 5 --retry-delay 3 --retry-all-errors https://github.com/google/go-containerregistry/releases/download/v0.20.2/go-containerregistry_Linux_x86_64.tar.gz | tar -xz -C /usr/local/bin crane",
          "docker buildx create --use --name workshop-builder || docker buildx use workshop-builder",
          "echo \"Fetching module source from $MODULES_ZIP_URI\"",
          "aws s3 cp \"$MODULES_ZIP_URI\" /tmp/modules.zip",
          "rm -rf /tmp/modules && mkdir -p /tmp/modules",
          "unzip -q /tmp/modules.zip -d /tmp/modules",
        ]
      }
      build = {
        commands = concat(
          ["echo Mirroring ${length(local.image_mirror_lines)} upstream images..."],
          local.image_mirror_lines,
          # Must precede the modules/ builds: the sandbox runtime image is built
          # FROM the published sandboxd image, no longer built here.
          ["echo Building ${length(local.agent_sandbox_source_lines) - 1} images from agent-sandbox ${local.agent_sandbox_version} source..."],
          local.agent_sandbox_source_lines,
          ["echo Building ${length(local.image_build_lines)} images..."],
          local.image_build_lines,
        )
      }
      post_build = {
        commands = ["echo All images built and pushed."]
      }
    }
  })
}

################################################################################
# Trigger the build during apply and wait for it to finish.
#
# Re-runs whenever the module source bundle changes (the S3 key embeds the
# content hash). Depends on the ECR repos so push targets exist.
################################################################################

resource "null_resource" "build_images" {
  count = var.prebuild_images ? 1 : 0

  triggers = {
    # In S3-source mode the URI changes when a new modules.zip is published;
    # in local mode the archive hash changes when ../modules changes.
    source_ref     = local.use_s3_source ? var.modules_zip_s3_uri : data.archive_file.modules[0].output_md5
    project        = aws_codebuild_project.images[0].name
    buildspec_hash = sha1(local.image_buildspec)
  }

  provisioner "local-exec" {
    interpreter = ["/usr/bin/env", "bash", "-c"]
    command     = "bash ${path.module}/scripts/run-codebuild.sh ${aws_codebuild_project.images[0].name} ${local.region}"
  }

  depends_on = [
    aws_ecr_repository.this,
    aws_codebuild_project.images,
    aws_iam_role_policy.codebuild_images,
    # Not redundant with the line above: this waits for the policy to PROPAGATE,
    # not just to be written. See the resource's comment.
    time_sleep.codebuild_iam_propagation,
  ]
}
