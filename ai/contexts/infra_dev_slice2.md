# Infra 現況 — dev-slice2 環境（Slice 2 CDC 網路層 + 來源 DB + generator）

> 記錄 Slice 2 網路層目前由 Terraform 實際管理、已部署的資源現況。**這是快照，每次 `terraform apply` 後直接覆寫更新，不累加歷史**（歷史異動查 git log 或 changelog.md）。內容一律以 `terraform output` / `terraform state list` 的實際輸出為準，不手動編造。
>
> 依 §3.3(b)「用完即拆」策略，這組資源在 Slice 2a/2b 驗證期間維持運行，驗證全部完成後才會 destroy（見 §4 項目 10 的啟停 runbook，屆時待補）——跟 [infra_dev.md](infra_dev.md)（Slice 0/1，長期持續運行）的生命週期不同，因此獨立成一份快照，不合併進同一份文件。

**最後更新**：2026-09-03
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

> 對應 [docs/specs/slice2a-cdc-ingestion.md](../../docs/specs/slice2a-cdc-ingestion.md) §4 項目 1～4。子網 AZ 為 `ap-northeast-1a`／`ap-northeast-1c`（此帳號無 `ap-northeast-1b`，實測得知）。Security Group `slice2-internal` 現有兩條 self-referencing 規則（443 給 Interface VPC Endpoint、5432 給 RDS）；MSK 的埠號將在 §4 項目 5 建立對應資源時補上。RDS 主密碼由 `random_password.trade_db` 產生，直接寫進 Lambda 環境變數，未透過 Secrets Manager（見 `lambda.tf` 註解說明原因）。Lambda `slice2-trade-generator` 已實測跑過 `init_schema` 與 20 筆交易生成，皆成功（`operations: INSERT 20 / UPDATE 33 / DELETE 4`，CloudWatch Logs 經 `logs_vpc_endpoint_id` 正常送達）。
