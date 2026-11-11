################################################################################
# Workshop node pool
#
# Replaces Auto Mode's built-in `general-purpose` NodePool (disabled in
# base.tf) with one that consolidates only WhenEmpty and only provisions
# sandbox-capable instances. See manifests/node-pool.yaml for the reasoning.
#
# Applied with kubectl rather than the kubernetes provider: NodePool is a CRD
# that Auto Mode registers after the cluster is up, so the provider would need
# the CRD to exist at plan time. Same pattern as the other manifests/ files —
# a static YAML applied by local-exec, re-applied when the file changes.
#
# This gates the rest of the cluster build (time_sleep.wait_60_seconds depends
# on it), so addons and the support stack schedule onto this pool instead of
# sitting Pending until it appears.
################################################################################

resource "null_resource" "workshop_node_pool" {
  triggers = {
    cluster_name = module.eks.cluster_name
    region       = local.region
    manifest     = "${path.module}/manifests/node-pool.yaml"
    manifest_md5 = filemd5("${path.module}/manifests/node-pool.yaml")
  }

  provisioner "local-exec" {
    # bash (not the runner's default /bin/sh) for `set -o pipefail`.
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      export KUBECONFIG="$(mktemp)"
      trap 'rm -f "$KUBECONFIG"' EXIT
      aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.region} --kubeconfig "$KUBECONFIG"

      # Auto Mode registers the Karpenter CRDs and the managed NodeClass a
      # little after the cluster reports ACTIVE. Poll for both rather than
      # racing them: applying before the CRD exists fails outright, and
      # applying before the NodeClass exists yields a NodePool stuck NotReady.
      for i in $(seq 1 30); do
        if kubectl get crd nodepools.karpenter.sh >/dev/null 2>&1 \
           && kubectl get nodeclass default >/dev/null 2>&1; then
          break
        fi
        echo "  waiting for the Auto Mode NodePool CRD + default NodeClass (attempt $i/30)..."
        sleep 10
      done
      kubectl get crd nodepools.karpenter.sh >/dev/null
      kubectl get nodeclass default >/dev/null

      kubectl apply -f "${self.triggers.manifest}"

      # Fail the apply here, not during the workshop. This is the cluster's
      # only general compute pool, so a bad nodeClassRef or an unsatisfiable
      # requirement would otherwise surface as every pod Pending hours later.
      if ! kubectl wait --for=condition=Ready nodepool/workshop-general-purpose --timeout=120s; then
        echo "ERROR: nodepool/workshop-general-purpose did not become Ready." >&2
        kubectl get nodepool workshop-general-purpose -o yaml >&2 || true
        echo "See the requirements note in manifests/node-pool.yaml." >&2
        exit 1
      fi

      echo "workshop node pool ready (consolidation: WhenEmpty, sandbox-capable instances only)"
    EOT
  }

  provisioner "local-exec" {
    when = destroy
    # --wait=false deliberately: deleting a NodePool makes Karpenter drain and
    # terminate its nodes, and with a 24h terminationGracePeriod that can block
    # a destroy for a long time. Fire and forget; the cluster teardown that
    # follows removes the nodes anyway.
    command = <<-EOT
      export KUBECONFIG="$(mktemp)"
      trap 'rm -f "$KUBECONFIG"' EXIT
      aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.region} --kubeconfig "$KUBECONFIG" || exit 0
      kubectl delete nodepool workshop-general-purpose --ignore-not-found --wait=false || true
    EOT
  }
}
