# 資料字典總覽 (Data Dictionary Overview)

> 這份文件是「總覽層」：列出本專案處理的資料領域與子類別、資料來源、目前實作現況，方便快速掌握系統處理哪些資料的樣貌。**不放欄位級 schema**——各層（Bronze/Silver/Gold）table 的欄位型別與意義，等該 table 實際建立後另開檔案記錄（若之後採用 dbt，欄位字典應以 `schema.yml` 為事實來源，這裡最多留連結，不手動複寫）。
>
> 資料領域分類依 [plan.md](../../plan.md) §0 業務情境：Market Data／Transaction Data／User Behavior，領域內部依資產類別／子類型再細分（見 plan.md §2.2 命名慣例）。

---

## 市場行情 (Market Data)

### 股票 (stock)

- **資料來源**：模擬資料 generator（[src/ingestion/generate_stock_data.py](../../src/ingestion/generate_stock_data.py)）產生假資料，不對接真實台股 API（見 [docs/specs/slice0-batch-market-data.md](../specs/slice0-batch-market-data.md) §3.2）
- **涵蓋標的**：`2330`、`2454`、`3653`，1 年歷史（平日）
- **現況**：Raw landing 已完成（Slice0 §4 項目 3），落地於 `s3://danny-data-engineering/raw/market_data/stock/`；Bronze/Silver/Gold（`bronze.stock_data`／`silver.stock_data`／`gold.daily_ohlcv`）尚未建立
- **相關文件**：[docs/specs/slice0-batch-market-data.md](../specs/slice0-batch-market-data.md)

---

## 交易資料 (Transaction Data)

尚未開始（對應 execution-roadmap.md Slice 2 — CDC 交易串流管線）。

---

## 使用者行為 (User Behavior / Clickstream)

尚未開始。
