# This account's CreateDatabaseDefaultPermissions/CreateTableDefaultPermissions
# are both empty (confirmed via `aws lakeformation get-data-lake-settings`), so
# newly created Glue databases do NOT fall back to the legacy IAM_ALLOWED_PRINCIPALS
# model like older databases in this account do — every principal needs an
# explicit Lake Formation grant, separate from and in addition to the IAM policy
# in iam.tf. Without this, the Glue Job fails with
# "Insufficient Lake Formation permission(s): Required Describe on <db>" even
# though its IAM role already has glue:GetDatabase etc.

resource "aws_lakeformation_permissions" "glue_market_data_database" {
  for_each = toset(var.glue_databases)

  principal   = aws_iam_role.glue_market_data.arn
  permissions = ["DESCRIBE", "CREATE_TABLE"]

  database {
    name = each.value
  }
}

# Table-level grant uses a database wildcard so it also covers tables that
# don't exist yet (e.g. bronze.stock_data on its first CREATE TABLE run),
# matching this project's decision to let Iceberg create tables dynamically
# rather than having Terraform manage table resources individually.
resource "aws_lakeformation_permissions" "glue_market_data_tables" {
  for_each = toset(var.glue_databases)

  principal   = aws_iam_role.glue_market_data.arn
  permissions = ["DESCRIBE", "SELECT", "INSERT", "ALTER", "DROP"]

  table {
    database_name = each.value
    wildcard      = true
  }
}

# Being a Lake Formation Data Lake Admin (see get-data-lake-settings) grants
# the *ability to manage* permissions, not implicit SELECT access to table
# data — confirmed the hard way via Athena's
# "Relation contains no accessible columns" error when querying bronze.stock_data
# as this user despite admin status. Read-only grant for manual verification
# (e.g. Athena smoke tests), separate from the Glue Job's read/write grant above.
resource "aws_lakeformation_permissions" "athena_reader_database" {
  for_each = toset(var.glue_databases)

  principal   = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/${var.athena_reader_user_name}"
  permissions = ["DESCRIBE"]

  database {
    name = each.value
  }
}

resource "aws_lakeformation_permissions" "athena_reader_tables" {
  for_each = toset(var.glue_databases)

  principal   = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/${var.athena_reader_user_name}"
  permissions = ["DESCRIBE", "SELECT"]

  table {
    database_name = each.value
    wildcard      = true
  }
}
