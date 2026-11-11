################################################################################
# S3 object storage for Milvus and Langfuse
#
# Each workload gets a dedicated private bucket and IAM role. EKS Pod Identity
# supplies short-lived credentials to the pods, so no AWS access keys are
# stored in Terraform state or Kubernetes Secrets.
################################################################################

locals {
  # Keep the account and Region first, then cap the shared portion so the
  # longest bucket name ("-langfuse-xxx") is at most 62 characters.
  object_storage_bucket_prefix = substr(
    lower("${data.aws_caller_identity.current.account_id}-${local.region}-${replace(local.name, "_", "-")}"),
    0,
    49
  )
}

resource "random_string" "object_storage_bucket_suffix" {
  length  = 3
  lower   = true
  upper   = false
  numeric = true
  special = false
}

resource "aws_s3_bucket" "milvus" {
  bucket        = "${local.object_storage_bucket_prefix}-milvus-${random_string.object_storage_bucket_suffix.result}"
  force_destroy = true

  tags = merge(local.tags, {
    Name    = "${local.name}-milvus"
    Service = "milvus"
  })
}

resource "aws_s3_bucket" "langfuse" {
  bucket        = "${local.object_storage_bucket_prefix}-langfuse-${random_string.object_storage_bucket_suffix.result}"
  force_destroy = true

  tags = merge(local.tags, {
    Name    = "${local.name}-langfuse"
    Service = "langfuse"
  })
}

resource "aws_s3_bucket_public_access_block" "milvus" {
  bucket = aws_s3_bucket.milvus.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "langfuse" {
  bucket = aws_s3_bucket.langfuse.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "milvus" {
  bucket = aws_s3_bucket.milvus.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_ownership_controls" "langfuse" {
  bucket = aws_s3_bucket.langfuse.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "milvus" {
  bucket = aws_s3_bucket.milvus.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "langfuse" {
  bucket = aws_s3_bucket.langfuse.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

data "aws_iam_policy_document" "milvus_bucket" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = [
      aws_s3_bucket.milvus.arn,
      "${aws_s3_bucket.milvus.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

data "aws_iam_policy_document" "langfuse_bucket" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = [
      aws_s3_bucket.langfuse.arn,
      "${aws_s3_bucket.langfuse.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "milvus" {
  bucket = aws_s3_bucket.milvus.id
  policy = data.aws_iam_policy_document.milvus_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.milvus]
}

resource "aws_s3_bucket_policy" "langfuse" {
  bucket = aws_s3_bucket.langfuse.id
  policy = data.aws_iam_policy_document.langfuse_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.langfuse]
}

################################################################################
# IAM roles scoped to each workload's bucket
################################################################################

data "aws_iam_policy_document" "object_storage_pod_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "milvus_s3" {
  name               = "${local.name}-milvus-s3"
  assume_role_policy = data.aws_iam_policy_document.object_storage_pod_trust.json
  tags               = local.tags
}

resource "aws_iam_role" "langfuse_s3" {
  name               = "${local.name}-langfuse-s3"
  assume_role_policy = data.aws_iam_policy_document.object_storage_pod_trust.json
  tags               = local.tags
}

data "aws_iam_policy_document" "milvus_s3" {
  statement {
    sid    = "MilvusBucketMetadata"
    effect = "Allow"
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
    ]
    resources = [aws_s3_bucket.milvus.arn]
  }

  statement {
    sid    = "MilvusObjects"
    effect = "Allow"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:ListMultipartUploadParts",
      "s3:PutObject",
    ]
    resources = ["${aws_s3_bucket.milvus.arn}/*"]
  }
}

data "aws_iam_policy_document" "langfuse_s3" {
  statement {
    sid    = "LangfuseBucketMetadata"
    effect = "Allow"
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
    ]
    resources = [aws_s3_bucket.langfuse.arn]
  }

  statement {
    sid    = "LangfuseObjects"
    effect = "Allow"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:ListMultipartUploadParts",
      "s3:PutObject",
    ]
    resources = ["${aws_s3_bucket.langfuse.arn}/*"]
  }
}

resource "aws_iam_role_policy" "milvus_s3" {
  name   = "milvus-s3"
  role   = aws_iam_role.milvus_s3.id
  policy = data.aws_iam_policy_document.milvus_s3.json
}

resource "aws_iam_role_policy" "langfuse_s3" {
  name   = "langfuse-s3"
  role   = aws_iam_role.langfuse_s3.id
  policy = data.aws_iam_policy_document.langfuse_s3.json
}

################################################################################
# Kubernetes service accounts and EKS Pod Identity associations
################################################################################

resource "kubernetes_namespace_v1" "langfuse" {
  metadata {
    name = "langfuse"
    labels = {
      "kubernetes.io/metadata.name" = "langfuse"
    }
  }

  depends_on = [module.eks]
}

resource "kubernetes_service_account_v1" "milvus" {
  metadata {
    name      = "milvus"
    namespace = kubernetes_namespace_v1.milvus.metadata[0].name
  }
}

resource "kubernetes_service_account_v1" "langfuse" {
  metadata {
    name      = "langfuse"
    namespace = kubernetes_namespace_v1.langfuse.metadata[0].name
  }
}

resource "aws_eks_pod_identity_association" "milvus" {
  cluster_name    = module.eks.cluster_name
  namespace       = kubernetes_namespace_v1.milvus.metadata[0].name
  service_account = kubernetes_service_account_v1.milvus.metadata[0].name
  role_arn        = aws_iam_role.milvus_s3.arn

  depends_on = [aws_iam_role_policy.milvus_s3]
}

resource "time_sleep" "wait_for_milvus_pod_identity" {
  create_duration = "5s"

  depends_on = [aws_eks_pod_identity_association.milvus]
}

resource "aws_eks_pod_identity_association" "langfuse" {
  cluster_name    = module.eks.cluster_name
  namespace       = kubernetes_namespace_v1.langfuse.metadata[0].name
  service_account = kubernetes_service_account_v1.langfuse.metadata[0].name
  role_arn        = aws_iam_role.langfuse_s3.arn

  depends_on = [aws_iam_role_policy.langfuse_s3]
}
