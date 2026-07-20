variable "aws_region" {
  description = "AWS region for Slice 0 資源"
  type        = string
  default     = "ap-northeast-1"
}

variable "bucket_name" {
  description = "本專案專屬的資料湖 bucket 名稱"
  type        = string
  default     = "danny-data-engineering"
}

variable "raw_landing_prefix" {
  description = "Raw landing 資料的 S3 key prefix"
  type        = string
  default     = "raw/market_data/"
}
