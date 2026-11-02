# ADR-0013: 以 Debezium heartbeat 與 `max_slot_wal_keep_size` 防止閒置時 replication slot 填滿來源 DB

| 屬性 | 值 |
| --- | --- |
| **狀態** | ✅ `Accepted` |
| **日期** | 2026-10-30 |
| **相關模組** | `infra/environments/dev-slice2/`（`msk_connector.tf`、`rds.tf`）、`src/ingestion/sql/create_trade_table.sql` |
| **決策者** | Danny |

## 背景 (Context)

[ADR-0007](0007-cdc-vs-batch-polling.md) 的注意事項只警告「consumer（Debezium connector）長時間離線」會讓 replication slot 累積 WAL。2026-10-27 至 10-30 的 Slice 2b spike 發現，**connector 在線但整體閒置時同樣會發生**：

- RDS PostgreSQL 的 `archive_timeout=300`、WAL 段 64MB，即使沒有任何業務流量，也每 5 分鐘產生一個 64MB 的 WAL 段（約 0.75GB/小時）。
- logical replication slot 保留 `restart_lsn` 之後的所有 WAL；`restart_lsn` 只有在 Debezium 回報「已處理到某個 LSN」時才前進，而 Debezium 只有處理到被擷取資料表（`public.trade`）的變更時才會回報。原本沒有設定 heartbeat，閒置期間 slot 完全不前進。
- 結果：20GB 儲存在最後一筆事件後約 32 小時被寫滿，RDS `storage-full`，Postgres 反覆 PANIC 當機約 45 小時；Debezium task 死亡，但 MSK Connect 的 connector 狀態仍顯示 `RUNNING`，看不出失效。
- Slice 2a 的驗證都在數小時內完成，所以沒有碰到。

這是 Slice 2a 設計本身的缺口，不是 Slice 2b spike 引入的問題。完整調查與證據見 [slice2b-iceberg-sink-spike-verification.md](../../runbooks/slice2b-iceberg-sink-spike-verification.md)。

## 決策 (Decision)

1. **啟用 Debezium heartbeat**：`heartbeat.interval.ms=60000`，並設定 `heartbeat.action.query`，每次心跳 upsert 一列到心跳表 `debezium_heartbeat`。心跳表不放進 `table.include.list`，不產生業務事件。
2. **在 RDS parameter group 設定 `max_slot_wal_keep_size=10240`**（MB，動態參數，不需重開機）作為保險絲。
3. 心跳表 DDL 納入 `create_trade_table.sql`，與 `trade` 表一起由 `init_schema` 建立。
4. generator Lambda 的唯讀診斷 payload `diagnose_replication` 保留，作為 replication slot 健康度的固定檢查工具。

## 理由 (Rationale)

1. **直接對應根因**：問題是 slot 不前進。heartbeat 讓 WAL 在閒置時也出現真正的寫入，Debezium 才有位置可確認、slot 才能前進。`SELECT 1` 這類不產生 WAL 寫入的 query 沒有效果。
2. **已用實測驗證**：套用後在零交易的狀態下，約 4 分鐘內 slot 保留的 WAL 由 1,792MB 降到 64MB；之後橫跨 3 個 5 分鐘切段週期（約 10 分鐘）維持 64MB、`wal_status=reserved`。
3. **不需要額外處理 publication**：Debezium 建立的 `dbz_publication` 為 `FOR ALL TABLES`，心跳表建立後自動納入。
4. **就地更新、沒有副作用**：修改 Debezium 設定在 AWS provider 5.100.0 為 in-place 更新，task 從原 offset 接續，沒有重新 snapshot、沒有多寫 `r` 事件。
5. **保險絲把失效模式降級**：heartbeat 失效或 connector 長期離線時，slot 超過上限會被作廢，而不是整個資料庫當機；損失的是 CDC 位置，不是來源 DB 的可用性。

**未選方案**：
- 只擴大儲存：只是延後，閒置夠久仍會寫滿。
- 排程對 `trade` 做假寫入：會污染業務資料與 Bronze。
- 只靠營運規則（閒置就拆 stack）：靠人記得，擋不住 connector 在線的閒置情境。

## 影響 (Consequences)

- ✅ **正面**：閒置不再累積 WAL；失效模式由「來源 DB 當機」降為「slot 作廢」；slot 健康度有固定的診斷工具可用。
- ⚠️ **注意**：
  - 多一張心跳表，以及每分鐘一則 `__debezium-heartbeat.transaction` 訊息；該 topic 的 schema 會經 converter 自動註冊進 Glue Schema Registry。心跳不會進 Bronze（Iceberg sink 的 `topics` 是精確指定 `transaction.trade.v1`）。
  - 重建 stack 時，`init_schema` 必須在 connector 建立之前執行（原本的建立流程階段二已是這個順序）。
  - 穩態下 slot 保留量約為一個 WAL 段（64MB），不是 0。
  - 長時間閒置已補測：自 2026-10-30 最後一筆交易後閒置約 70 小時（2026-11-02），slot 保留量仍為 64MB、心跳持續更新；原先沒有 heartbeat 時 32 小時就把 20GB 寫滿。
- ❌ **負面/限制**：`max_slot_wal_keep_size` 一旦觸發，slot 被作廢（`wal_status=lost`），Debezium 必須重建 slot 並重新 snapshot，**期間的事件永久遺失**。目前沒有刪除 replication slot 的工具，實際發生時需要新增 Lambda payload 或重建整組 stack。
