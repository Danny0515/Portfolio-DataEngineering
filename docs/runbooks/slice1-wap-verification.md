# Runbook: Slice1 WAP Staging 機制 Athena 查詢驗證

## 背景 (Why)

對應 [docs/specs/slice1-quality-contract.md](../specs/slice1-quality-contract.md) §4 項目 3「WAP staging 機制」：`src/transform/silver_stock.py` 從第 2 次執行起（`silver.stock` 已存在時），不再直接整表覆寫 main，改成先寫入 Iceberg 的 `staging` branch，main 維持不動。這份 runbook 補上「怎麼在正式環境（AWS Glue + Glue Data Catalog + Athena）用查詢核對這個行為」，比照 [slice0-verification.md](slice0-verification.md) 的方式——只看 Glue Job 回報 `SUCCEEDED` 不足以確認 branch 真的建對、main 真的沒被動到。

實作本身已經先用 [scripts/verify_wap_branch_write.py](../../scripts/verify_wap_branch_write.py) 在本機（簡化 schema + Iceberg **Hadoop catalog**，不碰 AWS）驗證過 branch 寫入機制；這份文件是同一件事在**正式環境**（真正的 `silver.stock`、**Glue Data Catalog**、Athena）的對應驗證，兩者互補，不是重複。

**兩者的權威性不對等，這點要明確**：本機 Hadoop catalog 只適合開發當下快速驗證邏輯本身寫得對不對（不用每次改動都真的跑一次 Glue Job，省時間也省成本），**不能取代正式環境驗證**——Hadoop catalog 是完全不同的 catalog-impl，測不到「Glue Data Catalog 支不支援某個 Iceberg 操作」這件事（見下方 §3.2/§8 風險說明的實際案例）。**Slice 1 階段驗收時，一律以這份文件（真實 AWS Glue + Glue Data Catalog + Athena）的結果為準**；本機腳本的結果只作為開發期間的參考，不具驗收效力。

**這份 runbook 同時是 spec §3.2 / §8 那個懸而未決風險的解答**：「AWS Glue Catalog + 目前綁定的 Iceberg 1.7.1 版本組合是否真的支援 `CREATE BRANCH` 操作」，本機驗證完全沒測到這件事——`verify_wap_branch_write.py` 用的是 Hadoop catalog（純檔案系統），branch 語法在 Iceberg Spark 層是通用邏輯沒錯，但「Glue Catalog 這個 catalog-impl 實作本身」有沒有正確支援 branch 相關的 RPC/metadata 操作，只有真的對著 `glue_catalog` 下 `ALTER TABLE ... CREATE BRANCH` 才測得到。**這件事已經在 2026-08-07 實際跑過兩輪確認：Glue Catalog + Iceberg 1.7.1 完整支援 branch 操作，spec §3.2/§8 的風險已解除，不需要走「降級為手動 staging table + ADR」的備案路線**——完整過程與數字見下方「參考結果」。

**範圍限制**：目前只有項目 3（Write 階段）完成，項目 4（Audit）與項目 5（Publish/fast-forward）都還沒實作。這份 runbook 只能驗證「staging 有沒有正確收到新資料、main 有沒有維持不動」，還不能驗證「品質不合格的資料會被擋下」——那要等項目 4/5 做完才有意義，屆時會在這份文件補上對應章節。

## 前置條件

- 本機已有可用的 AWS MFA session（`dt-lab-long-term-mfa`，見 `aws-cli-mfa-session` skill；也可以直接在 AWS Console 的 Athena 頁面手動貼上跑）
- `silver.stock` **必須已經存在**（沿用 Slice0 或先前 Slice1 執行留下的表即可，不需要重新跑 Bronze）。這點是這份 runbook 能不能驗證到重點的關鍑：`silver_stock.py` 只有在表已存在時才會走 staging branch 路徑；如果是全新環境、`silver.stock` 還不存在，第一次執行只會走 bootstrap（直接建表在 main），看不到任何 branch 行為，必須先確保表已存在再開始下面的步驟

## 部署新版程式碼

```bash
terraform apply
```

在 `infra/environments/dev` 下執行。這次改動只動了 `src/transform/silver_stock.py` 的內容，Terraform 會偵測到 `aws_s3_object.silver_script` 的 `etag` 變化並重新上傳腳本到 S3，不會新增任何資源。

## 記下執行前的基準

```sql
-- main 筆數（之後每一輪執行都應該維持這個數字不變）
SELECT COUNT(*) AS silver_count_before FROM silver.stock;

-- 目前的 branch/tag 清單，乾淨環境下應該只有 main 一條
SELECT * FROM "silver"."stock$refs";
```

## 觸發 Silver Glue Job（第一輪）

```bash
aws glue start-job-run --job-name slice0-silver-stock --region ap-northeast-1 --profile dt-lab-long-term-mfa
```

## 驗證：staging branch 是否正確建立、main 是否維持不動

```sql
-- 1. 應該多一條 name='staging' 的 ref，main 的 snapshot_id 應該跟執行前完全一樣
SELECT * FROM "silver"."stock$refs";

-- 2. main 筆數應該跟執行前的基準值一致，不因為這次執行而改變
SELECT COUNT(*) AS silver_count_after FROM silver.stock;

-- 3. snapshot 歷史應該多一筆新 snapshot；這筆新 snapshot 的 parent_id 應該等於
--    main 目前的 snapshot_id（對應 docs/specs/slice1-quality-contract.md §3.2
--    決定 A 底下、CREATE BRANCH IF NOT EXISTS 冪等性推導出的「main 永遠是
--    staging 每個新 snapshot 的祖先」這個性質，未來項目 5 的 fast_forward 依賴這點）
SELECT snapshot_id, parent_id, committed_at, operation
FROM "silver"."stock$snapshots"
ORDER BY committed_at DESC
LIMIT 5;
```

## 驗證：重跑（rerun）是否維持 main 不動、staging 持續疊加新 snapshot

比照 [slice0-verification.md](slice0-verification.md)「Bronze 重跑驗證」的精神，Silver 的 WAP write 也該實測「跑第二次」的行為，不能只驗證一次就假設冪等性成立：

```bash
aws glue start-job-run --job-name slice0-silver-stock --region ap-northeast-1 --profile dt-lab-long-term-mfa
```

```sql
-- main 筆數應該仍與最初基準值相同——連續兩輪執行都沒有更新過 main
SELECT COUNT(*) AS silver_count_after_2nd_run FROM silver.stock;

-- 應該又多一筆新 snapshot，其 parent_id 應該等於「第一輪執行後 staging 那筆
-- snapshot 的 snapshot_id」，而不是 main 的 snapshot_id——這才是
-- CREATE BRANCH IF NOT EXISTS 對已存在 branch 是 no-op（不重置 HEAD）的具體證據
SELECT snapshot_id, parent_id, committed_at, operation
FROM "silver"."stock$snapshots"
ORDER BY committed_at DESC
LIMIT 5;
```

## （選用）直接讀 staging branch 的實際資料內容

上面幾條查詢只靠 metadata table（`$refs`/`$snapshots`）就能確認「branch 有沒有建對、main 有沒有被動到」，不需要真的讀到 staging 的資料列。如果想進一步肉眼核對 staging 裡的實際內容，可以先試：

```sql
SELECT * FROM silver.stock FOR VERSION AS OF 'staging' LIMIT 20;
SELECT COUNT(*) FROM silver.stock FOR VERSION AS OF 'staging';
```

**（2026-08-07 已實測確認）**：這個語法可行，Athena 直接吃 branch 名稱字串，不需要先查 snapshot_id 再代入。當次跑出來 staging 筆數為 786，內容與 main 一致（因為當時跑的是乾淨資料，Write 階段本身不做品質過濾，Audit／項目 4 還沒接上）。

## 參考結果

**（2026-08-07 執行）**：`silver.stock` 執行前基準為 786 筆，main snapshot_id = `1685447700659273070`，`$refs` 只有 `main` 一條。

依上面流程連續觸發兩輪 `slice0-silver-stock`，兩輪 Job 都 `SUCCEEDED`（`ErrorMessage: null`），確認 Glue Catalog 完整支援 `CREATE BRANCH`：

| | main snapshot_id | staging snapshot_id | staging 的 parent_id |
| --- | --- | --- | --- |
| 執行前 | `1685447700659273070` | （不存在） | — |
| 第 1 輪後 | `1685447700659273070`（不變） | `8354526197036792519` | `1685447700659273070`（main） |
| 第 2 輪後 | `1685447700659273070`（不變） | `8009323305660367987` | `8354526197036792519`（上一輪的 staging，不是 main） |

兩輪執行後 `SELECT COUNT(*) FROM silver.stock` 皆維持 786，main 完全沒被動到。第 2 輪 staging 新 snapshot 的 `parent_id` 接的是「上一輪 staging 自己的 snapshot」而非 main，具體驗證了 `CREATE BRANCH IF NOT EXISTS` 對已存在的 branch 是 no-op、不會重置 HEAD，main 全程是 staging 每個新 snapshot 的祖先——未來項目 5 的 `fast_forward` 依賴的正是這個性質。

「直接讀 staging branch 資料內容」（`FOR VERSION AS OF 'staging'`）這次沒有實測，只驗證了 metadata table（`$refs`/`$snapshots`）+ 筆數不變這三點，這三點已經足以確認 branch 寫入機制在正式環境正確運作。

## 相關文件

- [docs/specs/slice1-quality-contract.md](../specs/slice1-quality-contract.md) §3.2 / §4 項目 3 — 這份 runbook 對應的決策與待驗收項目
- [scripts/verify_wap_branch_write.py](../../scripts/verify_wap_branch_write.py) — 同一套 branch 寫入機制在本機（簡化 schema、Iceberg Hadoop catalog）的獨立驗證腳本，這份文件是它在正式環境的對應版本
- [slice0-verification.md](slice0-verification.md) — Bronze/Silver/Gold 三層的基本查詢驗證；本文件延伸其中「Silver 驗證」一節，改為驗證 WAP staging 行為
- [aws-access-via-bastion.md](aws-access-via-bastion.md) — 如何取得 AWS 存取權限、如何觸發 Glue Job
