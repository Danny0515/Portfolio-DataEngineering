output "bucket_name" {
  description = "本專案專屬資料湖 bucket 名稱"
  value       = aws_s3_bucket.data_engineering.id
}

output "raw_landing_s3_uri" {
  description = "Slice 0 raw landing 的 S3 路徑"
  value       = "s3://${aws_s3_bucket.data_engineering.id}/${var.raw_landing_prefix}"
}

output "iceberg_warehouse_s3_uri" {
  description = "Iceberg warehouse 的 S3 路徑"
  value       = "s3://${aws_s3_bucket.data_engineering.id}/${var.iceberg_warehouse_prefix}"
}

output "glue_databases" {
  description = "已建立的 Glue Data Catalog database 名稱"
  value       = [for db in aws_glue_catalog_database.medallion : db.name]
}

output "glue_execution_role_arn" {
  description = "Medallion Glue Job 共用的執行角色 ARN"
  value       = aws_iam_role.glue_market_data.arn
}

output "glue_bronze_job_name" {
  description = "Bronze 落地 Glue Job 名稱，供 aws glue start-job-run 使用"
  value       = aws_glue_job.bronze_stock_data.name
}
