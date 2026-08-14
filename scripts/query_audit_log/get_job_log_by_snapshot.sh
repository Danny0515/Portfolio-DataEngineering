#!/usr/bin/env bash
# 用 Iceberg snapshot_id（silver.audit_log 的 batch_id）反查對應的 Glue Job Run，
# 印出該次執行的完整 CloudWatch log。
#
# snapshot_id 是 Iceberg 自己發的識別碼，跟 Glue Job Run ID（jr_...）是兩套獨立系統，
# 沒有內建對應表——CloudWatch log stream 是用 Job Run ID 命名的，不是 snapshot_id。
# 唯一的橋樑是 silver_stock.py 印出的 [Audit]/[Publish] 訊息裡剛好帶了 snapshot_id
# 字串，所以用 CloudWatch Logs 的全文搜尋（filter-log-events）反推出對應的 log stream。
set -euo pipefail

SNAPSHOT_ID="${1:?用法: scripts/query_audit_log.sh get_job_log_by_snapshot <snapshot_id> [job_name] [region]}"
JOB_NAME="${2:-slice0-silver-stock}"
REGION="${3:-ap-northeast-1}"
LOG_GROUP="/aws-glue/jobs/output"
PROFILE="${AWS_PROFILE:-dt-lab-long-term-mfa}"

echo "[1/2] 在 ${LOG_GROUP} 搜尋 snapshot_id=${SNAPSHOT_ID} ..."
# filter-log-events 會自動分頁，--query 是逐頁套用，用 events[0] 在沒命中的
# 頁面會印出一行 "None"；改用 events[*]（複數）讓沒命中的頁面印空行，
# 再用 grep 過濾掉空行、取第一筆真正命中的結果。
# grep 找不到相符行時會回傳非 0，加上 `|| true` 避免被 `pipefail` 當成整個
# pipeline 失敗、提早跳出腳本——找不到的情況要交給下面的 -z 判斷處理。
LOG_STREAM=$(aws logs filter-log-events \
  --profile "${PROFILE}" \
  --log-group-name "${LOG_GROUP}" \
  --filter-pattern "${SNAPSHOT_ID}" \
  --region "${REGION}" \
  --query 'events[*].logStreamName' --output text | grep -v '^$' | head -1 || true)

if [[ -z "${LOG_STREAM}" ]]; then
  echo "找不到含有這個 snapshot_id 的 log。請確認 snapshot_id 是否正確，" >&2
  echo "或這筆紀錄是否來自別的 Job（用第 2 個參數指定 job_name，預設是 ${JOB_NAME}）。" >&2
  exit 1
fi

echo "找到 Job Run ID: ${LOG_STREAM}"
echo

echo "[2/2] Job Run 狀態："
aws glue get-job-run \
  --profile "${PROFILE}" \
  --job-name "${JOB_NAME}" \
  --run-id "${LOG_STREAM}" \
  --region "${REGION}" \
  --query 'JobRun.{State:JobRunState,StartedOn:StartedOn,CompletedOn:CompletedOn,ExecutionTime:ExecutionTime}'
echo

echo "完整 log："
aws logs get-log-events \
  --profile "${PROFILE}" \
  --log-group-name "${LOG_GROUP}" \
  --log-stream-name "${LOG_STREAM}" \
  --region "${REGION}" \
  --query 'events[*].message' --output text
