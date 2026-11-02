# Runbook: Slice 2b Iceberg sink spike 驗證（§4 項目 1(a)）

## 背景 (Why)

對應 [docs/specs/slice2b-streaming-upsert.md](../specs/slice2b-streaming-upsert.md) §4 項目 1(a) 與 [ADR-0012](../architecture/adr/0012-kafka-connect-iceberg-sink-bronze.md)（✅ Accepted，本報告的 spike 通過後由使用者確認）：Kafka → Bronze 改由 **Apache Iceberg Kafka Connect sink（跑在 MSK Connect）** 負責，取代原本 Glue Streaming 直連 Kafka 的設計。這份 runbook 在正式環境（MSK Connect + Glue Catalog + Athena）驗證這條路徑能不能走通，並記錄過程中的真實失敗、修正與副作用。

**範圍限制**：只涵蓋 (a)（sink → Bronze）。(b)（Glue Streaming 讀 Bronze、`MERGE INTO` 寫 Silver）尚未執行，等你確認 (a) 的結果後才做；因此 **ADR-0012 狀態、spec §4 項目 1 的 ✅ 都沒有動**。

寫入的表一律用 spike 專用名稱 `bronze.spike_trade_events`，不碰日後正式的 `bronze.trade_events`。

## 結論摘要

| 問題 | 結果 |
| --- | --- |
| sink 能否在 MSK Connect 上運作 | ✅ 可以，但需要兩項設定修正（見「失敗與修正」） |
| 產物是否含 Glue Catalog 所需的 AWS 元件 | ✅ 發行 zip 已含 `iceberg-aws`、AWS SDK v2 的 `glue`／`s3`／`sts`／`lakeformation` jar，不需另補 aws bundle |
| 能否解 Glue Schema Registry 的 Debezium Avro（與 sink 合併成單一 plugin） | ✅ 無 classloader 衝突，事件正確寫入 |
| Athena 讀得到 | ✅ |
| tombstone（value 為 null）處理 | ✅ 不寫入、不報錯（16 則訊息 → 15 列） |
| 持續 append | ✅ 每個有資料的 commit 產生一個 append 快照；沒資料的 commit 不產生空快照 |
| 表建立方式 | auto-create 可行但需要過寬權限（`glue:CreateDatabase`＋LF `CREATE_DATABASE`）；**正式設計建議改為預先建表** |
| 同一交易內多筆變更的 LSN 是否各不相同 | ✅ 各不相同、嚴格遞增 |
| `op='r'`（重新 snapshot）的 LSN 順序 | 已實測，結論與 spec 原假設不同，見下 |
| 2a 證據缺口：真實 schema 相容性 | ✅ `BACKWARD`（2026-10-27 已確認） |
| (b) Silver 串流 | ⬜ 未執行 |

**另有一個與 sink 無關、但影響整個 Slice 2 運維的重大發現**：stack 閒置約 1 天 RDS 就會被 WAL 填滿，見「非預期發現」。

## 前置條件

- Slice 2 stack 已依 [slice2-stack-lifecycle.md](slice2-stack-lifecycle.md) 冷啟動（2026-10-27）。
- 本機 MFA session（`dt-lab-long-term-mfa`）有效。
- Terraform：[`msk_connector_iceberg_sink.tf`](../../infra/environments/dev-slice2/msk_connector_iceberg_sink.tf)（新增檔，spike 專用，可整檔移除）。

## 部署

### 產物與打包

- 來源：Confluent Hub「Apache Iceberg Sink Connector」1.9.2（`iceberg-iceberg-kafka-connect-1.9.2.zip`，159MB，sha1 `52dab2ff2b9659008deec803d1c1e92813c5ffa7` 核對通過）。Maven Central 只有核心 jar，沒有含依賴的發行版。
- 內容：234 個 jar（Iceberg 1.9.2、AWS SDK 2.29.52、Hadoop 3.4.1、Avro 1.12.0 等）。
- 精簡：移除 GCP／Azure／gRPC／OpenTelemetry 相關 61 個 jar（比對檔名 `azure|google|grpc|gcs|proto-google|opencensus|opentelemetry`），`lib` 由 165MB 降到 131MB。
- 合併：與 Glue SR converter jar（1.1.25）放進同一個 zip（MSK Connect 一個 connector 只能掛一個 plugin，見 [Pattern Card](../patterns/msk-connect-single-plugin-per-connector.md)），最終 zip 186,518,335 bytes（約 186MB），MSK Connect 接受，plugin 狀態 `ACTIVE`（無文件載明的大小限制被觸發）。

### 關鍵 connector 設定

`connector.class=org.apache.iceberg.connect.IcebergSinkConnector`、`topics=transaction.trade.v1`、`iceberg.tables=bronze.spike_trade_events`、`iceberg.tables.auto-create-enabled=true`、`iceberg.tables.evolve-schema-enabled=true`、GlueCatalog＋S3FileIO＋warehouse `s3://danny-data-engineering/lakehouse/`、`iceberg.control.topic=control-iceberg-spike`、`iceberg.control.commit.interval-ms=60000`（預設 300000，spike 縮短）、value converter 為 `AWSKafkaAvroConverter`、1 MCU／1 worker。

## 失敗與修正（依發生順序）

### 失敗 1：task 卡在 `InitProducerId`，約 60 秒後被殺

```
ERROR WorkerSinkTask{id=slice2-iceberg-sink-spike-0} Task threw an uncaught and unrecoverable exception.
org.apache.kafka.common.errors.TimeoutException: Timeout expired after 60000ms while awaiting InitProducerId
```

- **推測的原因**（修正後問題消失，但沒有直接查 broker 側證據）：sink 的 control topic 使用交易式 producer，需要 `__transaction_state` 內部 topic；預設副本數（3）大於本叢集 broker 數（2），建不出來。
- **修正**：[`msk.tf`](../../infra/environments/dev-slice2/msk.tf) 的 broker 設定新增 `transaction.state.log.replication.factor=2`、`transaction.state.log.min.isr=1`；`terraform apply` 就地更新（2 項更新、0 銷毀），cluster rolling restart 約 9 分 41 秒。
- 修正後該錯誤不再出現。注意：MSK Connect 不會自動重啟已被殺的 task，需要重建 connector（`terraform apply -replace=aws_mskconnect_connector.iceberg_sink`）。

### 失敗 2：自動建表時被拒絕 `glue:CreateDatabase`

```
AccessDeniedException: User: arn:aws:sts::393326654921:assumed-role/slice2-msk-connect-iceberg-sink/... is not authorized to perform: glue:CreateDatabase on resource: arn:aws:glue:ap-northeast-1:393326654921:catalog
```

- **原因**：開啟 auto-create 時，sink 在建表前會無條件嘗試建立 namespace（`bronze` 已存在也一樣，先過授權才吃 `AlreadyExists`）。
- **修正（spike 專用、過寬）**：IAM 加 `glue:CreateDatabase`（範圍限定 catalog 與 `database/bronze`），另加 Lake Formation catalog 層級的 `CREATE_DATABASE` grant。
- **建議**：正式設計**預先建表**（schema-first），就不需要這組權限；spike 建出的表結構可用 `SHOW CREATE TABLE` 當正式 DDL 的依據（對應 `docs/TODO.md`「建表與寫資料拆分」）。

## 驗證結果

### 自動建出的表結構

```
before      struct<trade_id:string,account_id:string,symbol:string,price:decimal(38,2),quantity:int,side:string,status:string,event_time:string,updated_at:string>
after       （同 before）
source      struct<version,connector,name,ts_ms:bigint,snapshot,db,sequence,ts_us,ts_ns,schema,table,txId:bigint,lsn:bigint,xmin:bigint>
transaction struct<id:string,total_order:bigint,data_collection_order:bigint>
op string, ts_ms bigint, ts_us bigint, ts_ns bigint
```

觀察：`price` 變成 `decimal(38,2)`（Avro 為 `decimal(12,2)`，sink 轉 Connect Decimal 時精度被放寬為 38，scale 保留）；`event_time`／`updated_at` 是字串（Debezium `ZonedTimestamp`）；`before`／`after`／`source` 是有型別的結構欄位，Silver 可直接用 `after.trade_id`、`source.lsn`，不需要解析 JSON。表由 sink 建立，`table_type=ICEBERG`，位置 `s3://danny-data-engineering/lakehouse/bronze.db/spike_trade_events`。

### 對帳

topic 當時有 16 則訊息（`c` 5、`u` 9、`d` 1、tombstone 1）→ Bronze 15 列（`c` 5、`u` 9、`d` 1）。tombstone 未寫入、task 無錯誤。這是 sink 的預設行為；若日後想保留刪除的「墓碑」語意，需另設處理。

### 持續 append 與 commit

`"spike_trade_events$snapshots"`：6 個快照，全部 `append`，各 1 個 data file（記錄數 15、4、2、7、3、1）。`committed to 0 table(s)` 的空週期**不會**產生空快照。commit 間隔 60 秒；事件進 topic 到出現在 Bronze 約 1–2 分鐘（受 commit 週期與 Athena 查詢時機影響，非精確量測）。每個有資料的 60 秒週期會多一個小檔，長期需要 compaction（已列於 spec §8 風險）。

### 附帶實測 1：同一交易內多筆變更的 LSN

新增 generator payload `multi_update_tx`，在單一交易（`txId=1573`）內對同一筆交易做 1 次 INSERT＋3 次 UPDATE：

| op | status | `source.lsn` | txId |
| --- | --- | --- | --- |
| c | NEW | 21541946544 | 1573 |
| u | PARTIALLY_FILLED | 21541947864 | 1573 |
| u | PARTIALLY_FILLED | 21541948096 | 1573 |
| u | FILLED | 21541948344 | 1573 |

**結論：同一交易內各筆變更的 `source.lsn` 各不相同、嚴格遞增**，spec §3.3 的 `s.source_lsn > t.source_lsn`（嚴格大於）成立，不需要 tie-break。

### 附帶實測 2：`op='r'`（初始快照）的 LSN

重建 Debezium connector 後重新 snapshot，6 筆 `r` 事件的 `source.lsn` 全部相同（`21273510984`，快照時的 WAL 位置）。與同批交易先前的 `c`／`u`／`d`（`5.3×10⁸` 量級）比較，**`r` 的 LSN 比先前事件大**，而重建後才發生的新事件（`2.14×10¹⁰` 起）又比 `r` 大。

**結論與 spec 原假設不同**：spec 原寫「確認 `r` 的 LSN 小於其後同一筆交易的 `c`/`u`/`d`」，實測是「`r` 的 LSN 反映快照當下的 WAL 位置，大於快照前的事件、小於快照後的事件」。MERGE 用嚴格大於仍正確（快照後的新事件 LSN 較大會覆蓋；快照前的舊事件不會蓋掉 `r`），但同一個 `trade_id` 在 `r` 之後可能不會再出現快照前的 `c`/`u`（見下方「歷史遺失」）。**spec §3.3 的此項前提描述需要更正**（未更動，待你確認）。

### 附帶實測 3：`trade_id` 重建後是否重複

`seed=1` 的 `trade_id` 前綴：2026-10-02 為 `T1790928976`、2026-10-27 為 `T1793082654`，id 由當下時間決定、不是由 seed 決定，是正面證據。**完整跨重建驗證仍未做**，維持「尚待驗證」。

## 非預期發現：RDS 被 WAL 填滿（影響整個 Slice 2 運維）

| 時間（UTC） | `OldestReplicationSlotLag` | `TransactionLogsDiskUsage` | `FreeStorageSpace` |
| --- | --- | --- | --- |
| 10/27 04:04 | 7.19 GB | 7.25 GB | 19.29 GB |
| 10/27 16:04 | 16.19 GB | 16.25 GB | 12.00 GB |
| 10/28 04:04 | 19.12 GB | 19.22 GB | 3.00 GB |
| 10/28 16:04 起 | — | 19.2 GB | 約 0.05 GB（`storage-full`） |

- **現象**：stack 閒置（沒有新交易）期間，replication slot（`slice2_trade_slot`）沒有前進，RDS 持續保留 WAL，約 **0.75 GB／小時**；20GB 儲存在約 1 天內被填滿，RDS 進入 `storage-full`，generator 連不上（`Can't create a connection ... port 5432`）。
- **推測的原因**（由 CloudWatch 指標與 Debezium 行為推論，尚未用 `pg_replication_slots` 直接確認）：slot 只在被擷取的表有變更時才前進，RDS 內部寫入產生的 WAL 被 slot 一直保留。ADR-0007 的「⚠️ 注意」寫的是「consumer 長時間離線」，這次 connector 是 `RUNNING` 的，也會發生。
- **Debezium task 也被拖死**：`2026-10-28 08:02:53` 起出現 `Producer failure ... Database connection failed when writing to copy ... Broken pipe`，之後 topic 沒有新事件，但 `describe-connector` 仍回報 `RUNNING`（connector 層級狀態看不出 task 失效）。重建 connector 後才恢復。
- **處置**：`rds.tf` 的 `allocated_storage` 20 → 30GB 並加 `apply_immediately=true`（就地更新，約 3 分 54 秒）。這只是延後，不是根治。
- **根治方向（未實作、未驗證）**：見下方「WAL 累積的根因（已用直接證據確認）」一節的方案。這屬於 2a 的設計缺口，不在本 spike 順手改。

### WAL 累積的根因（已用直接證據確認）

為了確認原因，我在 generator Lambda 加了一個**唯讀**診斷 payload（`diagnose_replication`，只跑 SELECT，查 `pg_replication_slots` 等），並讀了 RDS 的 Postgres 日誌與 CloudWatch 指標：

| 證據 | 內容 |
| --- | --- |
| RDS 閒置時自己持續產生 WAL | `archive_timeout=300`、`wal_segment_size=64MB`；checkpoint 日誌每 5 分鐘一筆 `distance=65536 kB`；`TransactionLogsGeneration` 平均 223,696 bytes/秒 ＝ 64MiB ÷ 300 秒，換算 **0.75 GiB／小時**（約 18GB／天），與 slot lag 的成長速度吻合 |
| slot 的 `restart_lsn` 長期卡住 | 診斷結果：`restart_lsn=0/20003610`（2026-10-27 第一批事件的位置），`current_lsn=5/C0004E8`，保留 WAL 21,139,279,576 bytes（約 19.7GiB）；`max_slot_wal_keep_size=-1`（無上限） |
| slot 建立時間 | Postgres 日誌：`2026-10-27 06:29:42 UTC` 建立 `slice2_trade_slot`，從此沒有再前進，直到本次實驗 |
| 磁碟滿與當機 | 日誌：`2026-10-28 08:02:48 UTC PANIC: could not write to file "pg_wal/xlogtemp.1352": No space left on device`，之後約 45 小時反覆 `FATAL ... No space left on device` 與 `terminating any other active server processes`（crash loop），直到儲存擴大 |
| Debezium 側 | `08:02:53` `Database connection failed when writing to copy ... Broken pipe`，之後 connector 回報 `RUNNING` 但 task 已不送事件 |
| **直接實驗** | 儲存擴大後，產生 1 筆交易（會產生被擷取的變更）→ 約 45 秒後 `restart_lsn` 由 `0/20003610` 跳到 `5/F68`，保留 WAL 由 **19.75 GB 降到 0.25 GB**，之後穩定 |

**因果鏈**：
1. RDS 即使完全沒有流量，也每 5 分鐘切一個 64MB WAL 段。
2. logical replication slot 會保留 `restart_lsn` 之後的全部 WAL。
3. `restart_lsn` 只有在 Debezium 回報「已處理到某個 LSN」之後才會前進；而 Debezium **只有在處理到被擷取的資料表（`public.trade`）的變更時才會回報**，沒有設定 heartbeat，所以閒置期間完全不前進。
4. 閒置約 32 小時（10/27 06:30 → 10/28 08:02）20GB 被填滿，Postgres PANIC。
5. 一旦有被擷取的變更，Debezium 回報新位置，WAL 立刻釋放。

**這不是 sink 的問題**，是 2a 的 Debezium 設定缺口：ADR-0007 的「⚠️ 注意」只講了「consumer 長時間離線」，實際上 **connector 在線但閒置也會發生**；原先 2a 驗證都在數小時內完成所以沒有碰到。

另外，時間點上有一個沒有完全釐清的細節：`confirmed_flush_lsn` 似乎會落後最新一批事件約一個批次才被回報（TX 事件在 06:10 已處理、`confirmed_flush` 仍停在前一批，直到下一次有新變更才更新）。這不影響上面的結論，但表示 heartbeat 也需要實測它推進 slot 的時機。

## 解決與驗證：永久修補（Debezium heartbeat + `max_slot_wal_keep_size`）

這個缺口是 Slice 2a 設計本身的問題（不是 spike 的產物），因此修補**永久保留，不隨 spike 一起復原**；決策記錄見 [ADR-0013](../architecture/adr/0013-debezium-heartbeat-and-slot-wal-cap.md)。

### 採用的做法

| 方案 | 內容 | 位置 |
| --- | --- | --- |
| A. Debezium heartbeat | 每 60 秒（`heartbeat.interval.ms=60000`）執行 `heartbeat.action.query`，對心跳表 `debezium_heartbeat` upsert 一列，讓 WAL 出現真正的寫入、slot 才有位置可確認 | [msk_connector.tf](../../infra/environments/dev-slice2/msk_connector.tf)、[create_trade_table.sql](../../src/ingestion/sql/create_trade_table.sql) |
| B. `max_slot_wal_keep_size` | `10240`（MB，約 10GB，動態參數）。heartbeat 失效或 connector 長期離線時，slot 會被作廢而不是把磁碟寫滿 | [rds.tf](../../infra/environments/dev-slice2/rds.tf) |

### 實施過程與實測結果（2026-10-30，UTC）

| 步驟 | 結果 |
| --- | --- |
| 前置檢查（唯讀 `diagnose_replication`） | publication `dbz_publication` 的 `puballtables=True`，涵蓋所有資料表，心跳表建好後自動納入（事前擔心的「`filtered` publication 不含心跳表、slot 不前進」不成立）；`max_slot_wal_keep_size` 當時尚是舊值 |
| 部署 generator + 參數 | `terraform apply -target=aws_lambda_function.trade_generator`；plan 連帶納入 `aws_db_parameter_group.trade` 就地更新（Lambda 依賴 RDS）。套用後 `diagnose_replication` 回報 `max_slot_wal_keep_size=10240` |
| 建心跳表 | invoke `{"init_schema": true}`；`publication_tables` 立即出現 `public.debezium_heartbeat` |
| Debezium connector | `terraform plan` 顯示 `aws_mskconnect_connector.debezium_postgres` 為 **in-place 更新**（非重建，provider 5.100.0 支援）；以 `-target` 套用，約 39 秒完成。task 就地重啟，log 顯示 `WAL resume position ... discovered`，**從原 offset 接續，沒有重新 snapshot，沒有多寫 `r` 事件** |
| 心跳寫入 | 套用後 1 分鐘內 `debezium_heartbeat.ts` 開始每分鐘更新（08:42:07、08:43:07、08:44:07…） |
| slot 前進（不產生任何交易） | 08:41:05 retained 1,728MB → 08:44:54 **64MB**；`confirmed_flush_lsn` 由 `5/10000738` 跳至 `5/7C00BB00`，`restart_lsn` 隨後跟上 |
| 持續性（約 10 分鐘、橫跨 3 個 5 分鐘 WAL 切段週期，期間不產生交易） | 08:45:52、08:50:43、08:55:35 三次取樣，retained 皆 **64MB**、`wal_status=reserved`，先前每 5 分鐘 +64MB 的累積消失 |
| Glue Schema Registry | registry 新增 `__debezium-heartbeat.transaction`（心跳訊息經 converter 自動註冊），沒有 `AccessDenied`，現有 IAM 足夠 |
| worker log | 套用後 10 分鐘內沒有 ERROR／Exception／AccessDenied |
| 回歸 | 產生 1 筆交易（`trade_id=T1793349929-0000`，`c`＋`u`＋`d`）：`bronze.spike_trade_events` 35 → 38 列，每列皆有 `trade_id`，沒有心跳列混入 Bronze（sink 的 `topics` 是精確指定 `transaction.trade.v1`） |

### 未驗證／已知限制

- **長時間閒置**（數小時以上）未實測；目前證據是約 10 分鐘、3 個切段週期。
- **B 觸發後的實際行為**（slot 被作廢、`wal_status=lost`、Debezium 失敗模式與復原）未實測，也不打算人為觸發。目前沒有刪除 replication slot 的工具（generator 只有唯讀診斷）；實際發生時需新增 payload 或重建整組 stack。
- 心跳 topic `__debezium-heartbeat.transaction` 是否有訊息，只能由 Glue SR 已註冊該 schema 間接推論（沒有 Kafka 管理介面可直接列 topic）。
- 穩態下 `restart_lsn` 會落後 `confirmed_flush_lsn` 約一個心跳週期，所以保留量固定停在約一個 WAL 段（64MB）而不是 0；這是預期現象，不是異常。

## 歷史遺失（重建 Debezium connector 的代價）

為了讓已死亡的 task 恢復，我重建了 Debezium connector。新 connector 沒有舊的 offset，於是重新做 initial snapshot：產生 6 筆 `r` 事件，之後才進入串流。**重建前、因 task 已死而沒有送進 topic 的 batch 2（3 筆交易的 3 `c`＋5 `u`＋1 `d`）只剩 snapshot 後的最終狀態（`r`），中間狀態（NEW → PARTIALLY_FILLED → FILLED）永久遺失**，這也是 CDC 在 connector 失效期間的固有風險。

## (b) Silver 串流：Bronze → Silver（2026-10-30）

### 設計與部署

- 腳本 [silver_trade_stream.py](../../src/transform/silver_trade_stream.py)；Glue job `slice2b-silver-trade-stream-spike`（[glue_silver_trade_stream.tf](../../infra/environments/dev/glue_silver_trade_stream.tf)，放 `dev` 環境，`gluestreaming`、Glue 5.0、**G.025X × 2**、timeout 180 分鐘當安全網）。
- 讀 `bronze.spike_trade_events`（`readStream.format("iceberg")`，觸發間隔 60 秒），`foreachBatch` 內先對批次做「每個 `trade_id` 取最大 `source.lsn`」（`op='d'` 取 `before` 並標 `is_deleted=true`），再對 `silver.spike_trade` 做 `MERGE INTO ... WHEN MATCHED AND 新 LSN > 舊 LSN THEN UPDATE ... WHEN NOT MATCHED THEN INSERT`。不含品質規則與 rejects 表（項目 5）。
- 純轉換函式 `latest_per_trade` 有 8 個本機 pyspark 單元測試（[test_silver_trade_stream.py](../../tests/transform/test_silver_trade_stream.py)），MERGE 本身只能在 Glue 驗證。
- **不需要新增任何 IAM／Lake Formation**：既有 `glue_market` 角色與 `bronze`／`silver` 的 wildcard 授權，就能讀由另一個 principal（sink 角色）建立的 Bronze 表，也能建立並寫入 `silver.spike_trade`；事前的假設成立。
- MERGE 用**完整限定名**寫法（依 ADR-0010 的提醒）在 Glue 5.0 直接成功，沒有用到備援的別名寫法。

### 實測結果

| Run | 設定 | 結果 |
| --- | --- | --- |
| 1 | `STREAM_FROM_TIMESTAMP`＝06:00 UTC，只讀較新的快照 | 啟動約 1 分 20 秒後 Silver 有資料；batch 0 MERGE 6 筆，這 6 列與參考答案一致 |
| 2 | 新 checkpoint、從頭讀 | batch 0 MERGE 13 筆；Silver 13 列與參考答案（由 Athena 對 Bronze 算出「每個 `trade_id` 取最大 LSN」）**0 差異**，含 3 筆軟刪除 |
| 2（續） | job 不停，用 generator 再產生 3 筆交易，再 1 筆 | 新交易依序在 batch 1／2／3 進入 Silver，與 Bronze 最新狀態一致；最終 Silver 17 列、與參考答案 0 差異 |
| 3 | 從頭讀，加 `streaming-max-rows-per-micro-batch=5`、觸發 10 秒 | **跑約 8 分鐘完全沒有批次**（沒有任何串流進度紀錄，引擎訊息為 `idle and waiting for new data`）；原因沒有診斷，只知道該選項下讀不到資料，因此未用於後續測試 |
| 4 | 新 checkpoint、從頭讀（**在 Bronze compaction 之後**） | batch 0 MERGE 17 筆；其餘 16 列不變，只有 `T1793352042-0000` 從 `NEW` 更新為 `FILLED`——它的 UPDATE 在 Run 2 停止後才被 sink commit，這是補上遲到的事件，不是異常 |
| 5 | 先用 Athena 把 Silver 一列改成 `source_lsn=999999999999`、`status='TAMPERED'`（模擬「Silver 已有比 Bronze 事件更新的狀態」），再從頭重播 | 該列**維持 `TAMPERED`**（舊事件 LSN 較小，被嚴格 `>` 擋下），其餘 16 列與參考答案一致；測試後已將該列還原為原值並確認 17 列 0 差異 |

結論：
- **MERGE 正確性**：LSN 較大者勝、嚴格 `>`、重播冪等、軟刪除、`r`／`c`／`u`／`d` 全部成立。
- **G.025X 在 Glue 5.0 的 `gluestreaming` 可用**：`start-job-run` 後立即進入 `RUNNING`，第一批 MERGE 約在啟動後 75 秒完成；`batch-stop-job-run` 後約 50～70 秒才進入 `STOPPED`。並行上限為 1，剛停掉一個 run 的瞬間再啟動會得到 `ConcurrentRunsExceededException`，需稍等。
- **compaction 的影響**：job 執行中對 Bronze 做 Athena `OPTIMIZE ... REWRITE DATA USING BIN_PACK`（12 個檔案合併為 1 個，產生 `replace` 快照，總筆數不變）。job 沒有失敗，**也沒有把已壓縮的舊資料重新送出**（隨後的新交易那一批只 MERGE 1 筆）；compaction 之後從頭重讀（Run 4／5）依然能讀到完整歷史。
- **延遲**：Silver 比 Bronze 晚 9～62 秒（受 60 秒觸發間隔支配）。端到端的大頭在 sink：兩次實測都是一筆交易的第一批事件在數秒內 commit，後續事件約 3 分鐘後才 commit（Bronze 快照 09:14:56／09:18:03、09:20:43／09:24:04）。(a) 時曾觀察到 1～2 分鐘，這次較長，**原因未釐清**（commit 間隔設定為 60 秒），不應直接當作 SLA。
- **發現並修正的問題**：Run 2 的 `numInputRows` 約為 Bronze 實際列數的 4 倍，原因是 `foreachBatch` 內對同一個 DataFrame 連續做 `isEmpty()`、`count()`、`MERGE`，每個動作都重掃來源；改為 `persist()` 後 Run 5 的 `numInputRows` 為 48，等於 Bronze 的實際列數。
- Silver 為 copy-on-write，快照類型是 `append`／`overwrite`；重播時即使只有一列有變化，也會重寫含該列的資料檔。

### 未驗證

- **以同一個 checkpoint 停止後再續跑**（斷點續傳）：每個 run 都使用新的 checkpoint，沒有測試。
- `streaming-max-rows-per-micro-batch` 為何讀不到資料（Run 3）。
- 真實資料量與長時間執行下 G.025X 的記憶體與批次耗時；快照過期（`expire_snapshots`）與孤兒檔清理對串流讀取的影響。
- sink 後續 commit 為何延遲約 3 分鐘。
- 逐筆品質規則、`silver.trade_rejects`、正式表名（項目 2～5）。

## 結論

**已解決**：sink 技術上可行（plugin 打包、解 Glue SR Debezium Avro、寫入 Glue Catalog、Athena 讀取、tombstone、持續 append）；auto-create 的授權缺口與 2-broker 的交易 topic 問題都已找到並記錄；同交易 LSN、`r` 的 LSN 行為有實測答案。

**未解決／未驗證**：
- (b) 已完成主要驗證（見「(b) Silver 串流」）；其「未驗證」清單另列（斷點續傳、真實資料量、`expire_snapshots` 影響、sink 後續 commit 約 3 分鐘延遲的原因）。
- DLQ 端到端觸發（維持 2a 的現況）。
- `trade_id` 的完整跨重建驗證。
- 正式設計的建表方式（預先建表）尚未實作；此 spike 的 auto-create 需要過寬權限，不建議沿用。

**已處理**：WAL／heartbeat 缺口已用 heartbeat + `max_slot_wal_keep_size` 永久修補並實測有效（見「解決與驗證」、[ADR-0013](../architecture/adr/0013-debezium-heartbeat-and-slot-wal-cap.md)）。

**(b) 的結論**：Glue Streaming（G.025X、Glue 5.0）讀 Bronze（Iceberg）並 `MERGE INTO` Silver 技術上可行：LSN 排序、重播冪等、軟刪除、亂序防護、compaction 的 `replace` 快照都通過實測，且不需新增 IAM／Lake Formation。依此 (a)(b) 兩個 spike 皆通過；ADR-0012 已由使用者確認轉為 `Accepted`（2026-11-02）；spec §4 項目 1 的勾選**尚未改動**。

**待決定**：(1) spec §4 項目 1 是否勾 ✅；(2) 是否修正 spec §3.3 對 `op='r'` LSN 的假設（(a) 實測與假設不符）；(3) spike 資源的移除：使用者決定不保留 spike，待三次 commit 完成後另以一個 commit 移除 spike 的程式與設定（保留 spike 版本於前面的 commit 以便退回），雲端資源與 `bronze.spike_trade_events`／`silver.spike_trade` 依下方台帳處理。

## 副作用台帳

### 可復原

| 類別 | 項目 | 復原方式 |
| --- | --- | --- |
| 程式 | 新增 `infra/environments/dev-slice2/msk_connector_iceberg_sink.tf`（未 commit） | 刪檔 → `terraform apply`，銷毀 plugin／connector／role／policy／log group／3 組 LF grant／S3 plugin 物件 |
| 程式 | `infra/environments/dev-slice2/msk.tf`：broker 設定新增 2 行（未 commit） | `git restore` → `terraform apply`（會再觸發 rolling restart）；此設定在 2-broker 下是 sink 的必要條件，若保留 sink 應保留 |
| 程式 | `infra/environments/dev-slice2/rds.tf`：儲存 20 → 30GB、`apply_immediately`（未 commit）。⚠️ 同檔另有**永久修補**的 `max_slot_wal_keep_size` 參數，**不可整檔 `git restore`**，只能還原儲存那幾行 | `git restore` 不能縮小已擴大的儲存，**RDS 儲存只能增不能減**；實際復原只能隨 stack 銷毀 |
| 程式 | `src/ingestion/generate_trade_data.py`：新增 `multi_update_tx`（未 commit，既有 7 個測試通過） | `git restore` → `terraform apply -target=aws_lambda_function.trade_generator`；或保留當測試工具 |
| 程式 | 本機 `build/iceberg_sink_plugin*`、`build/spike_dl/`、`/tmp/slice2_*`、`/tmp/athena_q.sh` | 刪除即可（`build/` 已被 git 忽略） |
| 雲端資源 | sink 的 Terraform 資源（共 14 個 state 項目，含 data source 與 null_resource） | 同上 |
| 資料 | Iceberg 表 `bronze.spike_trade_events`：32 列、6 個快照、S3 25 個物件共 212,662 bytes | Athena `DROP TABLE`（Iceberg 會連資料一起刪）並清 `lakehouse/bronze.db/spike_trade_events/`；**S3 開了版本控制，會留下 delete marker／舊版本，需另外清除**；**需你確認才執行** |
| 資料 | Athena 查詢結果：`athena-results/spike/` 70 個物件共 6,106 bytes | 清該 prefix（版本控制同上） |
| 資料 | 來源 RDS 的交易資料列（目前存留 10 筆） | 隨 stack 銷毀 |
| 程式 | (b) 新增 `infra/environments/dev/glue_silver_trade_stream.tf`、`src/transform/silver_trade_stream.py`、`tests/transform/test_silver_trade_stream.py`（皆未 commit） | 刪檔 → 在 `dev` 環境 `terraform apply`，銷毀 Glue job `slice2b-silver-trade-stream-spike` 與 S3 腳本物件 `glue-scripts/silver_trade_stream.py` |
| 雲端資源 | Glue job `slice2b-silver-trade-stream-spike`（`dev` state，2 個資源）；5 次 run 皆已 `STOPPED` | 同上；串流 job 不會自己結束，使用時務必 `batch-stop-job-run` |
| 資料 | Iceberg 表 `silver.spike_trade`：17 列、9 個快照、S3 53 個物件共 305,777 bytes（含 Athena `UPDATE` 測試留下的刪除檔） | Athena `DROP TABLE`（Iceberg 連資料一起刪）並清 `lakehouse/silver.db/spike_trade/`；S3 開了版本控制會留 delete marker／舊版本；**需你確認才執行** |
| 資料 | 串流 checkpoint：`glue-temp/spike-silver-trade/`（run1～run5 與 tmp，39 個物件共 6,443 bytes） | 清該 prefix（版本控制同上） |
| 資料 | `athena-results/spike/` 累計 181 個物件共 28,677 bytes（含 (a) 與 (b)） | 清該 prefix（版本控制同上） |
| 資料 | Bronze `bronze.spike_trade_events` 現為 48 列（`r` 6、`c` 15、`u` 24、`d` 3）；另有 Athena `OPTIMIZE` 產生的 `replace` 快照（12 個檔案合併為 1 個） | 與 (a) 的 Bronze 表一併處理（`DROP TABLE`）；`replace` 快照無法單獨還原 |
| 資料 | Silver 測試列 `T1793082654-0000` 曾被人為改成 `TAMPERED` | 已還原為原值並確認 17 列與參考答案 0 差異 |

### 永久修補（不隨 spike 復原）

> 這些是 WAL 缺口的修補，已實測有效並由 [ADR-0013](../architecture/adr/0013-debezium-heartbeat-and-slot-wal-cap.md) 記錄。**復原 spike 時不要動它們**；會與 spike 檔案混在同一個檔案裡的，已在上表標註。

| 類別 | 項目 | 說明 |
| --- | --- | --- |
| 程式 | `src/ingestion/sql/create_trade_table.sql`：新增心跳表 `debezium_heartbeat` | 冪等 DDL，已在 RDS 執行 |
| 程式 | `infra/environments/dev-slice2/msk_connector.tf`：`heartbeat.interval.ms`、`heartbeat.action.query` | Debezium connector 就地更新，沒有重建 |
| 程式 | `infra/environments/dev-slice2/rds.tf`：parameter group 的 `max_slot_wal_keep_size=10240` | 動態參數，已生效 |
| 程式 | `src/ingestion/generate_trade_data.py`：唯讀診斷 payload `diagnose_replication`（slot／walsender／交易／publication／心跳表，只跑 SELECT） | 升格為 slot 健康度診斷工具，保留 |
| 資料 | RDS 內的 `debezium_heartbeat` 表（1 列，每分鐘更新） | 隨 stack 銷毀；WAL 寫入量可忽略 |
| 資料（不可移除） | topic `__debezium-heartbeat.transaction` 每分鐘 1 則訊息；Glue Schema Registry 的 schema `__debezium-heartbeat.transaction` | 與其他 topic 一樣只能隨 stack 銷毀；不會進 Bronze |

### 無法復原

| 項目 | 說明 |
| --- | --- |
| 寫進 `transaction.trade.v1` 的事件 | 目前共 33 則：`c` 9、`u` 16、`d` 1、`r` 6、tombstone 1；其中 `r` 6 筆是重建 Debezium 後的 snapshot。topic 沒有刪除介面，只能隨 stack 銷毀 |
| sink 自動建立的 control topic `control-iceberg-spike` 與 consumer group（`connect-slice2-iceberg-sink-spike`、`…-coord`、`cg-control-*`）的位移 | 同上 |
| 因 broker 設定變更而建立的 `__transaction_state` 內部 topic | 同上（存在與否沒有直接列出，由修正後 task 正常運作推論） |
| 舊 Debezium connector 的 `__amazon_msk_connect_*` 內部 topic（connector 已重建一次） | 同上 |
| batch 2 的中間狀態事件（見「歷史遺失」） | 無法補回 |
| MSK 的 configuration 新增了 revision 2 | revision 不能刪除，隨 stack 銷毀 |
| RDS 儲存已擴大到 30GB | 只能增不能減 |
| (b) 階段與 WAL 修補驗證期間再經 generator 寫進 `transaction.trade.v1` 的事件 | 4 筆交易共 10 個 `c`／`u` 事件（Bronze 由 38 列增為 48 列）；加上 WAL 修補驗證用的那一筆交易的 `c`／`u`／`d` 與 tombstone；topic 只能隨 stack 銷毀 |
| `__debezium-heartbeat.transaction` 的心跳訊息 | 每分鐘 1 則，持續累積至 stack 銷毀（屬永久修補的一部分） |

### 復原指令（未執行，等你確認）

```bash
# 1. 移除 sink 與其 IAM／LF（刪除 msk_connector_iceberg_sink.tf 後）
cd infra/environments/dev-slice2 && terraform plan && terraform apply

# 2. 移除 spike 資料表與查詢結果（會刪資料，需確認）
aws athena start-query-execution --query-string "DROP TABLE bronze.spike_trade_events" \
  --result-configuration OutputLocation=s3://danny-data-engineering/athena-results/spike/
aws s3 rm s3://danny-data-engineering/lakehouse/bronze.db/spike_trade_events/ --recursive
aws s3 rm s3://danny-data-engineering/athena-results/spike/ --recursive
```

## 相關文件

- [docs/specs/slice2b-streaming-upsert.md](../specs/slice2b-streaming-upsert.md) §3.1、§3.3、§4 項目 1
- [ADR-0012](../architecture/adr/0012-kafka-connect-iceberg-sink-bronze.md)、[ADR-0007](../architecture/adr/0007-cdc-vs-batch-polling.md)（replication slot 注意事項）
- [slice2-stack-lifecycle.md](slice2-stack-lifecycle.md) — 需補上「閒置會填滿 RDS」的警語（尚未更新）
- [slice2-msk-connect-plugin-packaging-verification.md](slice2-msk-connect-plugin-packaging-verification.md) — 格式參考
- [infra/environments/dev-slice2/msk_connector_iceberg_sink.tf](../../infra/environments/dev-slice2/msk_connector_iceberg_sink.tf)
