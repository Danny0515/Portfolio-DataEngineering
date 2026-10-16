# Decision Log

> 跨 Slice 累積的技術選型決策索引。每筆條目是輕量索引——完整背景/理由留在原始 spec 章節，這裡只記「選了什麼、為什麼、隸屬哪個 ADR」，避免與 spec/ADR 內容重複。定位見 [execution-roadmap.md](../execution-roadmap.md) §3「每個 Slice 的完成 Gate」步驟 4：ADR 記大架構決策，Decision Log 記支撐該決策的技術選型細節。

| 日期 | 決策 | 隸屬 ADR | 詳細理由 |
| --- | --- | --- | --- |
| 2026-08-07 | Slice1 品質檢核工具選 **Great Expectations**，不選 Soda Core | [ADR-0004](architecture/adr/0004-wap-quality-gate.md) | [slice1-quality-contract.md §3.1](specs/slice1-quality-contract.md#31-品質檢核工具great-expectations-vs-soda-core) |
| 2026-08-07 | Slice1 WAP 暫存機制選 **Iceberg 原生 branch**，不降級為手動 staging table（AWS 環境已驗證支援） | [ADR-0004](architecture/adr/0004-wap-quality-gate.md) | [slice1-quality-contract.md §3.2](specs/slice1-quality-contract.md#32-wap-暫存分支機制iceberg-原生-branch-vs-手動-staging-table) |
| 2026-08-07 | Slice1 Data Contract 涵蓋範圍選**限縮版**：Silver 完整品質規則 + Gold schema-only，不含聚合一致性檢查 | [ADR-0004](architecture/adr/0004-wap-quality-gate.md) | [slice1-quality-contract.md §3.4](specs/slice1-quality-contract.md#34-data-contract-範圍) |
| 2026-08-21 | Slice2a 交易來源選 **RDS PostgreSQL**，不選 RDS MySQL、自架 EC2 或直接用 generator 寫 Kafka | [ADR-0007](architecture/adr/0007-cdc-vs-batch-polling.md) | [slice2a-cdc-ingestion.md §3.1](specs/slice2a-cdc-ingestion.md#31-交易來源真-oltp-db-vs-直接-producer-寫-kafka) |
| 2026-08-21 | Slice2a CDC 擷取方式選 **Debezium + MSK Connect**，不選 AWS DMS 或自架 Debezium Server | [ADR-0006](architecture/adr/0006-msk-vs-kinesis.md) | [slice2a-cdc-ingestion.md §3.2](specs/slice2a-cdc-ingestion.md#32-cdc-擷取方式debezium-on-msk-connect-vs-aws-dms-vs-自架-debezium-server) |
| 2026-08-21 | Slice2a MSK 佈署選 **Provisioned**（`kafka.t3.small` × 2）＋生命週期採**用完即拆**（獨立 `slice2.tfstate`） | 無對應 ADR（成本／生命週期營運決策，非架構取捨） | [slice2a-cdc-ingestion.md §3.3](specs/slice2a-cdc-ingestion.md#33-kafka-佈署形態與資源生命週期) |
| 2026-08-21 | Slice2a 序列化格式選 **Avro + AWS Glue Schema Registry**，相容性模式 `BACKWARD`、違約訊息送 DLQ | 無對應 ADR（plan.md 既定藍圖的實作級落地設定） | [slice2a-cdc-ingestion.md §3.4](specs/slice2a-cdc-ingestion.md#34-序列化格式schema-registry-與違約行為) |
| 2026-10-16 | Slice2b 串流運算選 **Glue Streaming**（Spark Structured Streaming，`foreachBatch` 內 `MERGE INTO`），不選 Managed Flink；Slice 3 引擎延後到該 Slice 重新評估 | [ADR-0010](architecture/adr/0010-glue-streaming-vs-managed-flink.md) | [slice2b-streaming-upsert.md §3.1](specs/slice2b-streaming-upsert.md#31-串流運算引擎managed-flink-vs-glue-streaming本片最重要的取捨) |
| 2026-10-16 | Slice2b 目標表選 **Bronze（`bronze.trade_events`，事件 append）+ Silver（`silver.trade`，當前狀態 MERGE INTO）**，不做 Gold；Bronze 保留 `_events` 尾綴為對命名模式的刻意例外，`before`／`after` 以 JSON 字串原樣保存 | 無對應 ADR（沿用 [ADR-0002](architecture/adr/0002-medallion-layering.md) 的分層職責，屬本片實作級落地設定） | [slice2b-streaming-upsert.md §3.2](specs/slice2b-streaming-upsert.md#32-目標表分層與命名) |
| 2026-10-16 | Slice2b「最新版本」以來源 **`source.lsn`** 判定（批次內去重 + `MERGE` 嚴格大於，重播冪等）；刪除選**軟刪除**（`is_deleted`），避免重播時復活已刪除的資料 | 無對應 ADR（upsert 語意的實作級取捨，實作中若發現份量夠再獨立成 ADR） | [slice2b-streaming-upsert.md §3.3](specs/slice2b-streaming-upsert.md#33-最新版本的判定與冪等策略) |
| 2026-10-16 | Slice2b 串流 Silver 品質閘：Registry 管「長得對」，Silver 管「值對、狀態對、不重複」；採**逐筆規則 + 隔離表**（規則共用 Slice 1 的 GX 規則格式、串流以輕量 PySpark 執行），排程稽核與告警留 Slice 4 | [ADR-0011](architecture/adr/0011-streaming-silver-quality-gate.md) | [slice2b-streaming-upsert.md §3.4](specs/slice2b-streaming-upsert.md#34-串流路徑的品質防線是否延伸到表層) |
