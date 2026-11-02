# 故障排除總覽 (Troubleshooting Overview)

> 這份文件是「總覽層」：收錄實作過程中遇到、**已解決、但未來可能重複踩到**的錯誤模式——不是零基礎教學（那些見 [docs/concepts/](../concepts/)），也不是單次驗證的存證（那些見 [docs/runbooks/](../runbooks/)）。目的是讓遇到類似症狀時，能快速聯想到「這個之前踩過」並找到解法跟辨識線索。
>
> **實作過程中若遇到預期外的錯誤，先查這份索引**；若沒有對應紀錄，待實作結束後在此新增一則。新增檔案時，檔名以主要技術/症狀關鍵字開頭（比照 [docs/concepts/overview.md](../concepts/overview.md) 的命名規則），方便同類問題在目錄裡排序相鄰。

---

## Python 編譯依賴的平台不符（本機 macOS vs Lambda Amazon Linux）

- **檔案**：[python_compiled-extension-platform-mismatch.md](python_compiled-extension-platform-mismatch.md)
- **症狀**：Lambda 執行時 `ImportModuleError: No module named 'orjson.orjson'`
- **根因**：`orjson`（`aws-glue-schema-registry` 的間接依賴）是編譯過的 Rust extension，本機 macOS 打包抓到 macOS 版 wheel，Lambda（Amazon Linux x86_64）載入不了
- **對應**：[docs/specs/slice2a-cdc-ingestion.md](../specs/slice2a-cdc-ingestion.md) §4 項目 8；[infra/environments/dev-slice2/msk_event_verifier.tf](../../infra/environments/dev-slice2/msk_event_verifier.tf)

---

## RDS 儲存被閒置的 replication slot 寫滿（connector 顯示 RUNNING 但 task 已死）

- **檔案**：[rds-storage-full-idle-replication-slot.md](rds-storage-full-idle-replication-slot.md)
- **症狀**：generator 連不上 RDS 5432、RDS `storage-full`／`PANIC`；`describe-connector` 仍是 `RUNNING` 但 worker log 有 `Broken pipe`
- **根因**：RDS 閒置也每 5 分鐘產生 64MB WAL，而 Debezium 沒有 heartbeat 時 slot 不前進，WAL 一路累積寫滿磁碟（connector 在線但閒置同樣會發生）
- **對應**：[ADR-0013](../architecture/adr/0013-debezium-heartbeat-and-slot-wal-cap.md)；[infra/environments/dev-slice2/msk_connector.tf](../../infra/environments/dev-slice2/msk_connector.tf)、[rds.tf](../../infra/environments/dev-slice2/rds.tf)
