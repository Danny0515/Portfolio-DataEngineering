# Spec: Slice 0 — Walking Skeleton（批次骨架）

> 對應 [execution-roadmap.md](../../execution-roadmap.md) Slice 0。
> 狀態：**待確認事項已定案 (§3 Decided)** — §3 待確認事項已由使用者拍板，以下 §4 實作項目清單即為實作依據。

---

## 1. 目標 (Goal)

證明 Lakehouse 的水電管線通了：一條最薄的批次路徑，從檔案落地到查得到結果，**不摻任何進階能力**（不做串流、CDC、資料品質框架、IaC、Airflow）。

資料流：

```
第三方歷史行情檔 (每日 CSV/Parquet)
  → S3 (raw landing)
  → Bronze (Iceberg, append 原樣落地)
  → Silver (Iceberg, 去重 / 型別校正 / 標準化)
  → Gold  (Iceberg, 簡單日聚合，如每日 OHLCV)
  → Athena 查得到
```

---

## 2. 範圍 (Scope) / 非範圍 (Non-Goals)

**範圍內**：
- 單一批次資料來源（歷史行情）的端到端 Medallion 管線
- Bronze / Silver / Gold 三層 Iceberg 表
- 手動或單一 script 觸發（不用 Airflow）
- Athena 查詢驗證

**刻意不做 (Out of Scope)**：串流、CDC、資料品質框架（Great Expectations/WAP）、Metadata/Catalog UI、IaC（Terraform）、多環境、Schema Registry。這些留給 Slice 1-4。

---

## 3. 待確認事項 (✅ 已定案)

這幾題是「地基」層級的選擇，決定結果直接決定架構：

### 3.1 執行環境：真實 AWS vs 本地模擬

✅ **決定：A. 真實 AWS**（S3 + Glue Data Catalog + Athena）。

已有組織額度可用，雲端費用可忽略不計。IAM 權限採**邊執行邊調整**策略——不預先設計完整權限模型，遇到實際跨不過去的權限限制時再回頭補權限，避免在 Slice0 就過度設計 IAM Policy。

| 選項 | 說明 | 成本 | 適合情境 |
| --- | --- | --- | --- |
| **A. 真實 AWS**（已選） | S3 + Glue Data Catalog + Athena（可用 Free Tier / 隨用隨關） | 極低（Slice0 資料量小），但需信用卡、有機會產生費用 | 想要作品集展示的是「真的在 AWS 上跑過」 |
| B. 本地模擬 | MinIO（S3 相容）+ Spark local + Iceberg local/Hive catalog + Trino/DuckDB 代替 Athena | 零成本 | 想先把邏輯打磨好，之後 Slice 4 用 Terraform 一次性搬上雲 |

### 3.2 資料來源：真實公開資料 vs 自產模擬資料

✅ **決定：B. 自產模擬資料**。理由：Slice 1 需要「故意灌壞資料」來測試 WAP Gate，自產資料更好控制，且不受外部 API 穩定性影響。之後可再加 A 作為真實資料的補充來源。

| 選項 | 說明 |
| --- | --- |
| A. 公開歷史行情 | 例如 Yahoo Finance / Stooq 下載每日 OHLCV CSV（免費、真實但需處理外部 API 穩定性） |
| **B. 自產模擬資料**（已選） | 寫一個小 generator 產生假的每日 K 線 CSV（完全可控，方便故意注入髒資料測試 Slice 1 的品質關卡） |

### 3.3 運算引擎：Spark vs dbt（Slice0 先選一個，越簡單越好）

✅ **決定：A. Spark**。Bronze / Silver / Gold 三層都用同一套 PySpark 程式讀寫 Iceberg，Slice0 不引入 dbt（dbt 留待後續 Slice 視需求評估）。

| 選項 | 說明 |
| --- | --- |
| **A. Spark**（已選） | PySpark 讀 CSV → 寫 Iceberg，Bronze/Silver/Gold 都用同一套程式 |
| B. dbt | Bronze 用簡單 Python/Spark 落地，Silver→Gold 用 dbt SQL model |

### 3.4 資料範圍

✅ **決定**：
- 股票 symbol：3 檔，代號為 `2330`、`2454`、`3653`（台股代號，由自產模擬資料 generator 產生對應假資料，不對接真實台股 API）
- 時間區間：1 年歷史

---

## 4. 實作項目清單 (Implementation Checklist)

> 待 §3 確認後，此清單即為實作依據。項目大致依序執行。

| # | 項目 | 說明 | 產出 |
| --- | --- | --- | --- |
| 1 | 專案骨架 | `src/` 下建立 `ingestion/`、`transform/` 等模組目錄 | 目錄結構 |
| 2 | 模擬資料 generator | 產生每日 OHLCV CSV（symbol, date, open, high, low, close, volume） | `src/ingestion/generate_stock_data.py` |
| 3 | Raw landing | 產生的 CSV 落地到 S3 raw 路徑。Bucket 透過 `infra/environments/dev/` 的 Terraform 建立(本專案專屬 bucket `danny-data-engineering`,非既有共用 bucket,依 RULE-001 禁止用 aws cli 部署) | `s3://danny-data-engineering/raw/market_data/stock/` |
| 4 | Bronze 落地 | 讀 raw CSV，原樣寫入 Iceberg Bronze table（append-only，保留來源 metadata） | Iceberg table `bronze.stock_data` |
| 5 | Iceberg + Glue Catalog 設定 | 建立 AWS Glue Data Catalog 作為 Iceberg catalog | catalog 設定檔 |
| 6 | Silver 轉換 | PySpark 讀 Bronze，去重、型別校正（price → decimal、date → date type）、標準化欄位命名 | Iceberg table `silver.stock_data` |
| 7 | Gold 聚合 | PySpark 做每日 OHLCV 聚合（此資料本身已是日頻，Gold 可先做簡單的月彙總或直接對映 Silver，視資料粒度而定） | Iceberg table `gold.daily_ohlcv` |
| 8 | 查詢驗證 | Athena 查詢 Gold 層，人工核對筆數與數字正確性 | 驗證紀錄 |
| 9 | Partition 設計 | 依交易日期（如 `date` 或 `year/month`）切 partition | table partition spec |
| 10 | 文件產出 | 依 execution-roadmap.md §2 Slice0 要求 | 見下方 §9 |

---

## 5. 輸出 (Outputs)

| 表 | 層級 | 內容 | 寫入模式 |
| --- | --- | --- | --- |
| `bronze.stock_data` | Bronze | 原始 OHLCV，含來源 metadata（ingest_time, source_file） | append |
| `silver.stock_data` | Silver | 去重、型別校正後的 OHLCV | append（此 Slice 不 upsert，因為歷史行情是 immutable 事實——這是 Slice 2 upsert 的對照組） |
| `gold.daily_ohlcv` | Gold | 對外可查詢的日頻行情寬表 | append / 依批次重算 |

---

## 6. 資料品質規則 (Data Quality Rules)

Slice 0 **不引入品質框架**，僅做最基本的程式內檢查（留待 Slice 1 用 Great Expectations/WAP 正式化）：

- `close`、`open`、`high`、`low` 不得為負值或空值
- `high >= low`
- 每個 (symbol, date) 不重複

---

## 7. 驗收標準 (Acceptance Criteria)

- [ ] 模擬資料 generator 可產生指定 symbol 數量與時間區間的 CSV
- [ ] 資料端到端從 raw landing 流到 Gold 層，過程無需人工中途介入
- [ ] Athena（或本地查詢引擎）可查到 Gold 層資料，且筆數與 generator 產出的原始資料一致
- [ ] Bronze 層資料可被重跑（reprocess）而不影響 Silver/Gold 的正確性
- [ ] 上述 §9 文件皆已產出

---

## 8. 相依 (Dependencies) / 風險 (Risks)

- **風險**：IAM 權限採邊執行邊調整策略，未預先設計完整權限模型，開發過程可能因權限不足而中斷，需視錯誤訊息隨時補權限
- **風險**：模擬資料若過於乾淨，Slice 1 的品質關卡測試效果有限——需在 generator 中預留「注入髒資料」的開關
- **相依**：§3 的待確認事項需先拍板，才能開始 §4 的實作

---

## 9. 相關文件 (Related ADR / Pattern / Contract)

依 execution-roadmap.md 要求，Slice 0 完成時需產出：

- `docs/architecture/adr/0001-use-iceberg.md` — 為何用 Iceberg 而非直接 Parquet on S3
- `docs/architecture/adr/0002-medallion-layering.md` — 為何分三層
- Decision Log：append vs overwrite 的取捨（本文件 §5 已先記錄初步理由，正式 ADR 待補）
