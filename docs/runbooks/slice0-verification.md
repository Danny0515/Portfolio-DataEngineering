# Runbook: Slice0 批次管線 Athena 查詢驗證

## 背景 (Why)

對應 [docs/specs/slice0-batch-market-data.md](../specs/slice0-batch-market-data.md) §4 項目 8「查詢驗證」：Bronze → Silver → Gold 三個 Glue Job 都跑過一次之後，用 Athena 人工核對筆數與數值正確性，而不是只看 Glue Job 回報 `SUCCEEDED` 就假設資料是對的。

這裡的檢查不是「跟一組寫死的魔術數字比對」——`generate_stock_data.py` 的資料範圍是「今天往回 N 年」，每次重新產生的實際筆數/月份都會隨執行日期變動。真正該核對的是**筆數之間的關係**（Bronze 應等於 Silver、Gold 應等於 symbol 數 × 涵蓋月數）跟**品質規則是否為 0 違規**，不是特定數字本身。

## 前置條件

- 本機已有可用的 AWS MFA session（`dt-lab-long-term-mfa`，見 `aws-cli-mfa-session` skill；也可以直接在 AWS Console 的 Athena 頁面手動貼上跑）
- `bronze.stock`、`silver.stock`、`gold.monthly_ohlcv` 三個 Glue Job 都已成功執行至少一次（見 [aws-access-via-bastion.md](aws-access-via-bastion.md) 觸發方式；或 `aws glue start-job-run --job-name <job> --region ap-northeast-1 --profile dt-lab-long-term-mfa`）

## Bronze 驗證

```sql
-- 筆數：應該等於 generator 產生的 (symbol 數 × 交易日數) 總列數
SELECT COUNT(*) AS bronze_count FROM bronze.stock;

-- Schema 應該全部是 string（inferSchema=false 的設計，見 ADR-0002 / arc42 08_concepts.md §8.2）
DESCRIBE bronze.stock;
```

## Silver 驗證

```sql
-- 1. 筆數比對：dirty-rate=0 時應該等於 Bronze 筆數（沒有資料被去重濾掉）
SELECT COUNT(*) AS silver_count FROM silver.stock;

-- 2. 各 symbol 筆數應該平均分布（N 檔 symbol 各自筆數相等）
SELECT symbol, COUNT(*) AS n
FROM silver.stock
GROUP BY symbol
ORDER BY symbol;

-- 3. 品質規則檢查（spec §6）：應該回傳 0 筆
SELECT *
FROM silver.stock
WHERE high < low
   OR open < 0 OR high < 0 OR low < 0 OR close < 0
   OR open IS NULL OR high IS NULL OR low IS NULL OR close IS NULL;

-- 4. 去重檢查：(symbol, trade_date) 不應該有重複，應該回傳 0 筆
SELECT symbol, trade_date, COUNT(*) AS n
FROM silver.stock
GROUP BY symbol, trade_date
HAVING COUNT(*) > 1;

-- 5. Schema 檢查：確認型別是 decimal/date/int，不是字串（Silver 負責 100% 型別解析，見 arc42 08_concepts.md §8.3）
DESCRIBE silver.stock;

-- 6. 抽樣看資料
SELECT * FROM silver.stock ORDER BY symbol, trade_date LIMIT 20;
```

**參考結果**（2026-07-31 執行，3 檔 symbol、262 個交易日）：Bronze/Silver 筆數皆為 786，各 symbol 均為 262 筆，品質違規與重複列皆為 0。

## Gold 驗證

```sql
-- 1. 總筆數：應該是 symbol 數 × 涵蓋月數
SELECT COUNT(*) AS gold_count FROM gold.monthly_ohlcv;

SELECT symbol, COUNT(*) AS n
FROM gold.monthly_ohlcv
GROUP BY symbol
ORDER BY symbol;

-- 2. Schema 檢查（月頻聚合，見 arc42 08_concepts.md §8.4）
DESCRIBE gold.monthly_ohlcv;

-- 3. 抽樣看資料
SELECT * FROM gold.monthly_ohlcv ORDER BY symbol, year_month LIMIT 20;

-- 4. 聚合正確性交叉驗證：任取一檔一個月，跟 Silver 明細手動聚合比對
--    下面兩條查詢的 high/low/volume 應該一致；Gold 的 open/close 應該對應
--    Silver 該月 first_day/last_day 那兩天的實際開/收盤價
SELECT
  MIN(trade_date) AS first_day,
  MAX(trade_date) AS last_day,
  MAX(high) AS month_high,
  MIN(low) AS month_low,
  SUM(volume) AS month_volume
FROM silver.stock
WHERE symbol = '<symbol>'
  AND trade_date >= date '<yyyy-mm>-01'
  AND trade_date < date '<yyyy-mm-次月>-01';

SELECT open, high, low, close, volume
FROM gold.monthly_ohlcv
WHERE symbol = '<symbol>' AND year_month = date '<yyyy-mm>-01';
```

**參考結果**（2026-07-31 執行）：Gold 39 筆（3 symbol × 13 個月），各 symbol 均為 13 筆；以 `2330` 2025-08 為例，交叉驗證 `SUM(volume)` 與 Gold 該列 `volume` 完全一致（225986996）。

## 相關文件

- [docs/specs/slice0-batch-market-data.md](../specs/slice0-batch-market-data.md) §4 項目 8 — 這份 runbook 對應的驗收項目
- [docs/arc42/08_concepts.md](../arc42/08_concepts.md) — Bronze/Silver/Gold 各層的設計原則（型別解析、去重規則、聚合邏輯）
- [docs/arc42/06_runtime_view.md](../arc42/06_runtime_view.md) — 目前批次管線的執行流程圖
- [aws-access-via-bastion.md](aws-access-via-bastion.md) — 如何取得 AWS 存取權限、如何觸發 Glue Job
