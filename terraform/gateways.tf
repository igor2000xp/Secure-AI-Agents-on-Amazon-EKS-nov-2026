################################################################################
# LLM / Agent gateways
#
# Two additional gateways installed via the Helm provider, both cluster-internal:
#
#   - Envoy AI Gateway  — the OpenAI-compatible LLM gateway to Bedrock.
#                         Runs on the Envoy Gateway base layer.
#   - agentgateway      — an AI-native proxy for MCP tool servers and agent-to-
#                         agent (A2A) traffic.
#
# Both consume the upstream Kubernetes Gateway API CRDs. ALL CRDs (Gateway API,
# Envoy Gateway, Envoy AI Gateway, agentgateway) are installed once via
# null_resource.gateway_crds using `kubectl apply --server-side` — NOT Helm —
# because the CRD Helm charts exceed Helm's 1 MB release-Secret limit. The
# controller charts below install with their CRDs already present.
################################################################################

locals {
  # Bedrock runtime endpoint used by the Envoy AI Gateway Backend /
  # BackendTLSPolicy. Pinned to var.bedrock_region, NOT the cluster Region:
  # Bedrock is only available in us-east-1 / us-west-2 on the workshop platform,
  # but the cluster may run elsewhere. See the variable in base.tf.
  bedrock_runtime_host = "bedrock-runtime.${var.bedrock_region}.amazonaws.com"

  # Langfuse project keys — the single definition. Fixed workshop values, seeded
  # into Langfuse by LANGFUSE_INIT_PROJECT_* (langfuse.tf) and consumed by:
  # the langfuse-keys Secret the agents read (langfuse.tf) and observability.tf,
  # which builds the OTLP
  # Basic-auth header the shared OTel Collector uses to forward traces.
  langfuse_pk = "pk-lf-workshop"
  langfuse_sk = "sk-lf-workshop"

  # Shared OTel Collector's OTLP/HTTP traces endpoint (ADOT-operator-managed, see
  # observability.tf). Both gateways export here; the collector owns the Langfuse
  # credential and forwards. Service name = "<cr-name>-collector" in ns telemetry.
  otel_collector_http_traces_endpoint = "http://agentgateway-traces-collector.telemetry.svc.cluster.local:4318/v1/traces"
}

################################################################################
# CRDs — installed via `kubectl apply --server-side`, NOT Helm.
#
# Why not Helm: the CRD Helm charts (gateway-crds-helm, ai-gateway-crds-helm,
# agentgateway-crds) bundle multi-megabyte CRD schemas. Helm stores the whole
# release (chart + rendered manifest, gzipped) in a Secret capped at 1,048,576
# bytes — gateway-crds-helm alone blows it ("Secret ... is invalid: data: Too
# long"). Server-side apply writes the CRDs directly to the API server with no
# release Secret and no size limit. (--server-side also avoids the
# last-applied-configuration annotation size limit on large CRDs.)
#
# All CRD source files are plain YAML (verified: no Helm templating), pinned by
# version. This single resource owns ALL CRDs the gateways need — Gateway API +
# Envoy Gateway + Envoy AI Gateway + agentgateway — so the controller Helm
# releases below install with their own CRDs skipped.
################################################################################

locals {
  # All CRDs are VENDORED into terraform/manifests/vendor rather than fetched from
  # GitHub at apply time. They used to be applied straight from github.com /
  # raw.githubusercontent.com URLs, but GitHub rate-limits by source IP and a
  # Workshop Studio provision runs from CodeBuild behind a shared NAT egress
  # address, so a real event died on:
  #
  #   error: unable to read URL "https://raw.githubusercontent.com/envoyproxy/
  #   ai-gateway/v1.0.0/.../aigateway.envoyproxy.io_aigatewayroutes.yaml",
  #   server reported 429 Too Many Requests, status code=429
  #
  # 11 files fetched back-to-back meant 11 chances to trip a 429 per provision.
  # The files now ship inside terraform.zip and apply from disk — no GitHub in the
  # provisioning path at all.
  #
  # Versions are read out of sources.yaml so it stays the single place a version is
  # written down: bump it there, run scripts/vendor-manifests.sh sync, done. No
  # edit to this file is needed for a version bump.
  vendor_dir     = "${path.module}/manifests/vendor"
  vendor_sources = yamldecode(file("${local.vendor_dir}/sources.yaml")).projects

  # One directory per project/version; kubectl applies a whole directory at once.
  gateway_api_crd_dir   = "${local.vendor_dir}/gateway-api/${local.vendor_sources["gateway-api"].version}"
  envoy_gateway_crd_dir = "${local.vendor_dir}/envoy-gateway/${local.vendor_sources["envoy-gateway"].version}"
  ai_gateway_crd_dir    = "${local.vendor_dir}/envoy-ai-gateway/${local.vendor_sources["envoy-ai-gateway"].version}"
  agentgateway_crd_dir  = "${local.vendor_dir}/agentgateway/${local.vendor_sources["agentgateway"].version}"

  # Hash every vendored file so a re-vendor (or a version bump, which changes the
  # paths) re-triggers the apply.
  vendored_crds_hash = sha256(join("", [
    for f in sort(tolist(fileset(local.vendor_dir, "**/*.yaml"))) :
    filesha256("${local.vendor_dir}/${f}")
  ]))
}

resource "null_resource" "gateway_crds" {
  triggers = {
    cluster_name       = module.eks.cluster_name
    region             = local.region
    gateway_api_dir    = local.gateway_api_crd_dir
    envoy_gateway_dir  = local.envoy_gateway_crd_dir
    ai_gateway_dir     = local.ai_gateway_crd_dir
    agentgateway_dir   = local.agentgateway_crd_dir
    vendored_crds_hash = local.vendored_crds_hash
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      export KUBECONFIG="$(mktemp)"
      trap 'rm -f "$KUBECONFIG"' EXIT
      aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.region} --kubeconfig "$KUBECONFIG"
      # --validate=false on every CRD apply: kubectl's default client-side
      # validation first downloads the API server's aggregated OpenAPI doc. Each
      # batch of server-side-applied CRDs forces the API server to rebuild that
      # doc, and while it rebuilds the /openapi/v2 fetch can fail — kubectl then
      # falls back to the default localhost:8080 client and dies with
      # "failed to download openapi ... connect: connection refused". This was
      # intermittently failing fresh provisions on the AI-gateway batch (the
      # first CRDs to apply right after the big Envoy Gateway batch). Validation
      # is pointless for applying a CRD (it is a self-contained schema doc), so
      # turning it off removes the dependency on the openapi endpoint entirely.
      # All four batches come off local disk (see the vendoring note above). Each
      # -f takes a DIRECTORY: kubectl applies every YAML in it, so one command per
      # project instead of one per file.
      # Gateway API (experimental channel) + Envoy Gateway CRDs.
      kubectl apply --server-side --validate=false -f "${self.triggers.gateway_api_dir}"
      kubectl apply --server-side --validate=false -f "${self.triggers.envoy_gateway_dir}"
      # Envoy AI Gateway + agentgateway CRDs (vendored chart templates, plain YAML).
      kubectl apply --server-side --validate=false -f "${self.triggers.ai_gateway_dir}"
      kubectl apply --server-side --validate=false -f "${self.triggers.agentgateway_dir}"
      # Block until the CRDs are Established so dependent kubectl applies + Helm
      # releases don't race CRD registration.
      kubectl wait --for=condition=Established --timeout=120s \
        crd/gateways.gateway.networking.k8s.io \
        crd/aigatewayroutes.aigateway.envoyproxy.io \
        crd/backends.gateway.envoyproxy.io \
        crd/agentgatewaybackends.agentgateway.dev
    EOT
  }

  depends_on = [module.eks]
}

################################################################################
# Envoy Gateway (base layer for Envoy AI Gateway)
################################################################################

resource "helm_release" "envoy_gateway" {
  name             = "envoy-gateway"
  repository       = "oci://docker.io/envoyproxy"
  chart            = "gateway-helm"
  version          = "v1.8.1"
  namespace        = "envoy-gateway-system"
  create_namespace = true
  wait             = false
  timeout          = 600

  # Skip Helm's client-side schema check. See
  # module.eks_blueprints_addons_cert_manager in addons.tf.
  disable_openapi_validation = true

  # CRDs are installed by null_resource.gateway_crds (server-side apply); the
  # main chart has none in crds/ anyway. safeUpgradePolicy resources reference
  # Gateway API CRDs and are template-rendered, so disable them.
  skip_crds = true
  set {
    name  = "crds.gatewayAPI.safeUpgradePolicy.enabled"
    value = "false"
  }

  # REQUIRED for Envoy AI Gateway integration. The ai-gateway-helm chart only
  # installs the controller + extproc — it does NOT configure the base Envoy
  # Gateway. Envoy AI Gateway registers as an xDS extension server so it can
  # fine-tune the xDS Envoy Gateway generates (inject the ext_proc filter,
  # translate OpenAI→Bedrock, wire the Backend API). Without this block the
  # data-plane proxy comes up but is a PLAIN proxy that ignores every
  # AIGatewayRoute — all requests 404 and the extproc is never called.
  # Values mirror ai-gateway v1.0.0 manifests/envoy-gateway-values.yaml; the
  # service fqdn must point at the ai-gateway controller (port 1063).
  values = [yamlencode({
    config = {
      envoyGateway = {
        gateway = {
          controllerName = "gateway.envoyproxy.io/gatewayclass-controller"
        }
        logging  = { level = { default = "info" } }
        provider = { type = "Kubernetes" }
        extensionApis = {
          enableEnvoyPatchPolicy = true
          enableBackend          = true
        }
        extensionManager = {
          hooks = {
            xdsTranslator = {
              translation = {
                listener = { includeAll = true }
                route    = { includeAll = true }
                cluster  = { includeAll = true }
                secret   = { includeAll = true }
              }
              post = ["Translation", "Cluster", "Route"]
            }
          }
          service = {
            fqdn = {
              hostname = "ai-gateway-controller.envoy-ai-gateway-system.svc.cluster.local"
              port     = 1063
            }
          }
        }
      }
    }
  })]

  depends_on = [null_resource.gateway_crds]
}

################################################################################
# Envoy AI Gateway (controller)
#
# CRDs are installed by null_resource.gateway_crds; only the controller chart
# is installed here.
################################################################################

resource "helm_release" "envoy_ai_gateway" {
  name             = "aieg"
  repository       = "oci://docker.io/envoyproxy"
  chart            = "ai-gateway-helm"
  version          = "v1.0.0"
  namespace        = "envoy-ai-gateway-system"
  create_namespace = true
  wait             = false
  timeout          = 600

  # Skip Helm's client-side schema check. See
  # module.eks_blueprints_addons_cert_manager in addons.tf.
  disable_openapi_validation = true

  # Export the gateway's per-request LLM traces (OpenInference conventions) to
  # the shared OTel Collector, which forwards to Langfuse (see observability.tf).
  # Set on the extProc container, which processes each LLM request and owns the
  # tracing. The extProc reads incoming W3C traceparent, so when an instrumented
  # agent propagates its trace context the gateway span nests under the agent's
  # Langfuse trace; otherwise it starts its own root trace. Tracing is
  # best-effort — export failures never fail the proxied request (so no hard
  # depends_on the collector; a brief startup gap just drops spans).
  #
  # NOTE: exports to the collector's OTLP/HTTP receiver — NOT direct to Langfuse.
  # The collector owns the Langfuse Basic-auth credential (single egress point),
  # so no OTEL_EXPORTER_OTLP_TRACES_HEADERS here anymore.
  values = [yamlencode({
    extProc = {
      extraEnvVars = [
        { name = "OTEL_TRACES_EXPORTER", value = "otlp" },
        { name = "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", value = local.otel_collector_http_traces_endpoint },
        { name = "OTEL_SERVICE_NAME", value = "envoy-ai-gateway" },
      ]
    }
  })]

  depends_on = [
    null_resource.gateway_crds,
    helm_release.envoy_gateway,
  ]
}

################################################################################
# Envoy AI Gateway → Bedrock, via EKS Pod Identity
#
# The Envoy data plane assumes this role through the AWS default credential
# chain (no static keys). The ServiceAccount the proxy runs under is created by
# the manifest below; the Pod Identity association binds it to the role.
################################################################################

data "aws_iam_policy_document" "ai_gateway_bedrock_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ai_gateway_bedrock" {
  name               = "${local.name}-ai-gateway-bedrock"
  assume_role_policy = data.aws_iam_policy_document.ai_gateway_bedrock_trust.json
  tags               = local.tags
}

data "aws_iam_policy_document" "ai_gateway_bedrock" {
  statement {
    sid    = "BedrockModelInvoke"
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
      "bedrock:Converse",
      "bedrock:ConverseStream",
    ]
    # Invoking a cross-region ("us.") inference profile needs permission on both
    # the profile ARN *and* every foundation-model ARN the profile can route to,
    # in each region it fans out over. Granting only the profile ARNs yields
    # 403 AccessDenied on the foundation model.
    resources = [
      "arn:aws:bedrock:*:*:inference-profile/us.amazon.nova-micro-v1:0",
      "arn:aws:bedrock:*:*:inference-profile/us.amazon.nova-pro-v1:0",
      "arn:aws:bedrock:*:*:inference-profile/us.amazon.nova-2-lite-v1:0",
      "arn:aws:bedrock:*:*:inference-profile/us.anthropic.claude-sonnet-5-5",
      "arn:aws:bedrock:*:*:inference-profile/us.anthropic.claude-haiku-4-5-20251001-v1:0",
      "arn:aws:bedrock:*::foundation-model/amazon.nova-micro-v1:0",
      "arn:aws:bedrock:*::foundation-model/amazon.nova-pro-v1:0",
      "arn:aws:bedrock:*::foundation-model/amazon.nova-2-lite-v1:0",
      "arn:aws:bedrock:*::foundation-model/anthropic.claude-sonnet-5-5",
      "arn:aws:bedrock:*::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0",
    ]
  }

  # Anthropic Claude models on Bedrock are delivered through AWS Marketplace, so
  # the invoking principal must be able to see/accept the model subscription at
  # invoke time. Without these, Claude routes return 403 AccessDenied
  # ("not authorized to perform ... aws-marketplace:ViewSubscriptions, Subscribe")
  # even though bedrock:InvokeModel is granted. First-party models (Amazon Nova)
  # need none of this, which is why Nova works and Claude does not until added.
  statement {
    sid    = "BedrockMarketplaceModelAccess"
    effect = "Allow"
    actions = [
      "aws-marketplace:ViewSubscriptions",
      "aws-marketplace:Subscribe",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ai_gateway_bedrock" {
  name   = "ai-gateway-bedrock-inline"
  role   = aws_iam_role.ai_gateway_bedrock.id
  policy = data.aws_iam_policy_document.ai_gateway_bedrock.json
}

resource "aws_eks_pod_identity_association" "ai_gateway_bedrock" {
  cluster_name    = module.eks.cluster_name
  namespace       = "envoy-gateway-system"
  service_account = "ai-gateway-dataplane-aws"
  role_arn        = aws_iam_role.ai_gateway_bedrock.arn
}

# Gateway + AIGatewayRoute + AIServiceBackend + BackendSecurityPolicy + Backend
# wiring Envoy AI Gateway to Bedrock. Cluster-internal (ClusterIP) — no ALB.
#
# The CRs live in terraform/manifests/envoy-ai-gateway-bedrock.yaml as a static
# file (same pattern as the other manifests/ files): kept out of the heredoc so the
# YAML is readable and free of Terraform ${...} interpolation. Only __REGION__
# and __BEDROCK_HOST__ are templated, via sed. Applied with kubectl to avoid
# plan-time CRD lookups against the AI Gateway CRDs. Re-applies when the
# manifest changes (filemd5 trigger).
#
# Two DIFFERENT Regions are in play here, so they are separate triggers:
#   * `region`         — the CLUSTER Region, for `aws eks update-kubeconfig`.
#   * `bedrock_region` — where model calls go, substituted into __REGION__ as
#     the SigV4 signing region. Must match the host in __BEDROCK_HOST__.
# Collapsing these back into one value silently breaks EU deployments.
resource "null_resource" "envoy_ai_gateway_bedrock_route" {
  triggers = {
    cluster_name   = module.eks.cluster_name
    region         = local.region
    bedrock_region = var.bedrock_region
    bedrock_host   = local.bedrock_runtime_host
    manifest       = "${path.module}/manifests/envoy-ai-gateway-bedrock.yaml"
    manifest_md5   = filemd5("${path.module}/manifests/envoy-ai-gateway-bedrock.yaml")
  }

  provisioner "local-exec" {
    # bash (not the runner's default /bin/sh) for `set -o pipefail`.
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      export KUBECONFIG="$(mktemp)"
      trap 'rm -f "$KUBECONFIG"' EXIT
      aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.region} --kubeconfig "$KUBECONFIG"
      sed -e "s|__REGION__|${self.triggers.bedrock_region}|g" \
          -e "s|__BEDROCK_HOST__|${self.triggers.bedrock_host}|g" \
          "${self.triggers.manifest}" | kubectl apply -f -
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      export KUBECONFIG="$(mktemp)"
      trap 'rm -f "$KUBECONFIG"' EXIT
      aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.region} --kubeconfig "$KUBECONFIG" || exit 0
      kubectl delete backendtlspolicy bedrock-tls -n envoy-ai-gateway-system --ignore-not-found --timeout=60s || true
      kubectl delete backend bedrock -n envoy-ai-gateway-system --ignore-not-found --timeout=60s || true
      kubectl delete backendsecuritypolicy bedrock -n envoy-ai-gateway-system --ignore-not-found --timeout=60s || true
      kubectl delete aiservicebackend bedrock -n envoy-ai-gateway-system --ignore-not-found --timeout=60s || true
      kubectl delete aigatewayroute bedrock -n envoy-ai-gateway-system --ignore-not-found --timeout=60s || true
      kubectl delete gateway envoy-ai-gateway -n envoy-ai-gateway-system --ignore-not-found --timeout=60s || true
      kubectl delete envoyproxy ai-gateway-with-aws -n envoy-ai-gateway-system --ignore-not-found --timeout=60s || true
    EOT
  }

  depends_on = [
    helm_release.envoy_ai_gateway,
    aws_eks_pod_identity_association.ai_gateway_bedrock,
  ]
}

################################################################################
# agentgateway (MCP / A2A proxy)
#
# Terraform stands up the control plane + a base Gateway only. Concrete MCP and
# A2A routes target participant-deployed MCP servers / agents that do not exist
# at apply time, so those routes are authored during the workshop, not here.
################################################################################

# agentgateway CRDs are installed by null_resource.gateway_crds (server-side
# apply); only the controller chart is installed here.
resource "helm_release" "agentgateway" {
  name             = "agentgateway"
  repository       = "oci://cr.agentgateway.dev/charts"
  chart            = "agentgateway"
  version          = "v1.3.1"
  namespace        = "agentgateway-system"
  create_namespace = true
  wait             = false
  timeout          = 600

  # Skip Helm's client-side schema check. See
  # module.eks_blueprints_addons_cert_manager in addons.tf.
  disable_openapi_validation = true

  # Rename the CONTROLLER's resources to "agentgateway-controller". By default
  # the chart names the controller Deployment/Service "agentgateway" — the SAME
  # name the controller then wants for the DATA-PLANE PROXY Deployment it creates
  # for the Gateway named "agentgateway" (see the base Gateway below). Those two
  # collide: the controller tries to overwrite its own Deployment and fails with
  # an immutable spec.selector error, looping forever, so the proxy (and its :80
  # listener) never come up and no MCP/A2A traffic can route. fullnameOverride
  # frees the "agentgateway" name for the proxy; the controller's xDS Service name
  # derives from the same fullname helper, so it stays self-consistent. Every
  # client reference (parentRefs, the agentgateway.* Service DNS) targets the
  # PROXY, which is now correctly named "agentgateway".
  set {
    name  = "fullnameOverride"
    value = "agentgateway-controller"
  }

  depends_on = [null_resource.gateway_crds]
}

# Base Gateway so the agentgateway data plane is running. MCP/A2A HTTPRoutes and
# Backends are workshop content (the backends are participant-deployed).
#
# The Gateway is kept CLUSTER-INTERNAL via an AgentgatewayParameters overlay
# that forces the data-plane Service to ClusterIP. Without it, agentgateway
# provisions the data-plane Service as type LoadBalancer with no annotations,
# which makes EKS's in-tree cloud provider create a public *Classic* ELB —
# unintended exposure (the gateways are meant to be reachable only in-cluster,
# like langfuse go through guarded ALBs and these do not).
resource "null_resource" "agentgateway_base" {
  triggers = {
    cluster_name = module.eks.cluster_name
    region       = local.region
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      export KUBECONFIG="$(mktemp)"
      trap 'rm -f "$KUBECONFIG"' EXIT
      aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.region} --kubeconfig "$KUBECONFIG"
      kubectl apply -f - <<'YAML'
      apiVersion: agentgateway.dev/v1alpha1
      kind: AgentgatewayParameters
      metadata:
        name: cluster-internal
        namespace: agentgateway-system
      spec:
        service:
          spec:
            type: ClusterIP
      ---
      apiVersion: gateway.networking.k8s.io/v1
      kind: Gateway
      metadata:
        name: agentgateway
        namespace: agentgateway-system
      spec:
        gatewayClassName: agentgateway
        infrastructure:
          parametersRef:
            group: agentgateway.dev
            kind: AgentgatewayParameters
            name: cluster-internal
        listeners:
          - name: http
            protocol: HTTP
            port: 80
            allowedRoutes:
              namespaces:
                from: All
      YAML
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      export KUBECONFIG="$(mktemp)"
      trap 'rm -f "$KUBECONFIG"' EXIT
      aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.region} --kubeconfig "$KUBECONFIG" || exit 0
      kubectl delete gateway agentgateway -n agentgateway-system --ignore-not-found --timeout=60s || true
      kubectl delete agentgatewayparameters cluster-internal -n agentgateway-system --ignore-not-found --timeout=60s || true
    EOT
  }

  depends_on = [helm_release.agentgateway]
}
