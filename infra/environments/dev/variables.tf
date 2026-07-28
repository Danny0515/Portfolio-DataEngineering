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
  default     = "raw/market_data/stock/"
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

variable "athena_reader_user_name" {
  description = "需要透過 Athena 人工查詢 medallion 表格的 IAM user 名稱（Lake Formation 的 DESCRIBE/SELECT 權限會 grant 給這個 principal；Lake Formation Data Lake Admin 不會自動有資料讀取權，需要額外 grant）"
  type        = string
  default     = "dannyhuang@cathayholdings.com.tw"
}
