# Project Rules（AI Agent 執行規則）

> 本文件記錄本專案對 Agent 的強制執行規則。每條規則需在 CLAUDE.md 中被引用，確保每個 session 都會被提醒遵守。
> 新增規則請使用 `add_project_rule` skill，維持格式一致。

## RULE-001：AWS 資源部署一律使用 Terraform，禁止用 AWS CLI 部署

- **規則**：所有 AWS 資源的建立/修改/刪除一律透過 Terraform（`infra/`）進行。禁止使用 `aws cli` 執行任何部署/變更性質指令（如 `aws s3 mb`、`aws s3api put-bucket-policy`、`aws glue create-database` 等）。
- **允許的 aws cli 用途**：僅限「驗證」與「排錯」，例如 `aws s3 ls`、`aws sts get-caller-identity`、`aws glue get-table` 等唯讀查詢指令，且僅能在 bastion 上執行（見 CLAUDE.md「環境限制」）。
- **Why**：確保雲端資源變更可被版控、可重現、可 review，避免產生 Terraform state 之外的「野生資源」，也呼應 execution-roadmap.md Slice 4 的 IaC 治理目標，提早建立紀律，避免之後要大量回頭補 `terraform import`。
- **How to apply**：Agent 規劃或執行任何 AWS 操作前，先判斷是「部署變更」還是「查詢驗證」；前者一律走 `infra/` 的 Terraform 檔案，後者才可用 aws cli。

## RULE-002：AWS CLI 操作優先使用 MFA 長期憑證，SSH Bastion 降級為備援手段

- **規則**：Agent 要執行任何 `aws cli` 操作前，依序嘗試：
  1. 先檢查是否已有可重用的 MFA session（base profile `dt-lab-long-term` 對應的 `dt-lab-long-term-mfa`，用 `aws-cli-mfa-session` skill 的 `check_mfa_session.sh dt-lab-long-term` 判斷是否 `REUSABLE`）
  2. 若無可用憑證，呼叫 global skill `aws-cli-mfa-session`，以 base profile `dt-lab-long-term` 建立 MFA session
  3. 若透過該 skill 建立連線失敗，才改用 [docs/runbooks/aws-access-via-bastion.md](../../docs/runbooks/aws-access-via-bastion.md) 描述的 SSH bastion（`danny-ops`）方式
- **Why**：原先假設「本機無法直接執行 aws cli」不成立——限制其實是本機缺帳號憑證，不是網路/IP 層級的硬限制；bastion 保留作為 MFA 連線失敗時的備援。完整驗證過程見 [changelog.md](changelog.md) Session 003。
- **How to apply**：Agent 規劃或執行任何需要雲端憑證的操作（AWS CLI、Terraform apply 等）前，先執行 MFA session 檢查/建立流程；只有在 `aws-cli-mfa-session` skill 明確建立失敗時，才退回「先 `ssh danny-ops` 再於遠端執行」的既有 bastion 流程。RULE-001（Terraform-only 部署）不受影響，仍然適用——這條規則只改變「怎麼取得憑證」，不改變「部署一律走 Terraform、CLI 僅限查詢/驗證」的限制。

## RULE-003：IAM 權限設定一律遵照 AWS 官方 Best Practice，衝突時才討論特例並留 ADR

- **規則**：Agent 設計/實作任何 IAM 權限相關的 Terraform 資源（IAM Role/Policy、Lake Formation 權限授予等）時，一律優先遵照 AWS 官方文件建議的 best practice（例如最小權限原則、避免用萬用字元 `Resource="*"`、依服務官方文件建議的權限模型設計，包含該服務是否疊了額外的授權層，例如 Glue Data Catalog + Lake Formation）。若 AWS best practice 跟 [plan.md](../../plan.md) 的技術選型/範圍，或本專案當下的具體需求產生衝突，不能自行決定妥協方案，必須先跟使用者討論、取得特例的解決方案共識；不論最終採用 best practice 還是特例，都要用 `add_adr` skill 留下對應的 ADR 記錄決策理由。
- **Why**：IAM policy 依最小權限原則設計好了，仍因沒查證這個帳號的 Glue Data Catalog 疊了一層 **Lake Formation** 授權，讓 Glue Job 跟 Athena 查詢各失敗一次，事後才補 grant。完整除錯過程見 [changelog.md](changelog.md) Session 003。
- **How to apply**：Agent 規劃或撰寫任何 IAM Role/Policy、Lake Formation 權限、或其他權限相關 Terraform 資源前，先查證 AWS 官方文件針對該服務的權限 best practice（含是否需要額外授權層），並以此為預設實作依據；只有在 best practice 跟 plan.md 或使用者明確提出的專案需求衝突時，才停下來跟使用者討論特例，取得共識後用 `add_adr` skill 產出 ADR。
