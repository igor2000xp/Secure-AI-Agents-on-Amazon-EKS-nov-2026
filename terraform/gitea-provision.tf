# Per-apply secrets for the bot + webhook (never match the public repo).
resource "random_password" "gitea_bot" {
  length  = 24
  special = false
}
resource "random_password" "gitea_participant" {
  length  = 20
  special = false
}
resource "random_password" "gitea_webhook_secret" {
  length  = 32
  special = false
}

locals {
  gitea_bot_user         = "coding-agent-bot"
  gitea_participant_user = "workshop-user"
  gitea_seed_repo        = "sample-app"
  gitea_trigger_label    = "agent"
  dispatcher_webhook_url = "http://coding-agent-dispatcher.default.svc.cluster.local:8080/webhook"
}

resource "null_resource" "gitea_provision" {
  triggers = {
    cluster_name = module.eks.cluster_name
    region       = local.region
    script_md5   = filemd5("${path.module}/scripts/gitea-provision.sh")
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      export KUBECONFIG="$(mktemp)"
      trap 'rm -f "$KUBECONFIG"' EXIT
      aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${local.region} --kubeconfig "$KUBECONFIG"
      kubectl -n gitea rollout status deployment/gitea --timeout=300s
      NS=gitea \
      ADMIN_USER=workshop-admin ADMIN_PASS='${random_password.gitea_admin.result}' \
      BOT_USER='${local.gitea_bot_user}' BOT_PASS='${random_password.gitea_bot.result}' \
      PARTICIPANT_USER='${local.gitea_participant_user}' PARTICIPANT_PASS='${random_password.gitea_participant.result}' \
      WEBHOOK_SECRET='${random_password.gitea_webhook_secret.result}' \
      DISPATCHER_WEBHOOK_URL='${local.dispatcher_webhook_url}' \
      SEED_REPO='${local.gitea_seed_repo}' TRIGGER_LABEL='${local.gitea_trigger_label}' \
      SEED_DIR='${path.module}/seed/sample-app' \
      bash ${path.module}/scripts/gitea-provision.sh
    EOT
  }

  depends_on = [helm_release.gitea, null_resource.gitea_tgb]
}

# Bot credentials + webhook secret for the dispatcher (the one machine credential
# the platform stores; consumed via secretKeyRef in the dispatcher Deployment).
resource "kubernetes_secret_v1" "coding_agent_creds" {
  metadata {
    name      = "coding-agent-creds"
    namespace = "default"
  }
  data = {
    "bot-username"   = local.gitea_bot_user
    "bot-password"   = random_password.gitea_bot.result
    "webhook-secret" = random_password.gitea_webhook_secret.result
    "repo-owner"     = local.gitea_participant_user
    "repo-name"      = local.gitea_seed_repo
    "trigger-label"  = local.gitea_trigger_label
  }
  depends_on = [module.eks]
}
