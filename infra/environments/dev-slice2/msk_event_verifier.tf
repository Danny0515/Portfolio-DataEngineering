# Slice 2 §4 項目 8：CDC 事件驗證。見
# docs/specs/slice2a-cdc-ingestion.md §4 項目 8、§7。
#
# 為什麼是 Lambda：跟 lambda.tf 的 trade_generator 同一個理由（ADR-0008）——MSK broker
# 在私有子網（無 IGW/NAT），本機沒有路徑直接連進去。這支 Lambda 掛在同一個 VPC/SG，
# 本機透過 `aws lambda invoke` 觸發，走 Lambda 的公開 API。
#
# 部署包用純 Python 的 kafka-python-ng（kafka-python 停更後的維護分支）+
# aws-glue-schema-registry（見 src/ingestion/verify_cdc_events.py 開頭註解），
# 延續 pg8000 選型的同一個原則：避免跨平台編譯問題。

locals {
  cdc_event_verifier_src_dir   = "${path.module}/../../../src/ingestion"
  cdc_event_verifier_build_dir = "${path.module}/build/cdc_event_verifier"
}

resource "null_resource" "build_cdc_event_verifier" {
  triggers = {
    script_hash = filesha256("${local.cdc_event_verifier_src_dir}/verify_cdc_events.py")
  }

  # aws-glue-schema-registry 間接依賴 orjson，是編譯過的 Rust extension（不是純
  # Python）——本機 macOS 直接 pip install 會抓到 macOS 版本的 .so，Lambda
  # （Amazon Linux x86_64）載入時炸掉（ImportModuleError: No module named
  # 'orjson.orjson'，已實測撞到）。加 --platform/--only-binary 強制抓 Linux
  # x86_64 版的預編譯 wheel，不需要在本機跨平台編譯。
  provisioner "local-exec" {
    command = <<-EOT
      rm -rf ${local.cdc_event_verifier_build_dir}
      mkdir -p ${local.cdc_event_verifier_build_dir}
      python3 -m pip install --quiet \
        --platform manylinux2014_x86_64 --implementation cp --python-version 3.12 \
        --only-binary=:all: --target ${local.cdc_event_verifier_build_dir} \
        kafka-python-ng aws-glue-schema-registry
      cp ${local.cdc_event_verifier_src_dir}/verify_cdc_events.py ${local.cdc_event_verifier_build_dir}/
    EOT
  }
}

data "archive_file" "cdc_event_verifier" {
  type        = "zip"
  source_dir  = local.cdc_event_verifier_build_dir
  output_path = "${path.module}/build/cdc_event_verifier.zip"
  depends_on  = [null_resource.build_cdc_event_verifier]
}

data "aws_iam_policy_document" "cdc_event_verifier_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cdc_event_verifier" {
  name               = "slice2-cdc-event-verifier-lambda"
  assume_role_policy = data.aws_iam_policy_document.cdc_event_verifier_assume.json
}

resource "aws_iam_role_policy_attachment" "cdc_event_verifier_vpc_access" {
  role       = aws_iam_role.cdc_event_verifier.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# 唯讀權限：consume 端只需要解析訊息 header 裡的 schema version UUID、查回實際
# schema 定義，不需要 msk_connector.tf 那組 producer/auto-registration 才要的
# CreateSchema／RegisterSchemaVersion／GetSchemaByDefinition。
# data.aws_caller_identity.current 已在 msk_connector.tf 宣告，這裡直接引用。
data "aws_iam_policy_document" "cdc_event_verifier_permissions" {
  statement {
    sid    = "GlueSchemaRegistryReadForDeserialization"
    effect = "Allow"
    actions = [
      "glue:GetSchemaVersion",
      "glue:GetSchema",
      "glue:ListSchemaVersions",
    ]
    resources = [
      aws_glue_registry.trade_events.arn,
      "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:schema/${aws_glue_registry.trade_events.registry_name}/*",
    ]
  }
}

resource "aws_iam_policy" "cdc_event_verifier_permissions" {
  name   = "slice2-cdc-event-verifier-permissions"
  policy = data.aws_iam_policy_document.cdc_event_verifier_permissions.json
}

resource "aws_iam_role_policy_attachment" "cdc_event_verifier_permissions" {
  role       = aws_iam_role.cdc_event_verifier.name
  policy_arn = aws_iam_policy.cdc_event_verifier_permissions.arn
}

resource "aws_lambda_function" "cdc_event_verifier" {
  function_name = "slice2-cdc-event-verifier"
  role          = aws_iam_role.cdc_event_verifier.arn
  handler       = "verify_cdc_events.lambda_handler"
  runtime       = "python3.12"
  # 90 秒：TLS 交握 + consumer group join + 呼叫端給的 poll 時間窗（預設 20 秒），
  # 不需要 trade_generator 那種迴圈式多次 DB 呼叫的 300 秒。
  timeout     = 90
  memory_size = 256

  filename         = data.archive_file.cdc_event_verifier.output_path
  source_code_hash = data.archive_file.cdc_event_verifier.output_base64sha256

  vpc_config {
    subnet_ids         = [for s in aws_subnet.private : s.id]
    security_group_ids = [aws_security_group.slice2_internal.id]
  }

  # 不額外設定 region 變數：AWS_REGION 是 Lambda 保留環境變數名稱，這裡設定會讓
  # apply 失敗；boto3.client("glue") 本來就會自動從 runtime 讀取 region。
  environment {
    variables = {
      MSK_BOOTSTRAP_BROKERS = aws_msk_cluster.trade.bootstrap_brokers_tls
      GLUE_REGISTRY_NAME    = aws_glue_registry.trade_events.registry_name
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.cdc_event_verifier_vpc_access,
    aws_iam_role_policy_attachment.cdc_event_verifier_permissions,
    aws_vpc_endpoint.logs,
    aws_vpc_endpoint.glue,
  ]
}
