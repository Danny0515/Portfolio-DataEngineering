output "bucket_name" {
  description = "本專案專屬資料湖 bucket 名稱"
  value       = aws_s3_bucket.data_engineering.id
}

output "raw_landing_s3_uri" {
  description = "Slice 0 raw landing 的 S3 路徑"
  value       = "s3://${aws_s3_bucket.data_engineering.id}/${var.raw_landing_prefix}"
}
