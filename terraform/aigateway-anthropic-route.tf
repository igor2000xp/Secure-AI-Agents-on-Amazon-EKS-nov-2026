# Applies the Anthropic-input AIGatewayRoute (module 1000). Depends on the
# bedrock route (which creates the Gateway + AIServiceBackend this route reuses).
resource "null_resource" "envoy_ai_gateway_anthropic_route" {
  triggers = {
    cluster_name = module.eks.cluster_name
    region       = local.region
    manifest     = "${path.module}/manifests/envoy-ai-gateway-anthropic.yaml"
    manifest_md5 = filemd5("${path.module}/manifests/envoy-ai-gateway-anthropic.yaml")
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      export KUBECONFIG="$(mktemp)"
      trap 'rm -f "$KUBECONFIG"' EXIT
      aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.region} --kubeconfig "$KUBECONFIG"
      kubectl apply -f "${self.triggers.manifest}"
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      export KUBECONFIG="$(mktemp)"
      trap 'rm -f "$KUBECONFIG"' EXIT
      aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.region} --kubeconfig "$KUBECONFIG" || exit 0
      kubectl delete aigatewayroute bedrock-anthropic -n envoy-ai-gateway-system --ignore-not-found --timeout=60s || true
    EOT
  }

  depends_on = [null_resource.envoy_ai_gateway_bedrock_route]
}
