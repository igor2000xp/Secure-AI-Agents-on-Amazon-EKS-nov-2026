################################################################################
# ECR repositories
#
# Consolidates the "aws ecr create-repository" commands previously in:
#   - content/20-.../200-strands-agents      → customer-agent
#   - content/20-.../500-agent-tools-mcp     → mcp-server
#   - content/20-.../600-multi-agent-a2a     → order-agent, product-agent,
#                                              orchestrator-agent
#
# force_delete = true so destroy / cleanup succeed after participants push
# images.
################################################################################

locals {
  ecr_repositories = toset([
    "customer-agent",
    "mcp-server",
    "order-agent",
    "product-agent",
    "orchestrator-agent",
    # module 900: the sandbox runtime image (sandboxd + pandas/matplotlib).
    "python-runtime-sandbox",
    # agent-sandbox control plane (agent-sandbox.tf). Mirrored from
    # registry.k8s.io so cluster nodes never pull from it at runtime. The
    # sandbox-router is not deployed, so there is no repo for it.
    "agent-sandbox-controller",
    # Built from an upstream clone: the MCP server is the one image upstream
    # does not publish. No "sandboxd" repo — that image IS published, and the
    # two runtime images use it as a build-time FROM base straight from
    # registry.k8s.io.
    "agent-sandbox-mcp-server",
    # module 1000: autonomous coding agent — Gitea mirror, coding runtime, dispatcher.
    "gitea",
    "coding-runtime-sandbox",
    "coding-agent-dispatcher",
  ])
}

resource "aws_ecr_repository" "this" {
  for_each = local.ecr_repositories

  name                 = each.key
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = false
  }

  tags = local.tags
}
