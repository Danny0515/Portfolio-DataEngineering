# FinLakehouse — 金融資料湖倉與即時分析平台

## 專案簡介 (Project Introduction)

**FinLakehouse** 是一個以 AWS 為核心、涵蓋完整資料工程生命週期的金融資料分析平台。模擬金融科技公司的資料平台情境，整合三類金融資料：Market Data、Transaction Data、User Behavior，同時涵蓋 **Batch (批次)** 與 **Streaming (串流)** 兩條資料路徑，並以 **Lakehouse (資料湖倉)** 架構為基礎。  
核心賣點不是單純 ETL，而是涵蓋 Ingestion → Transformation → Serving 的完整生態系，含 Data Quality、Metadata Management、DataOps。完整的架構願景、技術選型與分階段交付規劃見 [plan.md](plan.md)，執行順序見 [execution-roadmap.md](execution-roadmap.md)。

### 專案目標 (Project Goals)
- **完全透過 [Claude Code](https://claude.com/claude-code) 開發**：從架構規劃、Spec 撰寫、Terraform 基礎設施、PySpark 轉換邏輯、IAM/Lake Formation 權限設計到 ADR／文件產出，皆由使用者與 Claude Code 協作完成。  
- **SDD**：完整的文件架構設計，方便 AI Agent 開發時能依規格與既有決策脈絡進行，不需臆測需求。  
- **共智(Collective Intelligence)**：透過文件架構與 Agent 執行規則等文件，把開發過程中的知識與決策脈絡留在專案本身，而不是留在開發者腦內，確保接手的開發者或其他 AI  都能單憑這些文件跟程式脈絡掌握專案全貌並延續開發。
- **Harness Engineering 的可驗證證據**：`docs/`（Spec、ADR、Pattern Card、Decision Log）與 `ai/contexts/`（Agent 執行規則、開發 Session 紀錄）完整保留了規劃到實作的每個判斷與脈絡。

## 目錄 (Table of Contents)

- [架構總覽 (Architecture Overview)](#架構總覽-architecture-overview)
- [技術棧 (Tech Stack)](#技術棧-tech-stack)
- [目前進度 (Current Status)](#目前進度-current-status)
- [文件導覽 (Documentation Map)](#文件導覽-documentation-map)

---

## 架構總覽 (Architecture Overview)

```
                          ┌─────────────────────────────────────────────────────┐
                          │                  Metadata & Governance               │
                          │   OpenMetadata / DataHub · OpenLineage · Schema Reg.  │
                          └─────────────────────────────────────────────────────┘
                                          ▲ (lineage / contract / catalog)
                                          │
  ┌──────────────┐   ┌──────────────┐   ┌─┴────────────┐   ┌──────────────┐   ┌──────────────┐
  │  Sources     │   │  Ingestion   │   │  Storage     │   │ Transform    │   │  Serving     │
  │              │   │              │   │ (Lakehouse)  │   │              │   │              │
  │ Market Feed  │──▶│ MSK (Kafka)  │──▶│ S3 + Iceberg │──▶│ Flink (串流) │──▶│ Athena/Trino │
  │ Trade DB     │──▶│ Debezium CDC │   │              │   │ Spark (批次) │   │ Redshift     │
  │ App Logs     │──▶│ Fluent Bit   │   │ Bronze       │   │ dbt (SQL)    │   │ Pinot/Druid  │
  │ 3rd-party    │──▶│ DMS / Airbyte│   │ Silver       │   │              │   │ Feature Store│
  │              │   │ (批次)        │   │ Gold         │   │              │   │ API Layer    │
  └──────────────┘   └──────────────┘   └──────────────┘   └──────────────┘   └──────────────┘
                            │                    ▲                  │
                            └──── Data Quality (Great Expectations / Soda) ─────┘
                                  Orchestration: Airflow (MWAA) / Dagster
                                  DataOps: Terraform · GitHub Actions · OpenLineage (Phase 2)
```

設計原則：

- **Medallion Architecture (獎章分層)**：Bronze (原始) → Silver (清洗/標準化) → Gold (聚合/業務語意)
- **Lakehouse Table Format**：採用 Apache Iceberg，支援 ACID、Schema Evolution、Time Travel 與 Partition Evolution
- **Decoupling (解耦)**：Ingestion、Storage、Compute 全部分離，Compute 可彈性擴縮
- **Single Source of Truth (單一事實來源)**：S3 為唯一儲存底層，所有查詢引擎共用同一份資料

完整設計細節（各層技術選型理由、Data Quality/Contract 設計等）見 [plan.md](plan.md)。

## 技術棧 (Tech Stack)

| 領域 | 主選 (Primary) |
| --- | --- |
| 儲存底層 | Amazon S3 |
| Table Format | Apache Iceberg |
| 批次運算 | AWS Glue Jobs（代管 Spark） |
| 串流訊息中介 | Amazon MSK (Managed Kafka) + MSK Connect |
| CDC 擷取 | Debezium（透過 MSK Connect） |
| 串流運算 | Apache Flink（規劃中，Slice 2b 導入） |
| Ad-hoc 查詢 | Amazon Athena (Trino) |
| Catalog | AWS Glue Data Catalog + Lake Formation |
| Schema Registry | AWS Glue Schema Registry (Avro) |
| IaC | Terraform |
| 資料品質 | Great Expectations |

完整技術選型總表（含替代方案與理由）見 [plan.md §8](plan.md#8-技術選型總表-technology-selection-summary)。

## 目前進度 (Current Status)

專案採 [execution-roadmap.md](execution-roadmap.md) 定義的 Slice 順序漸進交付，目前進度：

- **Slice 0 — Walking Skeleton（✅ 完成）**：批次骨架，第三方歷史行情檔 → S3 raw landing → Bronze (Iceberg) → Silver → Gold → Athena 查得到
- **Slice 1 — Data Quality + Contract（✅ 完成）**：疊加 WAP (Write-Audit-Publish) 品質關卡於批次路徑，Great Expectations Audit、Publish/擋下機制、`market-data.contract.yaml`（v1）
- **Slice 2a — CDC 交易事件擷取（進行中）**：來源 OLTP DB → Kafka（Debezium + MSK Connect + Avro/Schema Registry），本專案第一條即時路徑的上半段
  - ✅ §3 待確認事項全數拍板（RDS PostgreSQL、Debezium + MSK Connect、MSK Provisioned + 用完即拆、Avro + Glue Schema Registry）
  - ✅ §4 項目 1：網路層 spike，確認 Control Tower SCP 未限制 VPC 相關資源
  - ⏳ §4 項目 2 起：`vpc.tf` 正式化、來源 DB、MSK、CDC connector 部署與驗證

詳細規格與驗收標準見對應 Slice 的 spec（[docs/specs/](docs/specs/)）；已拍板的架構決策見 [docs/architecture/adr/](docs/architecture/adr/)；跨 Slice 技術選型索引見 [docs/decision-log.md](docs/decision-log.md)。


## 文件導覽 (Documentation Map)

| 文件 | 用途 |
| --- | --- |
| [plan.md](plan.md) | 專案藍圖／北極星，整體架構與技術選型全貌 |
| [execution-roadmap.md](execution-roadmap.md) | 執行路線，Slice 拆分與順序 |
| [CLAUDE.md](CLAUDE.md) | AI Agent 開發守則（環境限制、專案規則、文件治理） |
| [docs/specs/](docs/specs/) | 各 Slice 的元件規格（Spec-Driven Development 入口） |
| [contracts/](contracts/) | 已生效的 Data Contract（YAML：schema、品質規則、違約行為） |
| [docs/architecture/adr/](docs/architecture/adr/) | 架構決策紀錄 (ADR) |
| [docs/decision-log.md](docs/decision-log.md) | 跨 Slice 技術選型索引，標註隸屬哪個 ADR |
| [docs/arc42/](docs/arc42/) | arc42 架構文件，含決策摘要總表 |
| [docs/data-dictionary/](docs/data-dictionary/) | 資料字典總覽，各資料領域現況 |
| [docs/runbooks/](docs/runbooks/) | 維運手冊（AWS 存取、故障排除、各 Slice 驗證紀錄） |
| [docs/concepts/](docs/concepts/) | 零基礎技術概念解說／學習筆記，加速無背景知識者上手 |
| [infra/](infra/) | Terraform IaC，依 Slice 切分獨立 state（`environments/dev`、`environments/dev-slice2`） |
| [src/](src/) | 原始碼：`ingestion/`（模擬資料 generator）、`quality/`（品質檢核規則）、`transform/`（Glue Job 轉換邏輯） |
| [ai/contexts/](ai/contexts/) | Agent 執行規則、infra 現況快照、開發 session 紀錄 |
