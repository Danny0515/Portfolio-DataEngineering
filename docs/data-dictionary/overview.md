# 資料字典總覽 (Data Dictionary Overview)

> 這份文件是「總覽層」：列出本專案處理的資料領域與子類別、資料來源、目前實作現況，方便快速掌握系統處理哪些資料的樣貌。**不放欄位級 schema**——各層（Bronze/Silver/Gold）table 的欄位型別與意義，等該 table 實際建立後另開檔案記錄（若之後採用 dbt，欄位字典應以 `schema.yml` 為事實來源，這裡最多留連結，不手動複寫）。
>
> 資料領域分類依 [plan.md](../../plan.md) §0 業務情境：Market Data／Transaction Data／User Behavior，領域內部依資產類別／子類型再細分（見 plan.md §2.2 命名慣例）。

---

## 市場行情 (Market Data)

### 股票 (stock)

- **資料來源**：模擬資料 generator（[src/ingestion/generate_stock_data.py](../../src/ingestion/generate_stock_data.py)）產生假資料，不對接真實台股 API（見 [docs/specs/slice0-batch-market-data.md](../specs/slice0-batch-market-data.md) §3.2）
- **涵蓋標的**：`2330`、`2454`、`3653`，1 年歷史（平日）
- **現況**：Slice0 §4 十項全數完成——Raw landing 落地於 `s3://danny-data-engineering/raw/market/stock/`；Bronze/Silver/Gold（`bronze.stock`／`silver.stock`／`gold.monthly_ohlcv`）皆已建立、部署、經 Athena 驗證，Silver/Gold 並已套用月粒度 partition
- **相關文件**：[docs/specs/slice0-batch-market-data.md](../specs/slice0-batch-market-data.md)

---

## 交易資料 (Transaction Data)

### 交易 (trade)

- **資料來源**：模擬交易 generator（[src/ingestion/generate_trade_data.py](../../src/ingestion/generate_trade_data.py)，部署為 Lambda `slice2-trade-generator`）對來源 RDS PostgreSQL 的 `trade` 表產生交易狀態機變更（NEW → PARTIALLY_FILLED → FILLED／CANCELLED），不對接真實交易系統（見 [docs/specs/slice2a-cdc-ingestion.md](../specs/slice2a-cdc-ingestion.md) §3.1）
- **涵蓋標的**：沿用 Slice 0 的 `2330`、`2454`、`3653`，讓兩條路徑日後（Slice 3）能 join
- **現況**：Slice 2a §4 十三項全數完成——來源 `trade` 表經 Debezium（MSK Connect）以 CDC 擷取，事件（含 before／after 影像與來源變更序 LSN）送進 Kafka topic `transaction.trade.v1`（Avro + Glue Schema Registry，相容性 `BACKWARD`），無法序列化的訊息進 `transaction.trade.v1.dlq`；Data Contract 為 [contracts/trade-events.contract.yaml](../../contracts/trade-events.contract.yaml)（v1）。依「用完即拆」策略，Slice 2 的雲端資源目前為已銷毀狀態（2026-10-02），重建步驟見 [slice2-stack-lifecycle.md](../runbooks/slice2-stack-lifecycle.md)
- **Lakehouse 表**：尚未建立。`bronze.trade_events`（CDC 事件原樣 append）與 `silver.trade`（每筆交易的最新合規狀態，`MERGE INTO`）為 Slice 2b 規劃，spec 的待確認事項已全數拍板，尚未開始實作
- **相關文件**：[docs/specs/slice2a-cdc-ingestion.md](../specs/slice2a-cdc-ingestion.md)、[docs/specs/slice2b-streaming-upsert.md](../specs/slice2b-streaming-upsert.md)、[docs/runbooks/slice2a-verification.md](../runbooks/slice2a-verification.md)

---

## 使用者行為 (User Behavior / Clickstream)

尚未開始。
