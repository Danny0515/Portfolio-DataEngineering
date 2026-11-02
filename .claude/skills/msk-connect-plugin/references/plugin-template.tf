# MSK Connect 合併 custom plugin 範本。用法見 ../SKILL.md。
#
# 佔位符：
#   <name>  snake_case，用於 Terraform 資源名稱與 build 目錄（例：iceberg_sink）
#   <slug>  kebab-case，用於 AWS 資源名稱與 S3 key（例：iceberg-sink）
#   <...>   其餘角括號內容依元件清單填入
#
# 同一個 connector 的所有元件都放進同一個 build 目錄、輸出一個 zip：
# MSK Connect 一個 connector 只能引用一個 custom plugin
# （docs/patterns/msk-connect-single-plugin-per-connector.md）。
#
# 下方 command 的 [A]／[B]／[C] 是三種來源格式，只保留實際用到的段落，並刪除標記註解。
# 本範本假設目標環境已有 aws_s3_bucket.msk_connect_plugins 與
# local.glue_schema_registry_converter_version（dev-slice2 的 msk_connect_plugin.tf）。

locals {
  <name>_version   = "<component_version>"
  <name>_sha1      = "<component_sha1>"
  <name>_build_dir = "${path.module}/build/<name>_plugin"
}

# 每個 plugin 使用自己的 build 目錄，不依賴其他資源的目錄：那些目錄的生命週期跟著
# 各自資源走，共用會讓這個 plugin 的可重現性依賴不相關資源的 apply 順序。
resource "null_resource" "build_<name>_plugin" {
  # 任一元件版本改變都要重新 build；只改打包邏輯時遞增 build_script，否則不會重跑。
  triggers = {
    component_version = local.<name>_version
    converter_version = local.glue_schema_registry_converter_version
    build_script      = "v1"
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      rm -rf ${local.<name>_build_dir}
      mkdir -p ${local.<name>_build_dir}/_dl ${local.<name>_build_dir}/<component_dir>

      # [A] Maven 的 -plugin tar.gz（例：Debezium）：自帶依賴，保留解壓後的巢狀目錄
      curl -sSL --fail -o ${local.<name>_build_dir}/_dl/component.tar.gz "<component_url>"
      tar -xzf ${local.<name>_build_dir}/_dl/component.tar.gz -C ${local.<name>_build_dir}

      # [B] Confluent Hub 發行 zip（例：Iceberg sink）：核對 checksum，取 lib/*.jar 並移除用不到的 jar。
      # pattern 必須至少命中一個檔案，否則 grep 失敗會讓 pipefail 中止 build。
      curl -sSL --fail -o ${local.<name>_build_dir}/_dl/component.zip "<component_url>"
      echo "${local.<name>_sha1}  ${local.<name>_build_dir}/_dl/component.zip" | shasum -c -
      unzip -q ${local.<name>_build_dir}/_dl/component.zip -d ${local.<name>_build_dir}/_dl -x "__MACOSX/*"
      cp ${local.<name>_build_dir}/_dl/<component_archive_dir>/lib/*.jar ${local.<name>_build_dir}/<component_dir>/
      (cd ${local.<name>_build_dir}/<component_dir> && ls | grep -iE "<prune_pattern>" | xargs rm -f)

      # [C] 裸 jar（例：Glue Schema Registry converter，自帶依賴的 uber jar）
      curl -sSL --fail -o ${local.<name>_build_dir}/schema-registry-kafkaconnect-converter-${local.glue_schema_registry_converter_version}.jar \
        "https://repo1.maven.org/maven2/software/amazon/glue/schema-registry-kafkaconnect-converter/${local.glue_schema_registry_converter_version}/schema-registry-kafkaconnect-converter-${local.glue_schema_registry_converter_version}.jar"

      rm -rf ${local.<name>_build_dir}/_dl
    EOT
  }
}

data "archive_file" "<name>_plugin" {
  type        = "zip"
  source_dir  = local.<name>_build_dir
  output_path = "${path.module}/build/<name>_plugin.zip"
  depends_on  = [null_resource.build_<name>_plugin]
}

# etag 用 archive_file 的輸出：filemd5() 是純函式，會在 local-exec 產生檔案前就求值。
resource "aws_s3_object" "<name>_plugin" {
  bucket = aws_s3_bucket.msk_connect_plugins.id
  key    = "msk-connect-plugins/<slug>-plugin.zip"
  source = data.archive_file.<name>_plugin.output_path
  etag   = data.archive_file.<name>_plugin.output_md5
}

resource "aws_mskconnect_custom_plugin" "<name>" {
  name         = "slice2-<slug>-plugin"
  content_type = "ZIP"

  location {
    s3 {
      bucket_arn = aws_s3_bucket.msk_connect_plugins.arn
      file_key   = aws_s3_object.<name>_plugin.key
    }
  }
}

# connector 引用時固定用這一個 plugin：
#
#   plugin {
#     custom_plugin {
#       arn      = aws_mskconnect_custom_plugin.<name>.arn
#       revision = aws_mskconnect_custom_plugin.<name>.latest_revision
#     }
#   }
