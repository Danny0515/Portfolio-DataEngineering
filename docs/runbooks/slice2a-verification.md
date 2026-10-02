# Runbook: Slice 2a 端到端驗證（CDC 交易事件擷取）

依 [execution-roadmap.md](../../execution-roadmap.md) §3 完成 Gate 的慣例，這是 Slice 2a 的**定案驗證文件**，彙總各衛星 runbook 的證據並對應回 spec §7 驗收標準——比照 [slice1-verification.md](slice1-verification.md) 的模式。

## 背景 (Why)

Slice 2a 已有四份衛星 runbook，各自證明了管線的一段：

- [slice2-network-layer-verification.md](slice2-network-layer-verification.md) — §4 項目 1：Control Tower SCP 不限制這組網路資源的建立與銷毀
- [slice2-msk-connect-plugin-packaging-verification.md](slice2-msk-connect-plugin-packaging-verification.md) — §4 項目 6：Debezium plugin／Glue Schema Registry converter 能打包成 custom plugin 並建到 `ACTIVE`
- [slice2-cdc-event-verification.md](slice2-cdc-event-verification.md) — §4 項目 8/9：insert/update/delete 三種操作正確產生 CDC 事件、完整交易生命週期、Schema 破壞性變更被 Registry 擋下、DLQ 機制
- [slice2-stack-lifecycle.md](slice2-stack-lifecycle.md) — §4 項目 10：建立/銷毀的正式程序（三階段 cold start、單一指令 teardown）

這四份都沒做過的事，是**本文件唯一新增的驗證活動**：`slice2-stack-lifecycle.md` 寫好之後從未被真的執行過一次完整的 destroy→重建循環（它自己當時的開頭也這樣寫明）。本文件比照 Slice 1 自己跑 Round 1/Round 2 全鏈測試的模式，實際照官方三階段流程執行一次 destroy→重建→煙霧測試→再次 destroy，驗證「整個 Slice 2a 真的能從頭建起來、也能乾淨拆掉」。

## 前置條件

依 RULE-002，本機可重用的 MFA session（`dt-lab-long-term-mfa`）。

---

## Destroy → 重建循環驗證（2026-10-02 執行）

### 銷毀前基準

`terraform state list` 共 55 項（含 data source），管理資源涵蓋項目 1-11 累積建置的全部內容。

### 銷毀

`terraform destroy`：`Destroy complete! Resources: 44 destroyed.`，`terraform state list` 確認清空。

### 重建階段一：VPC + RDS + generator Lambda

`terraform apply -target=aws_lambda_function.trade_generator`：**第一次嘗試失敗**——

```
Error: creating RDS DB Instance (slice2-trade): ... InsufficientDBInstanceCapacity:
You can't create a db.t4g.micro database instance because there are no
Availability Zones with sufficient capacity for VPC and storage type : gp3
for db.t4g.micro. Please try the request again at a later time.
```

這是 AWS 端暫時性容量不足，不是設定問題。直接重跑同一個指令，第二次成功：`Apply complete! Resources: 2 added, 0 changed, 0 destroyed.`（VPC/子網/SG/IAM 等鏈上資源第一次嘗試時已建立，第二次只需補上 RDS 與 Lambda 這兩個）。

### 重建階段二：建立來源表

```bash
aws lambda invoke --function-name slice2-trade-generator \
  --payload '{"init_schema": true}' --cli-binary-format raw-in-base64-out ...
```

回傳 `{"init_schema": "done"}`。

### 重建階段三：MSK／Schema Registry／Plugin／Connector／驗證用 Lambda

`terraform apply`（完整）——MSK cluster 建立花了 **27m37s**。緊接著 `aws_mskconnect_connector.debezium_postgres` 開始建立時，這次執行的背景指令撞到工具本身的長時間執行上限被中斷（不是 AWS 錯誤），Terraform 收到中斷訊號後有做 graceful shutdown，但連線器的 `CreateConnector` 請求當時已經送出、還在處理中：

- 直接查 AWS（`aws kafkaconnect list-connectors`）確認連線器**真的在 AWS 端建立中**（`CREATING`，稍後確認到 `RUNNING`），只是本機 `terraform state list` 還查不到這個資源——這是 Terraform CLI 被中斷跟 AWS 端非同步建立之間的落差，不是建立失敗
- 中間一次診斷用的 `terraform plan | head -20` 也造成一個殘留的 state lock（`head` 提前結束讀取讓上游 `terraform plan` 收到 SIGPIPE）；用 `ps aux` 確認沒有其他 terraform 行程真的在跑後，`terraform force-unlock -force <lock-id>` 解除
- 用 `terraform import aws_mskconnect_connector.debezium_postgres <connector-arn>` 把這個已存在的連線器接回 state
- 跑一次 `terraform plan` 確認只剩 3 項無害差異（連線器 `database.password` 的敏感度標記調整、兩個已知跟內容無關的 plugin S3 物件 etag 雜訊），`terraform apply` 套用後完全乾淨

### 重建後煙霧測試

```bash
aws lambda invoke --function-name slice2-trade-generator --payload '{"num_trades": 5, "seed": 1}' ...
# {"trades": 5, "trade_ids": [...], "dirty_injected": 0, "operations": {"INSERT": 5, "UPDATE": 9, "DELETE": 1}, "status_counts": {"FILLED": 4}}

aws kafkaconnect describe-connector --connector-arn ... --query connectorState --output text
# RUNNING

aws lambda invoke --function-name slice2-cdc-event-verifier \
  --payload '{"topic": "transaction.trade.v1", "max_messages": 50, "timeout_seconds": 20}' ...
```

驗證用 Lambda 回傳：`total_messages: 16`，`op_counts: {'c': 5, 'u': 9, 'd': 1, 'tombstone': 1}`——跟 generator 回報的 `INSERT:5/UPDATE:9/DELETE:1` 完全對得上（`tombstone` 對應那 1 筆 delete）。抽樣一筆事件：

```json
{
  "op": "c", "before": null,
  "after": {"trade_id": "T1790928976-0000", "account_id": "ACC0003", "symbol": "2330",
            "price": 604.15, "quantity": 17000, "side": "BUY", "status": "NEW",
            "event_time": "2026-10-02T08:16:16.115045Z", "updated_at": "2026-10-02T08:16:16.115045Z"},
  "lsn": 603980048, "ts_ms": 1790928976337
}
```

確認重建後的管線產生結構正確的 CDC 事件（before/after/LSN/ts_ms 皆正常），跟項目 8 原本驗證過的行為一致。

### 再次銷毀

`terraform destroy` 連續撞到同一種背景執行時間上限中斷了兩次，但都是**graceful shutdown**、沒有留下 lock 問題。兩次中斷後實際發現：

- 第一次中斷前，已成功銷毀 38 項資源，只剩 VPC/兩個子網/Security Group 這 4 項
- 這 4 項卡著不動的真正原因：`aws ec2 describe-network-interfaces` 查到 4 個 `slice2-trade-generator` 的 Lambda ENI，狀態是 `available`（已從 Lambda 卸載，但 AWS 還沒回收釋放），卡住了子網路／SG 的刪除——這是 AWS 刪除 VPC 內 Lambda 後的已知延遲行為，不是設定錯誤
- 手動 `aws ec2 delete-network-interface` 清掉這 4 個 ENI 後，再跑一次 `terraform destroy`，剩餘 4 項資源在 1 秒內全部刪除完成

最終 `terraform state list` 確認為空，`ai/contexts/infra_dev_slice2.md` 已同步覆寫為「資源已銷毀」狀態。

**這次發現的三個真實現象已回補進 [slice2-stack-lifecycle.md](slice2-stack-lifecycle.md) 的故障排除表**（RDS 暫時性容量不足、中斷造成的 state 落差與 `import` 修復方式、Lambda ENI 清理延遲），下次重建／銷毀可以直接照著處理，不需要重新摸索。

---

## 對應 spec §7 驗收標準

- [x] 在來源 DB 做 insert / update / delete，Kafka topic 上都能消費到對應的 CDC 事件，且帶 before / after 影像與來源變更序 —— [slice2-cdc-event-verification.md](slice2-cdc-event-verification.md)；本文件的煙霧測試在**重建後的全新環境**上再次確認
- [x] 一筆交易走完完整狀態機（NEW → PARTIALLY_FILLED → FILLED），topic 上能看到完整的三筆變更軌跡 —— [slice2-cdc-event-verification.md](slice2-cdc-event-verification.md)
- [x] 註冊破壞性 schema 變更時被 Schema Registry 擋下（附錯誤訊息佐證） —— [slice2-cdc-event-verification.md](slice2-cdc-event-verification.md) 項目 9
- [x] 違約 / 無法反序列化的訊息進入 DLQ topic，主流程不受阻塞 —— [slice2-cdc-event-verification.md](slice2-cdc-event-verification.md) 項目 9
- [x] `contracts/trade-events.contract.yaml`（v1）納入版控，與實際註冊的 Avro schema、§6 規則一致 —— 依真實查到的 `transaction.trade.v1` schema 撰寫，見契約檔頭註解
- [x] Slice 2 的資源可依 §4 項目 10 的 runbook 完整銷毀與重建 —— **本文件**：實際執行一輪 destroy→重建→煙霧測試→destroy，過程中的真實狀況（非預期錯誤、修復方式）已記錄並回補進 `slice2-stack-lifecycle.md`
- [x] 上述 §9 文件皆已產出 —— ADR-0006／0007（已存在，過時的「尚未建立」註記本次已修正）、`docs/decision-log.md` 的 Slice 2a §3 決策（已存在）、`contracts/trade-events.contract.yaml`、`slice2-stack-lifecycle.md`、**本文件**

---

## 相關文件

- [docs/specs/slice2a-cdc-ingestion.md](../specs/slice2a-cdc-ingestion.md) §4 項目 12/13、§7 — 對應的實作項目與驗收標準
- [slice2-network-layer-verification.md](slice2-network-layer-verification.md) — §4 項目 1 衛星 runbook
- [slice2-msk-connect-plugin-packaging-verification.md](slice2-msk-connect-plugin-packaging-verification.md) — §4 項目 6 衛星 runbook
- [slice2-cdc-event-verification.md](slice2-cdc-event-verification.md) — §4 項目 8/9 衛星 runbook
- [slice2-stack-lifecycle.md](slice2-stack-lifecycle.md) — §4 項目 10 衛星 runbook，本次新增的故障排除項目也在這裡
- `contracts/trade-events.contract.yaml` — §4 項目 11 產出
- [ai/contexts/infra_dev_slice2.md](../../ai/contexts/infra_dev_slice2.md) — 目前實際部署狀態快照（已銷毀）
