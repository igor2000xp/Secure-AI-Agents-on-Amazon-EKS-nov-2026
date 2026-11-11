################################################################################
# CloudFront + ALB for Gitea (module 1000)
#
# Mirrors cloudfront.tf (chat UI). CloudFront's default *.cloudfront.net cert
# gives Gitea HTTPS with no ACM/custom domain (Workshop Studio blocks ALB certs).
# The ALB is internet-facing but its SG admits ONLY the CloudFront origin-facing
# prefix list. Reuses the data sources from cloudfront.tf
# (aws_ec2_managed_prefix_list.cloudfront, the two AWS-managed CF policies).
# Human browser access only — the agent uses the in-cluster ClusterIP.
################################################################################

resource "aws_security_group" "gitea_alb" {
  name        = "${local.name}-gitea-alb"
  description = "Gitea ALB - ingress from CloudFront origin-facing prefix list only"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "HTTP from CloudFront only"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront.id]
  }

  egress {
    description = "All egress (to pod targets)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

# Open the cluster primary SG (where gitea pods run, target_type=ip) to the ALB
# SG on 3000.
resource "aws_security_group_rule" "gitea_alb_to_pods" {
  description              = "Gitea ALB to pod port 3000"
  type                     = "ingress"
  from_port                = 3000
  to_port                  = 3000
  protocol                 = "tcp"
  security_group_id        = module.eks.cluster_primary_security_group_id
  source_security_group_id = aws_security_group.gitea_alb.id
}

resource "aws_lb" "gitea" {
  name               = "${local.name}-gitea"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.gitea_alb.id]
  subnets            = module.vpc.public_subnets
  tags               = local.tags
}

resource "aws_lb_target_group" "gitea" {
  name        = "${local.name}-gitea"
  port        = 3000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = module.vpc.vpc_id

  health_check {
    path                = "/api/healthz"
    port                = "traffic-port"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
    matcher             = "200-399"
  }

  tags = local.tags
}

resource "aws_lb_listener" "gitea" {
  load_balancer_arn = aws_lb.gitea.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.gitea.arn
  }

  tags = local.tags
}

locals {
  gitea_origin_id = "gitea-alb"
}

resource "aws_cloudfront_distribution" "gitea" {
  enabled         = true
  comment         = "${local.name} gitea (module 1000)"
  is_ipv6_enabled = true

  origin {
    domain_name = aws_lb.gitea.dns_name
    origin_id   = local.gitea_origin_id

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = local.gitea_origin_id
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]

    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  price_class = "PriceClass_100"
  tags        = local.tags

  depends_on = [aws_lb_listener.gitea]
}

output "gitea_url" {
  description = "Gitea HTTPS URL (CloudFront)"
  value       = "https://${aws_cloudfront_distribution.gitea.domain_name}"
}

# Human sign-in for the coding-agent lab. Mirrors the chat_ui_* outputs: the
# IDE bootstrap reads these into GITEA_USERNAME / GITEA_PASSWORD env vars and
# the shell banner (workshop-only credential; plaintext there is acceptable).
output "gitea_username" {
  description = "Gitea participant username"
  value       = local.gitea_participant_user
}

output "gitea_password" {
  description = "Gitea participant password"
  value       = random_password.gitea_participant.result
  sensitive   = true
}
