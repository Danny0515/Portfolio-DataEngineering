---
description: 查詢資料管線各種 CloudWatch log 的統一入口，方法名稱對應獨立 script，目前提供 get_job_log_by_snapshot
---

# 查詢管線 Log (query_audit_log)

執行 [scripts/query_audit_log.sh](../../scripts/query_audit_log.sh) 這支 dispatcher：第一個參數是「方法名稱」，dispatcher 會呼叫 `scripts/query_audit_log/<method>.sh` 這支獨立 script 並把其餘參數原樣傳進去。

```bash
bash scripts/query_audit_log.sh <method> [args...]
```

一個方法一個檔案、彼此互不影響；新增方法不需要改 dispatcher 本身，見下方「如何新增方法」。

## 為什麼設計成 dispatcher，不是一個 skill 對應一支 script

這個 skill 之後會持續擴充（例如未來可能加 housekeeping log、bronze job log 的查詢方式），但每種查詢的參數、對應的 log group、判斷邏輯都不一樣，硬塞進同一支 script 會變成一堆 `if/elif` 難以維護。拆成「dispatcher + 每個方法各自獨立的 script」，新增一種查詢方式只需要新增一個檔案，不會動到既有方法，也不會讓單一 script 隨時間膨脹。

## 可用方法

### `get_job_log_by_snapshot`

用 Iceberg snapshot_id（`silver.audit_log.batch_id`）反查對應的 Glue Job Run，印出該次執行的完整 CloudWatch log。

```bash
bash scripts/query_audit_log.sh get_job_log_by_snapshot <snapshot_id> [job_name] [region]
```

- `snapshot_id`（必填）：`silver.audit_log.batch_id` 的值
- `job_name`（選填，預設 `slice0-silver-stock`）：目前只有這個 Job 會寫 `audit_log`；未來若有其他表也接上 Audit，可指定對應 Job
- `region`（選填，預設 `ap-northeast-1`）

**為什麼需要這個方法**：`silver.audit_log` 用 Iceberg 的 snapshot_id 當 `batch_id`（見 [docs/runbooks/slice1-publish-verification.md](../../docs/runbooks/slice1-publish-verification.md)），但 snapshot_id 跟 Glue Job Run ID（`jr_...`）是兩套獨立系統各自發的號碼，沒有內建對應表——CloudWatch log stream 是用 Job Run ID 命名的，不是 snapshot_id。唯一的橋樑是 `silver_stock.py` 印出的 `[Audit]`/`[Publish]` 訊息裡剛好帶了 snapshot_id 字串，只能用 CloudWatch Logs 的全文搜尋（`filter-log-events`）反推出對應的 log stream。這個方法把這個排查流程收斂成一個指令。

**使用時機**：在 Athena 查完 `silver.audit_log`（例如 `SELECT * FROM silver.audit_log WHERE success = false`）後，想深入看某一筆 `batch_id` 對應的完整 Job 執行細節——不只 `[Publish]` 那一行摘要，而是完整的 `[Audit]` 違規明細、`[Audit] cwd=...` 診斷輸出、Job 執行時間等。

**內部邏輯**：
1. 用 `aws logs filter-log-events` 在 `/aws-glue/jobs/output` 這個 log group 全文搜尋含有 snapshot_id 字串的事件，取第一筆命中的 `logStreamName`（= Glue Job Run ID）
2. 找不到就報錯並提示確認 `snapshot_id`／`job_name` 是否正確
3. 找到後先印該次 Job Run 的狀態摘要（`JobRunState`／`ExecutionTime`）
4. 再印該 log stream 的完整內容（`aws logs get-log-events`）

實作：[scripts/query_audit_log/get_job_log_by_snapshot.sh](../../scripts/query_audit_log/get_job_log_by_snapshot.sh)

## 如何新增方法

1. 在 `scripts/query_audit_log/` 底下新增一支獨立的 `<method_name>.sh`（命名慣例：`get_XXX_log`，跟 `get_job_log_by_snapshot` 一致），獨立處理該方法的參數與查詢邏輯，不用理會其他方法
2. 在這份文件的「可用方法」底下新增一個小節，說明用法、為什麼需要、使用時機、內部邏輯（比照 `get_job_log_by_snapshot` 那節的格式）
3. 不需要改 `scripts/query_audit_log.sh`（dispatcher）本身——它是用檔名自動比對方法名稱，新檔案會自動被 `usage()` 的可用方法清單抓到

## 前置條件

依 RULE-002，先確認本機已有可重用的 MFA session（`dt-lab-long-term-mfa`）。各方法 script 預設吃 `AWS_PROFILE` 環境變數，未設定時 fallback 用 `dt-lab-long-term-mfa`。

## 安全檢查

- 純查詢工具，不修改任何 AWS 資源，不需要額外確認門檻
- 依 RULE-001 精神，這裡的 `aws cli` 呼叫全部是唯讀查詢（`filter-log-events`／`get-log-events`／`get-job-run` 等），沒有任何部署/變更性質指令；新增方法時也應維持這個原則，不要在這個 skill 底下加入會變更 AWS 資源的操作
