
################################################################################
# cert-manager
#
# Required by the ADOT operator addon (its admission webhooks need
# cert-manager-issued certs). Auto Mode provides load balancing natively, so
# this is the only chart installed through the EKS Blueprints Addons module.
#
# wait_for_jobs matters here specifically: the cert-manager chart runs a
# `startupapicheck` post-install hook Job, and without this the release reports
# complete while that check is still in flight.
################################################################################

module "eks_blueprints_addons_cert_manager" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "1.23.0"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  # Skip the module's usage-telemetry CloudFormation stack.
  observability_tag = null

  enable_cert_manager = true
  cert_manager = {
    wait          = true
    wait_for_jobs = true
    # Skip Helm's client-side schema check. Before installing, Helm downloads the
    # cluster's OpenAPI schema to validate the rendered chart. On a new cluster
    # that download can briefly return 503 ("the server is currently unable to
    # handle the request") while API services come up or the control plane
    # scales. On 2026-10-16 that failed a Workshop Studio event, and Terraform
    # has no retry for it. The API server still validates every object on
    # create, so a bad manifest still fails the install. Every helm_release in
    # this repo sets the same flag.
    disable_openapi_validation = true
  }

  tags = local.tags

  depends_on = [time_sleep.wait_60_seconds]
}

################################################################################
# ADOT - AWS Distro for OpenTelemetry operator (EKS managed addon)
#
# Installs the operator only; it does not collect telemetry until an
# OpenTelemetryCollector CR is created (observability.tf). The operator's
# admission webhooks need cert-manager, so wait for its webhook to be Available
# first. The module already uses wait = true; this explicit gate keeps the
# ordering from depending on a module-internal default.
################################################################################

resource "null_resource" "wait_for_cert_manager" {
  triggers = {
    cluster_name = module.eks.cluster_name
    region       = local.region
  }

  provisioner "local-exec" {
    # The CodeBuild Terraform Runner's default shell is /bin/sh (dash), which
    # rejects `set -o pipefail`. Force bash, matching langfuse.tf.
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      export KUBECONFIG="$(mktemp)"
      trap 'rm -f "$KUBECONFIG"' EXIT
      aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.region} --kubeconfig "$KUBECONFIG"
      echo "Waiting for cert-manager webhook to be Available..."
      kubectl rollout status deploy/cert-manager-webhook -n cert-manager --timeout=10m
    EOT
  }

  depends_on = [module.eks_blueprints_addons_cert_manager]
}

resource "aws_eks_addon" "adot" {
  cluster_name  = module.eks.cluster_name
  addon_name    = "adot"
  addon_version = var.adot_addon_version

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    null_resource.wait_for_cert_manager,
  ]

  tags = local.tags
}

################################################################################
# EKS - StorageClass
################################################################################

resource "kubernetes_storage_class_v1" "ebs_sc" {
  metadata {
    name = "ebs-sc"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  # Auto Mode's built-in block storage provisioner. The self-managed EBS CSI
  # driver's ebs.csi.aws.com does not exist on this cluster.
  storage_provisioner = "ebs.csi.eks.amazonaws.com"
  volume_binding_mode = "WaitForFirstConsumer"

  # Stated explicitly, though "Delete" is already Kubernetes' default when the
  # field is omitted. It is the ONLY reclaim knob that exists, and it decides just
  # one thing: what happens to the PV and its EBS volume WHEN THE PVC IS DELETED.
  # It cannot cause a PVC to be deleted, so it does nothing about the volumes this
  # cluster used to leak — those leaked because nothing deleted their PVCs (charts
  # shipping helm.sh/resource-policy: keep, and StatefulSet volumeClaimTemplates
  # that Helm never owned). Those are fixed at each release; see the
  # persistentVolumeClaimRetentionPolicy / resource-policy values in the milvus
  # release below, langfuse.tf and gitea.tf.
  #
  # Note this value is copied onto each PV at provision time — editing it later
  # does not change PVs that already exist.
  reclaim_policy = "Delete"

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  # depends_on module.eks so this StorageClass is created only AFTER the
  # cluster-creator access-entry association (from
  # enable_cluster_creator_admin_permissions) is in effect. Otherwise, on a first
  # apply, the kubernetes provider can race that association and hit
  # "storageclasses.storage.k8s.io is forbidden", which leaves the cluster with
  # no default StorageClass, so every PVC (langfuse ClickHouse/Postgres/Redis,
  # milvus, gitea) stays Pending.
  depends_on = [
    module.eks,
  ]
}

################################################################################
# Storage reclamation barrier (destroy-time only)
#
# `helm_release`'s own `wait` only confirms a
# release's OWN manifest resources — Deployments, StatefulSets, chart-rendered
# PVCs — return NotFound. It does NOT confirm that a StatefulSet's
# volumeClaimTemplate PVCs (postgresql, redis, clickhouse, zookeeper, milvus's
# etcd) have been garbage-collected, or that the PV — and, through the EBS CSI
# controller's DeleteVolume call, the underlying EBS volume — behind ANY of
# these PVCs has actually been reclaimed. That chain (StatefulSet gone -> PVC
# GC'd via ownerReference -> PV deleted via the ebs-sc StorageClass's Delete
# reclaimPolicy -> CSI DeleteVolume) is asynchronous and untracked by
# Terraform's graph.
#
# Without this resource, kubernetes_storage_class_v1.ebs_sc and then the
# cluster itself (whose IAM role Auto Mode uses to call ec2:DeleteVolume) could
# be destroyed as soon as milvus/langfuse/gitea's helm_release resources report
# destroyed, racing that asynchronous reclamation. Once the cluster is gone,
# nothing deletes the remaining volumes, and they leak.
#
# This is a pure Kubernetes-side wait: no AWS API calls, nothing deleted here.
# It blocks until no PersistentVolume remains claimed from the milvus/langfuse/
# gitea namespaces, so the cluster is only torn down once reclamation has
# actually finished.
#
# ORDERING: this resource depends_on ebs_sc (created after it, so destroyed
# BEFORE it — the cluster stays intact through this wait), and each of
# helm_release.milvus/langfuse/gitea depends_on THIS resource (created after
# it, so destroyed BEFORE it — this wait only runs once all three releases are
# already gone).
################################################################################

resource "null_resource" "storage_reclaim_barrier" {
  triggers = {
    cluster_name = module.eks.cluster_name
    region       = local.region
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      export KUBECONFIG="$(mktemp)"
      trap 'rm -f "$KUBECONFIG"' EXIT

      if ! aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.region} --kubeconfig "$KUBECONFIG" >/dev/null 2>&1 \
        || ! kubectl get --raw /readyz >/dev/null 2>&1; then
        echo "[storage-reclaim] cluster unreachable; nothing to wait for."
        exit 0
      fi

      DEADLINE=$(( $(date +%s) + 600 ))
      while :; do
        LEFT=$(kubectl get pv -o jsonpath='{range .items[*]}{.spec.claimRef.namespace}{"\n"}{end}' 2>/dev/null \
          | grep -Ex 'milvus|langfuse|gitea' | wc -l)
        [ "$LEFT" -eq 0 ] && break
        if [ "$(date +%s)" -ge "$DEADLINE" ]; then
          echo "[storage-reclaim] ERROR: gave up after 10 min: $LEFT PV(s) still claimed from milvus/langfuse/gitea." >&2
          echo "[storage-reclaim]        Re-run the destroy to retry, or inspect with: kubectl get pv" >&2
          exit 1
        fi
        echo "[storage-reclaim] $LEFT PV(s) remaining; waiting..."
        sleep 10
      done
      echo "[storage-reclaim] no PVs remain for milvus/langfuse/gitea; safe to delete the cluster."
    EOT
  }

  depends_on = [
    kubernetes_storage_class_v1.ebs_sc,
  ]
}

################################################################################
# Milvus - Vector Database
#
# Milvus stores vector data and index files in Amazon S3 using EKS Pod Identity.
# Its local standalone volume remains Terraform-owned and is handed to the chart
# via existingClaim, instead of letting the chart render its keep-annotated PVC.
# The etcd PVC stays chart-managed and is handled by its
# persistentVolumeClaimRetentionPolicy below.
################################################################################

resource "kubernetes_namespace_v1" "milvus" {
  metadata {
    name = "milvus"
    labels = {
      "kubernetes.io/metadata.name" = "milvus"
    }
  }
  depends_on = [module.eks]
}

# Terraform-owned PVC for Milvus standalone. No resource-policy annotation, so
# nothing blocks deletion. wait_until_bound = false because ebs-sc is
# WaitForFirstConsumer: it stays Pending until the Milvus pod (created by the
# helm_release that depends on it) mounts it, so waiting here would deadlock.
resource "kubernetes_persistent_volume_claim_v1" "milvus_data" {
  metadata {
    name      = "milvus-data"
    namespace = kubernetes_namespace_v1.milvus.metadata[0].name
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

resource "helm_release" "milvus" {
  name = "milvus"
  # Pinned: an unpinned chart resolves to whatever is latest at apply time, so a
  # values path this config relies on (e.g. the persistence/annotations blocks
  # below) can silently move or a chart default can change (see the
  # helm.sh/resource-policy history in this file) without this diff showing it.
  # Bump deliberately; `helm repo add milvus https://zilliztech.github.io/
  # milvus-helm && helm search repo milvus/milvus --versions` lists newer ones.
  version          = "5.0.25"
  repository       = "https://zilliztech.github.io/milvus-helm"
  chart            = "milvus"
  namespace        = kubernetes_namespace_v1.milvus.metadata[0].name
  create_namespace = false
  # wait: true so apply fails fast (bounded by `timeout` below) if
  # standalone/etcd don't reach Ready, rather than deferring that
  # failure to whatever consumes milvus later. Same flag governs uninstall,
  # so destroy also blocks here until this release's own manifest resources
  # return NotFound — though the AUTHORITATIVE destroy-time guarantee is
  # null_resource.storage_reclaim_barrier below, which additionally waits for
  # the volumeClaimTemplate PVC (etcd) and actual PV disappearance. Unlike
  # langfuse (langfuse.tf), there is no known stuck-pod scenario here that a
  # passive wait would get in the way of recovering from — if one turns up,
  # drop this to `wait = false` the same way, for the same reason.
  wait    = true
  timeout = 600

  # Skip Helm's client-side schema check. See
  # module.eks_blueprints_addons_cert_manager in addons.tf.
  disable_openapi_validation = true

  values = [yamlencode({
    cluster = { enabled = false }

    # Keep the Milvus application version fixed even if the chart archive is
    # republished. Chart 5.0.25 normally resolves to this same image.
    image = {
      all = {
        repository = "milvusdb/milvus"
        tag        = "v2.6.21"
        pullPolicy = "IfNotPresent"
      }
    }

    serviceAccount = {
      create = false
      name   = kubernetes_service_account_v1.milvus.metadata[0].name
    }

    standalone = {
      resources = {
        requests = { cpu = "500m", memory = "2Gi" }
        limits   = { memory = "4Gi" }
      }
      persistence = {
        enabled = true
        # Mount the Terraform-owned PVC (see header) instead of letting the chart
        # render its own keep-annotated one. existingClaim makes the chart skip PVC
        # creation entirely.
        persistentVolumeClaim = {
          existingClaim = kubernetes_persistent_volume_claim_v1.milvus_data.metadata[0].name
        }
      }
    }

    etcd = {
      image = {
        registry   = "docker.io"
        repository = "bitnamilegacy/etcd"
        tag        = "3.5.21-debian-12-r0"
      }
      replicaCount = 1
      resources = {
        requests = { cpu = "250m", memory = "512Mi" }
        limits   = { memory = "1Gi" }
      }
      persistence = {
        enabled      = true
        storageClass = "ebs-sc"
        size         = "10Gi"
      }
      # data-milvus-etcd-0 is a StatefulSet volumeClaimTemplate, so HELM NEVER
      # CREATED IT and `helm uninstall` cannot delete it — no annotation helps.
      # This asks the StatefulSet controller to own the PVC (ownerReference), so
      # deleting the StatefulSet garbage-collects the PVC, which then triggers the
      # StorageClass's Delete reclaim. GA since Kubernetes 1.32 (cluster runs
      # var.cluster_version). whenScaled stays Retain: only teardown should drop
      # data, not an operational scale-down.
      persistentVolumeClaimRetentionPolicy = {
        enabled     = true
        whenScaled  = "Retain"
        whenDeleted = "Delete"
      }
    }

    minio = {
      enabled = false
    }

    externalS3 = {
      enabled        = true
      host           = "s3.${local.region}.${data.aws_partition.current.dns_suffix}"
      port           = "443"
      useSSL         = true
      bucketName     = aws_s3_bucket.milvus.bucket
      rootPath       = "milvus"
      useIAM         = true
      cloudProvider  = "aws"
      region         = local.region
      useVirtualHost = true
    }

    pulsarv3 = { enabled = false }
    pulsar   = { enabled = false }
    kafka    = { enabled = false }
  })]

  depends_on = [
    kubernetes_storage_class_v1.ebs_sc,
    # The Terraform-owned PVC must exist before the release mounts it, and on
    # destroy the release must be uninstalled BEFORE the PVC is deleted (Helm
    # leaves it alone; Terraform then deletes it and ebs-sc reclaims the EBS).
    kubernetes_persistent_volume_claim_v1.milvus_data,
    time_sleep.wait_for_milvus_pod_identity,
    time_sleep.wait_60_seconds,
    # Destroy-order guard: this release must be destroyed BEFORE the storage
    # reclaim barrier's wait runs, so the barrier's own destroy always sees
    # milvus already torn down.
    null_resource.storage_reclaim_barrier,
  ]
}
