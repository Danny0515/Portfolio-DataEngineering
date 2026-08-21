# Infra 現況 — dev 環境

> 記錄 dev 環境目前由 Terraform 實際管理、已部署的資源現況。**這是快照，每次 `terraform apply` 後直接覆寫更新，不累加歷史**（歷史異動查 git log 或 changelog.md）。內容一律以 `terraform output` / `terraform state list` 的實際輸出為準，不手動編造。

**最後更新**：2026-08-20
**Terraform 工作目錄**：`infra/environments/dev/`（依 RULE-002，優先在本機以 `AWS_PROFILE=dt-lab-long-term-mfa` 執行；MFA 連線失敗才退回 bastion `~/Portfolio-DataEngineering/infra/environments/dev/`）
**State 位置**：`s3://danny-data-engineering/terraform-state/dev/slice0.tfstate`

## Outputs（`terraform output`）

| Key | Value |
| --- | --- |
| bucket_name | `danny-data-engineering` |
| raw_landing_s3_uri | `s3://danny-data-engineering/raw/market/stock/` |
| iceberg_warehouse_s3_uri | `s3://danny-data-engineering/lakehouse/` |
| glue_databases | `["bronze", "gold", "silver"]` |
| glue_execution_role_arn | `arn:aws:iam::393326654921:role/glue-market-job-role` |
| glue_bronze_job_name | `slice0-bronze-stock` |
| glue_silver_job_name | `slice0-silver-stock` |
| glue_gold_job_name | `slice0-gold-monthly-ohlcv` |

## 已管理資源（`terraform state list`）

- `aws_s3_bucket.data_engineering`
- `aws_s3_bucket_versioning.data_engineering`
- `aws_s3_bucket_server_side_encryption_configuration.data_engineering`
- `aws_s3_bucket_public_access_block.data_engineering`
- `aws_glue_catalog_database.medallion["bronze"]`
- `aws_glue_catalog_database.medallion["gold"]`
- `aws_glue_catalog_database.medallion["silver"]`
- `aws_iam_role.glue_market`
- `aws_iam_policy.glue_market_data_access`
- `aws_iam_role_policy_attachment.glue_service_role`
- `aws_iam_role_policy_attachment.glue_market_data_access`
- `aws_lakeformation_permissions.glue_market_database["bronze"|"silver"|"gold"]`
- `aws_lakeformation_permissions.glue_market_tables["bronze"|"silver"|"gold"]`
- `aws_s3_object.bronze_script`
- `aws_s3_object.silver_script`
- `aws_s3_object.gold_script`
- `aws_glue_job.bronze_stock`
- `aws_glue_job.silver_stock`
- `aws_glue_job.gold_monthly_ohlcv`

> 專案總架構師帳號的 Lake Formation 授權不在此追蹤（刻意不由本專案 Terraform 管理，理由見 [ADR-0005](../../docs/architecture/adr/0005-project-admin-permission-exemption.md)），其現況需直接查 `aws lakeformation list-permissions`，不會出現在上方清單。
