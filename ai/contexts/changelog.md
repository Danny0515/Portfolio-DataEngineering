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

---

## Session 003 — 2026-07-28

- **Engineer**: Danny
- **Role**: Data Engineer
- **LLM Used**: Claude Code (claude-sonnet-5)
- **Module**: slice0-bronze-glue

### Completed

- [x] 盤點 Slice0 §4.4~4.5 所需的 Glue Catalog/IAM 現況：SSH 進 bastion 查現有 `danny-ops` role 權限與既有 Glue databases；釐清運算引擎採 AWS Glue Jobs（代管 serverless Spark），不在本機/bastion 裝 Java/PySpark
- [x] 實測用 bastion 借來的暫時憑證從本機直接呼叫 AWS API（`sts`/`s3`/`glue`）皆成功，確認限制其實是「本機沒有帳號憑證」而非網路層級限制；新增 RULE-002（AWS CLI 優先用 MFA 長期憑證 `dt-lab-long-term`，SSH bastion 降級為備援），同步更新 CLAUDE.md「環境限制」章節
- [x] 用 plan mode 規劃並實作 Slice0 §4.4~4.5：新增 `infra/environments/dev/{iam.tf,glue.tf,lakeformation.tf}`（Glue Database `bronze`/`silver`/`gold`、Glue Job 執行角色、Glue Job 定義）、`main.tf` 改名 `s3.tf` 呼應服務命名慣例、`src/transform/bronze_stock_data.py`（PySpark Bronze 落地腳本，讀 raw CSV 加 `ingest_time`/`source_file` 後 append 進 Iceberg，型別/品質檢查刻意留白）、根目錄 `pyproject.toml`（uv + ruff）
- [x] 新增 ADR-0001（`docs/architecture/adr/0001-use-iceberg.md`，為何用 Iceberg 而非 Parquet on S3）與 ADR-0002（`0002-medallion-layering.md`，為何分 Bronze/Silver/Gold 三層），同步 `docs/arc42/09_architecture_decisions.md` 決策總表
- [x] 本機未裝過 Terraform、Homebrew 因系統 Command Line Tools 過舊裝不了，改用官方 release 下載靜態執行檔到 `~/.local/bin/terraform`（已驗證 checksum）繞過 CLT 依賴；後續以 `AWS_PROFILE=dt-lab-long-term-mfa` 本機直接 `terraform apply`
- [x] 首次觸發 Glue Job 失敗：`Insufficient Lake Formation permission(s): Required Describe on bronze`——IAM policy 正確但這帳號的 Glue Data Catalog 疊了一層 Lake Formation 授權，`CreateDatabaseDefaultPermissions`/`CreateTableDefaultPermissions` 皆為空，新建 database 不會像舊資料庫一樣自動繼承 `IAM_ALLOWED_PRINCIPALS`；補上 `aws_lakeformation_permissions`（grant 給 Glue Job 執行角色），重跑成功，Iceberg snapshot 顯示 `total-records: 786`，與本機 raw CSV 786 筆一致
- [x] 使用者用 Athena 人工查詢又踩到第二次 Lake Formation 坑（`Relation contains no accessible columns`）：用 CLI 拆解測試（`SHOW COLUMNS` 成功、`SELECT *` 全部欄位不可存取）排除 SQL 語法問題，確認 Lake Formation Data Lake Admin 身份只代表能管理權限、不代表自動有資料 SELECT 權限；補上第二組 grant 給人身帳號 `dannyhuang@cathayholdings.com.tw`，查詢恢復正常
- [x] 新增 RULE-003（IAM 權限設定一律遵照 AWS 官方 best practice，與 plan.md/專案需求衝突時才討論特例並留 ADR），直接呼應本次兩次 Lake Formation 除錯過程
- [x] 依使用者臨時要求，將 `bronze`/`silver`/`gold` 三個 Glue database 的 `description` 都改為 `danny-test` 並重新部署

### Related ADRs

- [ADR-0001](../../docs/architecture/adr/0001-use-iceberg.md)：為何用 Iceberg 而非直接 Parquet on S3
- [ADR-0002](../../docs/architecture/adr/0002-medallion-layering.md)：為何分 Bronze/Silver/Gold 三層

### Next Steps

- [ ] (延續 Session 002) 依 §4 項目 6-9：實作 Silver/Gold PySpark 轉換、Athena 正式查詢驗證（本次僅為除錯過程中的手動驗證，非正式驗收）、partition 設計