################################################################################
# Warm pool of sandbox-capable node capacity
#
# Keeps one or more Nitro Sandbox-shaped placeholder pods running at negative
# priority so the EC2 capacity a lab's sandbox needs is already provisioned. See
# manifests/sandbox-warm-pool.yaml for the mechanics and the cost trade-off.
#
# Applied with kubectl rather than the kubernetes provider because
# `kubernetes_deployment_v1` does not expose `spec.template.spec.overhead`. That
# field is what claims the `eks.amazonaws.com/nitro-sandbox` slot, so a native
# resource would silently drop the one line that makes this a sandbox
# reservation rather than an ordinary idle pod.
#
# Same pattern as the other manifests/ files: a static YAML applied by
# local-exec, re-applied when the file changes (filemd5 trigger).
################################################################################

resource "null_resource" "sandbox_warm_pool" {
  triggers = {
    cluster_name = module.eks.cluster_name
    region       = local.region
    manifest     = "${path.module}/manifests/sandbox-warm-pool.yaml"
    manifest_md5 = filemd5("${path.module}/manifests/sandbox-warm-pool.yaml")
  }

  provisioner "local-exec" {
    # bash (not the runner's default /bin/sh) for `set -o pipefail`.
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      export KUBECONFIG="$(mktemp)"
      trap 'rm -f "$KUBECONFIG"' EXIT
      aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.region} --kubeconfig "$KUBECONFIG"

      # The RuntimeClass ships with Auto Mode, but the cluster may still be
      # registering it when this runs. Poll rather than fail the apply: without
      # it the Deployment is admitted and its pods stay Pending forever with
      # "RuntimeClass not found".
      for i in $(seq 1 30); do
        if kubectl get runtimeclass isolated-sandbox >/dev/null 2>&1; then break; fi
        echo "  waiting for runtimeclass/isolated-sandbox (attempt $i/30)..."
        sleep 10
      done
      kubectl get runtimeclass isolated-sandbox >/dev/null

      kubectl apply -f "${self.triggers.manifest}"

      # Deliberately NOT waiting for the rollout. The placeholder's whole job is
      # to sit Pending until Auto Mode provisions a node, which takes minutes,
      # and nothing downstream depends on it being Ready.
      echo "sandbox warm pool applied (pods may stay Pending while Auto Mode provisions capacity)"
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      export KUBECONFIG="$(mktemp)"
      trap 'rm -f "$KUBECONFIG"' EXIT
      aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.region} --kubeconfig "$KUBECONFIG" || exit 0
      kubectl delete deployment sandbox-warm-pool --ignore-not-found --timeout=60s || true
      kubectl delete priorityclass sandbox-warm-pool --ignore-not-found --timeout=60s || true
    EOT
  }

  depends_on = [
    # Cluster + Auto Mode node pools must exist before anything can schedule.
    module.eks,
    time_sleep.wait_60_seconds,
  ]
}
