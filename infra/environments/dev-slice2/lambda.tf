# Slice 2 交易資料模型與 generator（部署為 Lambda）
# 見 docs/specs/slice2a-cdc-ingestion.md §3.1、§4 項目 3
#
# 為什麼是 Lambda：RDS 在私有子網（無 IGW/NAT），本機沒有路徑直接連進去。Lambda 掛在
# 同一個 VPC/SG 裡執行，本機透過 `aws lambda invoke` 觸發——那條路徑走的是 Lambda 的公開
# API，不需要 bastion/peering/SSM。部署包用純 Python 的 pg8000（見 src/ingestion/
# generate_trade_data.py 開頭註解），不需要處理跨平台編譯。

locals {
  trade_generator_src_dir   = "${path.module}/../../../src/ingestion"
  trade_generator_build_dir = "${path.module}/build/trade_generator"
}

# pg8000 是純 Python，直接 pip install 進部署目錄即可，不需要 manylinux wheel 或跨平台編譯
resource "null_resource" "build_trade_generator" {
  triggers = {
    script_hash = filesha256("${local.trade_generator_src_dir}/generate_trade_data.py")
    sql_hash    = filesha256("${local.trade_generator_src_dir}/sql/create_trade_table.sql")
  }

  provisioner "local-exec" {
    command = <<-EOT
      rm -rf ${local.trade_generator_build_dir}
      mkdir -p ${local.trade_generator_build_dir}/sql
      python3 -m pip install --quiet --target ${local.trade_generator_build_dir} pg8000
      cp ${local.trade_generator_src_dir}/generate_trade_data.py ${local.trade_generator_build_dir}/
      cp ${local.trade_generator_src_dir}/sql/create_trade_table.sql ${local.trade_generator_build_dir}/sql/
    EOT
  }
}

data "archive_file" "trade_generator" {
  type        = "zip"
  source_dir  = local.trade_generator_build_dir
  output_path = "${path.module}/build/trade_generator.zip"
  depends_on  = [null_resource.build_trade_generator]
}

data "aws_iam_policy_document" "trade_generator_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "trade_generator" {
  name               = "slice2-trade-generator-lambda"
  assume_role_policy = data.aws_iam_policy_document.trade_generator_assume.json
}

# 受管政策已包含基本執行權限（CloudWatch Logs）與 VPC ENI 管理權限，Lambda 要在 VPC
# 內執行都需要後者
resource "aws_iam_role_policy_attachment" "trade_generator_vpc_access" {
  role       = aws_iam_role.trade_generator.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_lambda_function" "trade_generator" {
  function_name = "slice2-trade-generator"
  role          = aws_iam_role.trade_generator.arn
  handler       = "generate_trade_data.lambda_handler"
  runtime       = "python3.12"
  timeout       = 300
  memory_size   = 256

  filename         = data.archive_file.trade_generator.output_path
  source_code_hash = data.archive_file.trade_generator.output_base64sha256

  vpc_config {
    subnet_ids         = [for s in aws_subnet.private : s.id]
    security_group_ids = [aws_security_group.slice2_internal.id]
  }

  environment {
    variables = {
      DB_HOST     = aws_db_instance.trade.address
      DB_PORT     = tostring(aws_db_instance.trade.port)
      DB_NAME     = aws_db_instance.trade.db_name
      DB_USER     = aws_db_instance.trade.username
      DB_PASSWORD = random_password.trade_db.result
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.trade_generator_vpc_access,
    aws_vpc_endpoint.logs,
  ]
}
