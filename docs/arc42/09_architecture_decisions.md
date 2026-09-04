# 9. Architecture Decisions (架構決策)

此文件彙整本專案的重大架構決策摘要，完整推理過程見各 ADR 文件（[docs/architecture/adr/](../architecture/adr/)）。

## 決策狀態表

| 狀態 | 說明 |
| --- | --- |
| 💬 `Proposed` | 正在討論 |
| ✅ `Accepted` | 已拍板並實施中 |
| 🔄 `Superseded` | 已被更新的 ADR 取代，需註明新 ADR 代號 |
| ❌ `Deprecated` | 該決策已移除 |

## 決策總表

| ID | 決策標題 | 狀態 |
| --- | --- | --- |
| [ADR-0001](../architecture/adr/0001-use-iceberg.md) | 為何用 Iceberg 而非直接 Parquet on S3 | ✅ `Accepted` |
| [ADR-0002](../architecture/adr/0002-medallion-layering.md) | 為何分 Bronze/Silver/Gold 三層 | ✅ `Accepted` |
| [ADR-0003](../architecture/adr/0003-append-vs-overwrite.md) | 批次管線的寫入模式（Append vs 全量覆寫）與 Partition 設計 | ✅ `Accepted` |
| [ADR-0004](../architecture/adr/0004-wap-quality-gate.md) | 為何用 WAP (Write-Audit-Publish) Pattern 而非事後檢核 | ✅ `Accepted` |
| [ADR-0005](../architecture/adr/0005-project-admin-permission-exemption.md) | 專案總架構師帳號的 Lake Formation 權限不受本專案 Terraform 管理 | ✅ `Accepted` |
| [ADR-0006](../architecture/adr/0006-msk-vs-kinesis.md) | 為何選 MSK 而非 Kinesis | ✅ `Accepted` |
| [ADR-0007](../architecture/adr/0007-cdc-vs-batch-polling.md) | 為何用 CDC 而非定時撈整張表 | ✅ `Accepted` |
| [ADR-0008](../architecture/adr/0008-lambda-vpc-access-gateway.md) | 私有子網路資源存取：以 Lambda 作為存取閘道，取代 Bastion/SSM | ✅ `Accepted` |
