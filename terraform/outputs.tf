output "configure_kubectl" {
  description = "Configure kubectl: make sure you're logged in with the correct AWS profile and run the following command to update your kubeconfig"
  value       = "aws eks --region ${local.region} update-kubeconfig --name ${module.eks.cluster_name}"
}

output "ecr_repository_urls" {
  description = "Map of ECR repository name to repository URL for the self-managed track"
  value       = { for name, repo in aws_ecr_repository.this : name => repo.repository_url }
}

output "orders_table_name" {
  description = "DynamoDB table holding workshop order data (read by agent pods via Pod Identity)"
  value       = aws_dynamodb_table.orders.name
}

################################################################################
# Chat UI (Cognito-authenticated, via CloudFront)
################################################################################

output "chat_ui_url" {
  description = "Public HTTPS URL for the Chainlit chat UI (participant entry point). Sign in with one of the persona Cognito users."
  value       = "https://${aws_cloudfront_distribution.chainlit.domain_name}"
}

# Per-persona logins. Keys are the Cognito usernames / group names
# (sales-analyst, support-associate); values are their passwords.
output "chat_ui_usernames" {
  description = "Cognito usernames for the chat UI personas (also their group names)"
  value       = { for k, u in aws_cognito_user.persona : k => u.username }
}

output "chat_ui_passwords" {
  description = "Cognito passwords per persona username"
  value       = { for k, p in random_password.persona : k => p.result }
  sensitive   = true
}

output "cognito_hosted_ui_domain" {
  description = "Cognito Hosted UI URL backing the chat UI login"
  value       = "https://${local.cognito_hosted_ui_domain}"
}

# JWT validation inputs for the agentgateway persona-authz lab
# (700-agentgateway-authz). The lab substitutes these into the
# AgentgatewayPolicy jwtAuthentication provider (__COGNITO_ISSUER__ etc.).
output "cognito_issuer" {
  description = "Cognito JWT issuer (iss claim) — https://cognito-idp.<region>.amazonaws.com/<pool-id>"
  value       = "https://cognito-idp.${local.region}.amazonaws.com/${aws_cognito_user_pool.workshop.id}"
}

# agentgateway reaches the JWKS via a static Backend (host+port) + jwksPath, not
# a single URL — so the JWKS endpoint is split into host and path outputs.
output "cognito_jwks_host" {
  description = "Cognito JWKS host — the static Backend host agentgateway connects to for JWT verification"
  value       = "cognito-idp.${local.region}.amazonaws.com"
}

output "cognito_jwks_path" {
  description = "Cognito JWKS path — the jwksPath under the JWKS host (/<pool-id>/.well-known/jwks.json)"
  value       = "/${aws_cognito_user_pool.workshop.id}/.well-known/jwks.json"
}

output "cognito_client_id" {
  description = "Cognito app client ID — the JWT audience (aud claim)"
  value       = aws_cognito_user_pool_client.chainlit.id
}

# Langfuse UI admin login (seeded via LANGFUSE_INIT_* on first boot). Read by
# the IDE bootstrap into LANGFUSE_USERNAME / LANGFUSE_PASSWORD env vars, same
# flow as the chat-UI and Gitea credentials. The URL is the langfuse_url output
# in langfuse-cloudfront.tf (CloudFront in front of a private ALB).
output "langfuse_username" {
  description = "Langfuse UI admin email"
  value       = local.langfuse_admin_email
}

output "langfuse_password" {
  description = "Langfuse UI admin password"
  value       = random_password.langfuse_admin.result
  sensitive   = true
}

output "milvus_s3_bucket" {
  description = "S3 bucket used by Milvus for vector data and index files"
  value       = aws_s3_bucket.milvus.bucket
}

output "langfuse_s3_bucket" {
  description = "S3 bucket used by Langfuse for events, exports, and media"
  value       = aws_s3_bucket.langfuse.bucket
}
