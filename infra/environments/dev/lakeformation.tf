# This account's CreateDatabaseDefaultPermissions/CreateTableDefaultPermissions
# are both empty (confirmed via `aws lakeformation get-data-lake-settings`), so
# newly created Glue databases do NOT fall back to the legacy IAM_ALLOWED_PRINCIPALS
# model like older databases in this account do — every principal needs an
# explicit Lake Formation grant, separate from and in addition to the IAM policy
# in iam.tf. Without this, the Glue Job fails with
# "Insufficient Lake Formation permission(s): Required Describe on <db>" even
# though its IAM role already has glue:GetDatabase etc.

resource "aws_lakeformation_permissions" "glue_market_database" {
  for_each = toset(var.glue_databases)

  principal   = aws_iam_role.glue_market.arn
  permissions = ["DESCRIBE", "CREATE_TABLE"]

  database {
    name = each.value
  }
}

# Table-level grant uses a database wildcard so it also covers tables that
# don't exist yet (e.g. bronze.stock on its first CREATE TABLE run),
# matching this project's decision to let Iceberg create tables dynamically
# rather than having Terraform manage table resources individually.
resource "aws_lakeformation_permissions" "glue_market_tables" {
  for_each = toset(var.glue_databases)

  principal   = aws_iam_role.glue_market.arn
  permissions = ["DESCRIBE", "SELECT", "INSERT", "ALTER", "DROP"]

  table {
    database_name = each.value
    wildcard      = true
  }
}

# This project's chief-architect account is deliberately NOT declared here.
# Its permission boundary is governed at the AWS org level (Lake Formation
# Data Lake Admin status), not by this project's Terraform — RULE-003
# explicitly exempts it (see ADR-0005). We tried declaring an explicit grant
# for it first, but Lake Formation self-grant behavior for a Data Lake Admin
# auto-escalates any grant made by that principal to itself into "ALL" plus
# a broader grant-option set on read-back, regardless of what's requested —
# so no Terraform-declared permission list ever converges to a stable
# `terraform plan` (confirmed empirically during rollout). Managing it here
# would mean permanent diff noise, not real drift. See ADR-0005 for the full
# history and the decision to keep this principal's identity out of version
# control entirely (avoids committing a real person's email in `.tf`).
