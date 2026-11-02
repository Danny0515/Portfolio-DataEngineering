# RDS 儲存被閒置的 replication slot 寫滿（connector 顯示 RUNNING 但 task 已死）

> 故障排除筆記，**不是**規格或決策紀錄（那些見 [docs/specs/](../specs/)、[docs/architecture/adr/](../architecture/adr/)）。記錄一個「CDC 來源 DB 沒流量卻把磁碟寫滿」的錯誤模式，目的是讓遇到類似症狀時能快速聯想到「這個之前踩過」。決策見 [ADR-0013](../architecture/adr/0013-debezium-heartbeat-and-slot-wal-cap.md)，完整調查過程見 [slice2b-iceberg-sink-spike-verification.md](../runbooks/slice2b-iceberg-sink-spike-verification.md)。

## 症狀

- 呼叫 generator Lambda 時連不上 RDS：`Can't create a connection to host ... port 5432`。
- RDS 事件為 `storage-full`；Postgres 日誌出現 `PANIC ... No space left on device`，之後反覆當機重啟。
- `aws kafkaconnect describe-connector` 的 `connectorState` 仍是 `RUNNING`，但 worker log 在同一時間點出現 `Broken pipe`，task 其實已死、不再產生事件。
- `pg_replication_slots` 中 `restart_lsn` 卡在很久以前的位置，保留的 WAL 以每小時約 0.75GB 成長。

## 根因

RDS PostgreSQL 的 `archive_timeout=300`、WAL 段 64MB，**即使完全沒有業務流量也每 5 分鐘切一個 64MB 的 WAL 段**。logical replication slot 會保留 `restart_lsn` 之後的所有 WAL；而 `restart_lsn` 只有在 Debezium 回報「已處理到某個 LSN」時才會前進，Debezium 只有處理到**被擷取資料表**的變更時才會回報。若沒有設定 heartbeat，stack 閒置時 slot 完全不前進，WAL 一路累積直到磁碟寫滿（20GB 約 32 小時）。

這與「consumer 離線」不同：**connector 在線、但整體閒置時同樣會發生**。

## 解法

已用兩層修補處理（見 ADR-0013）：

1. **Debezium heartbeat**：`heartbeat.interval.ms` + 會真的寫表的 `heartbeat.action.query`（寫 `debezium_heartbeat`），讓 slot 在閒置時也持續前進。`SELECT 1` 這類不產生 WAL 的 query 沒有效果。
2. **`max_slot_wal_keep_size`**（RDS parameter group，目前 10240MB）：保險絲，超過上限時 slot 被作廢而不是把磁碟寫滿。

若已經卡在 `storage-full`：

- 先用 Terraform 擴大 `allocated_storage`（RDS 儲存只能增不能減）讓資料庫恢復。
- 產生任何一筆被擷取資料表的變更，slot 就會前進並釋放 WAL（實測保留量由約 19.75GB 降到 0.25GB）。
- connector 若 task 已死，狀態仍顯示 `RUNNING` 且 MSK Connect 不會自動重啟 task；需以 `terraform apply -replace=aws_mskconnect_connector.debezium_postgres` 重建，**代價是 offset 遺失、重新 snapshot（多寫 `r` 事件），且失效期間的中間狀態事件無法補回**。

## 辨識線索

- 診斷：呼叫 generator 的 `{"diagnose_replication": true}`（只跑 SELECT），看 `slots[].retained_bytes`、`wal_status`、`heartbeat[].ts` 是否每分鐘更新。
- 健康狀態：閒置時 `retained_bytes` 穩定在約 64MB（一個 WAL 段）。持續成長代表 slot 沒在前進。
- 不要只看 `describe-connector` 的狀態判斷 CDC 是否正常；要看 worker log 的 task 錯誤，或直接看 slot 位置。
- `wal_status=lost` 代表 slot 已因超過 `max_slot_wal_keep_size` 被作廢，Debezium 需要重建 slot 並重新 snapshot。
