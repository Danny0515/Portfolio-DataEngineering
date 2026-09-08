# Slice 2 §4 項目 6：Debezium plugin 打包 spike。見
# docs/specs/slice2a-cdc-ingestion.md §3.2、§4 項目 6、§8。
#
# 範圍：只驗證「plugin zip 打包 → S3 → aws_mskconnect_custom_plugin 能否建到 ACTIVE」，
# 不建立 aws_mskconnect_connector（那是項目 7 的職責，VPC 連線／IAM 授權這兩個未知數
#要等項目 7 真的建出 connector 才會被踩到，這裡建 custom plugin 完全不碰 VPC/IAM）。
#
# 拆成兩個獨立 custom plugin（Debezium connector 本體 + Glue Schema Registry
# converter），不合併成一個 zip：CreateConnector API 本來就接受 plugin 清單；分開打包
# 讓其中一個 CREATE_FAILED 時能立刻孤立問題範圍，不必在合併後的單一 zip 裡大海撈針。

locals {
  debezium_connector_postgres_version      = "3.1.1.Final"
  glue_schema_registry_converter_version   = "1.1.25"
  debezium_plugin_build_dir                = "${path.module}/build/debezium_postgres_plugin"
  glue_schema_registry_converter_build_dir = "${path.module}/build/glue_schema_registry_converter_plugin"
}

# dev-slice2 目前沒有自己的 S3 bucket；不跨 state 借用 dev/ 既有的
# danny-data-engineering——這個專案刻意把 dev／dev-slice2 兩個 state 切乾淨
# （§3.3(b)/§8 state 切分風險），跨 state 引用會讓一邊的 destroy 要顧慮另一邊。
resource "aws_s3_bucket" "msk_connect_plugins" {
  bucket = "danny-data-engineering-slice2-msk-connect"
}

resource "aws_s3_bucket_public_access_block" "msk_connect_plugins" {
  bucket = aws_s3_bucket.msk_connect_plugins.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Debezium 的 -plugin classifier tar.gz 是自帶完整依賴的自包含 bundle（已用 curl 實測
# 驗證：解壓後是 debezium-connector-postgres/ 目錄，5 個 jar，不需要另外湊依賴）
resource "null_resource" "build_debezium_postgres_plugin" {
  triggers = {
    debezium_version = local.debezium_connector_postgres_version
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      rm -rf ${local.debezium_plugin_build_dir}
      mkdir -p ${local.debezium_plugin_build_dir}
      curl -sSL --fail -o ${local.debezium_plugin_build_dir}/debezium-plugin.tar.gz \
        "https://repo1.maven.org/maven2/io/debezium/debezium-connector-postgres/${local.debezium_connector_postgres_version}/debezium-connector-postgres-${local.debezium_connector_postgres_version}-plugin.tar.gz"
      tar -xzf ${local.debezium_plugin_build_dir}/debezium-plugin.tar.gz -C ${local.debezium_plugin_build_dir}
      rm ${local.debezium_plugin_build_dir}/debezium-plugin.tar.gz
    EOT
  }
}

data "archive_file" "debezium_postgres_plugin" {
  type        = "zip"
  source_dir  = local.debezium_plugin_build_dir
  output_path = "${path.module}/build/debezium_postgres_plugin.zip"
  depends_on  = [null_resource.build_debezium_postgres_plugin]
}

resource "aws_s3_object" "debezium_postgres_plugin" {
  bucket = aws_s3_bucket.msk_connect_plugins.id
  key    = "msk-connect-plugins/debezium-postgres-plugin.zip"
  source = data.archive_file.debezium_postgres_plugin.output_path
  etag   = data.archive_file.debezium_postgres_plugin.output_md5
}

resource "aws_mskconnect_custom_plugin" "debezium_postgres" {
  name         = "slice2-debezium-postgres-plugin"
  content_type = "ZIP"

  location {
    s3 {
      bucket_arn = aws_s3_bucket.msk_connect_plugins.arn
      file_key   = aws_s3_object.debezium_postgres_plugin.key
    }
  }
}

# software.amazon.glue:schema-registry-kafkaconnect-converter 已用 curl --head 實測
# 驗證檔案大小 67MB，加上其 pom 綁定 maven-shade-plugin——強烈推論是自帶依賴的 uber
# jar，先不跑 Maven gathering。若這個假設錯誤（CREATE_FAILED 且訊息像缺 class），降級
# 方案是用 Docker 跑一次性的 `mvn dependency:copy-dependencies`（本機沒裝 mvn，不為了
# 一次性 spike 污染開發環境），詳見對應 runbook。
resource "null_resource" "build_glue_schema_registry_converter_plugin" {
  triggers = {
    converter_version = local.glue_schema_registry_converter_version
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      rm -rf ${local.glue_schema_registry_converter_build_dir}
      mkdir -p ${local.glue_schema_registry_converter_build_dir}
      curl -sSL --fail -o ${local.glue_schema_registry_converter_build_dir}/schema-registry-kafkaconnect-converter-${local.glue_schema_registry_converter_version}.jar \
        "https://repo1.maven.org/maven2/software/amazon/glue/schema-registry-kafkaconnect-converter/${local.glue_schema_registry_converter_version}/schema-registry-kafkaconnect-converter-${local.glue_schema_registry_converter_version}.jar"
    EOT
  }
}

# filemd5() 對一個要靠 local-exec 才會存在的檔案求值會直接出錯（純函式呼叫不會乖乖等
# depends_on，跟 data.archive_file 這種正規 data source 不同）——改用 archive_file 把
# 這顆 jar 包成 zip 上傳，跟 Debezium 那邊同一套模式，AWS 本來就支援「zip 內含 jar」。
data "archive_file" "glue_schema_registry_converter_plugin" {
  type        = "zip"
  source_file = "${local.glue_schema_registry_converter_build_dir}/schema-registry-kafkaconnect-converter-${local.glue_schema_registry_converter_version}.jar"
  output_path = "${path.module}/build/glue_schema_registry_converter_plugin.zip"
  depends_on  = [null_resource.build_glue_schema_registry_converter_plugin]
}

resource "aws_s3_object" "glue_schema_registry_converter_plugin" {
  bucket = aws_s3_bucket.msk_connect_plugins.id
  key    = "msk-connect-plugins/schema-registry-kafkaconnect-converter-${local.glue_schema_registry_converter_version}.zip"
  source = data.archive_file.glue_schema_registry_converter_plugin.output_path
  etag   = data.archive_file.glue_schema_registry_converter_plugin.output_md5
}

resource "aws_mskconnect_custom_plugin" "glue_schema_registry_converter" {
  name         = "slice2-glue-schema-registry-converter-plugin"
  content_type = "ZIP"

  location {
    s3 {
      bucket_arn = aws_s3_bucket.msk_connect_plugins.arn
      file_key   = aws_s3_object.glue_schema_registry_converter_plugin.key
    }
  }
}
