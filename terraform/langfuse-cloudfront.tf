################################################################################
# CloudFront + internal ALB for Langfuse
#
# Langfuse used to be published by the Helm chart's own Ingress: an
# internet-facing ALB on plaintext HTTP:80, with inbound-cidrs 0.0.0.0/0 in the
# Workshop Studio path. That put a tracing backend holding every prompt and
# completion on the open internet, protected only by its login form, and it
# blocked internal dry runs, where public HTTP endpoints are not allowed.
#
# CIDR scoping is not an option here: Workshop Studio vends accounts
# continuously and participants connect from arbitrary addresses, so there is no
# list to write. Instead the ALB is INTERNAL (private subnets, no public IP) and
# CloudFront reaches it through a VPC origin. Participants get HTTPS on the
# *.cloudfront.net cert, and the load balancer itself is unreachable from the
# internet, not merely firewalled.
#
# This differs from cloudfront.tf / gitea-cloudfront.tf, which use
# internet-facing ALBs restricted to the CloudFront prefix list. Those predate
# VPC origins. Same effect for a caller; this one is stricter, because there is
# no public listener to reach at all.
#
# Reuses the data sources declared in cloudfront.tf (the two AWS-managed
# CloudFront policies). The CloudFront prefix list is not needed: a VPC origin
# is authorized by security group, not by source IP.
################################################################################

# The ALB is private, so the only thing that may reach it is CloudFront's VPC
# origin ENI. Authorization is by security group: see
# aws_security_group_rule.langfuse_alb_from_cloudfront for which group, and why
# the rules here are standalone rather than inline.
resource "aws_security_group" "langfuse_alb" {
  name        = "${local.name}-langfuse-alb"
  description = "Langfuse internal ALB - reachable only via the CloudFront VPC origin"
  vpc_id      = module.vpc.vpc_id

  # No inline ingress/egress blocks. An inline block is authoritative: Terraform
  # deletes any rule on this group it did not create, which would revoke the
  # CloudFront rule below on the next apply. Inline and standalone rules cannot
  # be mixed on one group, so both directions are standalone.

  tags = local.tags
}

# CloudFront does NOT attach its VPC origin ENI to the ALB's security group. It
# creates its own service-managed group, CloudFront-VPCOrigins-Service-SG, and
# attaches the ENI to that. So the ALB must admit THAT group as the source; a
# self-referencing rule matches nothing and every request dies at the SG, which
# CloudFront surfaces to participants as a 504 with healthy ALB targets.
#
# The group is created by CloudFront along with the first VPC origin, so it does
# not exist on a fresh account at plan time. depends_on defers this read to
# apply, after the VPC origin is deployed.
data "aws_security_group" "cloudfront_vpc_origins" {
  name   = "CloudFront-VPCOrigins-Service-SG"
  vpc_id = module.vpc.vpc_id

  depends_on = [aws_cloudfront_vpc_origin.langfuse]
}

resource "aws_security_group_rule" "langfuse_alb_from_cloudfront" {
  description              = "HTTP from the CloudFront VPC origin service-managed SG"
  type                     = "ingress"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  security_group_id        = aws_security_group.langfuse_alb.id
  source_security_group_id = data.aws_security_group.cloudfront_vpc_origins.id
}

resource "aws_security_group_rule" "langfuse_alb_egress" {
  description       = "All egress (to pod targets)"
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.langfuse_alb.id
}

# Open the cluster primary SG (where langfuse-web pods run, target_type=ip) to
# the ALB SG on 3000. Required because the ALB + TargetGroupBinding are created
# directly rather than by Auto Mode from an Ingress, so nothing manages this rule
# for us. Without it the target health checks time out and CloudFront 504s.
resource "aws_security_group_rule" "langfuse_alb_to_pods" {
  description              = "Langfuse ALB to pod port 3000"
  type                     = "ingress"
  from_port                = 3000
  to_port                  = 3000
  protocol                 = "tcp"
  security_group_id        = module.eks.cluster_primary_security_group_id
  source_security_group_id = aws_security_group.langfuse_alb.id
}

resource "aws_lb" "langfuse" {
  name               = "${local.name}-langfuse"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.langfuse_alb.id]
  subnets            = module.vpc.private_subnets
  tags               = local.tags
}

resource "aws_lb_target_group" "langfuse" {
  name        = "${local.name}-langfuse"
  port        = 3000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = module.vpc.vpc_id

  health_check {
    # Langfuse exposes a readiness endpoint; it returns 200 once migrations are
    # done. The matcher stays wide because / redirects to the sign-in page.
    path                = "/api/public/health"
    port                = "traffic-port"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
    matcher             = "200-399"
  }

  tags = local.tags
}

resource "aws_lb_listener" "langfuse" {
  load_balancer_arn = aws_lb.langfuse.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.langfuse.arn
  }

  tags = local.tags
}

# TargetGroupBinding: Auto Mode registers the langfuse-web Service's pod
# IPs into the Terraform-managed target group. Applied via kubectl (not
# kubernetes_manifest) to avoid plan-time CRD lookups; destroy-time delete so the
# controller deregisters targets before the target group goes away.
resource "null_resource" "langfuse_tgb" {
  triggers = {
    cluster_name     = module.eks.cluster_name
    region           = local.region
    target_group_arn = aws_lb_target_group.langfuse.arn
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
        name: langfuse-web
        namespace: langfuse
      spec:
        serviceRef:
          name: langfuse-web
          port: 3000
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
      kubectl delete targetgroupbinding langfuse-web -n langfuse --ignore-not-found --wait=true --timeout=90s \
        || kubectl patch targetgroupbinding langfuse-web -n langfuse --type=merge \
             -p '{"metadata":{"finalizers":null}}' \
        || true
    EOT
  }

  depends_on = [
    aws_lb_target_group.langfuse,
    # langfuse-web must exist (and have been scaled up) before the binding is
    # applied; that orchestration lives in langfuse.tf.
    null_resource.langfuse_wait_and_enable,
    # The TargetGroupBinding CRD ships with Auto Mode, so the cluster is enough.
    module.eks,
    # Destroy-order guard: kubectl reaches the cluster endpoint for the delete
    # above, so keep the VPC until this resource is gone.
    module.vpc,
  ]
}

################################################################################
# CloudFront distribution (HTTPS viewer, VPC origin to the private ALB)
################################################################################

# A VPC origin lets CloudFront reach a load balancer that has no public
# address. CloudFront creates a managed ENI in the VPC and authorizes it by
# security group, which is why aws_security_group.langfuse_alb allows itself.
resource "aws_cloudfront_vpc_origin" "langfuse" {
  vpc_origin_endpoint_config {
    name                   = "${local.name}-langfuse"
    arn                    = aws_lb.langfuse.arn
    http_port              = 80
    https_port             = 443
    origin_protocol_policy = "http-only"

    origin_ssl_protocols {
      items    = ["TLSv1.2"]
      quantity = 1
    }
  }

  tags = local.tags

  depends_on = [aws_lb_listener.langfuse]
}

locals {
  langfuse_origin_id = "langfuse-alb"
}

resource "aws_cloudfront_distribution" "langfuse" {
  enabled         = true
  comment         = "${local.name} langfuse (private ALB via VPC origin)"
  is_ipv6_enabled = true

  origin {
    domain_name = aws_lb.langfuse.dns_name
    origin_id   = local.langfuse_origin_id

    vpc_origin_config {
      vpc_origin_id = aws_cloudfront_vpc_origin.langfuse.id
    }
  }

  # CachingDisabled + AllViewer: Langfuse is an interactive app with its own
  # session cookies, so nothing should be cached and every header must pass
  # through untouched.
  default_cache_behavior {
    target_origin_id       = local.langfuse_origin_id
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

  # The SG rule must exist before the distribution is considered done, or the
  # apply finishes and hands participants a URL that 504s.
  depends_on = [aws_security_group_rule.langfuse_alb_from_cloudfront]
}

output "langfuse_url" {
  description = "Langfuse HTTPS URL (CloudFront, private ALB origin)"
  value       = "https://${aws_cloudfront_distribution.langfuse.domain_name}"
}
