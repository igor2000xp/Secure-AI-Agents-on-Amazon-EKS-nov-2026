################################################################################
# CloudFront + ALB for the Chainlit chat UI
#
# Workshop Studio does not allow an HTTPS/ACM cert on the ALB, but Cognito
# requires HTTPS callback URLs. CloudFront's default *.cloudfront.net domain
# provides a valid AWS-managed HTTPS cert with no ACM cert / custom domain, so
# the Cognito Hosted UI OAuth flow works (callback lands on the CloudFront URL).
#
# The ALB is Terraform-managed (NOT created by Auto Mode from an Ingress or
# Gateway) so its DNS name is known at plan time and the CloudFront origin +
# Cognito callback + Chainlit env all resolve with plain references — no
# kubectl waits, no races. Auto Mode's load balancer controller only registers
# pod IPs into the target group via the TargetGroupBinding CR.
#
# The ALB is internet-facing but its security group only admits the AWS-managed
# CloudFront origin-facing prefix list, so nothing but CloudFront reaches it.
################################################################################

# CloudFront's origin-facing IP ranges, as a managed prefix list. Used to lock
# the ALB security group to CloudFront only.
data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

# AWS-managed CloudFront policies. CachingDisabled + AllViewer are required so
# WebSocket upgrade headers (Sec-WebSocket-*, Connection, Upgrade) and auth
# cookies pass through untouched — Chainlit is WebSocket-based.
data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer" {
  name = "Managed-AllViewer"
}

################################################################################
# ALB (internet-facing, CloudFront-only) → chainlit-ui pods via TargetGroupBinding
################################################################################

resource "aws_security_group" "chainlit_alb" {
  name        = "${local.name}-chainlit-alb"
  description = "Chainlit ALB - ingress from CloudFront origin-facing prefix list only"
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

# Allow the ALB to reach the Chainlit pods on 8000 (health check + traffic).
# With an ALB Ingress Auto Mode manages this rule automatically; because we
# create the ALB + TargetGroupBinding directly, we must open the cluster primary
# security group (which Auto Mode nodes and their pods use) to the ALB SG
# ourselves. Without this the ALB target health checks time out (Target.Timeout)
# and CloudFront returns 504.
resource "aws_security_group_rule" "chainlit_alb_to_pods" {
  description              = "Chainlit ALB to pod port 8000"
  type                     = "ingress"
  from_port                = 8000
  to_port                  = 8000
  protocol                 = "tcp"
  security_group_id        = module.eks.cluster_primary_security_group_id
  source_security_group_id = aws_security_group.chainlit_alb.id
}

resource "aws_lb" "chainlit" {
  name               = "${local.name}-chainlit"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.chainlit_alb.id]
  subnets            = module.vpc.public_subnets

  tags = local.tags
}

# target_type = ip so Auto Mode registers Chainlit pod IPs directly
# (the chainlit-ui Service stays ClusterIP). health check hits Chainlit's port.
resource "aws_lb_target_group" "chainlit" {
  name        = "${local.name}-chainlit"
  port        = 8000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = module.vpc.vpc_id

  health_check {
    path                = "/"
    port                = "traffic-port"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
    # Chainlit returns 200 on / (redirects to login when auth is enabled, which
    # is still a 2xx/3xx the ALB treats as healthy with this matcher).
    matcher = "200-399"
  }

  tags = local.tags
}

resource "aws_lb_listener" "chainlit" {
  load_balancer_arn = aws_lb.chainlit.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.chainlit.arn
  }

  tags = local.tags
}

# TargetGroupBinding: Auto Mode registers the chainlit-ui Service's pod
# IPs into the Terraform-managed target group. Applied via kubectl (not
# kubernetes_manifest) to avoid plan-time CRD lookups; destroy-time delete so
# the controller deregisters targets before the TG is removed.
resource "null_resource" "chainlit_tgb" {
  triggers = {
    cluster_name     = module.eks.cluster_name
    region           = local.region
    target_group_arn = aws_lb_target_group.chainlit.arn
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      export KUBECONFIG="$(mktemp)"
      trap 'rm -f "$KUBECONFIG"' EXIT
      aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.region} --kubeconfig "$KUBECONFIG"
      kubectl apply -f - <<'YAML'
      apiVersion: eks.amazonaws.com/v1
      kind: TargetGroupBinding
      metadata:
        name: chainlit-ui
        namespace: default
      spec:
        serviceRef:
          name: chainlit-ui
          port: 80
        targetGroupARN: ${self.triggers.target_group_arn}
        targetType: ip
      YAML
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      export KUBECONFIG="$(mktemp)"
      trap 'rm -f "$KUBECONFIG"' EXIT
      aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.region} --kubeconfig "$KUBECONFIG" || exit 0
      # Bounded, then forced. Auto Mode's load balancer controller clears the
      # finalizer by deregistering targets; if that stalls, an unbounded wait hangs
      # the whole destroy. The AWS target group is
      # Terraform-managed and destroyed separately, so dropping the finalizer here
      # leaks nothing.
      kubectl delete targetgroupbinding chainlit-ui -n default --ignore-not-found --wait=true --timeout=90s \
        || kubectl patch targetgroupbinding chainlit-ui -n default --type=merge \
             -p '{"metadata":{"finalizers":null}}' \
        || true
    EOT
  }

  depends_on = [
    aws_lb_target_group.chainlit,
    kubernetes_service_v1.chainlit_ui,
    # The TargetGroupBinding CRD ships with Auto Mode, so the cluster is enough.
    module.eks,
    # Destroy-order guard: kubectl reaches the cluster endpoint for the delete
    # above, so keep the VPC until this resource is gone.
    module.vpc,
  ]
}

################################################################################
# CloudFront distribution (HTTPS viewer via default cert, HTTP to ALB origin)
################################################################################

locals {
  chainlit_origin_id = "chainlit-alb"
}

resource "aws_cloudfront_distribution" "chainlit" {
  enabled         = true
  comment         = "${local.name} chainlit chat UI (Cognito-authenticated)"
  is_ipv6_enabled = true

  origin {
    domain_name = aws_lb.chainlit.dns_name
    origin_id   = local.chainlit_origin_id

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = local.chainlit_origin_id
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

  # Cheapest price class is fine for a workshop.
  price_class = "PriceClass_100"

  tags = local.tags

  depends_on = [aws_lb_listener.chainlit]
}
