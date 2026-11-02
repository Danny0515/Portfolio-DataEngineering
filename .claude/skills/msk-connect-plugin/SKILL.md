---
name: msk-connect-plugin
description: 把 connector 本體與 converter／SMT 等元件合併成單一 zip，產生 MSK Connect custom plugin 的 Terraform（build → S3 → aws_mskconnect_custom_plugin），並套用本專案已實測的打包規則。
when_to_use: 要新增或改版 MSK Connect custom plugin、幫 connector 組合多個外部元件，或部署新的 Kafka Connect connector 需要打包 plugin 時。
allowed-tools: Read Grep Glob Write Edit
argument-hint: [connector 名稱 | 元件清單]
---

# MSK Connect Plugin 打包

依元件清單產生「單一合併 plugin」的 Terraform。背景與限制見 Pattern Card：`docs/patterns/msk-connect-single-plugin-per-connector.md`。

## 範圍

- **涵蓋**：下載與合併元件 → 打包 zip → 上傳 S3 → `aws_mskconnect_custom_plugin`
- **不涵蓋**：IAM role、trust policy、log group、connector 設定。參考 `infra/environments/dev-slice2/msk_connector.tf` 與 ADR-0009
- **不執行**：`terraform apply` 與任何 AWS 呼叫。本 skill 只產生檔案

## 流程

1. **收集元件清單**。每個元件需要：名稱、版本、來源 URL、格式、checksum（非 Maven 來源必填）、要移除的 jar。缺的項目向使用者確認，不要猜版本。
2. **判斷元件是否自帶依賴**。不確定時先查發行內容。確定缺依賴時，降級方案見 `docs/runbooks/slice2-msk-connect-plugin-packaging-verification.md` 對應的 Docker + Maven 做法。
3. **產生 Terraform**。以 [references/plugin-template.tf](references/plugin-template.tf) 為基礎，替換佔位符、只保留用到的來源格式，寫入 `infra/environments/<env>/<name>_plugin.tf`，或併入該 connector 的 `.tf`。
4. **呈現給使用者確認**。列出元件版本、zip 內容與預期會變動的資源。部署依 RULE-001／RULE-002 走 Terraform 與 MFA session。
5. **列出部署後的驗證項目**（見下方）。

## 打包規則

| 規則 | 原因 |
| --- | --- |
| 一個 connector 只掛一個 plugin，從頭就合併，不先拆開打包 | `CreateConnector` 的 `plugins` 只接受恰好一個元素 |
| `etag` 用 `archive_file.output_md5`，不對 `local-exec` 產物呼叫 `filemd5()` | `filemd5()` 是純函式，會在檔案產生前求值，`terraform validate` 直接報錯 |
| 每個 plugin 用獨立 build 目錄 | 共用目錄會讓可重現性依賴不相關資源的 apply 順序 |
| `triggers` 納入所有元件版本；只改打包邏輯時遞增 `build_script` | `null_resource` 只在 triggers 改變時重跑 |
| 非 Maven 來源核對 checksum | Confluent Hub 下載沒有其他完整性保護 |
| 重用環境內的 `aws_s3_bucket.msk_connect_plugins`，不跨 state 借用 bucket | `dev`／`dev-slice2` 兩個 state 刻意切開，跨 state 引用會讓 destroy 互相牽制 |

## 已驗證的元件

| 元件 | 來源格式 | 注意 |
| --- | --- | --- |
| Debezium Postgres 3.1.1.Final | Maven `-plugin` tar.gz | 自帶依賴；保留 `debezium-connector-postgres/` 巢狀目錄，不需攤平 |
| Glue Schema Registry converter 1.1.25 | Maven 裸 jar | 自帶依賴的 uber jar，不需 Maven gathering |
| Iceberg Kafka Connect sink 1.9.2 | Confluent Hub 發行 zip | Maven Central 只有核心 jar，沒有含依賴的版本。發行 zip 已含 `iceberg-aws` 與 AWS SDK v2 的 glue／s3／sts／lakeformation，不需另補 aws bundle；sha1 為 `52dab2ff2b9659008deec803d1c1e92813c5ffa7` |

精簡 Iceberg sink 時，移除檔名符合 `azure|google|grpc|gcs|proto-google|opencensus|opentelemetry` 的 jar。實測 Iceberg sink 與 converter 合併後約 186MB，MSK Connect 接受。完整下載 URL 與打包步驟見 commit `09f70e8` 的 `infra/environments/dev-slice2/msk_connector_iceberg_sink.tf`。

新元件組合即使各自能打包成功，仍要驗證合併後在同一個 classloader 下是否相容。

## 部署注意事項

- **替換運行中 connector 的 plugin**：先看 `terraform plan` 是 update 還是 replace。Debezium 被重建會遺失 offset 並重新 snapshot，中斷期間的中間狀態無法補回，執行前必須向使用者說明。
- **2-broker 叢集上的 sink**：control topic 使用交易式 producer，需要 `transaction.state.log.*`，`msk.tf` 已設定。缺少時 task 會卡在 `InitProducerId` 約 60 秒後被殺。
- **task 失敗後**：MSK Connect 不會自動重啟已被殺的 task，修正後要重建 connector。
- **plan 雜訊**：既有 plugin 的 S3 etag 差異是已知現象，不代表內容改變。

## 部署後驗證

1. `terraform validate`
2. `aws kafkaconnect describe-custom-plugin --custom-plugin-arn <arn>` 回報 `customPluginState: ACTIVE`
3. connector 建立後檢查 worker log，確認沒有 `ClassNotFoundException`、`NoClassDefFoundError` 等 classloader 錯誤

## 參考

- `docs/runbooks/slice2-msk-connect-plugin-packaging-verification.md`：Debezium 與 converter 的打包驗證
- `docs/runbooks/slice2b-iceberg-sink-spike-verification.md`：Iceberg sink 打包、失敗與修正
- `infra/environments/dev-slice2/msk_connector.tf`：運行中的合併 plugin 實作
