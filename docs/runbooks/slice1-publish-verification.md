# Runbook: Slice1 Publish / 擋下邏輯 + 稽核紀錄落地 驗證

## 背景 (Why)

對應 [docs/specs/slice1-quality-contract.md](../specs/slice1-quality-contract.md) §4 項目 5「Publish / 擋下邏輯」與項目 6「稽核紀錄落地」。item 4 的 Audit 已經驗證過能在 Glue 上正確跑出 pass/fail（見 [slice1-gx-audit-verification.md](slice1-gx-audit-verification.md)），但結果只印到 CloudWatch，沒有任何實際動作——WAP Gate 當時還只是「觀察者」。這份 runbook 驗證的是把 Audit 結果變成真正動作的那一步：

- **Publish**：Audit 通過 → `CALL glue_catalog.system.fast_forward(...)` 把 `main` 推進到 staging 目前的 snapshot
- **擋下**：Audit 失敗 → `main` 完全不動
- **稽核紀錄**：不論通過或失敗，每次 Audit 都寫一筆到新的 Iceberg 表 `silver.audit_log`（`batch_id`／`success`／`violations`／`audited_at`），`batch_id` 用當次 staging 分支的 snapshot_id 識別

實作見 `src/transform/silver_stock.py` 的 `get_staging_snapshot_id()` / `write_audit_log()` 與其後的 `if audit_result.success: ... else: ...` 區塊。

## 前置條件

- 本機已有可重用的 AWS MFA session（`dt-lab-long-term-mfa`）
- `silver.stock` 已存在（沿用先前 Slice 執行留下的表）

## 部署

```bash
cd infra/environments/dev
AWS_PROFILE=dt-lab-long-term-mfa terraform apply -target=aws_s3_object.silver_script
```

只有 `silver_script` 這個 S3 物件因為程式碼內容變動而更新，`.tf` 本身沒有改動——`fast_forward` 用的 `ALTER` 權限、`audit_log` 新表用的 `CREATE_TABLE`/wildcard 權限，都已經被既有的 `lakeformation.tf` 設定涵蓋，這次沒有額外調整。

## 意外插曲：Bronze 裡的永久性髒資料，dedup 救不回來

原本預期「重新產生一批全乾淨資料、重跑 Bronze/Silver，靠 dedup 讓新資料蓋掉舊的髒資料」就能跑出一輪乾淨的 Audit，實際執行後發現不成立：

```bash
uv run python src/ingestion/generate_stock_data.py   # 重新產生全乾淨資料
aws s3 sync data/raw/market/stock/ s3://danny-data-engineering/raw/market/stock/
# 觸發 bronze/silver 之後，Audit 依然 success=False
```

查 `bronze.stock` 才發現：`invalid_symbol`（`symbol=9999/0000/ABCD`）、`invalid_date`（`date` 格式跑掉）、`empty_field` 打在 `symbol`/`date` 上這幾種髒資料 kind，會產生**全新的 (symbol, date) key**，跟乾淨資料完全不會撞到同一個 key，所以 Silver 的 dedup（`ORDER BY ingest_time DESC` 只在**同一個 key** 內比大小）永遠不會把它們排擠掉——這些列會**永久卡在 Bronze 裡**，不管重跑幾次乾淨資料都一樣。`negative_price`/`high_lt_low`/打在數值欄位上的 `empty_field` 則不受影響，因為它們沿用原本合法的 (symbol, date)，新的乾淨列會用更新的 `ingest_time` 蓋過去。

比對本機沒有污染的驗證資料，`bronze.stock` 當時累積 3213 列，其中 33 列符合「symbol 不在白名單／symbol 為 null／date 不是 `YYYY-MM-DD` 格式／date 為 null」的條件，用 Athena 對 Iceberg v2 表直接執行列級刪除，範圍精準、不影響其餘乾淨歷史列：

```sql
-- 執行前先 SELECT COUNT(*) 確認影響筆數，這裡是 33 / 3213
DELETE FROM bronze.stock
WHERE symbol IS NULL
   OR symbol NOT IN ('2330', '2454', '3653')
   OR date IS NULL
   OR NOT regexp_like(date, '^[0-9]{4}-[0-9]{2}-[0-9]{2}$');
```

刪除後確認同一條件查詢回傳 0 列，再重跑 Silver，才拿到真正的乾淨結果（見下方「第 2 輪」）。這件事本身也是這次驗證的一個副產品發現：**Bronze 的「累積、不刪除」設計（ADR-0002/0003）在正常資料世界裡沒問題，但測試/demo 情境下刻意灌入的髒資料，如果打中的是「新增一個從未存在過的 key」而非「污染既有 key」，會變成永久污染，只能用明確的 DELETE 清除，不能靠重灌乾淨資料自然覆蓋**。

## 驗證步驟與參考結果（2026-08-14 執行）

**執行前基準**：main snapshot_id = `1685447700659273070`（自 Slice1 branch 驗證以來未變動過）。

### 第 1 輪：仍受污染的 Bronze（部署後第一次觸發，尚未清除髒列）

```bash
aws glue start-job-run --job-name slice0-silver-stock --region ap-northeast-1
```

`JobRunState=SUCCEEDED`（144 秒）。CloudWatch：

```
[Audit] staging validation success=False
[Audit] FAILED: expect_column_values_to_not_be_null column=symbol
[Audit] FAILED: expect_column_values_to_be_in_set column=symbol
[Audit] FAILED: expect_column_values_to_not_be_null column=trade_date
[Audit] FAILED: expect_compound_columns_to_be_unique column_list=[symbol, trade_date]
[Publish] BLOCKED: batch 7551400955039697410 failed audit, main not updated, 4 violations logged to audit_log
```

這一輪意外證明了 Publish/擋下邏輯本身完全正確（即使不是原本規劃的「先跑乾淨」順序）：Audit 失敗、main 沒被動、`audit_log` 正確寫入一筆 `success=false` 的紀錄。

### 清除 Bronze 髒列（見上方「意外插曲」），第 2 輪：真正的乾淨資料

```bash
aws glue start-job-run --job-name slice0-silver-stock --region ap-northeast-1
```

`JobRunState=SUCCEEDED`（143 秒）。CloudWatch：

```
[Audit] staging validation success=True
[Publish] merged staging (snapshot=7882369420455484184) -> main
```

Athena 確認：

```sql
SELECT * FROM "silver"."stock$refs";
-- staging | BRANCH | 7882369420455484184
-- main    | BRANCH | 7882369420455484184   <- 跟執行前的 1685447700659273070 不同，且與 staging 一致
```

`main` 的 snapshot_id 從 `1685447700659273070` 變成 `7882369420455484184`，與 staging 當輪 snapshot 完全一致——**`fast_forward` 確實生效**，不是只看 Job 沒報錯就假設成功。`silver.audit_log` 新增一筆 `batch_id=7882369420455484184, success=true, violations=[]`。

### 第 3 輪：發佈成功之後，再灌一批新的髒資料

```bash
uv run python src/ingestion/generate_stock_data.py \
  --years 0.3 --dirty-rate 0.4 --seed 1 --output-dir /tmp/dirty-check-2
# 80 個交易日、252 列
aws s3 sync /tmp/dirty-check-2/ s3://danny-data-engineering/raw/market/stock/
aws glue start-job-run --job-name slice0-bronze-stock --region ap-northeast-1   # 先跑 Bronze
aws glue start-job-run --job-name slice0-silver-stock --region ap-northeast-1   # 再跑 Silver
```

`JobRunState=SUCCEEDED`（110 秒）。CloudWatch：

```
[Audit] staging validation success=False
[Audit] FAILED: expect_column_values_to_not_be_null column=symbol
[Audit] FAILED: expect_column_values_to_be_in_set column=symbol
[Audit] FAILED: expect_column_values_to_not_be_null column=trade_date
[Audit] FAILED: expect_column_values_to_not_be_null column=volume
[Audit] FAILED: expect_compound_columns_to_be_unique column_list=[symbol, trade_date]
[Publish] BLOCKED: batch 7603310256800310412 failed audit, main not updated, 5 violations logged to audit_log
```

Athena 確認：

```sql
SELECT * FROM "silver"."stock$refs";
-- staging | BRANCH | 7603310256800310412   <- 有推進
-- main    | BRANCH | 7882369420455484184   <- 完全沒變，跟第 2 輪結束時一致

SELECT COUNT(*) FROM silver.stock;  -- 816，維持第 2 輪發佈的乾淨結果，沒被這輪髒資料污染
```

這就是 spec §7 第一條驗收標準（灌壞資料要被擋下、main 不受影響）的直接證據：main 在已經發佈過一次的狀態下，面對新一輪髒資料，指標完全沒有被移動。

### `audit_log` 最終內容

```sql
SELECT batch_id, success, audited_at FROM silver.audit_log ORDER BY audited_at;
```

| batch_id | success | audited_at |
| --- | --- | --- |
| 7551400955039697410 | false | 2026-08-14 06:22:09 UTC |
| 7882369420455484184 | true | 2026-08-14 06:30:24 UTC |
| 7603310256800310412 | false | 2026-08-14 06:35:36 UTC |

三筆紀錄分別對應上面三輪，`batch_id` 跟每輪 CloudWatch 印出的批次編號一致，`success` 欄位跟 Audit 結果一致——這是 spec §7 第三條驗收標準（稽核紀錄 Athena 可查）的直接證據。第一輪失敗的 `violations` 欄位內容（JSON 字串）也跟當輪 CloudWatch 印出的違規明細逐條對應，未額外複製於此表（見上方 CloudWatch 區塊）。

## 追加：移除 Write 階段的手寫品質過濾（2026-08-14）

上面三輪跑完後發現 `silver_stock.py` 在 Write 階段（cast 之後）還留著一段手寫的 `filter()`，逐列濾掉 null/負值/`high<low` 的 OHLC——這段跟 GX 規則（§6）重疊，而且是**逐列靜默丟棄**：壞列進不了 staging，Audit 自然驗證不到，`negative_price`/`high_lt_low` 這兩種髒資料 kind 從來沒有在 `audit_log` 裡出現過（見上面第 1、3 輪的 CloudWatch 輸出，都只有 4-5 條違規，不含這兩種）。這跟「壞資料應該整批被擋下、留下稽核紀錄」的 WAP 精神不符，於是移除這段過濾，改成完全交給 GX 把關。

移除後重新部署、重跑一輪同樣的髒資料組合（`--years 0.3 --dirty-rate 0.4 --seed 1`），CloudWatch 這次看到 **14 條違規**（先前只有 4-5 條），新增的違規正是原本被濾掉的兩種：

```
[Audit] FAILED: expect_column_values_to_be_between column=open min_value=0.0
[Audit] FAILED: expect_column_values_to_be_between column=high min_value=0.0
[Audit] FAILED: expect_column_values_to_be_between column=low min_value=0.0
[Audit] FAILED: expect_column_values_to_be_between column=close min_value=0.0
[Audit] FAILED: expect_column_pair_values_a_to_be_greater_than_b column_A=high column_B=low
[Publish] BLOCKED: batch 7969718383083849533 failed audit, main not updated, 14 violations logged to audit_log
```

Athena 確認 `main` 仍是 `7882369420455484184`，完全沒被這輪異動——擋下邏輯不受這次改動影響，唯一改變的是 Audit 現在能看到、記錄到完整的違規全貌。

## 相關文件

- [docs/specs/slice1-quality-contract.md](../specs/slice1-quality-contract.md) §3.2 / §4 項目 5-6 — 這份 runbook 對應的決策與待驗收項目
- [docs/runbooks/slice1-gx-audit-verification.md](slice1-gx-audit-verification.md) — item 4 Audit 的正式環境驗證，本文件延伸驗證下一步的 Publish/擋下
- [docs/runbooks/slice1-wap-verification.md](slice1-wap-verification.md) — WAP staging（Write 階段）驗證，main 全程是 staging 祖先的性質是 `fast_forward` 能成立的前提
- [docs/runbooks/generate-stock-data.md](generate-stock-data.md) — 髒資料產生方式與涵蓋的六種 kind
