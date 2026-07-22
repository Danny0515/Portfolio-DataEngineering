# Infra 現況 — dev 環境

> 記錄 dev 環境目前由 Terraform 實際管理、已部署的資源現況。**這是快照，每次 `terraform apply` 後直接覆寫更新，不累加歷史**（歷史異動查 git log 或 changelog.md）。內容一律以 bastion 上 `terraform output` / `terraform state list` 的實際輸出為準，不手動編造。

**最後更新**：2026-07-22
**Terraform 工作目錄**：`infra/environments/dev/`（bastion 上對應 `~/Portfolio-DataEngineering/infra/environments/dev/`）
**State 位置**：`s3://danny-data-engineering/terraform-state/dev/slice0.tfstate`

## Outputs（`terraform output`）

| Key | Value |
| --- | --- |
| bucket_name | `danny-data-engineering` |
| raw_landing_s3_uri | `s3://danny-data-engineering/raw/market_data/stock/` |

## 已管理資源（`terraform state list`）

- `aws_s3_bucket.data_engineering`
- `aws_s3_bucket_versioning.data_engineering`
- `aws_s3_bucket_server_side_encryption_configuration.data_engineering`
- `aws_s3_bucket_public_access_block.data_engineering`
