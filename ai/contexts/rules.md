# Project Rules（AI Agent 執行規則）

> 本文件記錄本專案對 Agent 的強制執行規則。每條規則需在 CLAUDE.md 中被引用，確保每個 session 都會被提醒遵守。
> 新增規則請使用 `add_project_rule` skill，維持格式一致。

## RULE-001：AWS 資源部署一律使用 Terraform，禁止用 AWS CLI 部署

- **規則**：所有 AWS 資源的建立/修改/刪除一律透過 Terraform（`infra/`）進行。禁止使用 `aws cli` 執行任何部署/變更性質指令（如 `aws s3 mb`、`aws s3api put-bucket-policy`、`aws glue create-database` 等）。
- **允許的 aws cli 用途**：僅限「驗證」與「排錯」，例如 `aws s3 ls`、`aws sts get-caller-identity`、`aws glue get-table` 等唯讀查詢指令，且僅能在 bastion 上執行（見 CLAUDE.md「環境限制」）。
- **Why**：確保雲端資源變更可被版控、可重現、可 review，避免產生 Terraform state 之外的「野生資源」，也呼應 execution-roadmap.md Slice 4 的 IaC 治理目標，提早建立紀律，避免之後要大量回頭補 `terraform import`。
- **How to apply**：Agent 規劃或執行任何 AWS 操作前，先判斷是「部署變更」還是「查詢驗證」；前者一律走 `infra/` 的 Terraform 檔案，後者才可用 aws cli。
