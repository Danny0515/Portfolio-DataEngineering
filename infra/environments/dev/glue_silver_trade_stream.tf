# Slice 2b §4 項目 1(b) spike：Silver 串流作業（Bronze Iceberg → Silver Iceberg）
# 見 docs/specs/slice2b-streaming-upsert.md §4 項目 1、ADR-0012、ADR-0010。
#
# ⚠️ spike 專用、可整檔移除：刪除本檔後 terraform apply 即銷毀 job 與腳本物件。
# 來源是 spike 的 bronze.spike_trade_events（由 dev-slice2 的 Iceberg sink 寫入）、目標是
# silver.spike_trade，不碰正式表名（silver.trade 留到項目 4）。
#
# 不需要新增 IAM／Lake Formation：glue_market 角色的 S3 權限已涵蓋 lakehouse/* 與
# glue-temp/*（checkpoint 放這裡），lakeformation.tf 對 bronze／silver 的 wildcard 授權
# （DESCRIBE／SELECT／INSERT／ALTER）涵蓋後來才由 sink 建立的表。這個假設由 spike 實測驗證。
resource "aws_s3_object" "silver_trade_stream_script" {
  bucket = aws_s3_bucket.data_engineering.id
  key    = "glue-scripts/silver_trade_stream.py"
  source = "${path.module}/../../../src/transform/silver_trade_stream.py"
  etag   = filemd5("${path.module}/../../../src/transform/silver_trade_stream.py")
}

resource "aws_glue_job" "silver_trade_stream_spike" {
  name         = "slice2b-silver-trade-stream-spike"
  role_arn     = aws_iam_role.glue_market.arn
  glue_version = "5.0"
  max_retries  = 0

  # 串流作業不會自己結束、持續計費；timeout（分鐘）當作忘記停止時的安全網。
  timeout = 180

  command {
    name            = "gluestreaming"
    script_location = "s3://${aws_s3_bucket.data_engineering.id}/${aws_s3_object.silver_trade_stream_script.key}"
    python_version  = "3"
  }

  # G.025X 在 Glue 5.0 是否可用是 spike 要實測的項目（ADR-0010 ⚠️ 注意）；不可用就改 G.1X。
  worker_type       = "G.025X"
  number_of_workers = 2

  default_arguments = {
    "--job-language"                     = "python"
    "--datalake-formats"                 = "iceberg"
    "--conf"                             = local.iceberg_spark_conf
    "--TempDir"                          = "s3://${aws_s3_bucket.data_engineering.id}/glue-temp/spike-silver-trade/tmp/"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-metrics"                   = "true"
    # 預設 checkpoint；每次 start-job-run 以 --CHECKPOINT_PATH 覆寫成不同路徑，才能做
    # 「從頭重讀」「亂序」「重播冪等」三種測試。
    "--CHECKPOINT_PATH" = "s3://${aws_s3_bucket.data_engineering.id}/glue-temp/spike-silver-trade/default/"
  }
}
