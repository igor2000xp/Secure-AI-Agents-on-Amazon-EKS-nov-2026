################################################################################
# Cognito authentication for the Chainlit chat UI
#
# Chainlit uses its built-in "aws-cognito" OAuth provider (Hosted UI, code
# flow). The OAuth callback must be HTTPS, which is why the UI is fronted by
# CloudFront (cloudfront.tf) — the callback lands on the CloudFront domain.
#
# Auth uses two PRE-SEEDED retail-persona users, each in a Cognito group so the
# group propagates into the JWT as the `cognito:groups` claim:
#   - sales-analyst     — (future) may run dynamic code analysis on orders
#   - support-associate — order lookups only
# Phase 1 propagates the claim and the UI reflects the persona; the capability
# difference is NOT enforced at the tool yet (see the design doc). Each user's
# username + password are surfaced as outputs. Throwaway accounts for a
# time-boxed event.
################################################################################

locals {
  # Cognito Hosted UI domain prefix. Must be globally unique within the region
  # ACROSS ALL AWS ACCOUNTS — a fixed cluster-name prefix collides with any
  # prior/parallel workshop event in the same region ("Domain already
  # associated with another user pool"). The account ID isn't safe either:
  # Workshop Studio REPURPOSES accounts, so the same account can re-run the
  # workshop (or hold an orphaned pool from an incomplete teardown) and still
  # collide. A fresh random suffix per deploy sidesteps both. (<=63 chars,
  # [a-z0-9-]: 21-char name + '-' + 8 random = 30, within limits.)
  cognito_domain_prefix = "${replace(lower(local.name), "_", "-")}-${random_string.cognito_domain_suffix.result}"

  # Cognito Hosted UI hostname — BARE (no scheme). Chainlit's aws-cognito
  # provider builds URLs as f"https://{OAUTH_COGNITO_DOMAIN}/login", i.e. it
  # prepends https:// itself. Passing a value with the scheme produces the
  # malformed "https://https//..." redirect, so this must be host-only.
  cognito_hosted_ui_domain = "${local.cognito_domain_prefix}.auth.${local.region}.amazoncognito.com"

  # Pre-seeded persona users → each maps 1:1 to a Cognito group of the same
  # name, so login yields cognito:groups = [<persona>] in the JWT.
  personas = {
    "sales-analyst"     = "Sales Analyst"
    "support-associate" = "Support Associate"
  }
}

resource "aws_cognito_user_pool" "workshop" {
  name = "${local.name}-workshop"

  # Relaxed policy for a shared demo credential (no MFA, simple password).
  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_numbers   = true
    require_uppercase = true
    require_symbols   = false
  }

  # Plain username sign-in: omit username_attributes/alias_attributes entirely
  # (empty list conflicts with alias_attributes and can behave unexpectedly).

  account_recovery_setting {
    recovery_mechanism {
      name     = "admin_only"
      priority = 1
    }
  }

  tags = local.tags
}

resource "aws_cognito_user_pool_domain" "workshop" {
  domain       = local.cognito_domain_prefix
  user_pool_id = aws_cognito_user_pool.workshop.id
}

# App client WITH a secret — Chainlit's aws-cognito provider requires
# OAUTH_COGNITO_CLIENT_SECRET. Authorization-code flow only (most secure);
# callback/logout point at the CloudFront domain.
resource "aws_cognito_user_pool_client" "chainlit" {
  name         = "${local.name}-chainlit"
  user_pool_id = aws_cognito_user_pool.workshop.id

  generate_secret = true

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = ["COGNITO"]

  callback_urls = ["https://${aws_cloudfront_distribution.chainlit.domain_name}/auth/oauth/aws-cognito/callback"]
  logout_urls   = ["https://${aws_cloudfront_distribution.chainlit.domain_name}/"]

  # Standard SRP + refresh; no need for admin/password flows (OAuth only).
  explicit_auth_flows = [
    "ALLOW_REFRESH_TOKEN_AUTH",
    "ALLOW_USER_SRP_AUTH",
  ]

  depends_on = [aws_cloudfront_distribution.chainlit]
}

# One Cognito group per persona. Group membership surfaces automatically as the
# `cognito:groups` claim in the ID/access token — the mechanism that propagates
# the persona/role into the JWT (no custom attributes or Lambda needed).
resource "aws_cognito_user_group" "persona" {
  for_each = local.personas

  name         = each.key
  user_pool_id = aws_cognito_user_pool.workshop.id
  description  = "${each.value} persona"
}

# Pre-seeded persona users with permanent passwords (no forced reset).
# message_action=SUPPRESS so Cognito doesn't try to email a welcome message.
resource "random_password" "persona" {
  for_each = local.personas

  length  = 12
  special = false
  # Ensure it satisfies the pool policy (upper+lower+number).
  min_lower   = 2
  min_upper   = 2
  min_numeric = 2
}

resource "aws_cognito_user" "persona" {
  for_each = local.personas

  user_pool_id   = aws_cognito_user_pool.workshop.id
  username       = each.key
  password       = random_password.persona[each.key].result
  message_action = "SUPPRESS"

  attributes = {
    email          = "${each.key}@workshop.local"
    email_verified = "true"
  }
}

# Put each user in its matching group → cognito:groups = [<persona>] in the JWT.
resource "aws_cognito_user_in_group" "persona" {
  for_each = local.personas

  user_pool_id = aws_cognito_user_pool.workshop.id
  group_name   = aws_cognito_user_group.persona[each.key].name
  username     = aws_cognito_user.persona[each.key].username
}

# Random suffix that makes the Cognito Hosted UI domain prefix globally unique
# per deploy (see local.cognito_domain_prefix). Lowercase alphanumeric only —
# Cognito domain prefixes allow [a-z0-9-]; no uppercase, no other specials.
resource "random_string" "cognito_domain_suffix" {
  length  = 8
  lower   = true
  upper   = false
  numeric = true
  special = false
}

# Session-signing secret for Chainlit's auth cookies.
resource "random_password" "chainlit_auth_secret" {
  length  = 48
  special = false
}
