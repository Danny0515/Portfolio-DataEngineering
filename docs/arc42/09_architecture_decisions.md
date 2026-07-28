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
