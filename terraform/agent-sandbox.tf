################################################################################
# agent-sandbox control plane
#
# Installs the upstream kubernetes-sigs/agent-sandbox controller and its four
# CRDs — Sandbox, SandboxClaim, SandboxTemplate, SandboxWarmPool — so the
# "Agents using a sandbox" lab can ask for a sandbox through a Kubernetes API
# instead of hand-building a Pod.
#
# This sits ON TOP of Nitro Sandboxes rather than replacing them. A Sandbox's
# `spec.podTemplate` carries an ordinary pod spec, including
# `runtimeClassName`, so a SandboxTemplate that names `isolated-sandbox` makes
# every vended sandbox a Nitro Sandbox micro-VM. agent-sandbox supplies the
# lifecycle API (claim, bind, GC, warm pools); the Nitro hypervisor supplies the
# isolation boundary.
#
# WHAT CHANGED SINCE THE PRE-con320 INSTALL (v0.5.0 -> v1.x)
#   * The sandbox-router is gone. v0.5.0 shipped a router Deployment + Service
#     that proxied traffic to sandboxes, plus an ECR mirror and an ingress
#     NetworkPolicy for it. v1.x has no router at all: the release carries one
#     Deployment and one image, and clients connect to the sandbox pod directly
#     (the SDK's in-cluster connection configs).
#   * Install is one vendored file. v0.5.0 needed manifest.yaml +
#     extensions.yaml applied in order; v1.x publishes a combined
#     `sandbox-with-extensions.yaml`.
#   * No kata. The old SandboxTemplates named the `kata-fc` RuntimeClass, which
#     needed a self-managed Karpenter nested-virt node pool. `isolated-sandbox`
#     ships with EKS Auto Mode.
#
# Install method + ordering mirror gateways.tf: null_resource + kubectl, wait
# for CRDs Established and the controller Available before anything creates a
# CR, ordered destroy.
################################################################################

locals {
  # Version comes from the vendor manifest's sources.yaml, the single place a
  # vendored version is written down (see manifests/vendor/README.md).
  agent_sandbox_version = local.vendor_sources["agent-sandbox"].version
  agent_sandbox_dir     = "${local.vendor_dir}/agent-sandbox/${local.agent_sandbox_version}"
  agent_sandbox_file    = "${local.agent_sandbox_dir}/sandbox-with-extensions.yaml"

  # Upstream image ref in the vendored manifest, and the ECR mirror we rewrite
  # it to. The mirror is populated by crane in codebuild-images.tf.
  agent_sandbox_image_upstream = "registry.k8s.io/agent-sandbox/agent-sandbox-controller:${local.agent_sandbox_version}"
  agent_sandbox_image_mirror   = "${local.ecr_registry}/agent-sandbox-controller:${local.agent_sandbox_version}"

  # Namespace the lab's SandboxTemplate / WarmPool / SandboxClaims live in.
  # (The controller itself runs in agent-sandbox-system, created by the manifest.)
  agent_sandbox_namespace = "agent-sandbox"

  # The lab's SandboxTemplate + WarmPool. Separate from the vendored upstream
  # file because this one is ours: it is where runtimeClassName, the sandbox
  # overhead and the air-gap NetworkPolicy live.
  agent_sandbox_template_file = "${path.module}/manifests/agent-sandbox-template.yaml"

  # The coding agent's template + pool. Separate file because its posture is
  # different: an egress ALLOWLIST (gateway + Gitea) rather than an air gap, and
  # a bigger guest.
  agent_sandbox_coding_template_file = "${path.module}/manifests/agent-sandbox-coding-template.yaml"
}

resource "null_resource" "agent_sandbox" {
  triggers = {
    cluster_name = module.eks.cluster_name
    region       = local.region
    version      = local.agent_sandbox_version
    image        = local.agent_sandbox_image_mirror
    manifest     = local.agent_sandbox_file
    manifest_md5 = filemd5(local.agent_sandbox_file)
    sandbox_ns   = local.agent_sandbox_namespace
    template     = local.agent_sandbox_template_file
    template_md5 = filemd5(local.agent_sandbox_template_file)
    coding       = local.agent_sandbox_coding_template_file
    coding_md5   = filemd5(local.agent_sandbox_coding_template_file)
    ecr          = local.ecr_registry
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      export KUBECONFIG="$(mktemp)"
      trap 'rm -f "$KUBECONFIG"' EXIT
      aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.region} --kubeconfig "$KUBECONFIG"

      # Repoint the controller image at our ECR mirror. Done with sed on the way
      # in rather than a kustomize patch to keep the vendored file byte-identical
      # to the upstream release — `vendor-manifests.sh verify` hashes it.
      #
      # --server-side: the CRDs in this file are large enough to blow the
      # client-side last-applied-configuration annotation limit.
      sed "s|${local.agent_sandbox_image_upstream}|${self.triggers.image}|g" "${self.triggers.manifest}" \
        | kubectl apply --server-side --force-conflicts -f -

      # Nothing may create a CR until the CRDs are Established.
      kubectl wait --for=condition=Established --timeout=120s \
        crd/sandboxes.agents.x-k8s.io \
        crd/sandboxtemplates.extensions.agents.x-k8s.io \
        crd/sandboxwarmpools.extensions.agents.x-k8s.io \
        crd/sandboxclaims.extensions.agents.x-k8s.io

      # ...and until the controller is actually serving, or the first
      # SandboxClaim sits Pending with nothing to reconcile it.
      kubectl rollout status -n agent-sandbox-system deploy/agent-sandbox-controller --timeout=300s

      # Namespace for the lab's sandbox objects. The explicit label keeps
      # namespaceSelector-based NetworkPolicies working on clusters that do not
      # add kubernetes.io/metadata.name automatically.
      kubectl create namespace "${self.triggers.sandbox_ns}" --dry-run=client -o yaml | kubectl apply -f -
      kubectl label namespace "${self.triggers.sandbox_ns}" \
        "kubernetes.io/metadata.name=${self.triggers.sandbox_ns}" --overwrite

      # The lab's SandboxTemplate + WarmPool. Applied after the namespace
      # exists and the controller is up, so the pool starts pre-booting
      # immediately. __ECR__ is sed'd rather than templated into the file so
      # the manifest stays readable (and kubectl-appliable) on its own.
      sed "s|__ECR__|${self.triggers.ecr}|g" "${self.triggers.template}" | kubectl apply -f -
      sed "s|__ECR__|${self.triggers.ecr}|g" "${self.triggers.coding}" | kubectl apply -f -

      # Deliberately NOT waiting for the pool to be ready: a warm sandbox is a
      # full micro-VM boot plus possibly a node provision, which takes minutes,
      # and nothing downstream in the apply depends on it. A claim that arrives
      # before the pool is warm just pays a cold start.
      echo "agent-sandbox ${self.triggers.version} installed (controller in agent-sandbox-system, template + warm pool in ${self.triggers.sandbox_ns})"
    EOT
  }

  provisioner "local-exec" {
    when = destroy
    # Order matters and every delete is bounded. A Sandbox or warm-pool object
    # whose controller is already gone keeps its finalizer forever, so an
    # unbounded namespace delete would hang the whole destroy.
    command = <<-EOT
      export KUBECONFIG="$(mktemp)"
      trap 'rm -f "$KUBECONFIG"' EXIT
      aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.region} --kubeconfig "$KUBECONFIG" || exit 0
      ns="${self.triggers.sandbox_ns}"
      kubectl delete sandboxclaim --all -n "$ns" --ignore-not-found --timeout=60s || true
      kubectl delete sandbox --all -n "$ns" --ignore-not-found --timeout=60s || true
      kubectl delete sandboxwarmpool --all -n "$ns" --ignore-not-found --timeout=60s || true
      kubectl delete sandboxtemplate --all -n "$ns" --ignore-not-found --timeout=60s || true
      kubectl delete namespace "$ns" --ignore-not-found --timeout=120s || true
      kubectl delete -f "${self.triggers.manifest}" --ignore-not-found --timeout=180s || true
    EOT
  }

  depends_on = [
    module.eks,
    # The controller image must be in the ECR mirror before the Deployment
    # tries to pull it.
    null_resource.build_images,
    # Only general compute pool now that general-purpose is off.
    null_resource.workshop_node_pool,
  ]
}
