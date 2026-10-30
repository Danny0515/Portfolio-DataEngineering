# Infra 現況 — dev-slice2 環境（Slice 2 CDC 網路層 + 來源 DB + generator + MSK/Connect）

> 記錄 Slice 2 網路層目前由 Terraform 實際管理、已部署的資源現況。**這是快照，每次 `terraform apply`／`terraform destroy` 後直接覆寫更新，不累加歷史**（歷史異動查 git log 或 changelog.md）。內容一律以 `terraform output` / `terraform state list` 的實際輸出為準，不手動編造。
>
> 依 §3.3(b)「用完即拆」策略，這組資源在 Slice 2a/2b 驗證期間維持運行，驗證全部完成後 destroy（見 §4 項目 10 的 [slice2-stack-lifecycle.md](../../docs/runbooks/slice2-stack-lifecycle.md)）——跟 [infra_dev.md](infra_dev.md)（Slice 0/1，長期持續運行）的生命週期不同，因此獨立成一份快照，不合併進同一份文件。

**最後更新**：2026-10-27
**Terraform 工作目錄**：`infra/environments/dev-slice2/`（依 RULE-002，優先在本機以 `AWS_PROFILE=dt-lab-long-term-mfa` 執行）
**State 位置**：`s3://danny-data-engineering/terraform-state/dev/slice2.tfstate`

## 目前狀態：**運行中**（2026-10-27 為 Slice 2b 開發冷啟動復原，`terraform state list` 共 55 項）

為了讓 Slice 2b 有 topic 可消費，這次依 [slice2-stack-lifecycle.md](../../docs/runbooks/slice2-stack-lifecycle.md) 的三階段 Cold Start 復原 2a 原樣（`.tf` 自 2026-10-02 之後沒有異動）。階段一 13 項、階段三 31 項全部 `Apply complete`，無 destroy。MSK cluster 建立約 29 分鐘、connector 約 3 分 46 秒；全程無 RDS 容量不足、state lock 或 connector 脫離 state 的狀況。

**煙霧測試結果**：connector `RUNNING`；`slice2-trade-generator`（`num_trades: 5, seed: 1`）回報 `INSERT 5 / UPDATE 9 / DELETE 1`，`slice2-cdc-event-verifier` 從 `transaction.trade.v1` 讀到 16 筆（`c` 5、`u` 9、`d` 1、tombstone 1），與 generator 一致；事件帶 `before`／`after`／`source.lsn`。topic 目前有這 16 筆事件（全在 partition 0，offset 0–15），RDS 內有 5 筆交易（其中 1 筆已刪除）。

**費用提醒**：這組資源粗估約 $0.28–0.30／小時（放一天約 $7），2b 開發空檔或結束後請依 runbook 的「銷毀流程」`terraform destroy`，並將本檔改回「已銷毀」。

## Outputs

| Key | Value |
| --- | --- |
| `vpc_id` | `vpc-07ed09762ce731bb9` |
| `private_subnet_ids` | `subnet-0a3dabd9f46493a6b`、`subnet-08aa09edb9fd311a1` |
| `internal_security_group_id` | `sg-0974747d96bda5484` |
| `s3_vpc_endpoint_id` | `vpce-0b758fd1dfa147a41` |
| `glue_vpc_endpoint_id` | `vpce-094e0f1cccf61bc0c` |
| `logs_vpc_endpoint_id` | `vpce-0f0205d27f3e29640` |
| `trade_db_endpoint` | `slice2-trade.cbluumyfbmux.ap-northeast-1.rds.amazonaws.com` |
| `trade_generator_function_name` | `slice2-trade-generator` |
| `cdc_event_verifier_function_name` | `slice2-cdc-event-verifier` |
| `msk_cluster_arn` | `arn:aws:kafka:ap-northeast-1:393326654921:cluster/slice2-trade-msk/ee5bc677-5e26-4eef-b16c-add091085c76-2` |
| `msk_bootstrap_brokers_tls` | `b-1.slice2trademsk.0i82j6.c2.kafka.ap-northeast-1.amazonaws.com:9094,b-2.slice2trademsk.0i82j6.c2.kafka.ap-northeast-1.amazonaws.com:9094` |
| `msk_connector_name` | `slice2-debezium-postgres-connector` |
| `msk_connector_arn` | `arn:aws:kafkaconnect:ap-northeast-1:393326654921:connector/slice2-debezium-postgres-connector/7862dab1-049b-4bbf-827c-c54b628e8758-2` |
| `msk_connect_execution_role_arn` | `arn:aws:iam::393326654921:role/slice2-msk-connect-debezium` |
| `msk_connect_worker_log_group_name` | `/msk-connect/slice2-debezium-postgres-connector` |
| `msk_connect_plugin_bucket_name` | `danny-data-engineering-slice2-msk-connect` |
| `debezium_combined_plugin_arn` | `arn:aws:kafkaconnect:ap-northeast-1:393326654921:custom-plugin/slice2-debezium-combined-plugin/14b1e218-8617-4e02-a440-4b59a16416ae-2`（revision 1，connector 實際使用） |
| `debezium_postgres_plugin_arn` | `arn:aws:kafkaconnect:ap-northeast-1:393326654921:custom-plugin/slice2-debezium-postgres-plugin/c2f0607b-f916-4264-9647-77b80c22808f-2`（revision 1，項目 6 spike 遺留） |
| `glue_schema_registry_converter_plugin_arn` | `arn:aws:kafkaconnect:ap-northeast-1:393326654921:custom-plugin/slice2-glue-schema-registry-converter-plugin/ab5cb0a3-c5da-43d4-ab24-d0dc60c071d7-2`（revision 1，項目 6 spike 遺留） |
| `glue_schema_registry_name` | `slice2-trade-events` |
| `glue_schema_registry_arn` | `arn:aws:glue:ap-northeast-1:393326654921:registry/slice2-trade-events` |
| `trade_events_schema_arn` | `arn:aws:glue:ap-northeast-1:393326654921:schema/slice2-trade-events/trade_events`（測試替身，不被真實流量使用） |

另外，Debezium converter 自動註冊的真實 schema `transaction.trade.v1`（相容性 `BACKWARD`，已於 2026-10-27 以 `aws glue get-schema` 確認）不在 Terraform state 內，隨 registry 一起銷毀。

## 已管理資源（`terraform state list`，共 55 項，含 data source 與 null_resource）

| 類別 | 資源 |
| --- | --- |
| 網路 | `aws_vpc.slice2`、`aws_subnet.private["a"]`／`["c"]`、`aws_route_table.private`、`aws_route_table_association.private["a"]`／`["c"]`、`aws_security_group.slice2_internal`、`aws_vpc_endpoint.s3`／`glue`／`logs` |
| 來源 DB | `aws_db_instance.trade`、`aws_db_parameter_group.trade`、`aws_db_subnet_group.trade`、`random_password.trade_db` |
| generator Lambda | `aws_lambda_function.trade_generator`、`aws_iam_role.trade_generator`、`aws_iam_role_policy_attachment.trade_generator_vpc_access`、`null_resource.build_trade_generator` |
| MSK | `aws_msk_cluster.trade`、`aws_msk_configuration.trade` |
| Schema Registry | `aws_glue_registry.trade_events`、`aws_glue_schema.trade_events` |
| MSK Connect plugin | `aws_s3_bucket.msk_connect_plugins`、`aws_s3_bucket_public_access_block.msk_connect_plugins`、`aws_s3_object.debezium_combined_plugin`／`debezium_postgres_plugin`／`glue_schema_registry_converter_plugin`、`aws_mskconnect_custom_plugin.debezium_combined`／`debezium_postgres`／`glue_schema_registry_converter`、`null_resource.build_debezium_combined_plugin`／`build_debezium_postgres_plugin`／`build_glue_schema_registry_converter_plugin` |
| MSK Connect connector | `aws_mskconnect_connector.debezium_postgres`、`aws_cloudwatch_log_group.msk_connect_debezium`、`aws_iam_role.msk_connect_debezium`、`aws_iam_policy.msk_connect_permissions`、`aws_iam_role_policy_attachment.msk_connect_permissions` |
| 驗證用 Lambda | `aws_lambda_function.cdc_event_verifier`、`aws_iam_role.cdc_event_verifier`、`aws_iam_policy.cdc_event_verifier_permissions`、`aws_iam_role_policy_attachment.cdc_event_verifier_permissions`／`cdc_event_verifier_vpc_access`、`null_resource.build_cdc_event_verifier` |
| data source | `data.archive_file.*`（5 個）、`data.aws_caller_identity.current`、`data.aws_iam_policy_document.*`（5 個） |

> 重建過程的真實現象與處理方式見 [slice2-stack-lifecycle.md](../../docs/runbooks/slice2-stack-lifecycle.md) 故障排除；上一輪（2026-10-02）遇到的 RDS 容量不足、state lock、connector 脫離 state、Lambda ENI 卡 destroy，這次都沒有發生。
