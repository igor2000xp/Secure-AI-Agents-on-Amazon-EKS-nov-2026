################################################################################
# Chainlit Chat UI
#
# Pre-built public ECR image — no per-participant docker build needed. The image
# must be (re)published from modules/ui/ with the @cl.oauth_callback handler for
# Cognito auth to take effect (see modules/ui/app.py).
#
# Reachability: NOT an ALB Ingress. A Terraform-managed ALB + CloudFront front
# this Service (see cloudfront.tf) so Cognito's HTTPS-only OAuth callback works.
# The Service stays ClusterIP; the TargetGroupBinding registers its pods.
################################################################################

resource "kubernetes_deployment_v1" "chainlit_ui" {
  metadata {
    name      = "chainlit-ui"
    namespace = "default"
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "chainlit-ui" }
    }

    template {
      metadata {
        labels = { app = "chainlit-ui" }
      }

      spec {
        container {
          name              = "chainlit-ui"
          image             = "public.ecr.aws/e9a3v2u0/chainlit-ui:cognito-auth"
          image_pull_policy = "Always"

          port {
            container_port = 8000
          }

          # Cognito OAuth (Chainlit's built-in aws-cognito provider). CHAINLIT_URL
          # is the public CloudFront origin so the OAuth redirect/callback resolve
          # to the HTTPS domain Cognito requires.
          env {
            name  = "OAUTH_COGNITO_CLIENT_ID"
            value = aws_cognito_user_pool_client.chainlit.id
          }
          env {
            name  = "OAUTH_COGNITO_CLIENT_SECRET"
            value = aws_cognito_user_pool_client.chainlit.client_secret
          }
          env {
            name  = "OAUTH_COGNITO_DOMAIN"
            value = local.cognito_hosted_ui_domain
          }
          env {
            name  = "CHAINLIT_URL"
            value = "https://${aws_cloudfront_distribution.chainlit.domain_name}"
          }
          env {
            name  = "CHAINLIT_AUTH_SECRET"
            value = random_password.chainlit_auth_secret.result
          }

          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
          }
        }
      }
    }
  }

  # Needs the Cognito client + CloudFront domain (their values are baked into
  # env above).
  depends_on = [
    module.eks,
    aws_cognito_user_pool_client.chainlit,
    aws_cloudfront_distribution.chainlit,
  ]
}

resource "kubernetes_service_v1" "chainlit_ui" {
  metadata {
    name      = "chainlit-ui"
    namespace = "default"
  }

  spec {
    selector = { app = "chainlit-ui" }

    port {
      port        = 80
      target_port = 8000
    }
  }

  depends_on = [module.eks]
}

# NOTE: no kubernetes_ingress_v1 here. The chat UI is fronted by a
# Terraform-managed ALB + CloudFront (cloudfront.tf) instead of an ALB Ingress,
# because Cognito requires an HTTPS callback URL and Workshop Studio does not
# allow an ALB cert — CloudFront's default cert provides HTTPS. The
# TargetGroupBinding in cloudfront.tf registers this Service's pods into the
# ALB target group.
