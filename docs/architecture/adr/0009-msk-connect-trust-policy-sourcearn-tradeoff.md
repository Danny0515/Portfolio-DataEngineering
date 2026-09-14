# ADR-0009: MSK Connect worker IAM trust policy 的 SourceArn 妥協方案

| 屬性 | 值 |
| --- | --- |
| **狀態** | ✅ `Accepted` |
| **日期** | 2026-09-14 |
| **相關模組** | `infra/environments/dev-slice2/msk_connector.tf` |
| **決策者** | Danny |

## 背景 (Context)

§4 項目 7 部署 `aws_mskconnect_connector` 時，需要建立一個 IAM Role 讓 MSK Connect 服務（`kafkaconnect.amazonaws.com`）可以 assume。AWS 官方文件建議的 trust policy 範例，用 `aws:SourceArn` condition 精確比對 connector 自己的 ARN，防止 confused deputy 問題（其他帳號或其他 connector 冒用這個 Role）。但這個 ARN 帶有隨機產生的 UUID 後綴，只有在 connector 真正建立完成後才存在；而 Terraform 的資源相依順序要求 Role 必須先存在，connector 才能引用它的 ARN——形成順序衝突，官方範例的寫法在 Terraform 裡無法直接套用。這正是 RULE-003 定義的「AWS best practice 跟專案實際需求衝突」情境，需要跟使用者討論並留下決策記錄。

## 決策 (Decision)

Trust policy 採用折衷方案：同時檢查 `aws:SourceAccount`（帳號層級，精確比對）與 `aws:SourceArn`（萬用字元比對到 connector 名稱層級，即 `arn:aws:kafkaconnect:<region>:<account>:connector/slice2-debezium-postgres-connector/*`，只有隨機 UUID 部分用萬用字元）。connector 的名稱在撰寫 Terraform 當下就已固定，不受「先有 Role 才能建 connector」順序問題影響。

## 理由 (Rationale)

1. 完全比照官方範例的精確 ARN 比對做不到——Terraform 的資源相依圖要求 Role 在 connector 之前建立，此時 connector 的完整 ARN（含隨機 UUID）尚未存在。
2. 只比對 `SourceAccount`（放棄 `SourceArn`）雖然沒有順序問題，但保護範圍太寬：同一個 AWS 帳號內任何其他 MSK Connect connector 都能冒用這個 Role，沒有真正達到「這個 Role 只服務這一個 connector」的最小權限精神。
3. 折衷方案鎖定到「這個特定名稱的 connector」，只在隨機 UUID 這一段讓步，是官方建議與 Terraform 實務限制之間可以達到的最緊範圍；本專案目前每個 stack 只有一個 MSK Connect connector，這個折衷在實務上等同精確比對。

## 影響 (Consequences)

- ✅ **正面**：Trust policy 範圍限縮到帳號層級 + 特定 connector 名稱，比只用 `SourceAccount` 更緊，同時不受 Terraform 建立順序限制卡住。
- ⚠️ **注意**：萬用字元只取代 UUID 段，connector 名稱本身仍是固定字串精確比對，不會意外放寬到其他同前綴的 connector。
- ❌ **負面/限制**：跟 AWS 官方範例的「精確 ARN 比對」相比，理論上防護力略低（若攻擊者能在同一帳號內建立一個名稱完全相同的 connector，這個 trust policy 無法區分新舊兩個同名 connector）——但這個情境需要攻擊者已經有能力在本帳號建立 MSK Connect 資源，屬於已經有相當程度帳號存取權限的情境，非這個 trust policy 設計要防禦的威脅模型。
