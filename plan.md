# FinLakehouse — 金融資料湖倉與即時分析平台 (Side Project Plan)

> 一個以 AWS 為核心、涵蓋完整資料工程生命週期 (Data Engineering Lifecycle) 的金融資料分析平台。
> 同時包含 **Batch (批次)** 與 **Streaming (串流)** 兩條資料路徑，並以 **Lakehouse (資料湖倉)** 架構為基礎。
> 本專案刻意以 **Spec-Driven Development (規格驅動開發)** + **文件架構 (Documentation Architecture)** 為前提設計，方便使用 Harness Engineer (AI Agent 開發者) 進行開發。
>
> **使用方式**：本文件是專案的「地圖」——實作進行到細節、忘記最初動機或架構全貌時，回來看本文件即可掌握全貌，不需要另外比對 ADR / Decision Log 才能拼出需求全貌。ADR 記錄的是「為什麼選這個」的局部理由，本文件記錄的是「整體是什麼」。修訂歷史見文末 [Changelog](#changelog)。

---

## 目錄 (Table of Contents)

- [0. 專案定位 (Positioning)](#0-專案定位-positioning)
  - [業務情境 (Business Scenario)](#業務情境-business-scenario)
- [1. 整體架構 (High-Level Architecture)](#1-整體架構-high-level-architecture)
- [2. 完整資料工程生命週期 (Data Engineering Lifecycle)](#2-完整資料工程生命週期-data-engineering-lifecycle)
  - [2.1 Ingestion (資料擷取)](#21-ingestion-資料擷取)
  - [2.2 Storage (儲存 — Lakehouse)](#22-storage-儲存-lakehouse)
  - [2.3 Transformation (轉換)](#23-transformation-轉換)
  - [2.4 Serving (資料服務)](#24-serving-資料服務)
- [3. Data Quality (資料品質)](#3-data-quality-資料品質)
- [4. Metadata Management (中繼資料管理)](#4-metadata-management-中繼資料管理)
  - [4.1 Data Catalog & Lineage (資料目錄與血緣)](#41-data-catalog-lineage-資料目錄與血緣)
  - [4.2 Data Contract (資料契約)](#42-data-contract-資料契約)
- [5. DataOps (第二階段)](#5-dataops-第二階段)
- [6. 文件架構設計 (Documentation Architecture for Harness Engineering)](#6-文件架構設計-documentation-architecture-for-harness-engineering)
  - [6.1 倉庫文件結構 (Repository Documentation Layout)](#61-倉庫文件結構-repository-documentation-layout)
  - [6.2 核心文件類型 (Document Types)](#62-核心文件類型-document-types)
  - [6.3 Spec 範本 (Spec Template)](#63-spec-範本-spec-template)
- [7. 分階段交付 (Phased Delivery)](#7-分階段交付-phased-delivery)
- [8. 技術選型總表 (Technology Selection Summary)](#8-技術選型總表-technology-selection-summary)
- [9. 成功標準 (Definition of Done)](#9-成功標準-definition-of-done)
- [Changelog](#changelog)

---

## 0. 專案定位 (Positioning)

| 項目 | 說明 |
| --- | --- |
| 目標角色 | 4 年經驗 Data Engineer，展現資料湖倉 / 資料流 / 平台治理能力 |
| 核心賣點 | 不是單純 ETL，而是涵蓋 Ingestion → Transformation → Serving 的完整生態系，含 Data Quality (資料品質)、Metadata Management (中繼資料管理)、DataOps |
| 雲端平台 | AWS 為主，搭配開源生態系 (Kafka / Flink / Iceberg / dbt / Airflow) |
| 開發方式 | Harness Engineer (AI Agent) 主導開發，因此文件架構與規格 (Spec) 為一等公民 |

### 業務情境 (Business Scenario)

模擬一個 **券商 / 金融科技公司的資料平台**，整合三類金融資料，各自細分子類別：

1. **市場行情 (Market Data)**：即時報價、Tick 資料、K 線 — 高頻 Streaming
2. **交易資料 (Transaction Data)**：下單、成交、帳務 — CDC (Change Data Capture) Streaming + Batch 對帳
3. **使用者行為 (User Behavior / Clickstream)**：App / Web 操作日誌 — Log Streaming

**對外服務目標 (Serving Use Cases)**：

- 即時風控 (Real-time Risk)：部位、曝險、異常交易偵測
- 交易分析儀表板 (Trading Dashboard)：低延遲 OLAP 查詢
- 監理報表 (Regulatory Reporting)：批次、可追溯 (Auditable)、需資料血緣
- ML 特徵 (Feature Store)：給風控 / 推薦模型使用

> 金融情境特別能凸顯 **資料正確性、可追溯性 (Lineage)、資料契約 (Data Contract)、Time Travel (時間回溯)** 的價值，這正是 Lakehouse 與治理能力的展示重點。

---

## 1. 整體架構 (High-Level Architecture)

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
- **Lakehouse Table Format**：採用 **Apache Iceberg**，因為金融資料需要 ACID、Schema Evolution (結構演進)、Time Travel (時間回溯／審計) 與分割演進 (Partition Evolution)
- **Decoupling (解耦)**：Ingestion、Storage、Compute 全部分離，Compute 可彈性擴縮
- **Single Source of Truth (單一事實來源)**：S3 為唯一儲存底層，所有查詢引擎共用同一份資料

---

## 2. 完整資料工程生命週期 (Data Engineering Lifecycle)

### 2.1 Ingestion (資料擷取)

| 資料類型 | 模式 | 推薦技術 (AWS / OSS) | 理由 |
| --- | --- | --- | --- |
| 即時市場行情 (Tick / Quote) | Streaming | **Amazon MSK (Managed Kafka)** + Producer | 高吞吐、低延遲、可重播 (Replay)；金融高頻資料首選 |
| 交易 DB 變更 (CDC) | Streaming | **Debezium + MSK Connect** (或 AWS DMS) | 從 OLTP DB 擷取變更而不影響交易系統，保留 before/after 影像供對帳 |
| App / Web 操作日誌 | Streaming | **Fluent Bit (Fluentd)** + MSK | Fluent Bit 輕量、適合容器 / EC2 端的 log 收集，再進 Kafka 統一緩衝 |
| 第三方參考資料 / 歷史行情 | Batch | **AWS DMS / Airbyte → S3** | 低頻、結構穩定，批次拉取即可 |
| 檔案上傳 (對帳檔、監理檔) | Batch | **S3 + EventBridge 觸發** | 事件驅動的檔案落地處理 |

> 替代方案備註：若想完全 AWS-native，Streaming 可用 **Kinesis Data Streams** 取代 MSK；但本專案選 MSK 以展現對 Kafka 生態系 (Schema Registry / Connect / Streams) 的掌握。

**Schema 管控**：所有進入 Kafka 的訊息透過 **AWS Glue Schema Registry** (或 Confluent Schema Registry) 以 **Avro / Protobuf** 註冊，作為 Data Contract 的技術強制點 (見 §4)。

### 2.2 Storage (儲存 — Lakehouse)

| 層級 | 內容 | 格式 / 技術 | 說明 |
| --- | --- | --- | --- |
| Bronze (原始層) | 原樣落地、append-only | S3 + Iceberg | 保留原始 payload 與 metadata，可重跑 (Reprocess) |
| Silver (清洗層) | 去重、標準化、型別校正、CDC 合併 | S3 + Iceberg (MERGE INTO) | 套用 Data Quality 規則；交易資料在此 upsert |
| Gold (業務層) | 聚合、業務指標、寬表、維度模型 | S3 + Iceberg | 對接 Serving；如部位表、風控指標、報表寬表 |

- **儲存底層**：Amazon S3 (含 S3 Lifecycle 做冷熱分層)
- **Table Format**：Apache Iceberg (透過 Glue Data Catalog 作為 Iceberg Catalog)
- **檔案格式**：Parquet (列式、壓縮、適合分析)
- **命名慣例**：三大資料領域（Market Data／Transaction Data／User Behavior）內部依**資產類別／子類型**再細分一層，例如股票行情為 `market/stock/`（S3 路徑）、`<layer>.stock`（Iceberg table）；日後新增期貨、債券比照 `market/futures/`、`<layer>.futures`，不需重新設計既有命名，命名不加 `_data` 尾綴。

### 2.3 Transformation (轉換)

| 路徑 | 引擎 | 推薦技術 | 用途 |
| --- | --- | --- | --- |
| Streaming 轉換 | **Apache Flink** | **Amazon Managed Service for Apache Flink** | 即時聚合、視窗運算 (Windowing)、即時風控規則、Tick → K 線 |
| Batch 轉換 (重運算) | **Apache Spark** | **EMR on EKS / AWS Glue** | 大量歷史回算、對帳、複雜 Join |
| Batch 轉換 (SQL 語意層) | **dbt** | **dbt-core + dbt-athena / dbt-trino** | Silver → Gold 的業務邏輯、可測試、可文件化、可血緣 |
| 編排 (Orchestration) | **Airflow** | **Amazon MWAA** (或 Dagster) | 排程、相依管理、SLA、回填 (Backfill) |

> 為何 batch 同時用 Spark + dbt：Spark 處理重量級分散式運算 (對帳、回算)；dbt 負責 SQL 化的業務轉換層，天生支援測試與血緣，與文件架構契合度高。

### 2.4 Serving (資料服務)

| 服務型態 | 推薦技術 | 用途 |
| --- | --- | --- |
| Ad-hoc 查詢 / 探索 | **Amazon Athena (Trino)** | 直接查 Iceberg，無伺服器、低成本 |
| 資料倉儲 / BI 報表 | **Amazon Redshift** (Spectrum 接 S3) | 監理報表、複雜分析、固定報表 |
| 低延遲即時 OLAP | **Apache Pinot / ClickHouse / Druid** | 交易儀表板、即時風控查詢 (sub-second) |
| ML 特徵服務 | **SageMaker Feature Store** | 風控 / 推薦模型的線上 + 離線特徵 |
| API 服務層 | **API Gateway + Lambda** | 對外提供指標查詢 API |

---

## 3. Data Quality (資料品質)

金融資料對正確性零容忍，品質檢核是核心展示點。

| 面向 | 推薦技術 | 落點 |
| --- | --- | --- |
| 規則驗證 (Validation) | **Great Expectations** 或 **Soda Core** | Bronze→Silver、Silver→Gold 之間的 Gate |
| 轉換層測試 | **dbt tests** (not_null / unique / relationships / accepted_values) | dbt model 上直接定義 |
| 異常偵測 (Anomaly) | 自訂規則 + **CloudWatch / SNS 告警** | 交易量、價格跳動、Volume 偏離 |
| 對帳 (Reconciliation) | Spark 批次比對 | 交易筆數 / 金額與來源系統核對 |

**品質檢核策略**：

- **WAP (Write-Audit-Publish) Pattern**：利用 Iceberg 的能力，資料先寫入暫存分支 → 跑品質檢核 (Audit) → 通過才 Publish。確保壞資料不外流到 Gold / Serving。
- **品質維度**：完整性 (Completeness)、唯一性 (Uniqueness)、時效性 (Timeliness)、有效性 (Validity)、一致性 (Consistency)、準確性 (Accuracy)。
- **品質結果寫回 Metadata**：檢核結果回報給 OpenMetadata，形成可視化的品質分數。

---

## 4. Metadata Management (中繼資料管理)

### 4.1 Data Catalog & Lineage (資料目錄與血緣)

| 功能 | 推薦技術 | 說明 |
| --- | --- | --- |
| 技術 Catalog | **AWS Glue Data Catalog** | Iceberg / 查詢引擎共用的中央 Metastore |
| 業務 Catalog + 血緣 | **OpenMetadata** (或 DataHub) | 資料字典、Owner、Tag、欄位級血緣 (Column-level Lineage)、品質分數 |
| 血緣標準 | **OpenLineage** | 從 Airflow / Spark / dbt 自動發送 lineage 事件 |

血緣展示：從來源 (Kafka topic / 上游 DB) → Bronze → Silver → Gold → 報表/儀表板，端到端可追溯，並支援 **影響分析 (Impact Analysis)**。

### 4.2 Data Contract (資料契約)

> 資料契約是 producer (上游) 與 consumer (下游) 之間的正式協議，金融資料尤其重要。

| 層面 | 實作方式 |
| --- | --- |
| 契約格式 | 採 **Data Contract Spec (datacontract.com)** 或自訂 YAML，含 schema、SLA、品質規則、語意 |
| 技術強制 (Streaming) | **Schema Registry** + 相容性規則 (Backward / Forward Compatibility) |
| 技術強制 (Batch/Table) | Iceberg Schema + dbt contract (`contract: enforced`) |
| 版本控制 | 契約檔放 Git，PR review，CI 驗證相容性 |
| 違約處理 | Schema 不相容 → CI 擋下 / 訊息進 Dead Letter Queue (DLQ) |

**契約範例 (示意)**：

```yaml
# contracts/trade_events.contract.yaml
dataContractSpecification: "0.9.3"
id: trade-events
info:
  title: 交易事件 (Trade Events)
  owner: trading-platform-team
servers:
  kafka:
    type: kafka
    topic: trade.events.v1
models:
  trade:
    fields:
      trade_id:   { type: string, required: true, unique: true }
      account_id: { type: string, required: true }
      symbol:     { type: string, required: true }
      price:      { type: decimal, required: true }
      quantity:   { type: long, required: true }
      side:       { type: string, enum: [BUY, SELL] }
      event_time: { type: timestamp, required: true }
quality:
  - type: freshness
    column: event_time
    threshold: 5m
servicelevels:
  availability: 99.9%
```

---

## 5. DataOps (第二階段)

> Phase 2 重點：把平台「工程化」，展現可維運、可重現、可觀測的能力。

| 面向 | 推薦技術 | 說明 |
| --- | --- | --- |
| 基礎設施即程式 (IaC) | **Terraform** | MSK / S3 / Glue / EMR / Redshift 全部宣告式管理 |
| CI/CD | **GitHub Actions** | Lint、dbt 編譯/測試、契約相容性檢查、IaC plan、部署 |
| 環境管理 | dev / staging / prod 多環境 | 以 Terraform workspace + 參數化 |
| 資料可觀測性 (Observability) | **OpenLineage + Marquez** | 資料新鮮度、Volume、Schema 變更監控 |
| 容器 / 部署 | **EKS / ECR** | Flink / 自訂 service 容器化 |
| 監控告警 | **CloudWatch + Grafana + SNS** | Pipeline 失敗、SLA、品質告警 |
| 資料測試 | dbt test + Great Expectations in CI | PR 階段擋下品質回歸 |

DataOps 成熟度路線：手動 → 自動化 CI/CD → 資料可觀測性 → 自動回滾 / 自癒。

---

## 6. 文件架構設計 (Documentation Architecture for Harness Engineering)

> 因為要用 Harness Engineer (AI Agent) 開發，**文件即規格 (Docs as Spec)**。文件架構本身就是展示重點。

### 6.1 倉庫文件結構 (Repository Documentation Layout)

```
Portfolio-DataEngineering/
├── README.md                      # 專案總覽、快速開始、架構圖
├── plan.md                        # 本計劃書
├── CLAUDE.md                      # AI Agent 開發守則 (慣例、技術棧、禁則)
├── docs/
│   ├── arc42/                     # 架構文件 (arc42 模板,一章一份 .md)
│   │   ├── 03_context.md          # 系統情境與範圍
│   │   ├── 06_runtime_view.md     # 資料流 / 執行時期視角 (batch + streaming)
│   │   └── 09_architecture_decisions.md  # 決策摘要,完整推理連結 adr/
│   ├── architecture/
│   │   └── adr/                   # Architecture Decision Records (架構決策紀錄)
│   │       ├── 0001-use-iceberg.md
│   │       ├── 0002-msk-vs-kinesis.md
│   │       └── 0003-medallion-layering.md
│   ├── specs/                     # 元件規格 (Spec-Driven Development 入口)
│   │   ├── ingestion-market-data.md
│   │   ├── cdc-trade-pipeline.md
│   │   └── risk-aggregation.md
│   ├── patterns/                  # Pattern Cards (可複用設計樣式)
│   │   ├── wap-quality-gate.md
│   │   ├── cdc-merge-into.md
│   │   └── streaming-windowing.md
│   ├── runbooks/                  # 維運手冊 (故障排除、回填、重跑)
│   │   ├── backfill.md
│   │   └── pipeline-failure.md
│   ├── data-dictionary/           # 資料字典 (各層 schema 說明)
│   └── glossary.md                # 名詞表 (業務 + 技術術語)
├── contracts/                     # 資料契約 (Data Contracts,被 CI/pipeline 消費的設定檔)
│   └── *.contract.yaml
├── infra/                         # Terraform (IaC)
├── pipelines/                     # Flink / Spark / dbt 程式碼
├── quality/                       # Great Expectations / Soda 設定
└── tests/
```

### 6.2 核心文件類型 (Document Types)

| 文件類型 | 目的 | 對 AI Agent 開發的價值 |
| --- | --- | --- |
| **ADR (架構決策紀錄)** | 記錄「為什麼這樣選」 | Agent 理解約束與決策脈絡，不會推翻既定設計 |
| **Spec (元件規格)** | 描述「要做什麼、輸入輸出、驗收標準」 | Agent 的開發任務單，含 Acceptance Criteria |
| **Pattern Card (樣式卡)** | 可複用設計樣式 (含程式碼骨架) | Agent 依樣式產出一致風格的程式碼 |
| **Data Contract** | 資料介面協議 | Agent 知道 schema 與品質期望，避免破壞下游 |
| **Runbook (維運手冊)** | 標準作業流程 | Agent 執行重跑 / 回填等運維任務 |
| **CLAUDE.md** | 開發守則、慣例、禁則 | Agent 的全域行為約束 |

### 6.3 Spec 範本 (Spec Template)

```markdown
# Spec: <元件名稱>
## 1. 目標 (Goal)
## 2. 範圍 (Scope) / 非範圍 (Non-Goals)
## 3. 輸入 (Inputs)：來源、schema、契約連結
## 4. 處理邏輯 (Processing Logic)
## 5. 輸出 (Outputs)：目標表 / topic、schema、SLA
## 6. 資料品質規則 (Data Quality Rules)
## 7. 驗收標準 (Acceptance Criteria) — 可測試
## 8. 相依 (Dependencies) / 風險 (Risks)
## 9. 相關文件 (Related ADR / Pattern / Contract)
```

---

## 7. 分階段交付 (Phased Delivery)

| 階段 | 主題 | 交付內容 | 展示能力 |
| --- | --- | --- | --- |
| **Phase 0** | 文件骨架 + IaC | 文件架構、ADR、Terraform 基礎 (S3/Glue/MSK) | 規格驅動、IaC |
| **Phase 1a** | Batch 主幹 | 第三方資料 → Bronze/Silver/Gold (Iceberg) + dbt + Athena | Lakehouse、批次轉換、Medallion |
| **Phase 1b** | Streaming 主幹 | Market data → MSK → Flink → Iceberg；CDC trade pipeline | 資料流、Flink、CDC |
| **Phase 1c** | Serving | Athena/Redshift 報表 + Pinot 即時儀表板 | 多型態 Serving |
| **Phase 2a** | Data Quality | Great Expectations + WAP Gate + dbt tests | 資料品質工程 |
| **Phase 2b** | Metadata | OpenMetadata + OpenLineage 血緣 + Data Contract | 治理、血緣、契約 |
| **Phase 2c** | DataOps | CI/CD、可觀測性、多環境、告警 | 平台工程化 |

---

## 8. 技術選型總表 (Technology Selection Summary)

| 領域 | 主選 (Primary) | 替代 (Alternative) | 一句話理由 |
| --- | --- | --- | --- |
| Log 收集 | Fluent Bit | Fluentd / Vector | 輕量、容器友善 |
| 訊息匯流排 | Amazon MSK (Kafka) | Kinesis Data Streams | 生態系完整、可重播 |
| CDC | Debezium | AWS DMS | 不侵入來源、保留變更影像 |
| 批次擷取 | Airbyte / DMS | Glue | 連接器豐富 |
| 儲存底層 | Amazon S3 | — | 業界標準資料湖底層 |
| Table Format | Apache Iceberg | Delta / Hudi | ACID + Time Travel + Schema/Partition Evolution |
| 串流運算 | Apache Flink (Managed) | Spark Structured Streaming | 真串流、低延遲、視窗運算強 |
| 批次運算 | Spark (EMR/Glue) | — | 分散式重運算 |
| SQL 轉換 | dbt | — | 可測試、可血緣、文件化 |
| 編排 | Airflow (MWAA) | Dagster | 生態成熟 |
| Ad-hoc 查詢 | Athena (Trino) | — | 無伺服器查 Iceberg |
| 資料倉儲 | Redshift | — | 監理報表 |
| 即時 OLAP | Apache Pinot | ClickHouse / Druid | sub-second 儀表板 |
| 特徵庫 | SageMaker Feature Store | Feast | 線上+離線特徵 |
| 資料品質 | Great Expectations | Soda Core | 規則豐富、可報告 |
| Catalog/血緣 | OpenMetadata | DataHub | 開源、血緣+品質整合 |
| 血緣標準 | OpenLineage | — | 跨工具標準協定 |
| Schema 管控 | Glue Schema Registry | Confluent SR | 契約技術強制點 |
| IaC | Terraform | AWS CDK | 雲端中立、社群大 |
| CI/CD | GitHub Actions | — | 與 repo 整合 |

---

## 9. 成功標準 (Definition of Done)

- [ ] Batch 與 Streaming 兩條路徑皆可端到端運作，資料落到 Iceberg Gold 層
- [ ] Serving 層可同時提供「批次報表 (Athena/Redshift)」與「即時查詢 (Pinot)」
- [ ] Data Quality Gate 能擋下不合格資料 (WAP)，並有品質報告
- [ ] OpenMetadata 可視化端到端欄位級血緣，且有至少一份生效的 Data Contract
- [ ] 全部基礎設施以 Terraform 管理，CI/CD 可自動測試與部署 (Phase 2)
- [ ] 文件架構完整：README + ADR + Spec + Pattern Card + Runbook + Data Contract 齊備
- [ ] 整個專案可由 Harness Engineer 依 Spec 重現開發

---

## Changelog

> 只記錄本文件的**實質修訂**（範圍/架構真的改變），不記錄規劃期的例行討論調整。用於回溯「這份地圖曾經因為什麼原因變成現在這樣」——日常閱讀全貌不需要看這裡，只有要追查某段內容的變動原因時才查。

| 日期 | 修改章節 | 原因 |
| --- | --- | --- |
| 2026-07-17 | 新增「使用方式」說明 + 建立本 Changelog | 釐清 plan.md 應作為實作期回頭查閱全貌的「地圖」，並補上可回溯的修訂紀錄機制 |
| 2026-07-17 | §6.1 倉庫文件結構 | 改用 arc42 模板撰寫架構文件（取代 overview.md/data-flow.md），contracts/ 移至頂層以反映其為 CI/pipeline 消費的設定檔而非純文件 |
| 2026-07-22 | §2.2 Storage | 補上資產類別命名慣例，回應 Slice0 stock 資料命名需求 |
| 2026-07-31 | §2.2 Storage | 命名慣例拿掉多餘的 `_data` 尾綴（`market_data`→`market`、`<layer>.stock_data`→`<layer>.stock`），因為資料湖倉裡的內容本來就是資料，尾綴多餘；已同步修改所有受影響的程式與文件（S3 路徑、Iceberg table 名稱、Terraform 資源識別字、IAM/Glue Job 命名） |