# ADR-0010: 2b 串流運算選 Glue Streaming，不選 Managed Flink

| 屬性 | 值 |
| --- | --- |
| **狀態** | ✅ `Accepted` |
| **日期** | 2026-10-16 |
| **相關模組** | Slice 2b 串流運算（尚未實作；將位於 `infra/environments/dev-slice2/` 與 `src/transform/`） |
| **決策者** | Danny |

> **範圍註記**：Glue Streaming 的職責範圍已由 [ADR-0012](0012-kafka-connect-iceberg-sink-bronze.md)（💬 `Proposed`）縮小為「Bronze → Silver」，Kafka → Bronze 改由 Iceberg Kafka Connect sink 負責；本 ADR 對「Glue Streaming 優於 Managed Flink」的結論不變。若 ADR-0012 的 spike 不通過，則維持下方的原設計。

## 背景 (Context)

Slice 2b 要把 2a 送進 Kafka 的 CDC 事件落進 Iceberg：`bronze.trade_events` append、`silver.trade` 以 `MERGE INTO` 維護當前狀態。plan.md §2.3／§8 將 Managed Flink 列為串流運算主選、Spark Structured Streaming 列為替代，spec §3.1 原建議選 Flink、Glue Streaming 作為卡關時的降級方案。討論過程中查到的事實，改變了原本的取捨：

- Flink 沒有現成可解 Glue Schema Registry Debezium Avro 的 SQL format，可能得寫 Java DataStream 自訂反序列化。
- Flink Iceberg sink 的 upsert 為「後到者贏」，不比較來源變更序（LSN），重播冪等要自行補排序邏輯。
- Flink × Glue Catalog × 本專案 VPC／Lake Formation 的組合有多項需實測才能確定的未知項（Iceberg sink 搭配 Glue Catalog、hidden partitioning、Athena 讀 equality delete、版本相容矩陣、打包方式等）。

## 決策 (Decision)

Slice 2b 的串流運算採 AWS Glue Streaming（Spark Structured Streaming），在 `foreachBatch` 內以 `MERGE INTO` 寫入 Iceberg，不採 Amazon Managed Service for Apache Flink。Slice 3（即時聚合／視窗）的串流引擎不在此決定，延後到該 Slice 的 spec §3 重新評估。

## 理由 (Rationale)

1. **敘事一致**：本片核心是 Slice 0 的 append 與本片 upsert 的對照。Glue 路線字面上就是 `MERGE INTO`，Pattern Card `cdc-merge-into` 與 Decision Log 的對照不必改寫成「equality delete upsert」。
2. **重播冪等最好證明**：`MERGE INTO ... WHEN MATCHED AND s.lsn > t.lsn` 直接把來源變更序寫進 SQL，重播不會用舊值覆蓋新值；Flink 路線要自行加排序或去重邏輯。
3. **解碼路徑較明確**：2a 的驗證用 Lambda 已有 Python 解碼 Glue SR 的做法可參考；Flink 的對應路徑未驗證。
4. **技術棧連續**：沿用 Glue 5.0、PySpark、`iceberg_spark_conf`、Lake Formation 角色模式與 pytest／本機 `pyspark` 測試。
5. **未知項明顯較少**：Glue 路線剩下的是 Glue connection 連私有子網的 MSK、`MERGE` 的 alias 差異、worker 規格，屬補設定層級。
6. **本片不需要 Flink 的優勢**：2b 的工作是從 topic 把來源資料納入 Lakehouse（topic → Iceberg），可接受秒級的延遲誤差，真串流的低延遲在這裡用不到。Flink 優於 Glue Streaming 的地方是視窗運算（Windowing），那是 Slice 3 才會真正需要的能力，屆時再評估才有意義。
7. **費用不是決定因素**：資料量極小，兩者都是時間計費，差距遠小於忘記銷毀的風險。

**Alternatives considered**：

- **Glue Streaming**（選定）：理由如上。
- Amazon Managed Service for Apache Flink（未選）：真串流、視窗運算強，且 plan.md 主選、Slice 3 本來就要用；但在本片有 15 項需實測的未知風險（Glue SR 解碼、Iceberg sink × Glue Catalog、重播冪等語意、Athena 讀 equality delete、hidden partitioning、版本相容、打包、Lake Formation、VPC 網路、commit 延遲、小檔等），且會把敘事從 `MERGE INTO` 變成 equality delete upsert。

## 影響 (Consequences)

- ✅ **正面**：敘事與 spec 一致、風險低；2b 的產物（Kafka topic 與 Iceberg 表）皆為引擎中立，不會鎖死 Slice 3 的引擎選擇。
- ⚠️ **注意**：Glue 5.0（Spark 3.5.4）的 `MERGE INTO` 對別名解析與 4.0 不同，需用完整限定名；G.025X worker 在 Glue 5.0 是否可用須實測；Glue connection 與 SG 規則需補在 `dev-slice2`；Flink 的 Iceberg／Glue SR 相容性仍未驗證，Slice 3 開始前需做獨立 spike。
- ❌ **負面/限制**：串流引擎要學兩次（Slice 3 若選 Flink）；與 plan.md／execution-roadmap.md 的 Flink 主選不一致，需透過 `planning_project` 同步；微批次延遲為秒級，不是 sub-second。
