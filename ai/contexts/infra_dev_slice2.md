# Infra 現況 — dev-slice2 環境（Slice 2 CDC 網路層 + 來源 DB + generator + MSK/Connect）

> 記錄 Slice 2 網路層目前由 Terraform 實際管理、已部署的資源現況。**這是快照，每次 `terraform apply`／`terraform destroy` 後直接覆寫更新，不累加歷史**（歷史異動查 git log 或 changelog.md）。內容一律以 `terraform output` / `terraform state list` 的實際輸出為準，不手動編造。
>
> 依 §3.3(b)「用完即拆」策略，這組資源在 Slice 2a/2b 驗證期間維持運行，驗證全部完成後 destroy（見 §4 項目 10 的 [slice2-stack-lifecycle.md](../../docs/runbooks/slice2-stack-lifecycle.md)）——跟 [infra_dev.md](infra_dev.md)（Slice 0/1，長期持續運行）的生命週期不同，因此獨立成一份快照，不合併進同一份文件。

**最後更新**：2026-11-02
**Terraform 工作目錄**：`infra/environments/dev-slice2/`（依 RULE-002，優先在本機以 `AWS_PROFILE=dt-lab-long-term-mfa` 執行）
**State 位置**：`s3://danny-data-engineering/terraform-state/dev/slice2.tfstate`

## 目前狀態：**運行中**（2026-10-27 為 Slice 2b 開發冷啟動復原；2026-11-02 已移除 Slice 2b spike 資源，`terraform state list` 共 55 項）

2026-10-27 依 [slice2-stack-lifecycle.md](../../docs/runbooks/slice2-stack-lifecycle.md) 三階段 Cold Start 復原 2a 原樣（55 項）；2026-10-30 為 Slice 2b §4 項目 1 的 spike 曾新增 Iceberg sink 相關資源（14 項），已於 2026-11-02 移除，項目數回到 55。spike 期間調整、**保留**的既有設定：`msk.tf` 的 broker 設定新增 `transaction.state.log.replication.factor=2`／`transaction.state.log.min.isr=1`（正式版 sink 在 2-broker 下必要；MSK configuration 目前為 revision 2）、`rds.tf` 儲存 20 → 30GB（含 `apply_immediately`）；另有 2026-10-30 的 WAL 永久修補（見下方「目前狀態重點」）。完整過程、失敗與副作用台帳見 [slice2b-iceberg-sink-spike-verification.md](../../docs/runbooks/slice2b-iceberg-sink-spike-verification.md)。

**目前狀態重點**：
- Debezium connector 在 2026-10-30 被重建一次（舊 task 因 RDS 儲存被 WAL 填滿而失效，見 spike runbook），目前 ARN 為下表所列；重建時重新做了 initial snapshot。
- Slice 2b spike 的 Iceberg sink connector、Glue 串流 job 與兩張 spike 表（`bronze.spike_trade_events`、`silver.spike_trade`）已於 2026-11-02 移除；MSK Connect 目前只剩 Debezium connector（`RUNNING`）。無法移除的殘留（control topic、consumer group、spike 期間寫入 topic 的事件、S3 舊版本）見 spike runbook 的「移除紀錄」。
- RDS 內有 14 筆交易；另有心跳表 `debezium_heartbeat`（1 列，每分鐘更新）。
- **閒置 WAL 防護已就緒**（[ADR-0013](../../docs/architecture/adr/0013-debezium-heartbeat-and-slot-wal-cap.md)）：Debezium connector 已加 heartbeat（每 60 秒，就地更新、未重建），RDS parameter group 已設 `max_slot_wal_keep_size=10240`。2026-11-02 實測：自 2026-10-30 最後一筆交易後閒置約 70 小時，replication slot 保留量仍穩定在 64MB（`wal_status=reserved`）、心跳持續更新。檢查方式：generator 的 `{"diagnose_replication": true}`。

**費用提醒**：這組資源粗估約 $0.28–0.30／小時；放一天約 $7。2b 開發空檔或結束後請依 runbook 的「銷毀流程」`terraform destroy`，並將本檔改回「已銷毀」。

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
| `msk_connector_arn` | `arn:aws:kafkaconnect:ap-northeast-1:393326654921:connector/slice2-debezium-postgres-connector/ec3ce8c2-f31c-4be8-989c-71a012e7090e-2`（2026-10-30 重建後的 ARN） |
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
