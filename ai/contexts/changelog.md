# Changelog

> 記錄本專案每個開發 session 的異動，依 `~/.claude/templates/change_log_session_template` 格式附加。

---

## Session 001 — 2026-07-20

- **Engineer**: Danny
- **Role**: Data Engineer
- **LLM Used**: Claude Code (claude-sonnet-5)
- **Module**: slice0-infra-bootstrap

### Completed

- [x] 新增 `add_project_rule` skill（`.claude/commands/add_project_rule.md`），用於把討論出的 Agent 執行規則寫入 `ai/contexts/rules.md` 並同步 CLAUDE.md「專案規則」清單，寫入前需先取得使用者確認
- [x] 建立 `ai/contexts/rules.md`，新增 RULE-001：AWS 資源部署一律使用 Terraform，禁止用 `aws cli` 執行部署性質指令（僅允許唯讀查詢，且限 bastion 上執行），並在 CLAUDE.md 新增「專案規則」章節引用此規則
- [x] 在 CLAUDE.md 新增「環境限制」章節，說明組織 AWS 帳號受 Control Tower 治理、本機無法直接執行 aws cli，所有操作需先 SSH 進 bastion（`ec2-user@danny-ops`）再執行，並連結對應 runbook
- [x] 新增 `docs/runbooks/aws-access-via-bastion.md`，記錄透過 SSH bastion 存取 AWS 的連線設定與故障排除步驟
- [x] 新增 `infra/environments/dev/` Terraform 骨架（main.tf/variables.tf/outputs.tf/provider.tf/versions.tf/terraform.tfvars/.terraform.lock.hcl），定義 Slice0 專屬 S3 bucket（`danny-data-engineering`，`ap-northeast-1`），含 versioning、SSE-S3 加密、public access block
- [x] 更新 `.gitignore` 新增 Terraform 相關忽略規則（`.terraform/`、`*.tfstate` 等）
- [x] 同步更新 `docs/specs/slice0-batch-market-data.md` §4 項目 3：raw landing bucket 改為透過 Terraform 建立的專屬 bucket，而非既有共用 bucket
- [x] 於 bastion 執行 `terraform init`/`plan`/`apply`，實際建立 `danny-data-engineering` bucket（versioning/加密/public access block 皆確認生效），完成 §4 項目 3 的實際部署；過程中 `rsync --delete` 一度誤刪 bastion 上剛產生的 local state，已用 `terraform import` 復原並改用 S3 backend（state 現存於 `s3://danny-data-engineering/terraform-state/dev/slice0.tfstate`），`terraform plan` 確認 `No changes`。部署現況見 `ai/contexts/infra_dev.md`
- [x] 將 bastion 上的專案路徑由 `~/infra` 改為 `~/Portfolio-DataEngineering/infra`，避免與同機其他專案的目錄混淆；已同步更新 runbook 的 rsync/cd 路徑並驗證 `terraform plan` 仍為 `No changes`

### Related ADRs

- 無新增 ADR（本次為部署方式/Agent 協作機制的治理決策，已記錄於 `ai/contexts/rules.md` RULE-001，不屬於 execution-roadmap.md 定義的 Slice0 資料架構 ADR 產出項）

### Next Steps

- [ ] 依 `docs/specs/slice0-batch-market-data.md` §4 項目 1-2：建立 `src/ingestion/` 等模組骨架，並實作模擬資料 generator（`generate_market_data.py`）
- [ ] 依 §4 項目 4-10：實作 Bronze/Silver/Gold PySpark 轉換、建立 Glue Data Catalog、Athena 查詢驗證、partition 設計，並補齊 ADR（0001-use-iceberg、0002-medallion-layering）

---

## Session 002 — 2026-07-22

- **Engineer**: Danny
- **Role**: Data Engineer
- **LLM Used**: Claude Code (claude-sonnet-5)
- **Module**: slice0-ingestion

### Completed

- [x] (延續 Session 001 Next Steps §4 項目 1-2) 建立 `src/ingestion/`、`src/transform/` 模組骨架，並實作模擬資料 generator `src/ingestion/generate_stock_data.py`（stdlib-only，產生 3 檔台股代號 `2330`/`2454`/`3653` 的每日 OHLCV CSV，內建 dirty-data 注入模式供 Slice 1 品質關卡測試用）
- [x] 新增 `rsync_to_bastion` skill（`.claude/commands/rsync_to_bastion.md` + `scripts/rsync_to_bastion.sh`），統一整個專案同步到 bastion 的方式，取代先前 Terraform／資料上傳各自維護不同 rsync/exclude 指令的做法；同步更新 `docs/runbooks/aws-access-via-bastion.md` 的 Bootstrap/日常流程改用此腳本，並新增「上傳模擬資料到 Raw Landing」章節記錄 generator → rsync_to_bastion → `aws s3 sync` 的實際落地流程
- [x] 依上述流程實際執行 generator 並落地到 `s3://danny-data-engineering/raw/market_data/stock/`，完成 Slice0 §4 項目 3 的資料面工作（Session 001 僅完成 bucket 基礎設施）；`docs/data-dictionary/README.md`（新增）記錄此現況：Raw landing 已完成，Bronze/Silver/Gold 尚未建立
- [x] `plan.md` §2.2 Storage 新增「命名慣例」說明：三大資料領域內部依資產類別/子類型再分層（例：`market_data/stock/`、`<layer>.stock_data`），已依 `planning_project` skill 流程取得確認並補上 Changelog（2026-07-22）
- [x] 依新命名慣例同步更新 `infra/environments/dev/{terraform.tfvars,variables.tf}` 的 `raw_landing_prefix` 為 `raw/market_data/stock/`、`ai/contexts/infra_dev.md` 快照、以及 `docs/specs/slice0-batch-market-data.md` §4/§5 的路徑與 table 命名（`market_data` → `stock_data`）；順手修正 spec §3.4 symbol 代號筆誤（`3563`→`3653`，與 generator 實際預設值一致）
- [x] `.gitignore` 新增 `data/`（產生的模擬資料為可重新產生內容，不進版控）

### Related ADRs

- 無新增 ADR（本次為依 §3 既有決策的落地實作與命名細化，非新的架構取捨決策）

### Next Steps

- [ ] (延續 Session 001) 依 §4 項目 4-10：實作 Bronze/Silver/Gold PySpark 轉換、建立 Glue Data Catalog、Athena 查詢驗證、partition 設計，並補齊 ADR（0001-use-iceberg、0002-medallion-layering）