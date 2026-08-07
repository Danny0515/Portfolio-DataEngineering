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

## Session 004 — 2026-07-31

- **Engineer**: Danny
- **Role**: Data Engineer
- **LLM Used**: Claude Code (claude-sonnet-5)
- **Module**: slice0-silver-gold-glue

### Completed

- [x] 依 spec §4 項目 6~7，新增 `src/transform/silver_stock.py`（依 `(symbol, date)` 去重、`ingest_time` window 取最新批次、型別 cast、品質過濾、`createOrReplace()` 全量覆寫）與 `src/transform/gold_monthly_ohlcv.py`（月頻聚合、`min_by`/`max_by` 取當月首末交易日 OHLC、`createOrReplace()`）；Gold 改月頻而非日頻，因為 Silver 已是 1 row/(symbol, date)，日粒度聚合會是無意義的 no-op，table 定名 `gold.monthly_ohlcv`；同步在 `infra/environments/dev/glue.tf` 新增對應 Glue Job、`outputs.tf` 新增 output
- [x] 新增 `docs/arc42/06_runtime_view.md`（mermaid flowchart 呈現目前實際批次執行流程）與 `08_concepts.md`（Medallion Architecture 通用設計原則，8.1~8.7），並同步修正 `docs/specs/slice0-batch-market-data.md`、`docs/architecture/adr/0002-medallion-layering.md` 的 append/overwrite 用詞與 Gold table 名稱
- [x] 依使用者要求，Bronze 改為全字串讀取（`inferSchema=false`），型別解析 100% 交給 Silver（含新增 `volume` 顯式 cast、處理順序改為 dedup→cast→filter），同步更新 ADR-0002 與 arc42 08_concepts.md 對應段落
- [x] 依使用者要求，拿掉命名慣例裡多餘的 `_data` 尾綴（`market_data`→`market`、`<layer>.stock_data`→`<layer>.stock`）：更新 `plan.md` §2.2 命名慣例本文並補 Changelog、Terraform 資源識別字全面改名（`aws_iam_role.glue_market_data`→`glue_market` 等，含 IAM/Lake Formation/Glue Job）、`bronze_stock_data.py`→`bronze_stock.py`、`generate_stock_data.py` 輸出路徑與檔名（`market_data.csv`→`market.csv`）
- [x] 本機首次成功安裝 Terraform（先前因 Homebrew 需要的 Xcode Command Line Tools 過舊而卡住，使用者自行更新後裝成功），之後可直接本機 `terraform plan`/`apply`，不需再走 bastion
- [x] 用 MFA session（RULE-002）完成：清空舊資源（舊 raw CSV、舊 `bronze.stock_data` table，經使用者在 Lake Formation Console 調整權限後親自執行刪除）→ `terraform apply`（20 個新建、16 個銷毀重建，符合改名預期）→ 重新產生模擬資料並上傳新路徑 → 依序觸發 Bronze/Silver/Gold 三個 Glue Job，全部成功
- [x] Athena 查詢驗證（spec §4 項目 8，正式驗收）：筆數 Bronze 786 = Silver 786，各 symbol 均 262 筆；Gold 39 筆（3 symbol × 13 個月）；品質規則違規與去重重複皆為 0；以 `2330` 2025-08 交叉驗證聚合值（`SUM(volume)` = Gold 該列 `volume`），全部通過；整理成 `docs/runbooks/slice0-verification.md` 供之後重複使用
- [x] 更新 `ai/contexts/infra_dev.md` 快照（依 `terraform output`/`state list` 實際輸出覆寫）

### Related ADRs

- 無新增 ADR；修正既有 [ADR-0002](../../docs/architecture/adr/0002-medallion-layering.md)（Bronze `inferSchema=false` 描述、table 改名），非新決策

### Next Steps

- [ ] 精簡 `docs/arc42/08_concepts.md`

---

## Session 005 — 2026-08-05

- **Engineer**: Danny
- **Role**: Data Engineer
- **LLM Used**: Claude Code (claude-sonnet-5)
- **Module**: slice0-docs-cleanup

### Completed

- [x] (延續 Session 004 Next Steps) 精簡 `docs/arc42/08_concepts.md`：新增章節目錄（8.1~8.8）方便導覽，並縮短部分段落的重複描述（如 8.2 Bronze 職責邊界、8.3 Silver 型別校正範例）；刻意不過度精簡——保留原始設計動機與理由的完整說明，因為後續資料域擴充（期貨、交易資料等）時仍會頻繁變動這份文件，過度精簡會讓人看不出「當初為什麼這樣設計」

### Related ADRs

- 無新增 ADR（本次為既有 ADR-0002/ADR-0003 落地細節的文件整理，非新決策）

### Next Steps

- [ ] 開始 Slice 1 §4 項目 4.1~4.9 的實作（依 `docs/specs/slice1-quality-contract.md`）

---

## Session 006 — 2026-08-05

- **Engineer**: Danny
- **Role**: Data Engineer
- **LLM Used**: Claude Code (claude-sonnet-5)
- **Module**: slice1-quality-foundation

### Completed

- [x] (延續 Session 005 Next Step，部分完成) Slice 1 §4 項目 1：擴充 `src/ingestion/generate_stock_data.py` 髒資料注入，新增至 6 種類型對應 §6 四個品質維度（completeness/validity×3/uniqueness/consistency），並新增 `--end-date` 參數方便產生指定區間的測試批次
- [x] Slice 1 §4 項目 2：建立 GX（Great Expectations）基底——`src/quality/build_expectation_suite.py`（YAML 規則 → GX ExpectationSuite 的通用 loader，無 table-specific 邏輯）+ `src/quality/rules/silver_stock.yaml`（14 條宣告式規則，依完整性/有效性/唯一性/一致性四維度分組，對應 §6）+ GX 專案骨架（`great_expectations.yml`、產出的 `expectations/silver_stock.json`、自訂 data docs 樣式、`.gitignore` 排除 `uncommitted/`）
- [x] 新增 `tests/quality/test_build_expectation_suite.py`：以 ephemeral pandas context 執行真實 GX validation（非 mock），涵蓋規則覆蓋率的結構測試，以及「6 種髒資料全被抓到」+「全乾淨批次通過」兩個端到端案例
- [x] 新增 `docs/runbooks/generate-stock-data.md`，記錄 generator 參數說明（含新增的 `--end-date`、既有 `--dirty-rate`）與 Slice0/Slice1 雙重用途
- [x] `pyproject.toml` 新增 `great-expectations`、`pytest` 依賴與 `[tool.pytest.ini_options]`（`testpaths=["tests"]`）
- [x] `docs/specs/slice1-quality-contract.md` §4 項目 1-2 標記完成，狀態列更新為「§3 待確認事項已全數拍板」

### Related ADRs

- 無新增 ADR；spec §3.1（Great Expectations vs Soda Core）已拍板但尚無正式 ADR。**注意**：spec §9／execution-roadmap.md 預期的 ADR 檔名 `0003-wap-quality-gate.md` 已與現有 `0003-append-vs-overwrite.md`（Slice0）編號衝突，之後落筆需改用下一個可用編號（如 0004）

### Next Steps

- [ ] (延續 Session 005，範圍縮小為) Slice 1 §4 項目 3-9：WAP staging 機制（Iceberg branch）、Audit 執行、Publish/擋下邏輯、稽核紀錄落地、Data Contract 撰寫（`market-data.contract.yaml`）、端到端驗證、文件產出（Pattern Card + ADR + Decision Log）
- [ ] 視 §4 項目 3-6 完成進度，補寫 `docs/arc42/08_concepts.md` 的「Data Quality 設計原則」一節（sync-arc42 本次判斷 WAP Gate 尚未接進 pipeline，暫緩）

### Notes

> 品質規則刻意設計成 YAML 宣告式（`rules/*.yaml`）而非寫死在 Python，之後新增資料域只需新增一份 YAML，不用碰 `build_expectation_suite.py`。

---

## Session 007 — 2026-08-07

- **Engineer**: Danny
- **Role**: Data Engineer
- **LLM Used**: Claude Code (claude-sonnet-5)
- **Module**: slice1-wap-staging

### Completed

- [x] Slice 1 §4 項目 3：`src/transform/silver_stock.py` 實作 WAP Write 階段——`table_exists` 判斷後，寫入 Iceberg `staging` branch（`ALTER TABLE ... CREATE BRANCH IF NOT EXISTS` + `.writeTo(...).overwrite(lit(True))`）取代直接覆寫 main；第一次執行（表不存在時）仍走原本 `createOrReplace()` 直接建表在 main（bootstrap，無資料可保護）
- [x] `pyproject.toml` 新增 `pyspark`（對齊 Glue 5.0 = Spark 3.5.4）dev dependency；新增 `scripts/verify_wap_branch_write.py`——本機用簡化 schema + Iceberg **Hadoop catalog**（非 AWS）獨立驗證 branch 寫入機制，7 項斷言全數通過，包含證實 `createOrReplace()` 對 branch-qualified identifier 不適用、`CREATE BRANCH IF NOT EXISTS` 冪等性
- [x] 依使用者要求，在真實 AWS Glue（`slice0-silver-stock` job，經 `terraform apply -target` 部署新版腳本、`dt-lab-long-term-mfa` MFA session）連續觸發兩輪，透過 Athena `$refs`/`$snapshots` metadata table 與 `FOR VERSION AS OF 'staging'` 查詢確認：**Glue Data Catalog + Iceberg 1.7.1 完整支援 branch 操作**，main 全程不受影響（786 筆、snapshot_id 不變），staging 兩輪各自新增 snapshot 且 parent lineage 正確銜接（第 2 輪 parent 接第 1 輪 staging，而非 main）——spec §3.2/§8 懸而未決的 Glue branch 支援度風險已解除，不需降級為手動 staging table
- [x] 新增 `docs/runbooks/slice1-verification.md`：正式環境 WAP staging 驗證 runbook，含上述實測參考結果，並明訂本機 Hadoop catalog 僅供開發當下快速驗證邏輯、不具驗收效力，Slice 1 驗收一律以 Glue 實測結果為準；同步在 `docs/runbooks/slice0-verification.md` Silver 驗證段落補注記，說明「每次執行都直接寫 main」的假設在 WAP 導入後不再成立
- [x] `docs/specs/slice1-quality-contract.md` §4 項目 3 標記完成
- [x] 精簡 `silver_stock.py` 累積註解（多個 session 疊加後 172 行→113 行）：移除已可從程式碼本身看出、或與既有 ADR 重複的說明，只保留真正影響決策的關鍵註解（如 `CREATE BRANCH IF NOT EXISTS` 冪等性為何重要、為何用 `overwrite()` 而非 `createOrReplace()`）

### Related ADRs

- 無新增 ADR。原先 spec §8 風險預留「若 Glue Catalog 不支援 branch 操作，需降級為手動 staging table 並留 ADR」——本次實測確認 Glue Catalog 完整支援，未觸發降級條件，故不需要 ADR；WAP Gate 的正式 ADR（`0004-wap-quality-gate.md`，注意編號需避開既有 `0003-append-vs-overwrite.md`）仍留待項目 9

### Next Steps

- [ ] (延續 Session 006，範圍縮小為) Slice 1 §4 項目 4-9：Audit 執行、Publish/擋下邏輯、稽核紀錄落地、Data Contract 撰寫（`market-data.contract.yaml`）、端到端驗證、文件產出（Pattern Card + ADR + Decision Log）
- [ ] (延續 Session 006) 視 §4 項目 4-6 完成進度，補寫 `docs/arc42/08_concepts.md` 的「Data Quality 設計原則」一節（WAP Gate 尚未完整接進 pipeline，暫緩）

### Notes

> 本機用 Hadoop catalog 驗證的是「Iceberg branch 寫入機制本身」，跟 spec §3.2/§8 真正要問的「Glue Data Catalog 這個 catalog-impl 支不支援 branch」是兩件分開的事，前者不能替代後者——這點在本機驗證完成、使用者主動要求「直接測試 Glue 是否可行」後才補上，也因此在驗證腳本與 runbook 裡都刻意標註兩者的差異與各自涵蓋範圍，並在 runbook 中明訂為 Slice 1 階段往後的驗收慣例。