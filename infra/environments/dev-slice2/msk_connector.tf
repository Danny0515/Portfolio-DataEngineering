# Slice 2 §4 項目 7：CDC connector 部署。
# 見 docs/specs/slice2a-cdc-ingestion.md §4 項目 7、§8。
#
# ⚠️ 修正項目 6 的錯誤假設：msk_connect_plugin.tf 建的兩個獨立 custom plugin
# 不會被下面的 connector 引用。官方 API 文件（API_CreateConnector.html）明載 MSK
# Connect 目前不支援指定多個 plugin 清單，`plugins` 必須是恰好一個元素的清單；
# 要用多個 plugin 必須先合併成同一個 zip。因此這裡另建第三個「合併版」custom
# plugin，同時包含 Debezium 本體與 Glue Schema Registry converter 的 jar。
# 項目 6 那兩個舊 plugin 保留作為「各元件個別能打包成功」的歷史 spike 證據，
# 不刪除（見 runbook 生命週期章節）。

locals {
  debezium_combined_build_dir = "${path.module}/build/debezium_combined_plugin"
  msk_connector_name          = "slice2-debezium-postgres-connector"
}

data "aws_caller_identity" "current" {}

# 全新、獨立下載，不依賴 msk_connect_plugin.tf 那兩個 null_resource 各自的 build
# 目錄——那兩個目錄的生命週期跟著各自資源走，耦合檔案系統狀態而非 Terraform 追蹤
# 的輸出，會讓這個 plugin 的可重現性依賴到不相關資源的 apply 順序。
resource "null_resource" "build_debezium_combined_plugin" {
  triggers = {
    debezium_version  = local.debezium_connector_postgres_version
    converter_version = local.glue_schema_registry_converter_version
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      rm -rf ${local.debezium_combined_build_dir}
      mkdir -p ${local.debezium_combined_build_dir}
      curl -sSL --fail -o ${local.debezium_combined_build_dir}/debezium-plugin.tar.gz \
        "https://repo1.maven.org/maven2/io/debezium/debezium-connector-postgres/${local.debezium_connector_postgres_version}/debezium-connector-postgres-${local.debezium_connector_postgres_version}-plugin.tar.gz"
      tar -xzf ${local.debezium_combined_build_dir}/debezium-plugin.tar.gz -C ${local.debezium_combined_build_dir}
      rm ${local.debezium_combined_build_dir}/debezium-plugin.tar.gz
      curl -sSL --fail -o ${local.debezium_combined_build_dir}/schema-registry-kafkaconnect-converter-${local.glue_schema_registry_converter_version}.jar \
        "https://repo1.maven.org/maven2/software/amazon/glue/schema-registry-kafkaconnect-converter/${local.glue_schema_registry_converter_version}/schema-registry-kafkaconnect-converter-${local.glue_schema_registry_converter_version}.jar"
    EOT
  }
}

data "archive_file" "debezium_combined_plugin" {
  type        = "zip"
  source_dir  = local.debezium_combined_build_dir
  output_path = "${path.module}/build/debezium_combined_plugin.zip"
  depends_on  = [null_resource.build_debezium_combined_plugin]
}

resource "aws_s3_object" "debezium_combined_plugin" {
  bucket = aws_s3_bucket.msk_connect_plugins.id
  key    = "msk-connect-plugins/debezium-combined-plugin.zip"
  source = data.archive_file.debezium_combined_plugin.output_path
  etag   = data.archive_file.debezium_combined_plugin.output_md5
}

resource "aws_mskconnect_custom_plugin" "debezium_combined" {
  name         = "slice2-debezium-combined-plugin"
  content_type = "ZIP"

  location {
    s3 {
      bucket_arn = aws_s3_bucket.msk_connect_plugins.arn
      file_key   = aws_s3_object.debezium_combined_plugin.key
    }
  }
}

# Trust policy：aws:SourceArn 官方建議精確比對 connector 自己的 ARN，但那個 ARN
# 帶隨機 UUID、要 connector 建立後才存在，跟「先有 Role 才能建 connector」的
# Terraform 順序衝突。妥協方案（已與使用者確認，驗證通過後留 ADR 記錄）：
# SourceAccount 精確比對 + SourceArn 只在隨機 UUID 部分用萬用字元，connector
# 名稱本身仍是固定字串。
data "aws_iam_policy_document" "msk_connect_trust" {
  statement {
    sid     = "AllowMSKConnectAssumeScopedToThisConnector"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["kafkaconnect.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:kafkaconnect:${var.aws_region}:${data.aws_caller_identity.current.account_id}:connector/${local.msk_connector_name}/*"]
    }
  }
}

resource "aws_iam_role" "msk_connect_debezium" {
  name               = "slice2-msk-connect-debezium"
  assume_role_policy = data.aws_iam_policy_document.msk_connect_trust.json
}

resource "aws_cloudwatch_log_group" "msk_connect_debezium" {
  name              = "/msk-connect/${local.msk_connector_name}"
  retention_in_days = 14
}

# 因為 MSK cluster 是 unauthenticated（見 msk.tf），不需要官方文件那一大段
# kafka-cluster:* 權限（只有 IAM 認證的 cluster 才需要）；也不需要 S3 讀取權限
# （custom plugin 建立當下 MSK Connect 就把內容複製進自己的儲存，不維持連結）。
# Glue Schema Registry 的 action 已對照 AWS 官方 AWSGlueSchemaRegistryFullAccess/
# ReadonlyAccess 兩個 managed policy 逐一核對存在。
data "aws_iam_policy_document" "msk_connect_permissions" {
  statement {
    sid    = "CloudWatchLogsWorkerLogging"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.msk_connect_debezium.arn}:*"]
  }

  statement {
    sid    = "GlueSchemaRegistryLookupAndAutoRegister"
    effect = "Allow"
    actions = [
      "glue:GetSchemaByDefinition",
      "glue:GetSchemaVersion",
      "glue:GetSchema",
      "glue:ListSchemaVersions",
      "glue:CreateSchema",
      "glue:RegisterSchemaVersion",
    ]
    resources = [
      aws_glue_registry.trade_events.arn,
      "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:schema/${aws_glue_registry.trade_events.registry_name}/*",
    ]
  }
}

resource "aws_iam_policy" "msk_connect_permissions" {
  name   = "slice2-msk-connect-debezium-permissions"
  policy = data.aws_iam_policy_document.msk_connect_permissions.json
}

resource "aws_iam_role_policy_attachment" "msk_connect_permissions" {
  role       = aws_iam_role.msk_connect_debezium.name
  policy_arn = aws_iam_policy.msk_connect_permissions.arn
}

resource "aws_mskconnect_connector" "debezium_postgres" {
  name                 = local.msk_connector_name
  kafkaconnect_version = "3.7.x" # MSK Connect 目前僅支援 2.7.1 / 3.7.x，已即時查證

  capacity {
    # 不用 autoscaling：Debezium 關聯式來源連接器天生單 task/單 replication
    # slot，max_worker_count 永遠用不到，autoscaling 只會多出沒意義的設定面。
    provisioned_capacity {
      mcu_count    = 1
      worker_count = 1
    }
  }

  connector_configuration = {
    "connector.class" = "io.debezium.connector.postgresql.PostgresConnector"
    "tasks.max"        = "1"

    "database.hostname" = aws_db_instance.trade.address
    "database.port"     = tostring(aws_db_instance.trade.port)
    "database.user"     = aws_db_instance.trade.username
    "database.password" = random_password.trade_db.result
    "database.dbname"   = aws_db_instance.trade.db_name

    "topic.prefix"       = "transaction"
    "plugin.name"        = "pgoutput"
    "slot.name"          = "slice2_trade_slot"
    "table.include.list" = "public.trade"

    # Debezium 預設 topic 命名是 <topic.prefix>.<schema>.<table>，會產生
    # transaction.public.trade，不是 spec §5 已承諾的 transaction.trade.v1；
    # 用 RegexRouter SMT 在序列化前改名。
    "transforms"                   = "route"
    "transforms.route.type"        = "org.apache.kafka.connect.transforms.RegexRouter"
    "transforms.route.regex"       = "transaction\\.public\\.trade"
    "transforms.route.replacement" = "transaction.trade.v1"

    # 判斷取捨、非定案：key 用純字串避免另外處理 key schema，2b 若需要直接解析
    # key 的結構化欄位再回頭改成 Avro。
    "key.converter" = "org.apache.kafka.connect.storage.StringConverter"

    "value.converter"                               = "com.amazonaws.services.schemaregistry.kafkaconnect.AWSKafkaAvroConverter"
    "value.converter.region"                        = var.aws_region
    "value.converter.registry.name"                 = aws_glue_registry.trade_events.registry_name
    "value.converter.schemaAutoRegistrationEnabled"  = "true"
    "value.converter.avroRecordType"                 = "GENERIC_RECORD"

    "errors.tolerance"                               = "all"
    "errors.deadletterqueue.topic.name"               = "transaction.trade.v1.dlq"
    "errors.deadletterqueue.topic.replication.factor" = "2"
    "errors.deadletterqueue.context.headers.enable"   = "true"
  }

  kafka_cluster {
    apache_kafka_cluster {
      bootstrap_servers = aws_msk_cluster.trade.bootstrap_brokers_tls

      # 不需要新增 SG 規則：slice2_internal 的 self-referencing 規則本來就涵蓋
      # 443/5432/9094，MSK Connect 的 ENI 加入同一張 SG 後全部涵蓋到。
      vpc {
        security_groups = [aws_security_group.slice2_internal.id]
        subnets         = [for s in aws_subnet.private : s.id]
      }
    }
  }

  kafka_cluster_client_authentication {
    authentication_type = "NONE" # 對應 msk.tf 的 client_authentication.unauthenticated = true
  }

  kafka_cluster_encryption_in_transit {
    encryption_type = "TLS" # 對應 msk.tf 只開 9094 TLS，未開 9092 PLAINTEXT
  }

  plugin {
    custom_plugin {
      arn      = aws_mskconnect_custom_plugin.debezium_combined.arn
      revision = aws_mskconnect_custom_plugin.debezium_combined.latest_revision
    }
  }

  service_execution_role_arn = aws_iam_role.msk_connect_debezium.arn

  log_delivery {
    worker_log_delivery {
      cloudwatch_logs {
        enabled   = true
        log_group = aws_cloudwatch_log_group.msk_connect_debezium.name
      }
    }
  }
}
