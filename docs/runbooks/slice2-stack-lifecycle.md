# Runbook: dev-slice2 資源啟停（建立／銷毀）

## 背景 (Why)

依 [docs/specs/slice2a-cdc-ingestion.md](../specs/slice2a-cdc-ingestion.md) §3.3(b)，`infra/environments/dev-slice2/` 這組資源（VPC、RDS、MSK、MSK Connect、兩支 Lambda）是本專案第一批**常駐計費資源**，採「用完即拆」策略：驗證期間 `apply`，驗證完 `destroy`，不像 `dev`（Slice 0/1）環境長期運行。這份 runbook 就是 §4 項目 10 要求的啟停程序——沒有它，下次要 demo 或跑 Slice 2b 時，沒人記得該用什麼順序重建。**這份 runbook 同時服務 Slice 2a／2b，2b 直接沿用，不另外寫一份。**

這是一份可重複執行的操作手冊，不是單次驗證紀錄——跟 `docs/runbooks/` 底下其他 `slice2-*-verification.md` 檔案的定位不同，格式上比照 [aws-access-via-bastion.md](aws-access-via-bastion.md)。

**目前狀態**：§4 項目 12 已依本文件的三階段流程實際執行過一輪完整的 destroy→重建→煙霧測試→destroy 循環（2026-10-02），確認流程本身可行；過程中遇到的真實狀況（非預期錯誤與處理方式）已整理進下方「故障排除」，完整紀錄見 [slice2a-verification.md](slice2a-verification.md)。

---

## 前置條件

依 RULE-002，優先使用本機可重用的 MFA session：

```bash
aws sts get-caller-identity --profile dt-lab-long-term-mfa
```

若過期（`ExpiredToken`），呼叫 `aws-cli-mfa-session` skill 重建，之後所有指令都加 `--profile dt-lab-long-term-mfa`。

---

## 建立流程（Cold Start）

**核心限制，務必先讀**：`msk_connector.tf` 的 Debezium connector 設定 `table.include.list = "public.trade"`，假設來源表已經存在——但這張表**不是 Terraform 建立的**，只有手動呼叫 `slice2-trade-generator` Lambda 傳 `{"init_schema": true}` 才會執行建表 DDL（`src/ingestion/generate_trade_data.py` 的 `run_ddl`）。如果只跑一次涵蓋全部 `.tf` 的 `terraform apply`，connector 極可能在表不存在的情況下啟動失敗。因此建立流程**必須分兩階段**，中間插入手動建表這一步。

### 階段一：網路 + RDS + generator Lambda

```bash
cd infra/environments/dev-slice2
terraform init   # 若 .terraform/ 不存在
terraform plan -target=aws_lambda_function.trade_generator
terraform apply -target=aws_lambda_function.trade_generator
```

`-target` 會自動帶出它依賴的整條鏈（VPC、子網、SG、`logs` VPC Endpoint、RDS、IAM Role），不需要逐一列出。RDS 建立通常需要 5-10 分鐘，等 `apply` 完成再往下走。

### 階段二：建立來源表

```bash
aws lambda invoke --function-name slice2-trade-generator \
  --payload '{"init_schema": true}' \
  --cli-binary-format raw-in-base64-out \
  /tmp/init_schema_output.json
cat /tmp/init_schema_output.json   # 預期 {"init_schema": "done"}
```

### 階段三：其餘資源（MSK／Schema Registry／Plugin／Connector／驗證用 Lambda）

```bash
terraform plan
terraform apply
```

這一階段內部的順序（MSK cluster 先於 connector、plugin 先於 connector 等）Terraform 會依 `.tf` 裡的資源引用自動處理，不需要再拆更細的階段。MSK cluster 建立通常需要 20-30 分鐘，是整個流程裡最久的一段，其餘資源（Schema Registry、Lambda、MSK Connect connector）通常數分鐘內完成。

### 建完之後怎麼確認正常

這份 runbook 不重複驗證細節，直接連過去：

- 連線層／基礎設施是否如預期：[slice2-network-layer-verification.md](slice2-network-layer-verification.md)
- CDC 事件是否正常產生、DLQ 與 Schema 相容性檢查是否正常：[slice2-cdc-event-verification.md](slice2-cdc-event-verification.md)
- 快速健檢 connector 狀態：
  ```bash
  aws kafkaconnect describe-connector \
    --connector-arn "$(terraform output -raw msk_connector_arn)" \
    --query connectorState --output text
  # 預期 RUNNING
  ```

**apply 完成後別忘了**刷新 `ai/contexts/infra_dev_slice2.md`（依 `check-infra-snapshot.sh` hook 的提示，`terraform output`／`state list` 貼進去覆寫既有內容），以及跑 `/explain-infra` 讓 `README.md` 跟改動過的 `.tf` 同步。

---

## 銷毀流程（Teardown）

跟建立不同，銷毀**不需要分階段**——`terraform destroy` 會依資源依賴關係自動反向處理，一次處理全部：

```bash
cd infra/environments/dev-slice2
terraform destroy
```

**整組一起拆，不要挑資源刪**：依 [ADR-0007](../architecture/adr/0007-cdc-vs-batch-polling.md)「⚠️ 注意」段落，Debezium 的 replication slot（`slice2_trade_slot`）若 consumer 長時間離線會持續累積 WAL、佔用來源 DB 儲存空間；這組資源刻意設計成 RDS 隨整個 `terraform destroy` 一起銷毀，slot 隨 instance 一起消失，不會留下孤兒 slot，不需要額外手動清理。

**銷毀後不會自動清掉、但成本可忽略的殘留**：兩支 Lambda（`slice2-trade-generator`、`slice2-cdc-event-verifier`）的 CloudWatch Log Group（`/aws/lambda/<function-name>`）是 AWS 自動建立，不在 Terraform state 裡，`destroy` 不會刪除。低流量下儲存成本可忽略，非必要不用管；真的要清乾淨可手動：

```bash
aws logs delete-log-group --log-group-name /aws/lambda/slice2-trade-generator
aws logs delete-log-group --log-group-name /aws/lambda/slice2-cdc-event-verifier
```

**destroy 後**：`ai/contexts/infra_dev_slice2.md` 快照應更新為「目前無資源」狀態（或註明銷毀日期），避免下次讀到的是過期的已刪除資源清單。

---

## 成本注意事項

這個 repo 目前沒有為這組資源寫過任何實際金額（spec §8 只建議「apply 前估一次月費上限」，一直沒人真的算過）。以下是這次用 WebSearch／WebFetch 查到的**粗估**，來源是第三方雲端計費彙整站與 AWS 官方部落格/文件頁交叉核對，**不是**從 AWS 官方定價頁面即時表格抓到的精確數字（官方頁面是 JS 動態渲染，工具抓不到）：

| 資源 | 粗估單價 | 說明 |
| --- | --- | --- |
| RDS `db.t4g.micro`（single-AZ） | ~$0.02/hr | |
| MSK `kafka.t3.small` × 2 broker | ~$0.10/hr | AWS 官方部落格標題本身寫「$2.50/day 以內」，量級吻合 |
| MSK Connect（1 MCU × 1 worker） | ~$0.11/hr | 官方報價 $0.11 / MCU-hr |
| Interface VPC Endpoint × 2（`glue`／`logs`，各跨 2 AZ） | ~$0.04-0.06/hr | 不含資料處理費用 |
| **合計（粗估）** | **~$0.28-0.30/hr** | |

換算：放著不管一天約 **$7**，一週約 **$47**，一個月約 **$200+**——這是「用完即拆」策略存在的具體理由。**這只是量級參考，不是精確報價**：正式決定月費上限前，建議用 [AWS Pricing Calculator](https://calculator.aws) 針對 `ap-northeast-1` 覆核一次。Lambda／S3／CloudWatch Logs 在這個流量級別成本可忽略，未列入。

---

## 故障排除

| 現象 | 原因 | 處理 |
| --- | --- | --- |
| `terraform destroy` 時 `aws_s3_bucket.msk_connect_plugins` 報 `BucketNotEmpty` | 舊版設定沒開 `force_destroy`，且 bucket 裡有 Terraform 沒追蹤到的物件（例如手動上傳過的測試檔） | 目前 `msk_connect_plugin.tf` 已加上 `force_destroy = true`（見下方相關文件的 commit），正常情況不會再發生；若仍發生，代表用的是舊版 `.tf`，先 `git pull` 確認版本，或手動 `aws s3 rm s3://danny-data-engineering-slice2-msk-connect --recursive` 清空後再 destroy |
| Connector 建立後狀態一直不是 `RUNNING`，或找不到 `public.trade` | 表還沒建立就 apply 了 connector（跳過了「建立流程」階段二的 `init_schema` 呼叫） | 確認表已存在（呼叫 `slice2-trade-generator` 的 `{"query": true}` payload 查詢，或直接連檢查），若沒有則補跑 `init_schema`，再視情況 `terraform apply -replace=aws_mskconnect_connector.debezium_postgres` |
| `terraform apply`（階段三）卡在 MSK cluster 建立很久 | 正常現象，非錯誤 | MSK Provisioned cluster 建立本來就要 20-30 分鐘，是整個流程最久的一段，耐心等待即可 |
| `terraform plan` 對兩個大型 MSK Connect plugin 的 `aws_s3_object` 一直顯示 etag 差異，即使剛 apply 完 | 已知、跟內容變動無關的既存現象：這兩個 zip（~58MB）超過 S3 multipart 上傳門檻，Terraform 用整檔 MD5 跟 S3 的 multipart ETag 格式天生比不出「相等」 | 不影響功能，忽略即可；不要為了讓 plan 乾淨而反覆 apply，不會收斂 |
| `terraform apply` 建立 RDS 時報 `InsufficientDBInstanceCapacity`（`db.t4g.micro` 在這個 VPC 的 AZ 沒有足夠容量） | AWS 端暫時性容量不足，非設定問題——2026-10-02 實測遇過一次 | 直接重跑同一個 `terraform apply` 指令即可，通常很快就能排到容量；不需要改機型或換 AZ |
| 執行中的 `terraform apply`／`destroy` 被中斷（本機工具的長時間執行限制、網路斷線等），後續指令報 `Error acquiring the state lock` | 被中斷的指令沒能正常釋放 state lock | 先用 `ps aux \| grep terraform` 確認真的沒有其他 terraform 行程在跑，再執行 `terraform force-unlock -force <lock-id>`（lock ID 會在錯誤訊息裡）；**此操作有風險，執行前務必先排除真的有併發操作在跑的可能性** |
| 上面那種中斷發生在 `aws_mskconnect_connector` 建立中途——AWS 其實已經真的在建立（可用 `aws kafkaconnect list-connectors` 查到 `CREATING`／`RUNNING`），但本機 `terraform state list` 查不到這個資源 | Terraform CLI 被中斷時，連線器剛送出 `CreateConnector` 請求、還沒等到結果就被取消，AWS 端的建立不會因此停止，但本機 state 沒記到 | 等 AWS 端狀態穩定（`RUNNING` 或 `FAILED`）後，用 `terraform import aws_mskconnect_connector.debezium_postgres <connector-arn>` 把它接回 state，再跑一次 `terraform plan` 確認沒有意外差異（這次實測接回後只剩 `database.password` 敏感度標記這種無害的 in-place update） |
| `terraform destroy` 銷毀子網路／Security Group 時卡很久（正常應該幾秒內完成，卻跑了幾分鐘還沒結束） | 掛 VPC 的 Lambda（`trade_generator`／`cdc_event_verifier`）被刪除後，其 ENI 會先進入 `available`（已卸載、尚未釋放）狀態一段時間才被 AWS 自動回收，期間會卡住所屬子網路／SG 的刪除——2026-10-02 實測卡了將近 10 分鐘 | 用 `aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=<vpc-id>"` 確認是否有 `available` 狀態的殘留 ENI，若有可直接 `aws ec2 delete-network-interface --network-interface-id <eni-id>` 手動刪除加速，不需要死等 AWS 自動回收 |

---

## 相關文件

- [docs/specs/slice2a-cdc-ingestion.md](../specs/slice2a-cdc-ingestion.md) §3.3(b)、§4 項目 10、§7 — 對應的決策與驗收標準
- [ADR-0007](../architecture/adr/0007-cdc-vs-batch-polling.md) — CDC 選型與 replication slot 注意事項（「⚠️ 注意」段落）
- [slice2-network-layer-verification.md](slice2-network-layer-verification.md) — 網路層驗證
- [slice2-cdc-event-verification.md](slice2-cdc-event-verification.md) — CDC 事件／Schema 相容性／DLQ 驗證
- [ai/contexts/infra_dev_slice2.md](../../ai/contexts/infra_dev_slice2.md) — 目前實際部署狀態快照
- `infra/environments/dev-slice2/msk_connect_plugin.tf` — `force_destroy` 設定
- [slice2a-verification.md](slice2a-verification.md) — §4 項目 12 實際執行過的完整 destroy→重建→destroy 循環紀錄
