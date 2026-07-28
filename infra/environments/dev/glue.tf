resource "aws_glue_catalog_database" "medallion" {
  for_each = toset(var.glue_databases)

  name        = each.value
  description = "danny-test"

  # No location_uri: Iceberg tables derive their actual S3 location from the
  # Spark catalog's `warehouse` config (see aws_glue_job below), not from the
  # Glue database's LocationUri. Setting it here would be cosmetic and could
  # mislead readers into thinking it controls where data lands.
}

resource "aws_s3_object" "bronze_script" {
  bucket = aws_s3_bucket.data_engineering.id
  key    = "glue-scripts/bronze_stock_data.py"
  source = "${path.module}/../../../src/transform/bronze_stock_data.py"
  etag   = filemd5("${path.module}/../../../src/transform/bronze_stock_data.py")
}

locals {
  iceberg_warehouse_s3_uri = "s3://${aws_s3_bucket.data_engineering.id}/${var.iceberg_warehouse_prefix}"

  # Multiple Spark --conf entries are packed into a single job-parameter
  # string, each pair after the first prefixed with " --conf " (AWS Glue's
  # documented pattern for --datalake-formats=iceberg + Glue Data Catalog).
  iceberg_spark_conf = join(" --conf ", [
    "spark.sql.extensions=org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions",
    "spark.sql.catalog.glue_catalog=org.apache.iceberg.spark.SparkCatalog",
    "spark.sql.catalog.glue_catalog.warehouse=${local.iceberg_warehouse_s3_uri}",
    "spark.sql.catalog.glue_catalog.catalog-impl=org.apache.iceberg.aws.glue.GlueCatalog",
    "spark.sql.catalog.glue_catalog.io-impl=org.apache.iceberg.aws.s3.S3FileIO",
  ])
}

resource "aws_glue_job" "bronze_stock_data" {
  name         = "slice0-bronze-stock-data"
  role_arn     = aws_iam_role.glue_market_data.arn
  glue_version = "5.0"
  max_retries  = 0
  timeout      = 10

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.data_engineering.id}/${aws_s3_object.bronze_script.key}"
    python_version  = "3"
  }

  worker_type       = "G.1X"
  number_of_workers = 2

  default_arguments = {
    "--job-language"                     = "python"
    "--datalake-formats"                 = "iceberg"
    "--conf"                             = local.iceberg_spark_conf
    "--TempDir"                          = "s3://${aws_s3_bucket.data_engineering.id}/glue-temp/bronze-stock-data/"
    "--RAW_INPUT_PATH"                   = "s3://${aws_s3_bucket.data_engineering.id}/${var.raw_landing_prefix}"
    "--ICEBERG_DB"                       = "bronze"
    "--ICEBERG_TABLE"                    = "stock_data"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-metrics"                   = "true"
  }
}
