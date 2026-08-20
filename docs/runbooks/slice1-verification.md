# Runbook: Slice1 端到端驗證（Bronze→Silver WAP Gate→Gold→Athena）

## 背景 (Why)

對應 [docs/specs/slice1-quality-contract.md](../specs/slice1-quality-contract.md) §4 項目 8「端到端驗證」。這份文件是 Slice 1 整體是否可視為完成的定案驗證——比照 [slice0-verification.md](slice0-verification.md) 對 Slice 0 的角色，用同一個檔名代表「這個 Slice 完成的證據」，跟三份個別機制的衛星 runbook 分工：

- [slice1-wap-verification.md](slice1-wap-verification.md) — 只驗證 Write 階段（staging branch 建立、main 不受影響）
- [slice1-gx-audit-verification.md](slice1-gx-audit-verification.md) — 只驗證 Audit 階段（GX 在 Glue Spark 上能否正確跑）
- [slice1-publish-verification.md](slice1-publish-verification.md) — 只驗證 Publish/擋下 + 稽核紀錄落地

這三份都已個別驗證過各自的機制，但都還沒有人跑過「整條 Bronze→Silver(WAP)→Gold→Athena 鏈路，分別餵全乾淨資料與含髒資料各一輪，從頭到尾看結果」——這正是 spec §7 驗收標準第 1、2、3 條要求的證據形狀。本文件補上這個視角，不重複三份衛星 runbook 已經證實過的細節（例如 branch 語意、GX 套件打包），只聚焦在「整條鏈路串起來、Gold 層也拉進來看」這件事。

## 前置條件

- 本機已有可重用的 AWS MFA session（`dt-lab-long-term-mfa`，見 `aws-cli-mfa-session` skill）
- `bronze.stock`、`silver.stock`、`gold.monthly_ohlcv` 三個 Glue Job 已存在且先前至少成功執行過一次

## 執行前基準（2026-08-19）

延續前次 session（見 [slice1-publish-verification.md](slice1-publish-verification.md)）結束時的狀態：

| | 值 |
| --- | --- |
| `bronze.stock` 筆數 | 4836 |
| `silver.stock`（main）筆數 | 816 |
| `gold.monthly_ohlcv` 筆數 | 39 |
| main snapshot_id | `7882369420455484184` |

## Round 1：全乾淨資料端到端

```bash
uv run python src/ingestion/generate_stock_data.py   # 預設全乾淨，262 個交易日、786 列
aws s3 sync data/raw/market/stock/ s3://danny-data-engineering/raw/market/stock/ --profile dt-lab-long-term-mfa --region ap-northeast-1
aws glue start-job-run --job-name slice0-bronze-stock --region ap-northeast-1 --profile dt-lab-long-term-mfa
```

Bronze `SUCCEEDED`（86 秒）。

### 意外插曲：上次 session 遺留的永久性 Bronze 污染，這次才發作

跑第一次 Silver 時 Audit **意外失敗**：

```
[Audit] staging validation success=False
[Audit] FAILED: expect_column_values_to_not_be_null column=symbol
[Audit] FAILED: expect_column_values_to_be_in_set column=symbol
[Audit] FAILED: expect_column_values_to_not_be_null column=trade_date
[Audit] FAILED: expect_compound_columns_to_be_unique column_list=[symbol, trade_date]
[Publish] BLOCKED: batch 307223448062407430 failed audit, main not updated, 4 violations logged to audit_log
```

這批資料理論上是全乾淨的，不該觸犯任何規則。查 `bronze.stock` 才發現：[slice1-publish-verification.md](slice1-publish-verification.md)「意外插曲」記錄過的問題（`invalid_symbol`/`invalid_date`/打在 `symbol`/`date` 上的 `empty_field` 會產生全新 `(symbol, date)` key，dedup 救不回來，永久卡在 Bronze）在**上次 session 結束時沒有清乾淨**——這次一啟動就踩到，`bronze.stock` 裡還殘留 68 列符合污染條件的舊資料。比照上次記錄的作法，執行同一條 `DELETE`（範圍精準，只刪符合污染條件的列，不影響其餘歷史資料）：

```sql
-- 執行前 68 列符合污染條件
DELETE FROM bronze.stock
WHERE symbol IS NULL
   OR symbol NOT IN ('2330', '2454', '3653')
   OR date IS NULL
   OR NOT regexp_like(date, '^[0-9]{4}-[0-9]{2}-[0-9]{2}$');
-- 執行後同條件查詢回傳 0 列，bronze.stock 總數變為 5593
```

清除後重跑 Silver：

```bash
aws glue start-job-run --job-name slice0-silver-stock --region ap-northeast-1 --profile dt-lab-long-term-mfa
```

`SUCCEEDED`（132 秒）：

```
[Audit] staging validation success=True
[Publish] merged staging (snapshot=6301798231775002437) -> main
```

再跑 Gold：

```bash
aws glue start-job-run --job-name slice0-gold-monthly-ohlcv --region ap-northeast-1 --profile dt-lab-long-term-mfa
```

`SUCCEEDED`（54 秒）。

### Round 1 參考結果

```sql
SELECT * FROM "silver"."stock$refs";
-- staging | BRANCH | 6301798231775002437
-- main    | BRANCH | 6301798231775002437   <- 與 staging 一致，fast_forward 生效

SELECT COUNT(*) FROM silver.stock;  -- 825

-- 品質規則檢查（spec §6），應回傳 0
SELECT COUNT(*) FROM silver.stock
WHERE high < low OR open < 0 OR high < 0 OR low < 0 OR close < 0
   OR open IS NULL OR high IS NULL OR low IS NULL OR close IS NULL
   OR symbol NOT IN ('2330','2454','3653');
-- 0

-- 去重檢查，應回傳 0
SELECT COUNT(*) FROM (SELECT symbol, trade_date FROM silver.stock GROUP BY symbol, trade_date HAVING COUNT(*) > 1);
-- 0

SELECT COUNT(*) FROM gold.monthly_ohlcv;  -- 42
```

Gold 聚合正確性交叉驗證（`2330` / `2026-07`）：

```sql
SELECT MIN(trade_date) first_day, MAX(trade_date) last_day, MAX(high) month_high, MIN(low) month_low, SUM(volume) month_volume
FROM silver.stock WHERE symbol='2330' AND trade_date >= date '2026-07-01' AND trade_date < date '2026-08-01';
-- first_day=2026-07-01, last_day=2026-07-31, month_high=506.41, month_low=449.46, month_volume=245648623

SELECT open, high, low, close, volume FROM gold.monthly_ohlcv WHERE symbol='2330' AND year_month=date '2026-07-01';
-- open=450.45, high=506.41, low=449.46, close=499.23, volume=245648623
```

`high`/`low`/`volume` 與 Silver 明細手動聚合完全一致。`audit_log` 這輪新增兩筆：`307223448062407430`（`success=false`，前述誤觸發的污染批次）與 `6301798231775002437`（`success=true`，清除後的真正乾淨批次）——連同意外插曲本身也是 spec §7 第三條驗收標準（稽核紀錄可查到「哪個批次被擋下、觸犯哪條規則」）的額外佐證，即使起因不是刻意注入的髒資料。

## Round 2：含髒資料端到端

```bash
uv run python src/ingestion/generate_stock_data.py \
  --years 0.3 --dirty-rate 0.4 --seed 1 \
  --output-dir /tmp/dirty-check-e2e
# 79 個交易日、249 列
aws s3 sync /tmp/dirty-check-e2e/ s3://danny-data-engineering/raw/market/stock/ --profile dt-lab-long-term-mfa --region ap-northeast-1
aws glue start-job-run --job-name slice0-bronze-stock --region ap-northeast-1 --profile dt-lab-long-term-mfa   # 88 秒 SUCCEEDED
aws glue start-job-run --job-name slice0-silver-stock --region ap-northeast-1 --profile dt-lab-long-term-mfa   # 136 秒 SUCCEEDED
```

CloudWatch：

```
[Audit] staging validation success=False
[Audit] FAILED: expect_column_values_to_not_be_null column=symbol
[Audit] FAILED: expect_column_values_to_be_in_set column=symbol
[Audit] FAILED: expect_column_values_to_not_be_null column=trade_date
[Audit] FAILED: expect_column_values_to_not_be_null column=open
[Audit] FAILED: expect_column_values_to_be_between column=open min_value=0.0
[Audit] FAILED: expect_column_values_to_not_be_null column=high
[Audit] FAILED: expect_column_values_to_be_between column=high min_value=0.0
[Audit] FAILED: expect_column_values_to_not_be_null column=low
[Audit] FAILED: expect_column_values_to_be_between column=low min_value=0.0
[Audit] FAILED: expect_column_values_to_not_be_null column=close
[Audit] FAILED: expect_column_values_to_be_between column=close min_value=0.0
[Audit] FAILED: expect_column_values_to_not_be_null column=volume
[Audit] FAILED: expect_column_pair_values_a_to_be_greater_than_b column_A=high column_B=low
[Audit] FAILED: expect_compound_columns_to_be_unique column_list=[symbol, trade_date]
[Publish] BLOCKED: batch 319170298987995934 failed audit, main not updated, 14 violations logged to audit_log
```

14 條規則全數觸發（`--years 0.3 --dirty-rate 0.4 --seed 1` 涵蓋全部六種髒資料 kind，對應 §6 四個維度），符合 [slice1-gx-audit-verification.md](slice1-gx-audit-verification.md) 的 `TestSuiteCatchesDirtyData` 涵蓋範圍。

### Round 2 參考結果

```sql
SELECT * FROM "silver"."stock$refs";
-- staging | BRANCH | 319170298987995934   <- 有推進
-- main    | BRANCH | 6301798231775002437  <- 完全沒變，與 Round 1 結束時一致

SELECT COUNT(*) FROM silver.stock;         -- 825，維持 Round 1 發佈的乾淨結果
SELECT COUNT(*) FROM gold.monthly_ohlcv;   -- 42，未受影響（沒有重跑 Gold，因為 Silver main 沒變，重跑只會得到相同結果）

SELECT batch_id, success, audited_at FROM silver.audit_log ORDER BY audited_at DESC LIMIT 1;
-- 319170298987995934 | false | 2026-08-19 08:25:23 UTC
```

main 在已發佈過一次的狀態下，面對新一輪髒資料，指標完全沒有被移動——這是 spec §7 第一條驗收標準（灌壞資料要被擋下、正式 `silver.stock` 不受影響）的直接證據。

**Bronze 保留原樣、可重跑**：`bronze.stock` 從 5593 成長到 6430（含這輪 249 列髒資料 + 與既有分區重疊日期的重複落地，符合 Bronze append-only 設計），驗證了「Bronze 原樣保留，壞資料進得去 Bronze 但出不了 Silver」。

**已知風險清理**：這輪髒資料裡的 `invalid_symbol`/`invalid_date`/打在 `symbol`/`date` 上的 `empty_field` 又產生了 33 列新的永久污染（同 Round 1 意外插曲的成因）。驗證完成後執行同一條 `DELETE` 清理，確認 0 列殘留，避免留給下一次驗證繼續誤判。

## 對應 spec §7 驗收標準

- [x] 故意灌一批違反 §6 任一規則的資料，能被 Gate 擋下，且正式 `silver.stock` 不受影響（Bronze 仍保留原樣，可重跑）—— Round 2
- [x] 正常乾淨資料能正確通過 Audit 並 publish 到正式 Silver，Gold 層數字與 Slice 0 驗收邏輯一致 —— Round 1
- [x] 稽核紀錄可在 Athena 查到「哪個批次被擋下、觸犯哪條規則」—— Round 1（意外插曲批次）與 Round 2 皆有完整 `violations` 明細對應 CloudWatch 輸出

## 相關文件

- [docs/specs/slice1-quality-contract.md](../specs/slice1-quality-contract.md) §4 項目 8 / §7 — 這份 runbook 對應的驗收項目
- [slice1-wap-verification.md](slice1-wap-verification.md) — Write 階段（staging branch）個別驗證
- [slice1-gx-audit-verification.md](slice1-gx-audit-verification.md) — Audit 階段（GX on Spark on Glue）個別驗證
- [slice1-publish-verification.md](slice1-publish-verification.md) — Publish/擋下 + 稽核紀錄落地個別驗證，「意外插曲」章節記錄了本文件 Round 1/2 都再次踩到的同一個 Bronze 永久污染問題
- [generate-stock-data.md](generate-stock-data.md) — 髒資料產生方式與涵蓋的六種 kind
- [slice0-verification.md](slice0-verification.md) — Slice 0 對應的定案驗證文件，本文件延續同樣的角色定位到 Slice 1
