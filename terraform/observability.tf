################################################################################
# Gateway trace observability → Langfuse (shared, cross-gateway)
#
# A single OTel Collector is the ONE authenticated egress to Langfuse for both
# gateways:
#   - Envoy AI Gateway extProc → collector (OTLP/HTTP :4318)   [see gateways.tf]
#   - agentgateway (MCP/A2A)   → collector (OTLP/gRPC :4317)   [AgentgatewayPolicy]
#
# Why a collector (not direct, like Envoy did in Phase B): agentgateway's
# AgentgatewayPolicy.frontend.tracing has NO header field (verified v1.3.1 CRD),
# so it cannot send the HTTP Basic auth that Langfuse's OTLP endpoint requires.
# The collector adds that header on egress; Envoy converges onto it so the
# Langfuse credential lives in exactly one place.
#
# The collector is managed by the ADOT operator (already installed as an EKS
# addon — operator only, no collector until this CR). We create an
# OpenTelemetryCollector CR and the operator runs the Deployment + Service.
#
# CR/Service naming + apiVersion (verified from authoritative sources; RE-VERIFY
# LIVE at deploy since no workshop cluster was reachable when authored):
#   - EKS default ADOT addon = v0.151.x → OTel operator serves
#     opentelemetry.io/v1beta1 as the stable OpenTelemetryCollector version.
#   - The operator names the managed Service "<cr-name>-collector", i.e.
#     "agentgateway-traces-collector" in ns "telemetry".
#   Re-check: `kubectl get crd opentelemetrycollectors.opentelemetry.io
#   -o jsonpath='{.spec.versions[*].name}'` and `kubectl get svc -n telemetry`.
################################################################################

resource "kubernetes_namespace_v1" "telemetry" {
  metadata {
    name = "telemetry"
  }

  depends_on = [module.eks, kubernetes_config_map_v1.network_policy]
}

# Apply the OpenTelemetryCollector CR + the agentgateway tracing policy.
#
# Ordering (all enforced below): the ADOT operator installs asynchronously, so
# we WAIT for its CRD to be Established before applying the CR (same race class
# as the gateway CRDs). We then wait for the operator-created collector
# Deployment to be Available BEFORE applying the AgentgatewayPolicy, so the
# policy never points agentgateway at an endpoint-less Service.
#
# __LANGFUSE_AUTH__ is substituted with base64("<pk>:<sk>") via sed (same
# placeholder pattern as __REGION__ in envoy-ai-gateway-bedrock.yaml).
resource "null_resource" "otel_collector" {
  triggers = {
    cluster_name  = module.eks.cluster_name
    region        = local.region
    langfuse_auth = base64encode("${local.langfuse_pk}:${local.langfuse_sk}")
    manifest      = "${path.module}/manifests/otel-collector-langfuse.yaml"
    manifest_md5  = filemd5("${path.module}/manifests/otel-collector-langfuse.yaml")
  }

  provisioner "local-exec" {
    # bash (not the runner's default /bin/sh) for `set -o pipefail`.
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      export KUBECONFIG="$(mktemp)"
      trap 'rm -f "$KUBECONFIG"' EXIT
      aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.region} --kubeconfig "$KUBECONFIG"

      # 1. Wait for the ADOT operator's CRD before applying the CR (async addon).
      #    `kubectl wait` errors NotFound (and aborts under set -e) if the CRD
      #    isn't REGISTERED yet — it only waits on the condition of an existing
      #    resource, not for the resource to appear. The ADOT managed addon
      #    installs this CRD asynchronously, so first poll until it EXISTS, then
      #    wait for it to be Established.
      crd=crd/opentelemetrycollectors.opentelemetry.io
      for i in $(seq 1 30); do
        if kubectl get "$crd" >/dev/null 2>&1; then break; fi
        echo "  waiting for $crd to be registered (attempt $i/30)..."
        sleep 10
      done
      kubectl wait --for=condition=Established --timeout=120s "$crd"

      # 2. Render (inject the Langfuse Basic-auth blob) and apply the collector CR.
      #    Split the manifest at the '---' so we can apply the CR first, wait for
      #    the operator to bring it up, THEN apply the AgentgatewayPolicy.
      sed "s|__LANGFUSE_AUTH__|${self.triggers.langfuse_auth}|g" \
        "${self.triggers.manifest}" > /tmp/otel-collector-rendered.yaml

      # OpenTelemetryCollector CR (first doc).
      awk 'BEGIN{d=0} /^---$/{d++; next} d==0{print}' /tmp/otel-collector-rendered.yaml \
        | kubectl apply -f -

      # 3. Wait for the operator-created collector Deployment to be Available.
      #    The ADOT operator reconciles the CR into a Deployment ASYNCHRONOUSLY,
      #    so the Deployment does not exist the instant `kubectl apply` returns.
      #    `kubectl wait` errors NotFound (and aborts under set -e) on a resource
      #    that isn't there yet — same race class as the CRD in step 1 — so poll
      #    until the Deployment EXISTS, THEN wait for it to be Available.
      dep=deploy/agentgateway-traces-collector
      for i in $(seq 1 30); do
        if kubectl get "$dep" -n telemetry >/dev/null 2>&1; then break; fi
        echo "  waiting for $dep to be created by the operator (attempt $i/30)..."
        sleep 10
      done
      kubectl wait --for=condition=Available --timeout=180s \
        -n telemetry deploy/agentgateway-traces-collector

      # 4. AgentgatewayPolicy (second doc) — now the collector Service has endpoints.
      awk 'BEGIN{d=0} /^---$/{d++; next} d==1{print}' /tmp/otel-collector-rendered.yaml \
        | kubectl apply -f -
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      export KUBECONFIG="$(mktemp)"
      trap 'rm -f "$KUBECONFIG"' EXIT
      aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.region} --kubeconfig "$KUBECONFIG" || exit 0
      kubectl delete agentgatewaypolicy tracing -n agentgateway-system --ignore-not-found --timeout=60s || true
      kubectl delete opentelemetrycollector agentgateway-traces -n telemetry --ignore-not-found --timeout=60s || true
    EOT
  }

  depends_on = [
    kubernetes_namespace_v1.telemetry,
    # Operator installed, target Gateway exists, Langfuse ready to receive.
    aws_eks_addon.adot,
    null_resource.agentgateway_base,
    null_resource.langfuse_wait_and_enable,
  ]
}
