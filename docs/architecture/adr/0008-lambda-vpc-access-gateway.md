# ADR-0008: 私有子網路資源存取：以 Lambda 作為存取閘道，取代 Bastion/SSM

| 屬性 | 值 |
| --- | --- |
| **狀態** | ✅ `Accepted` |
| **日期** | 2026-09-03 |
| **相關模組** | `infra/environments/dev-slice2/lambda.tf`、`src/ingestion/generate_trade_data.py` |
| **決策者** | Danny |

## 背景 (Context)

§4 項目 4 部署的 RDS（`slice2-trade`）依 best practice 放在私有子網路，`publicly_accessible=false`，VPC 沒有 IGW/NAT，本機或任何 AWS Console 工具都無法直接連線。開發流程需要一個方式對 RDS 寫入/查詢測試資料，且後續項目（§4 項目 7 CDC connector 除錯、項目 8 事件驗證）大概率會重複遇到同樣「如何從外部碰觸私有 VPC 內資源」的問題。討論時列出四個方案：(a) VPC Peering 接既有 bastion、(b) Glue Python Shell + VPC connection、(c) SSM Session Manager + 專用 EC2、(d) Lambda 掛 VPC 設定。

## 決策 (Decision)

採用 (d)：以 Lambda（`trade_generator`，掛載於私有子網路 + `slice2_internal` SG）作為存取私有 VPC 內資源的統一閘道，透過公開的 `lambda:Invoke` API 觸發。此模式不只服務這次的 generator，作為本 Slice 之後任何「需要從 VPC 外部操作 VPC 內資源」情境的預設方案。

## 理由 (Rationale)

1. Lambda ENI 掛在私有子網路內可直接連線同 VPC 資源，但觸發走公開 API，不需要在 VPC 邊界開任何 inbound 通道。
2. 對照 (a)/(c)：兩者都需要一台常駐 EC2，有維運負擔（patch、金鑰/連線設定）與持續攻擊面；Lambda 無伺服器、閒置零成本。
3. 對照 (b)：Glue Python Shell 啟動延遲以分鐘計，不適合互動式開發流程；Lambda cold start 是秒級。
4. 與本專案既有／未來的事件驅動 serverless 運算方向一致，不是額外引入的新典範。

**Alternatives considered**：

- Lambda + VPC 設定（選定）：理由如上。
- VPC Peering 接既有 bastion（未選）：需常駐 EC2、SSH 金鑰管理，維運成本與攻擊面較高。
- AWS Glue Python Shell + VPC connection（未選）：啟動延遲不適合互動式開發流程。
- SSM Session Manager + 專用 EC2（未選）：仍需常駐 EC2，維運成本與 bastion 方案類似，僅省去 SSH 金鑰管理。

## 影響 (Consequences)

- ✅ **正面**：不需維運常駐 EC2/bastion；本機可直接呼叫公開 API 存取私有資源；符合 Control Tower 治理下最小化長駐運算資源的原則。
- ⚠️ **注意**：Lambda 出站流量（CloudWatch Logs 等）仍需要 NAT 或 VPC Interface Endpoint（本次因此額外新增 `logs` endpoint）；每次呼叫是短生命週期執行（最長 300 秒），不適合長時間持久連線或逐步除錯。
- ❌ **負面/限制**：目前 `trade_generator` 同時承擔「資料產生器」與「私有資源存取閘道」兩種職責，未來存取需求增加（如任意 SQL 查詢）時，可能需要拆成獨立的通用查詢 Lambda。
