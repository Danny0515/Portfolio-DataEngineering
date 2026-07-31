data "aws_caller_identity" "current" {}

# Shared execution role for the medallion-layer Glue Jobs (Bronze now,
# Silver/Gold later reuse it — they need near-identical S3 + Glue Catalog
# access, so one role avoids repeated Terraform churn per layer).
resource "aws_iam_role" "glue_market" {
  name = "glue-market-job-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "glue.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "glue_service_role" {
  role       = aws_iam_role.glue_market.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

data "aws_iam_policy_document" "glue_market_data_access" {
  statement {
    sid    = "S3ReadWriteMarketPrefixes"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [
      "${aws_s3_bucket.data_engineering.arn}/raw/*",
      "${aws_s3_bucket.data_engineering.arn}/${var.iceberg_warehouse_prefix}*",
      "${aws_s3_bucket.data_engineering.arn}/glue-temp/*",
      "${aws_s3_bucket.data_engineering.arn}/glue-scripts/*",
    ]
  }

  statement {
    sid    = "S3ListMarketPrefixes"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
    ]
    resources = [aws_s3_bucket.data_engineering.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values = [
        "raw/*",
        "${var.iceberg_warehouse_prefix}*",
        "glue-temp/*",
        "glue-scripts/*",
      ]
    }
  }

  statement {
    sid    = "GlueCatalogMedallionDatabases"
    effect = "Allow"
    actions = [
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:CreateTable",
      "glue:GetTable",
      "glue:GetTables",
      "glue:UpdateTable",
      "glue:DeleteTable",
      "glue:GetPartition",
      "glue:GetPartitions",
      "glue:CreatePartition",
      "glue:BatchCreatePartition",
      "glue:BatchGetPartition",
      "glue:BatchDeletePartition",
      "glue:UpdatePartition",
    ]
    resources = concat(
      ["arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:catalog"],
      [
        for db in var.glue_databases :
        "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:database/${db}"
      ],
      [
        for db in var.glue_databases :
        "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${db}/*"
      ],
    )
  }
}

resource "aws_iam_policy" "glue_market_data_access" {
  name   = "glue-market-data-access"
  policy = data.aws_iam_policy_document.glue_market_data_access.json
}

resource "aws_iam_role_policy_attachment" "glue_market_data_access" {
  role       = aws_iam_role.glue_market.name
  policy_arn = aws_iam_policy.glue_market_data_access.arn
}
