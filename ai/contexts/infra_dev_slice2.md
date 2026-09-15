# Infra 現況 — dev-slice2 環境（Slice 2 CDC 網路層 + 來源 DB + generator + MSK/Connect）

> 記錄 Slice 2 網路層目前由 Terraform 實際管理、已部署的資源現況。**這是快照，每次 `terraform apply` 後直接覆寫更新，不累加歷史**（歷史異動查 git log 或 changelog.md）。內容一律以 `terraform output` / `terraform state list` 的實際輸出為準，不手動編造。
>
> 依 §3.3(b)「用完即拆」策略，這組資源在 Slice 2a/2b 驗證期間維持運行，驗證全部完成後才會 destroy（見 §4 項目 10 的啟停 runbook，屆時待補）——跟 [infra_dev.md](infra_dev.md)（Slice 0/1，長期持續運行）的生命週期不同，因此獨立成一份快照，不合併進同一份文件。

**最後更新**：2026-09-15
**Terraform 工作目錄**：`infra/environments/dev-slice2/`（依 RULE-002，優先在本機以 `AWS_PROFILE=dt-lab-long-term-mfa` 執行）
**State 位置**：`s3://danny-data-engineering/terraform-state/dev/slice2.tfstate`

## Outputs（`terraform output`）

| Key | Value |
| --- | --- |
| vpc_id | `vpc-0c80ecb9a8100e273` |
| private_subnet_ids | `["subnet-0d2acd2f0ed4abab5", "subnet-05eedd9316196b8d2"]` |
| s3_vpc_endpoint_id | `vpce-07cf547a7ec877ca0` |
| glue_vpc_endpoint_id | `vpce-0589038dd7d04bba2` |
| logs_vpc_endpoint_id | `vpce-0dd3f46341cdabbd7` |
| internal_security_group_id | `sg-0a917aece7c5c922d` |
| trade_db_endpoint | `slice2-trade.cbluumyfbmux.ap-northeast-1.rds.amazonaws.com` |
| trade_generator_function_name | `slice2-trade-generator` |
| msk_cluster_arn | `arn:aws:kafka:ap-northeast-1:393326654921:cluster/slice2-trade-msk/08e31904-7f2c-4b7a-8295-9c9eb1dd881d-2` |
| msk_bootstrap_brokers_tls | `b-1.slice2trademsk.lprhxt.c2.kafka.ap-northeast-1.amazonaws.com:9094,b-2.slice2trademsk.lprhxt.c2.kafka.ap-northeast-1.amazonaws.com:9094` |
| glue_schema_registry_name | `slice2-trade-events` |
| glue_schema_registry_arn | `arn:aws:glue:ap-northeast-1:393326654921:registry/slice2-trade-events` |
| trade_events_schema_arn | `arn:aws:glue:ap-northeast-1:393326654921:schema/slice2-trade-events/trade_events` |
| msk_connect_plugin_bucket_name | `danny-data-engineering-slice2-msk-connect` |
| debezium_postgres_plugin_arn | `arn:aws:kafkaconnect:ap-northeast-1:393326654921:custom-plugin/slice2-debezium-postgres-plugin/8c305182-79b1-41c0-9255-899f56f3c8a0-2` |
| debezium_postgres_plugin_latest_revision | `1` |
| glue_schema_registry_converter_plugin_arn | `arn:aws:kafkaconnect:ap-northeast-1:393326654921:custom-plugin/slice2-glue-schema-registry-converter-plugin/1b27c571-395d-48f7-b73b-f94c125a5a21-2` |
| glue_schema_registry_converter_plugin_latest_revision | `1` |
| msk_connector_arn | `arn:aws:kafkaconnect:ap-northeast-1:393326654921:connector/slice2-debezium-postgres-connector/8c65002a-419d-49b7-9eb1-c5c40881519e-2` |
| msk_connector_name | `slice2-debezium-postgres-connector` |
| msk_connect_worker_log_group_name | `/msk-connect/slice2-debezium-postgres-connector` |
| debezium_combined_plugin_arn | `arn:aws:kafkaconnect:ap-northeast-1:393326654921:custom-plugin/slice2-debezium-combined-plugin/8082bee5-aab5-4592-b29b-9652a33181dd-2` |
| debezium_combined_plugin_latest_revision | `1` |
| msk_connect_execution_role_arn | `arn:aws:iam::393326654921:role/slice2-msk-connect-debezium` |
| cdc_event_verifier_function_name | `slice2-cdc-event-verifier` |

## 已管理資源（`terraform state list`）

- `aws_vpc.slice2`
- `aws_subnet.private["a"]`
- `aws_subnet.private["c"]`
- `aws_route_table.private`
- `aws_route_table_association.private["a"]`
- `aws_route_table_association.private["c"]`
- `aws_security_group.slice2_internal`
- `aws_vpc_endpoint.s3`
- `aws_vpc_endpoint.glue`
- `aws_vpc_endpoint.logs`
- `random_password.trade_db`
- `aws_db_subnet_group.trade`
- `aws_db_parameter_group.trade`
- `aws_db_instance.trade`
- `aws_iam_role.trade_generator`
- `aws_iam_role_policy_attachment.trade_generator_vpc_access`
- `null_resource.build_trade_generator`
- `aws_lambda_function.trade_generator`
- `data.archive_file.trade_generator`
- `data.aws_iam_policy_document.trade_generator_assume`
- `aws_msk_configuration.trade`
- `aws_msk_cluster.trade`
- `aws_glue_registry.trade_events`
- `aws_glue_schema.trade_events`
- `aws_s3_bucket.msk_connect_plugins`
- `aws_s3_bucket_public_access_block.msk_connect_plugins`
- `null_resource.build_debezium_postgres_plugin`
- `data.archive_file.debezium_postgres_plugin`
- `aws_s3_object.debezium_postgres_plugin`
- `aws_mskconnect_custom_plugin.debezium_postgres`
- `null_resource.build_glue_schema_registry_converter_plugin`
- `data.archive_file.glue_schema_registry_converter_plugin`
- `aws_s3_object.glue_schema_registry_converter_plugin`
- `aws_mskconnect_custom_plugin.glue_schema_registry_converter`
- `data.aws_caller_identity.current`
- `null_resource.build_debezium_combined_plugin`
- `data.archive_file.debezium_combined_plugin`
- `aws_s3_object.debezium_combined_plugin`
- `aws_mskconnect_custom_plugin.debezium_combined`
- `data.aws_iam_policy_document.msk_connect_trust`
- `aws_iam_role.msk_connect_debezium`
- `aws_cloudwatch_log_group.msk_connect_debezium`
- `data.aws_iam_policy_document.msk_connect_permissions`
- `aws_iam_policy.msk_connect_permissions`
- `aws_iam_role_policy_attachment.msk_connect_permissions`
- `aws_mskconnect_connector.debezium_postgres`
- `data.aws_iam_policy_document.cdc_event_verifier_assume`
- `aws_iam_role.cdc_event_verifier`
- `data.aws_iam_policy_document.cdc_event_verifier_permissions`
- `aws_iam_policy.cdc_event_verifier_permissions`
- `aws_iam_role_policy_attachment.cdc_event_verifier_vpc_access`
- `aws_iam_role_policy_attachment.cdc_event_verifier_permissions`
- `null_resource.build_cdc_event_verifier`
- `data.archive_file.cdc_event_verifier`
- `aws_lambda_function.cdc_event_verifier`

> 對應 [docs/specs/slice2a-cdc-ingestion.md](../../docs/specs/slice2a-cdc-ingestion.md) §4 項目 1～8。子網 AZ 為 `ap-northeast-1a`／`ap-northeast-1c`（此帳號無 `ap-northeast-1b`，實測得知）。Security Group `slice2-internal` 現有三條 self-referencing 規則（443 給 Interface VPC Endpoint、5432 給 RDS、9094 給 MSK broker TLS）。RDS 主密碼由 `random_password.trade_db` 產生，直接寫進 Lambda 環境變數，未透過 Secrets Manager（見 `lambda.tf` 註解說明原因）。MSK cluster `slice2-trade-msk`（Provisioned，2× `kafka.t3.small`，kafka 3.9.x，TLS-only、unauthenticated）為 `ACTIVE`；Glue Schema Registry `slice2-trade-events` 下有兩個 schema：`trade_events`（項目 5/6 手動註冊，供項目 9 相容性測試用，未被真正流量使用）與 `transaction.trade.v1`（項目 7 connector 首次寫入時自動註冊，是真正的 CDC envelope schema）。
>
> **§4 項目 7**：`aws_mskconnect_connector.debezium_postgres` 為 `RUNNING`——合併打包 Debezium 3.1.1.Final + Glue Schema Registry converter 1.1.25 成單一 custom plugin（`aws_mskconnect_custom_plugin.debezium_combined`；項目 6 的兩個獨立 plugin 因 MSK Connect「一個 connector 只能掛一個 plugin」的限制未被使用，保留為歷史 spike 證據），IAM trust policy 用 `SourceAccount` + `SourceArn`（萬用比對 connector 名稱）妥協方案（見 [ADR-0009](../../docs/architecture/adr/0009-msk-connect-trust-policy-sourcearn-tradeoff.md)）。
>
> **§4 項目 8**：新增 `aws_lambda_function.cdc_event_verifier`（`kafka-python-ng` + `aws-glue-schema-registry` 消費並解碼 `transaction.trade.v1`），已實測驗證 insert/update/delete 三種操作皆產生正確的 CDC 事件（含 before/after、遞增 LSN），並在同一批訊息裡找到 6 筆完整 `NEW→PARTIALLY_FILLED→FILLED` 生命週期與 2 筆 `NEW→CANCELLED→DELETE` 路徑，細節見 [slice2-cdc-event-verification.md](../runbooks/slice2-cdc-event-verification.md)。實作過程中發現 `aws-glue-schema-registry` 間接依賴的 `orjson` 是編譯過的 Rust extension，本機 macOS 打包需要加 `--platform manylinux2014_x86_64 --only-binary=:all:` 才能抓到 Lambda（Amazon Linux）相容的版本。
