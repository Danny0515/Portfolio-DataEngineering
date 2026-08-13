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
  key    = "glue-scripts/bronze_stock.py"
  source = "${path.module}/../../../src/transform/bronze_stock.py"
  etag   = filemd5("${path.module}/../../../src/transform/bronze_stock.py")
}

resource "aws_s3_object" "silver_script" {
  bucket = aws_s3_bucket.data_engineering.id
  key    = "glue-scripts/silver_stock.py"
  source = "${path.module}/../../../src/transform/silver_stock.py"
  etag   = filemd5("${path.module}/../../../src/transform/silver_stock.py")
}

# GX Expectation Suite (spec §4 item 2 output), shipped alongside silver_stock.py
# via --extra-files so the item 4 Audit step can load it without reconstructing
# the FileDataContext project layout on Glue's single-script runtime.
resource "aws_s3_object" "silver_stock_suite" {
  bucket = aws_s3_bucket.data_engineering.id
  key    = "glue-scripts/silver_stock_suite.json"
  source = "${path.module}/../../../src/quality/gx/expectations/silver_stock.json"
  etag   = filemd5("${path.module}/../../../src/quality/gx/expectations/silver_stock.json")
}

resource "aws_s3_object" "gold_script" {
  bucket = aws_s3_bucket.data_engineering.id
  key    = "glue-scripts/gold_monthly_ohlcv.py"
  source = "${path.module}/../../../src/transform/gold_monthly_ohlcv.py"
  etag   = filemd5("${path.module}/../../../src/transform/gold_monthly_ohlcv.py")
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

resource "aws_glue_job" "bronze_stock" {
  name         = "slice0-bronze-stock"
  role_arn     = aws_iam_role.glue_market.arn
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
    "--TempDir"                          = "s3://${aws_s3_bucket.data_engineering.id}/glue-temp/bronze-stock/"
    "--RAW_INPUT_PATH"                   = "s3://${aws_s3_bucket.data_engineering.id}/${var.raw_landing_prefix}"
    "--ICEBERG_DB"                       = "bronze"
    "--ICEBERG_TABLE"                    = "stock"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-metrics"                   = "true"
  }
}

resource "aws_glue_job" "silver_stock" {
  name         = "slice0-silver-stock"
  role_arn     = aws_iam_role.glue_market.arn
  glue_version = "5.0"
  max_retries  = 0
  timeout      = 10

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.data_engineering.id}/${aws_s3_object.silver_script.key}"
    python_version  = "3"
  }

  worker_type       = "G.1X"
  number_of_workers = 2

  default_arguments = {
    "--job-language"                     = "python"
    "--datalake-formats"                 = "iceberg"
    "--conf"                             = local.iceberg_spark_conf
    "--TempDir"                          = "s3://${aws_s3_bucket.data_engineering.id}/glue-temp/silver-stock/"
    "--SOURCE_DB"                        = "bronze"
    "--SOURCE_TABLE"                     = "stock"
    "--ICEBERG_DB"                       = "silver"
    "--ICEBERG_TABLE"                    = "stock"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-metrics"                   = "true"
    # spec §8 GX-on-Spark-on-Glue spike: install GX at job bootstrap and ship
    # the item 2 Expectation Suite JSON alongside the script (item 4 Audit).
    "--additional-python-modules" = "great-expectations==1.19.1"
    "--extra-files"               = "s3://${aws_s3_bucket.data_engineering.id}/${aws_s3_object.silver_stock_suite.key}"
  }
}

resource "aws_glue_job" "gold_monthly_ohlcv" {
  name         = "slice0-gold-monthly-ohlcv"
  role_arn     = aws_iam_role.glue_market.arn
  glue_version = "5.0"
  max_retries  = 0
  timeout      = 10

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.data_engineering.id}/${aws_s3_object.gold_script.key}"
    python_version  = "3"
  }

  worker_type       = "G.1X"
  number_of_workers = 2

  default_arguments = {
    "--job-language"                     = "python"
    "--datalake-formats"                 = "iceberg"
    "--conf"                             = local.iceberg_spark_conf
    "--TempDir"                          = "s3://${aws_s3_bucket.data_engineering.id}/glue-temp/gold-monthly-ohlcv/"
    "--SOURCE_DB"                        = "silver"
    "--SOURCE_TABLE"                     = "stock"
    "--ICEBERG_DB"                       = "gold"
    "--ICEBERG_TABLE"                    = "monthly_ohlcv"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-metrics"                   = "true"
  }
}
