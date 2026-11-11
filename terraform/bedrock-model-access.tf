# Enable Bedrock model access (foundation-model agreement / AWS Marketplace
# subscription) for the Anthropic Claude models the coding agent invokes through
# the Envoy AI Gateway /anthropic route. Without the subscription, those routes
# return 403 AccessDenied at invoke time even though the gateway's IAM role has
# bedrock:InvokeModel (see terraform/gateways.tf). Best-effort + idempotent: the
# script treats "already exists" as success and skips regions the account cannot
# use, so it never fails the apply. See scripts/bedrock-model-access.sh.
resource "null_resource" "bedrock_model_access" {
  triggers = {
    script_md5 = filemd5("${path.module}/scripts/bedrock-model-access.sh")
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "bash ${path.module}/scripts/bedrock-model-access.sh"
  }
}
