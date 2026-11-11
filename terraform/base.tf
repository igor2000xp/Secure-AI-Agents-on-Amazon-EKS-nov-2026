provider "aws" {
  region = local.region
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      # This requires the awscli to be installed locally where Terraform is executed
      args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

# Exclude Local Zones / Wavelength Zones (opt-in zones); EKS control plane and
# NAT gateways only support standard regional AZs. Without this filter, an
# account with Local Zones opted in (e.g. us-west-2-lax-*) can land subnets in
# an unsupported zone.
data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# tflint-ignore: terraform_unused_declarations
variable "eks_cluster_id" {
  description = "EKS cluster name"
  type        = string
}
variable "aws_region" {
  description = "AWS Region"
  type        = string

  validation {
    condition     = contains(["us-east-1", "us-west-2", "eu-north-1", "eu-west-2"], var.aws_region)
    error_message = "The workshop runs only in us-east-1, us-west-2, eu-north-1 or eu-west-2."
  }
}

# Region the Envoy AI Gateway calls Amazon Bedrock in, INDEPENDENT of the Region
# the cluster runs in. On the workshop platform Bedrock is only available in
# us-east-1 and us-west-2, while the cluster may run in an EU Region, so model
# traffic is pinned here rather than following var.aws_region.
#
# This single value drives BOTH the Bedrock runtime hostname and the SigV4
# signing region in the gateway's BackendSecurityPolicy (see gateways.tf). They
# must always match: a signing region that disagrees with the endpoint fails
# every model call with an opaque 403, so they are deliberately not separate
# inputs.
#
# The `us.*` cross-region inference profiles the gateway targets are valid from
# both allowed Regions, so no model ID changes with this setting.
variable "bedrock_region" {
  description = "AWS Region for Bedrock model calls (independent of the cluster Region)"
  type        = string
  default     = "us-west-2"

  validation {
    condition     = contains(["us-east-1", "us-west-2"], var.bedrock_region)
    error_message = "Bedrock is available only in us-east-1 or us-west-2 on the workshop platform."
  }
}

locals {
  name   = var.eks_cluster_id
  region = var.aws_region

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = {
    Blueprint  = local.name
    GithubRepo = "github.com/aws-ia/terraform-aws-eks-blueprints"
  }
}

################################################################################
# Cluster
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.24.0"

  name                   = local.name
  kubernetes_version     = var.cluster_version
  endpoint_public_access = true

  # Pin the Kubernetes Service CIDR. Left unset, EKS picks EITHER 10.100.0.0/16
  # or 172.20.0.0/16, so the ClusterIP of a given service — notably CoreDNS at
  # <service-cidr>.0.10 — differs between provisions. The coding sandbox's DNS
  # egress policy has to name that address as an ipBlock (a ClusterIP is not a
  # pod, so no podSelector can match it), and a policy pinned to the wrong half
  # of a coin flip silently denies DNS inside the sandbox.
  #
  # Does not overlap the VPC (10.0.0.0/16), which is the only hard constraint.
  # Changing this on an existing cluster forces a new cluster.
  service_ipv4_cidr = "172.20.0.0/16"

  # Control plane AUDIT logging, for the Command Center's `k8s_audit` gates.
  #
  # The gate tracker's provisioner subscribes the cluster's
  # /aws/eks/<name>/cluster log group when the team's `deployment_success` event
  # fires, and evaluates gates against the Kubernetes API requests recorded
  # there. Without `audit` in this list the log group carries no API requests
  # and every k8s_audit gate stays red forever.
  #
  # Only `audit` is enabled. `api` and `authenticator` (the module's other
  # defaults) are pure cost here, because nothing consumes them.
  #
  # The module creates the log group itself (create_cloudwatch_log_group
  # defaults true), which is what we want: it exists before the team stack
  # finishes, so it is already there when deployment_success fires. Do NOT also
  # pre-create it from CDK, or the apply collides on an existing log group.
  enabled_log_types = ["audit"]

  # Audit logs are billed as CloudWatch Logs ingestion in the TEAM account and
  # nothing reads them after the event, so keep the shortest retention rather
  # than the module's 90-day default.
  cloudwatch_log_group_retention_in_days = 1

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  enable_cluster_creator_admin_permissions = true

  # EKS Auto Mode runs compute, block storage, load balancing, pod networking,
  # CoreDNS and the Pod Identity agent as managed capabilities. The built-in
  # system pool runs cluster add-ons.
  #
  # `general-purpose` is deliberately NOT enabled. Its NodePool is EKS-managed
  # and cannot be edited, and two of its defaults hurt this workshop: it
  # consolidates WhenEmptyOrUnderutilized (so Karpenter drains and replaces
  # nodes that are still running agents, which participants see as unexplained
  # mid-lab restarts) and it has no sandbox-capability requirement. A
  # replacement pool with the same instance selection, WhenEmpty consolidation
  # and a Nitro Sandbox requirement is applied in node-pool.tf.
  #
  # "system" stays enabled for two reasons: it runs the cluster add-ons, and it
  # keeps the EKS-managed `default` NodeClass present for the replacement pool
  # to reference.
  compute_config = {
    enabled    = true
    node_pools = ["system"]
  }

  # Auto Mode nodes use the cluster primary security group, which allows all
  # traffic between its members, so no separate node security group is needed.
  create_node_security_group = false

  # Auto Mode runs networking, kube-proxy, CoreDNS, the Pod Identity agent and
  # the EBS CSI driver on every node, so only add-ons it does not provide are
  # listed. The ADOT operator addon needs cert-manager first, so it is a
  # standalone aws_eks_addon in addons.tf.
  addons = {
    metrics-server     = { most_recent = true }
    kube-state-metrics = { most_recent = true }
  }

  tags = local.tags
}

# Turns on Kubernetes NetworkPolicy enforcement on Auto Mode nodes. Without it,
# NetworkPolicy objects are accepted but not enforced. The built-in NodeClass
# defaults to DefaultAllow, so traffic is open until a policy selects a pod.
resource "kubernetes_config_map_v1" "network_policy" {
  metadata {
    name      = "amazon-vpc-cni"
    namespace = "kube-system"
  }

  data = {
    "enable-network-policy-controller" = "true"
  }

  depends_on = [module.eks]
}

resource "time_sleep" "wait_60_seconds" {
  create_duration = "60s"

  depends_on = [
    module.eks,
    # The workshop node pool is the cluster's only general compute pool now
    # that general-purpose is off, so it has to exist before the add-ons and
    # support stack that gate on this sleep try to schedule.
    null_resource.workshop_node_pool,
  ]
}
