# Slice 2b §4 項目 1(a)：Iceberg Kafka Connect sink spike（ADR-0012，💬 Proposed）。
# 見 docs/specs/slice2b-streaming-upsert.md §3.1、§4 項目 1、docs/architecture/adr/0012-*.md。
#
# ⚠️ 這是 spike，可整檔移除：不修改任何既有 .tf；寫入的表名一律帶 spike_ 前綴
# （bronze.spike_trade_events），避免污染日後正式的 bronze.trade_events。
# 復原方式：刪除本檔 → terraform apply（銷毀 plugin／connector／role／policy／
# log group／LF grant）；Iceberg 表與 S3 資料另需手動移除，見 spike runbook 的
# 「副作用台帳」。若 spike 通過，本檔視為項目 3 的起點（改成正式表名、移除 spike 命名）。
#
# 沿用 msk_connector.tf 的模式（單一 plugin = sink 本體 + Glue SR converter、
# 獨立 trust／role／log group），因為 MSK Connect 一個 connector 只能掛一個
# plugin（見 docs/patterns/msk-connect-single-plugin-per-connector.md）。刻意複製貼上，
# 不重構運行中的 Debezium connector；是否抽模組於 spike 通過後再決定。

variable "data_bucket_name" {
  description = "資料湖 bucket 名稱（dev 環境擁有，這裡用字面值引用，不用 terraform_remote_state，維持 dev／dev-slice2 兩個 state 切乾淨）"
  type        = string
  default     = "danny-data-engineering"
}

variable "iceberg_warehouse_prefix" {
  description = "Iceberg warehouse 的 S3 key prefix，需與 dev 環境的 iceberg_warehouse_prefix 一致"
  type        = string
  default     = "lakehouse/"
}

locals {
  iceberg_sink_version         = "1.9.2"
  iceberg_sink_sha1            = "52dab2ff2b9659008deec803d1c1e92813c5ffa7"
  iceberg_sink_download_url    = "https://hub-downloads.confluent.io/api/plugins/iceberg/iceberg-kafka-connect/versions/${local.iceberg_sink_version}/iceberg-iceberg-kafka-connect-${local.iceberg_sink_version}.zip"
  iceberg_sink_build_dir       = "${path.module}/build/iceberg_sink_plugin"
  iceberg_sink_connector_name  = "slice2-iceberg-sink-spike"
  iceberg_warehouse_uri        = "s3://${var.data_bucket_name}/${var.iceberg_warehouse_prefix}"
  iceberg_sink_bronze_database = "bronze"
  iceberg_sink_bronze_table    = "spike_trade_events"
}

# 產物來自 Confluent Hub 上的 Apache Iceberg Sink Connector 發行 zip（Maven Central
# 只有核心 jar，沒有含依賴的 runtime）。zip 內已含 iceberg-aws、AWS SDK v2 的 glue／
# s3／sts／lakeformation 等 jar，不需要另補 aws bundle；GCP／Azure／gRPC 相關 jar
# 用不到，打包時移除以縮小 plugin（移除清單見 spike runbook）。
resource "null_resource" "build_iceberg_sink_plugin" {
  triggers = {
    sink_version      = local.iceberg_sink_version
    converter_version = local.glue_schema_registry_converter_version
    build_script      = "v1-prune-gcp-azure"
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      rm -rf ${local.iceberg_sink_build_dir}
      mkdir -p ${local.iceberg_sink_build_dir}/_dl ${local.iceberg_sink_build_dir}/iceberg-kafka-connect
      curl -sSL --fail -o ${local.iceberg_sink_build_dir}/_dl/sink.zip "${local.iceberg_sink_download_url}"
      echo "${local.iceberg_sink_sha1}  ${local.iceberg_sink_build_dir}/_dl/sink.zip" | shasum -c -
      unzip -q ${local.iceberg_sink_build_dir}/_dl/sink.zip -d ${local.iceberg_sink_build_dir}/_dl -x "__MACOSX/*"
      cp ${local.iceberg_sink_build_dir}/_dl/iceberg-iceberg-kafka-connect-${local.iceberg_sink_version}/lib/*.jar ${local.iceberg_sink_build_dir}/iceberg-kafka-connect/
      (cd ${local.iceberg_sink_build_dir}/iceberg-kafka-connect && ls | grep -iE "azure|google|grpc|gcs|proto-google|opencensus|opentelemetry" | xargs rm -f)
      rm -rf ${local.iceberg_sink_build_dir}/_dl
      curl -sSL --fail -o ${local.iceberg_sink_build_dir}/schema-registry-kafkaconnect-converter-${local.glue_schema_registry_converter_version}.jar \
        "https://repo1.maven.org/maven2/software/amazon/glue/schema-registry-kafkaconnect-converter/${local.glue_schema_registry_converter_version}/schema-registry-kafkaconnect-converter-${local.glue_schema_registry_converter_version}.jar"
    EOT
  }
}

data "archive_file" "iceberg_sink_plugin" {
  type        = "zip"
  source_dir  = local.iceberg_sink_build_dir
  output_path = "${path.module}/build/iceberg_sink_plugin.zip"
  depends_on  = [null_resource.build_iceberg_sink_plugin]
}

resource "aws_s3_object" "iceberg_sink_plugin" {
  bucket = aws_s3_bucket.msk_connect_plugins.id
  key    = "msk-connect-plugins/iceberg-sink-spike-plugin.zip"
  source = data.archive_file.iceberg_sink_plugin.output_path
  etag   = data.archive_file.iceberg_sink_plugin.output_md5
}

resource "aws_mskconnect_custom_plugin" "iceberg_sink" {
  name         = "slice2-iceberg-sink-spike-plugin"
  content_type = "ZIP"

  location {
    s3 {
      bucket_arn = aws_s3_bucket.msk_connect_plugins.arn
      file_key   = aws_s3_object.iceberg_sink_plugin.key
    }
  }
}

# Trust policy 沿用 ADR-0009 的妥協寫法（SourceAccount 精確比對 + SourceArn 對
# connector 名稱固定、UUID 部分萬用字元）。
data "aws_iam_policy_document" "iceberg_sink_trust" {
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
      values   = ["arn:aws:kafkaconnect:${var.aws_region}:${data.aws_caller_identity.current.account_id}:connector/${local.iceberg_sink_connector_name}/*"]
    }
  }
}

resource "aws_iam_role" "msk_connect_iceberg_sink" {
  name               = "slice2-msk-connect-iceberg-sink"
  assume_role_policy = data.aws_iam_policy_document.iceberg_sink_trust.json
}

resource "aws_cloudwatch_log_group" "msk_connect_iceberg_sink" {
  name              = "/msk-connect/${local.iceberg_sink_connector_name}"
  retention_in_days = 14
}

# 權限範圍：
# - logs：只寫自己的 log group。
# - Glue Schema Registry：只讀（sink 解碼，不註冊 schema），範圍鎖定本專案 registry。
# - S3：只動 warehouse prefix（sink 寫 data／metadata 檔）。
# - Glue Catalog：只動 bronze 資料庫與其下的表（auto-create 需要 CreateTable／UpdateTable）。
# MSK cluster 為 unauthenticated，不需要 kafka-cluster:* 權限。
data "aws_iam_policy_document" "iceberg_sink_permissions" {
  statement {
    sid    = "CloudWatchLogsWorkerLogging"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.msk_connect_iceberg_sink.arn}:*"]
  }

  statement {
    sid    = "GlueSchemaRegistryReadForDecoding"
    effect = "Allow"
    actions = [
      "glue:GetSchemaByDefinition",
      "glue:GetSchemaVersion",
      "glue:GetSchema",
      "glue:ListSchemaVersions",
    ]
    resources = [
      aws_glue_registry.trade_events.arn,
      "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:schema/${aws_glue_registry.trade_events.registry_name}/*",
    ]
  }

  statement {
    sid    = "S3WarehouseObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["arn:aws:s3:::${var.data_bucket_name}/${var.iceberg_warehouse_prefix}*"]
  }

  statement {
    sid       = "S3WarehouseList"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = ["arn:aws:s3:::${var.data_bucket_name}"]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${var.iceberg_warehouse_prefix}*"]
    }
  }

  statement {
    sid    = "GlueCatalogBronzeDatabase"
    effect = "Allow"
    actions = [
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:CreateTable",
      "glue:GetTable",
      "glue:GetTables",
      "glue:UpdateTable",
    ]
    resources = [
      "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:catalog",
      "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:database/${local.iceberg_sink_bronze_database}",
      "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${local.iceberg_sink_bronze_database}/*",
    ]
  }

  # ⚠️ spike 專用（實測發現）：開啟 auto-create 時，sink 在建表前會無條件呼叫
  # createNamespace（即使 bronze 已存在，也會先打 glue:CreateDatabase 再吃
  # AlreadyExists），沒有這個 IAM 權限就在授權階段被拒絕。資源範圍限定在 catalog 與
  # bronze，但仍屬過寬權限；正式設計應改為預先建表（schema-first），移除這段與下方
  # 的 CREATE_DATABASE LF grant。
  statement {
    sid     = "SpikeOnlyGlueCreateDatabaseForAutoCreate"
    effect  = "Allow"
    actions = ["glue:CreateDatabase"]
    resources = [
      "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:catalog",
      "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:database/${local.iceberg_sink_bronze_database}",
    ]
  }
}

resource "aws_iam_policy" "iceberg_sink_permissions" {
  name   = "slice2-msk-connect-iceberg-sink-permissions"
  policy = data.aws_iam_policy_document.iceberg_sink_permissions.json
}

resource "aws_iam_role_policy_attachment" "iceberg_sink_permissions" {
  role       = aws_iam_role.msk_connect_iceberg_sink.name
  policy_arn = aws_iam_policy.iceberg_sink_permissions.arn
}

# Lake Formation：本帳號的預設權限為空（見 dev/lakeformation.tf 開頭註解），新的
# principal 必須另有 LF grant，IAM policy 不夠。表層用資料庫萬用字元，涵蓋 sink
# 第一次 auto-create 時還不存在的表。這組 grant 隨本 state 管理、隨 destroy 一起移除。
# spike 專用：對應上面的 glue:CreateDatabase（LF 另外檢查 catalog 層級的 CREATE_DATABASE）。
resource "aws_lakeformation_permissions" "iceberg_sink_create_database" {
  principal   = aws_iam_role.msk_connect_iceberg_sink.arn
  permissions = ["CREATE_DATABASE"]

  catalog_resource = true
}

resource "aws_lakeformation_permissions" "iceberg_sink_database" {
  principal   = aws_iam_role.msk_connect_iceberg_sink.arn
  permissions = ["DESCRIBE", "CREATE_TABLE"]

  database {
    name = local.iceberg_sink_bronze_database
  }
}

resource "aws_lakeformation_permissions" "iceberg_sink_tables" {
  principal   = aws_iam_role.msk_connect_iceberg_sink.arn
  permissions = ["DESCRIBE", "SELECT", "INSERT", "ALTER"]

  table {
    database_name = local.iceberg_sink_bronze_database
    wildcard      = true
  }
}

resource "aws_mskconnect_connector" "iceberg_sink" {
  name                 = local.iceberg_sink_connector_name
  kafkaconnect_version = "3.7.x"

  capacity {
    provisioned_capacity {
      mcu_count    = 1
      worker_count = 1
    }
  }

  connector_configuration = {
    "connector.class" = "org.apache.iceberg.connect.IcebergSinkConnector"
    "tasks.max"       = "1"
    "topics"          = "transaction.trade.v1"

    # 寫入目標：spike 專用表名，由 sink 自動建立（auto-create 與「先建表」的取捨是
    # spike 要回答的問題之一，見 docs/TODO.md「建表與寫資料拆分」）。
    "iceberg.tables"                       = "${local.iceberg_sink_bronze_database}.${local.iceberg_sink_bronze_table}"
    "iceberg.tables.auto-create-enabled"   = "true"
    "iceberg.tables.evolve-schema-enabled" = "true"

    "iceberg.catalog.catalog-impl"  = "org.apache.iceberg.aws.glue.GlueCatalog"
    "iceberg.catalog.io-impl"       = "org.apache.iceberg.aws.s3.S3FileIO"
    "iceberg.catalog.warehouse"     = local.iceberg_warehouse_uri
    "iceberg.catalog.client.region" = var.aws_region

    # control topic 的 Kafka client（TLS，cluster 為 unauthenticated）。spike 階段
    # commit 間隔先縮到 60 秒以縮短驗證等待；預設 300 秒，取捨寫進 spike 結果。
    "iceberg.control.topic"              = "control-iceberg-spike"
    "iceberg.control.commit.interval-ms" = "60000"
    "iceberg.kafka.bootstrap.servers"    = aws_msk_cluster.trade.bootstrap_brokers_tls
    "iceberg.kafka.security.protocol"    = "SSL"

    "key.converter" = "org.apache.kafka.connect.storage.StringConverter"

    "value.converter"                               = "com.amazonaws.services.schemaregistry.kafkaconnect.AWSKafkaAvroConverter"
    "value.converter.region"                        = var.aws_region
    "value.converter.registry.name"                 = aws_glue_registry.trade_events.registry_name
    "value.converter.schemaAutoRegistrationEnabled" = "false"
    "value.converter.avroRecordType"                = "GENERIC_RECORD"
  }

  kafka_cluster {
    apache_kafka_cluster {
      bootstrap_servers = aws_msk_cluster.trade.bootstrap_brokers_tls

      vpc {
        security_groups = [aws_security_group.slice2_internal.id]
        subnets         = [for s in aws_subnet.private : s.id]
      }
    }
  }

  kafka_cluster_client_authentication {
    authentication_type = "NONE"
  }

  kafka_cluster_encryption_in_transit {
    encryption_type = "TLS"
  }

  plugin {
    custom_plugin {
      arn      = aws_mskconnect_custom_plugin.iceberg_sink.arn
      revision = aws_mskconnect_custom_plugin.iceberg_sink.latest_revision
    }
  }

  service_execution_role_arn = aws_iam_role.msk_connect_iceberg_sink.arn

  log_delivery {
    worker_log_delivery {
      cloudwatch_logs {
        enabled   = true
        log_group = aws_cloudwatch_log_group.msk_connect_iceberg_sink.name
      }
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.iceberg_sink_permissions,
    aws_lakeformation_permissions.iceberg_sink_create_database,
    aws_lakeformation_permissions.iceberg_sink_database,
    aws_lakeformation_permissions.iceberg_sink_tables,
  ]
}

output "iceberg_sink_connector_arn" {
  description = "Slice 2b spike 的 Iceberg sink connector ARN"
  value       = aws_mskconnect_connector.iceberg_sink.arn
}

output "iceberg_sink_log_group_name" {
  description = "Iceberg sink connector 的 worker log group"
  value       = aws_cloudwatch_log_group.msk_connect_iceberg_sink.name
}
