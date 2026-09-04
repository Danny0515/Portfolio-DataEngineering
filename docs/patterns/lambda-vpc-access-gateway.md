# Pattern Card: Lambda 作為私有 VPC 資源存取閘道 (Lambda as VPC Access Gateway)

| 屬性 | 值 |
| --- | --- |
| **狀態** | ✅ `Accepted` |
| **相關模組** | `infra/environments/dev-slice2/lambda.tf`、`vpc.tf` |
| **對應決策** | [ADR-0008](../architecture/adr/0008-lambda-vpc-access-gateway.md) |
| **決策者** | Danny |

## 適用情境 (When to Use)

任何「運算資源需要存取部署在私有子網路（無 IGW/NAT、`publicly_accessible=false`）內的 AWS 資源（RDS、MSK broker 等），但呼叫方在 VPC 外部（本機開發環境、CI runner 等）」的情境：

- 私有子網路資源基於資安考量不打算對外開放
- 呼叫頻率是間歇性、互動式（開發除錯、資料查詢/寫入），非長時間持久連線
- 不想為了單一存取需求，額外維運一台常駐 bastion/EC2

**不適用**的情境：需要長時間持久連線或互動式逐步除錯（如需要 REPL 連進資料庫、或跑超過 Lambda 15 分鐘上限的長任務）；已經有其他理由必須維運常駐運算資源（如同時要跑排程任務），此時邊際成本已付出，直接共用即可。

## 核心機制 (Access Flow)

```
本機開發環境 / CI              私有子網路 (無 IGW/NAT)
   │                                │
   │  lambda:Invoke (公開 API)      │
   ▼                                │
[AWS Lambda] ── ENI 掛在私有子網路內 ─┤
   │  (Security Group 允許存取)     │
   ▼                                │
[RDS / MSK / 其他 VPC 內資源] ◀──────┘

Lambda 出站 (CloudWatch Logs 等 AWS API)
   │
   ▼
[VPC Interface Endpoint]（無 NAT 時必須額外建立）
```

### 關鍵設計決策（對照 lambda.tf / vpc.tf 行號）

1. **Lambda 掛在資源所在的私有子網路 + 共用 SG**（[lambda.tf:72-75](../../infra/environments/dev-slice2/lambda.tf#L72-L75)）：`vpc_config` 指到跟 RDS 相同的 private subnets 與 `slice2_internal` SG，讓 Lambda 的 ENI 拿到 VPC 內部 IP，可以走 SG 規則直連。

2. **IAM Role 一定要掛 AWSLambdaVPCAccessExecutionRole**（[lambda.tf:56-59](../../infra/environments/dev-slice2/lambda.tf#L56-L59)）：Lambda 要在 VPC 內執行，除了基本執行權限，還需要這個受管政策授予的 ENI 建立/刪除權限，少了這條 Lambda 會直接部署失敗。

3. **SG 用自我參照規則開放，不用固定 CIDR**（[vpc.tf:52-58](../../infra/environments/dev-slice2/vpc.tf#L52-L58)）：`self = true` 讓同一個 SG 底下的成員（Lambda、RDS）互通，之後同 VPC 新增其他資源只要掛同一個 SG 就自動打通，不必每次新增資源都手動加規則。

4. **VPC 內沒有 NAT，Lambda 自己的 AWS API 呼叫需要額外的 Interface Endpoint**（[vpc.tf:81-88](../../infra/environments/dev-slice2/vpc.tf#L81-L88)、[lambda.tf:87-90](../../infra/environments/dev-slice2/lambda.tf#L87-L90)）：Lambda 連得到 RDS 不代表連得到 CloudWatch Logs——那是另一條出站路徑，一樣得靠 VPC Endpoint 或 NAT 才能離開子網路；套用本樣式若沒有 NAT，記得同步評估 Lambda 需要呼叫哪些 AWS API，逐一補 Interface Endpoint。

## 如何在未來 Slice/其他情境重用此樣式

1. **確認目標資源真的沒有其他對外路徑**：先排除是否已有現成的 bastion/VPN 可以共用，避免重複建置存取閘道
2. **複製 vpc_config + IAM Role 的骨架**：[lambda.tf](../../infra/environments/dev-slice2/lambda.tf) 第 49-59、72-75 行是可直接參考的骨架，重點是 subnet/SG 要跟目標資源一致
3. **盤點這支 Lambda 需要呼叫哪些 AWS API**：不只是目標資源本身（RDS/MSK），還包含 Lambda 執行本身依賴的 API（CloudWatch Logs 是最低限度），逐一確認有沒有 NAT 或對應的 Interface Endpoint
4. **職責保持單一**：這支 Lambda 的定位是「存取閘道」，若同時要承擔複雜業務邏輯，評估是否該拆成獨立 Lambda，避免職責混雜（見 ADR-0008 影響段落的已知限制）

## 相關文件

- [docs/architecture/adr/0008-lambda-vpc-access-gateway.md](../architecture/adr/0008-lambda-vpc-access-gateway.md) — 為何選 Lambda 而非 bastion/SSM/Glue Python Shell
- [docs/specs/slice2a-cdc-ingestion.md](../specs/slice2a-cdc-ingestion.md) §4 項目 3/4 — 本樣式第一次落地的實作
- [docs/concepts/rds-lambda-eli5.html](../concepts/rds-lambda-eli5.html) — 零基礎圖解版本
