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
  default     = "raw/market/stock/"
}

variable "iceberg_warehouse_prefix" {
  description = "Iceberg warehouse 的 S3 key prefix，Bronze/Silver/Gold table 資料與 metadata 落地位置"
  type        = string
  default     = "lakehouse/"
}

variable "glue_databases" {
  description = "Medallion 分層對應的 Glue Data Catalog database 名稱"
  type        = list(string)
  default     = ["bronze", "silver", "gold"]
}

