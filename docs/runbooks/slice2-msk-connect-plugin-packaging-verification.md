# Runbook: Debezium plugin 打包驗證（MSK Connect custom plugin spike）

## 背景 (Why)

對應 [docs/specs/slice2a-cdc-ingestion.md](../specs/slice2a-cdc-ingestion.md) §3.2、§4 項目 6、§8「MSK Connect × Debezium 打包」風險項。§3.2 選定 Debezium + MSK Connect 路線時，列了三個尚未驗證的未知數：plugin 打包、VPC 連線、IAM 授權。這份 spike 只處理第一個。

## 範圍限制

只驗證「plugin zip 打包 → S3 → `aws_mskconnect_custom_plugin` 能否建到 `ACTIVE`」，**不建立 `aws_mskconnect_connector`**——那是 §4 項目 7 明確的職責（「connector 設定...與 IAM/VPC 授權」）。建立 custom plugin 純粹是 S3 + MSK Connect control plane 操作，完全不碰 VPC、也不需要新的 IAM Role，所以「VPC 連線」「IAM 授權」這兩個未知數本來就無法在這裡驗證，要等項目 7 真的建出一個 connector 才會被實際踩到。

另外一個範圍決定：Debezium connector 與 AWS Glue Schema Registry Kafka Connect converter 拆成**兩個獨立的 custom plugin**，不合併成一個 zip——MSK Connect 的 `CreateConnector` API 本來就接受 plugin 清單，拆開能讓其中一個失敗時立刻孤立問題範圍，不必在合併後的單一 zip 裡大海撈針。

## 前置條件

- 本機已有可重用的 AWS MFA session（`dt-lab-long-term-mfa`）
- 本機 `curl`/`tar`/`unzip` 已足夠；**主線路徑不需要 Maven 或 Docker**（本機確認沒裝 `mvn`，有 Docker 27.4.0 作為降級方案的備用工具，但這次沒用到）
- `infra/environments/dev-slice2/` 既有的 VPC/RDS/MSK/Schema Registry 資源已就緒（§4 項目 1-5）

## 部署

新增 `infra/environments/dev-slice2/msk_connect_plugin.tf`，核心資源：

```hcl
resource "aws_s3_bucket" "msk_connect_plugins" {
  bucket = "danny-data-engineering-slice2-msk-connect"
}

resource "null_resource" "build_debezium_postgres_plugin" {
  provisioner "local-exec" {
    command = <<-EOT
      curl -sSL --fail -o .../debezium-plugin.tar.gz \
        "https://repo1.maven.org/maven2/io/debezium/debezium-connector-postgres/3.1.1.Final/debezium-connector-postgres-3.1.1.Final-plugin.tar.gz"
      tar -xzf .../debezium-plugin.tar.gz -C ...
    EOT
  }
}

data "archive_file" "debezium_postgres_plugin" {
  type        = "zip"
  source_dir  = local.debezium_plugin_build_dir
  output_path = "${path.module}/build/debezium_postgres_plugin.zip"
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
```

`software.amazon.glue:schema-registry-kafkaconnect-converter:1.1.25` 這顆 jar 用同一套 `null_resource` + `data.archive_file` 模式打包（converter 本身是裸 jar，包成 zip 上傳，`content_type = "ZIP"`）。完整內容見 `infra/environments/dev-slice2/msk_connect_plugin.tf`。

**一個實作過程中修正的坑**：converter jar 原本用 `filemd5()` 直接對 `local-exec` 產生的檔案求值當 `aws_s3_object.etag`，`terraform validate` 直接報錯——`filemd5()` 是純函式，會在檔案還沒被 `local-exec` 建立前就求值，不會乖乖等 `depends_on`（跟 `data.archive_file` 這種正規 data source不同）。改成跟 Debezium 那邊一樣，用 `data.archive_file` 包一層才解決。

```bash
cd infra/environments/dev-slice2
AWS_PROFILE=dt-lab-long-term-mfa terraform init
AWS_PROFILE=dt-lab-long-term-mfa terraform plan
AWS_PROFILE=dt-lab-long-term-mfa terraform apply
```

## 驗證步驟與參考結果（2026-09-08 執行）

### `terraform apply`

```
Plan: 8 to add, 0 to change, 0 to destroy.
...
aws_mskconnect_custom_plugin.debezium_postgres: Creation complete after 4s
  [id=arn:aws:kafkaconnect:ap-northeast-1:393326654921:custom-plugin/slice2-debezium-postgres-plugin/8c305182-79b1-41c0-9255-899f56f3c8a0-2]
aws_mskconnect_custom_plugin.glue_schema_registry_converter: Creation complete after 8s
  [id=arn:aws:kafkaconnect:ap-northeast-1:393326654921:custom-plugin/slice2-glue-schema-registry-converter-plugin/1b27c571-395d-48f7-b73b-f94c125a5a21-2]

Apply complete! Resources: 8 added, 0 changed, 0 destroyed.
```

8 個資源全數建立成功，過程中沒有出現任何 `AccessDenied` 之類的 SCP 拒絕訊息——**Control Tower 沒有限制 `kafkaconnect:CreateCustomPlugin` 或新建 S3 bucket**，這是本次 spike 要回答的核心未知數。

### 交叉驗證（`aws kafkaconnect describe-custom-plugin` ×2）

```bash
AWS_PROFILE=dt-lab-long-term-mfa aws kafkaconnect describe-custom-plugin \
  --custom-plugin-arn <debezium arn>
```
```json
{
    "customPluginState": "ACTIVE",
    "latestRevision": {
        "contentType": "ZIP",
        "fileDescription": {"fileMd5": "52a3ed4c0dd97a19e0e1c3e591481e00", "fileSize": 4606471},
        "revision": 1
    },
    "name": "slice2-debezium-postgres-plugin"
}
```

```bash
AWS_PROFILE=dt-lab-long-term-mfa aws kafkaconnect describe-custom-plugin \
  --custom-plugin-arn <converter arn>
```
```json
{
    "customPluginState": "ACTIVE",
    "latestRevision": {
        "contentType": "ZIP",
        "fileDescription": {"fileMd5": "bcc2db4240c9d3b0ae45996b365eea0b", "fileSize": 61207195},
        "revision": 1
    },
    "name": "slice2-glue-schema-registry-converter-plugin"
}
```

**兩個 plugin 第一次嘗試就都是 `ACTIVE`**，沒有進入 `CREATE_FAILED`：

- Debezium 的 tar.gz 維持原生巢狀 `debezium-connector-postgres/*.jar` 結構、沒有攤平，MSK Connect 直接接受——不需要攤平重試。
- Glue Schema Registry converter「67MB 檔案大小 + POM 綁定 `maven-shade-plugin`」推論它是自帶完整依賴的 uber jar，這個推論成立——不需要走 Docker/Maven 湊 transitive dependency 的降級方案。

## 生命週期

這兩個 plugin 跟承載它們的 S3 bucket **保留、不銷毀**：§4 項目 7 要直接用 `debezium_postgres_plugin_arn`／`glue_schema_registry_converter_plugin_arn`（連同各自的 `latest_revision`）建立 connector，跟項目 1 那種「驗完即拆」的網路層 spike 性質不同。§3.3(b) 的「用完即拆」仍然適用，但要等整個 Slice 2 stack（含項目 7-9 的 CDC 事件驗證）全部收尾後，才會在項目 10 的啟停 runbook 階段整組銷毀。

## 結論

已解決：plugin 打包機制本身可行（Debezium 官方 `-plugin` tar.gz 與 Glue Schema Registry converter jar 都能直接包成 zip 用），Control Tower SCP 沒有限制 `kafkaconnect:CreateCustomPlugin` 這個 API 命名空間。

留給項目 7：VPC 連線（MSK Connect worker 能否連到 MSK broker/RDS）、IAM 授權（connector 執行角色的最小權限設計，呼應 RULE-003）、兩個獨立打包的 plugin 掛到同一個 connector 上是否真的相容（classloader 層級沒有版本衝突）——這些都要等項目 7 真的建出 `aws_mskconnect_connector` 才會被驗證到。

## 相關文件

- [docs/specs/slice2a-cdc-ingestion.md](../specs/slice2a-cdc-ingestion.md) §3.2 / §4 項目 6 / §8 — 這份 runbook 對應的實作項目與風險項
- `infra/environments/dev-slice2/msk_connect_plugin.tf` — 本次驗證使用的 Terraform 資源定義
- [slice2-network-layer-verification.md](slice2-network-layer-verification.md) — 同一份 spec 前一個 spike（§4 項目 1），本文件的結構模板
