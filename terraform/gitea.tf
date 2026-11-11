################################################################################
# Gitea (module 1000) — in-cluster git host for the autonomous coding agent.
#
# Issues + PRs + webhooks. Built-in local auth (Cognito federation is an
# out-of-scope extension). ROOT_URL is the Gitea CloudFront domain so human
# clone/links are correct; the agent + webhook use the in-cluster ClusterIP
# (gitea-http.gitea.svc.cluster.local:3000). SQLite + single replica — a
# workshop-simple footprint. Image mirrored to ECR (codebuild-images.tf).
################################################################################

resource "kubernetes_namespace_v1" "gitea" {
  metadata {
    name = "gitea"
    labels = {
      "kubernetes.io/metadata.name" = "gitea"
    }
  }
  depends_on = [module.eks]
}

# Random admin password per apply (never matches the public repo).
resource "random_password" "gitea_admin" {
  length  = 24
  special = false
}

# Terraform-owned PVC for gitea, handed to the chart via persistence.create=false +
# claimName (same pattern as the milvus PVCs in addons.tf). The gitea chart otherwise
# renders gitea-shared-storage with its default helm.sh/resource-policy: keep, which
# makes `helm uninstall` skip it and leak the EBS volume. Owning the PVC here removes
# the annotation problem entirely: Helm never manages it, and `terraform destroy`
# deletes it directly (ebs-sc's Delete reclaim drops the volume). wait_until_bound =
# false because ebs-sc is WaitForFirstConsumer — it binds only once the gitea pod
# (from the release that depends on this) mounts it, so waiting here would deadlock.
resource "kubernetes_persistent_volume_claim_v1" "gitea_data" {
  metadata {
    name      = "gitea-shared-storage"
    namespace = kubernetes_namespace_v1.gitea.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "ebs-sc"
    resources {
      requests = { storage = "10Gi" }
    }
  }
  wait_until_bound = false
  depends_on       = [kubernetes_storage_class_v1.ebs_sc]
}

resource "helm_release" "gitea" {
  name       = "gitea"
  repository = "https://dl.gitea.com/charts/"
  chart      = "gitea"
  version    = "12.1.3" # pin; appVersion Gitea 1.24.3 (matches the mirrored gitea:1.24.3 image)
  namespace  = kubernetes_namespace_v1.gitea.metadata[0].name
  timeout    = 900

  # Skip Helm's client-side schema check. See
  # module.eks_blueprints_addons_cert_manager in addons.tf.
  disable_openapi_validation = true

  values = [yamlencode({
    # Mirror the image to ECR (repo convention: no docker.io pulls at runtime).
    image = {
      registry   = local.ecr_registry
      repository = "gitea"
      tag        = "1.24.3"
      # Chart default rootless=true -> the pod pulls "gitea:1.24.3-rootless".
      # codebuild-images.tf mirrors that rootless tag (alongside the plain tag)
      # into ECR. If that mirror is missing, gitea ImagePullBackOffs and the Helm
      # wait times out (context deadline exceeded).
    }
    service = {
      http = { type = "ClusterIP", port = 3000 }
      ssh  = { type = "ClusterIP", port = 22 }
    }
    # SQLite: disable the chart's bundled HA deps.
    "postgresql-ha"  = { enabled = false }
    postgresql       = { enabled = false }
    "redis-cluster"  = { enabled = false }
    "valkey-cluster" = { enabled = false }
    # persistence: mount the Terraform-owned PVC (see kubernetes_persistent_volume_
    # claim_v1.gitea_data above). create=false makes the chart skip rendering its
    # own keep-annotated PVC; claimName points at ours. This replaces the earlier
    # resource-policy annotation approach, which could not reliably delete the PVC.
    persistence = {
      enabled   = true
      create    = false
      claimName = kubernetes_persistent_volume_claim_v1.gitea_data.metadata[0].name
    }
    gitea = {
      admin = {
        username = "workshop-admin"
        password = random_password.gitea_admin.result
        email    = "admin@example.com"
      }
      config = {
        database = { DB_TYPE = "sqlite3" }
        server = {
          ROOT_URL   = "https://${aws_cloudfront_distribution.gitea.domain_name}/"
          DOMAIN     = aws_cloudfront_distribution.gitea.domain_name
          SSH_DOMAIN = aws_cloudfront_distribution.gitea.domain_name
        }
        service = {
          DISABLE_REGISTRATION = true
          REQUIRE_SIGNIN_VIEW  = false
        }
        # Allow the in-cluster webhook target (private address).
        webhook = { ALLOWED_HOST_LIST = "*" }
      }
    }
  })]

  depends_on = [
    kubernetes_namespace_v1.gitea,
    # PVC must exist before the release mounts it; on destroy the release is
    # uninstalled before the PVC is deleted (helm leaves it; Terraform deletes it).
    kubernetes_persistent_volume_claim_v1.gitea_data,
    null_resource.build_images, # image must be mirrored to ECR first
    # This chart runs a pod with a 10Gi PVC and the release WAITS for readiness
    # (helm provider default) on a 900s timeout, so its scheduling
    # prerequisite must exist first or the wait burns the full timeout: a
    # default StorageClass, or the PVC stays Pending (see addons.tf).
    kubernetes_storage_class_v1.ebs_sc,
    # Destroy-order guard: this release must be destroyed BEFORE the storage
    # reclaim barrier's wait runs (addons.tf), so the barrier's own destroy
    # always sees gitea already torn down.
    null_resource.storage_reclaim_barrier,
  ]
}

# Register gitea pod IPs into the Terraform-managed target group.
resource "null_resource" "gitea_tgb" {
  triggers = {
    cluster_name     = module.eks.cluster_name
    region           = local.region
    target_group_arn = aws_lb_target_group.gitea.arn
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
        name: gitea-http
        namespace: gitea
      spec:
        serviceRef:
          name: gitea-http
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
      kubectl delete targetgroupbinding gitea-http -n gitea --ignore-not-found --wait=true --timeout=90s \
        || kubectl patch targetgroupbinding gitea-http -n gitea --type=merge \
             -p '{"metadata":{"finalizers":null}}' \
        || true
    EOT
  }

  depends_on = [
    aws_lb_target_group.gitea,
    helm_release.gitea,
    module.eks,
    # Destroy-order guard: kubectl reaches the cluster endpoint for the delete
    # above, so keep the VPC until this resource is gone.
    module.vpc,
  ]
}
