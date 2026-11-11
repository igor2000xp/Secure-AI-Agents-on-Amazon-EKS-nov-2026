################################################################################
# Order data (DynamoDB) + agent Pod Identity
#
# Replaces the hardcoded ORDERS dict in the agent code with a real DynamoDB
# table. Agent pods read/write it via EKS Pod Identity bound to a dedicated
# "agent" service account. Ephemeral: PAY_PER_REQUEST, no deletion protection,
# and the seed rows are Terraform-managed so `terraform destroy` removes the
# table and its data.
################################################################################

resource "aws_dynamodb_table" "orders" {
  name         = "${local.name}-orders"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "order_id"

  attribute {
    name = "order_id"
    type = "S"
  }

  # GSI key attributes (only keys must be declared; other fields are schemaless).
  attribute {
    name = "period"
    type = "S"
  }
  attribute {
    name = "order_date"
    type = "S"
  }

  # Lets the code-exec broker Query a fiscal-period slice (e.g. "2026-Q1")
  # ordered by order_date, instead of scanning the whole table.
  global_secondary_index {
    name            = "period-index"
    hash_key        = "period"
    range_key       = "order_date"
    projection_type = "ALL"
  }

  tags = local.tags
}

################################################################################
# Seed data — ~500 synthetic orders loaded from a committed data file.
#
# The dataset (data/orders.json) is generated ONCE, locally, by
# data/generate_orders.py and committed as the source of truth, so every event
# gets identical data (stable "hero" orders ORD-1001..ORD-1005, one per status,
# referenced by the lab docs + agent examples). It is loaded via a bash loader
# rather than per-item Terraform resources — 500 aws_dynamodb_table_item
# resources would mean slow plans and bloated state.
#
# scripts/load_orders.sh reads the JSON (already DynamoDB-marshalled), chunks it
# into batches of 25, and calls `aws dynamodb batch-write-item`. PutRequest is an
# upsert, so re-running is idempotent. The filemd5 trigger re-loads only when the
# dataset changes.
#
# `items` is stored as a JSON string (per the tool contract); scalar fields are
# native String attributes. processing/cancelled orders OMIT the `tracking`
# attribute entirely (schemaless null); agent code reads it with .get().
################################################################################

resource "null_resource" "load_orders" {
  triggers = {
    table = aws_dynamodb_table.orders.name
    # Re-run whenever the dataset changes.
    orders_md5 = filemd5("${path.module}/data/orders.json")
  }

  provisioner "local-exec" {
    # /bin/bash (not the runner's default /bin/sh=dash) so `set -o pipefail`
    # and other bashisms in the loader work.
    interpreter = ["/bin/bash", "-c"]
    command = join(" ", [
      "${path.module}/scripts/load_orders.sh",
      aws_dynamodb_table.orders.name,
      local.region,
      "${path.module}/data/orders.json",
    ])
  }

  depends_on = [
    aws_dynamodb_table.orders,
    # Not strictly required for the load itself (the runner writes with its own
    # creds), but keeps the table's access wiring settled before we populate it.
    aws_eks_pod_identity_association.agent,
  ]
}

################################################################################
# Agent service account + Pod Identity → DynamoDB
#
# A dedicated "agent" SA (default namespace) so only agent pods get DynamoDB
# access — not chainlit-ui or other workloads on the default SA. The agent
# deployments set serviceAccountName: agent (see modules/.../k8s.yaml).
################################################################################

resource "kubernetes_service_account_v1" "agent" {
  metadata {
    name      = "agent"
    namespace = "default"
  }

  depends_on = [module.eks]
}

data "aws_iam_policy_document" "agent_pod_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "agent_pod" {
  name               = "${local.name}-agent-pod"
  assume_role_policy = data.aws_iam_policy_document.agent_pod_trust.json
  tags               = local.tags
}

data "aws_iam_policy_document" "agent_pod" {
  statement {
    sid    = "OrdersTableAccess"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      # Query is for the mcp-server's get_orders tool, which fetches a whole
      # fiscal quarter off the period GSI for sandbox analysis. Querying an
      # index needs the index ARN as well as the table's, hence index/* below.
      # Note this widens the orders MCP server's reach: before get_orders it
      # could only read one order at a time by key.
      "dynamodb:Query",
    ]
    resources = [
      aws_dynamodb_table.orders.arn,
      "${aws_dynamodb_table.orders.arn}/index/*",
    ]
  }
}

resource "aws_iam_role_policy" "agent_pod" {
  name   = "agent-pod-dynamodb"
  role   = aws_iam_role.agent_pod.id
  policy = data.aws_iam_policy_document.agent_pod.json
}

resource "aws_eks_pod_identity_association" "agent" {
  cluster_name    = module.eks.cluster_name
  namespace       = kubernetes_service_account_v1.agent.metadata[0].namespace
  service_account = kubernetes_service_account_v1.agent.metadata[0].name
  role_arn        = aws_iam_role.agent_pod.arn
}

#############################################################################