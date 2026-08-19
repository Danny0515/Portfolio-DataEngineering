# Runbook: GX-on-Spark-on-Glue 整合複雜度驗證（Audit spike）

## 背景 (Why)

對應 [docs/specs/slice1-quality-contract.md](../specs/slice1-quality-contract.md) §8「Great Expectations 在 Spark on Glue 環境的整合複雜度」風險項，以及 §4 項目 4「Audit 執行」的第一步落地。§8 把這個風險拆成三個具體未知項：

1. **依賴打包**：`great-expectations==1.19.1`（含 pandas/numpy/scipy/pydantic/altair 等重依賴鏈）能否透過 `--additional-python-modules` 在 Glue 5.0 runtime 裝起來，會不會跟 Glue 內建套件版本衝突、耗時是否落在 Job `timeout = 10` 分鐘內。
2. **Data Context 模式**：本機 `src/quality/gx/` 是 FileDataContext 專案骨架，跟 Glue「單一 .py 腳本上傳 S3」的部署模型天生不合，能否改用 `gx.get_context(mode="ephemeral")` 搭配直接載入已 commit 的 Suite JSON 運作。
3. **Spark 執行引擎相容性**：GX 的 Spark Datasource/Validator 對 Glue 提供的 `SparkSession`、讀自 Iceberg `branch_staging` 的 DataFrame 能否正確運作。

未知項 #2、#3 已經在本機用真實 `pyspark` + GX 驗證過可行（見 `tests/quality/test_gx_spark_validation.py`），唯一沒辦法在本機驗證、必須實際跑一次 Glue Job 才有答案的是未知項 #1。這份 runbook 記錄真實環境（AWS Glue + Iceberg `staging` branch）的驗證過程與結果。

**範圍限制**：這次只驗證「Audit 能不能在 Glue 上正確跑出 pass/fail」，不含 item 5（Publish/fast-forward 擋下邏輯）與 item 6（稽核紀錄落地到可查詢的表）——Audit 結果目前只印到 CloudWatch，不會擋下任何資料、也不會寫入任何稽核表。

## 前置條件

- 本機已有可重用的 AWS MFA session（`dt-lab-long-term-mfa`，用 `aws-cli-mfa-session` skill 的 `check_mfa_session.sh dt-lab-long-term` 確認 `REUSABLE`）
- `silver.stock` 必須已存在（沿用 Slice0/先前 Slice1 執行留下的表），否則 Silver Job 會走 bootstrap 分支，跳過 staging/Audit 邏輯

## 部署新版程式碼與 Terraform 設定

改動涵蓋：
- `src/transform/silver_stock.py`：在 WAP Write 之後新增 Audit 步驟（讀 staging → 載入 Suite JSON → 建 GX ephemeral context + Spark Datasource → validate → 印出結果）
- `infra/environments/dev/glue.tf`：新增 `aws_s3_object.silver_stock_suite`（上傳 `src/quality/gx/expectations/silver_stock.json`），並在 `aws_glue_job.silver_stock` 的 `default_arguments` 加上 `--additional-python-modules = "great-expectations==1.19.1"` 與 `--extra-files`（指到剛上傳的 suite JSON）

```bash
cd infra/environments/dev
AWS_PROFILE=dt-lab-long-term-mfa terraform apply \
  -target=aws_s3_object.silver_script \
  -target=aws_s3_object.silver_stock_suite \
  -target=aws_glue_job.silver_stock
```

**未用 `terraform apply`（不帶 `-target`）的原因**：`terraform plan` 當下額外顯示 `aws_lakeformation_permissions.athena_reader_tables["bronze"]` 要 `-/+`（destroy + 重建），把該 table 的實際權限從 `ALTER/DELETE/DROP/INSERT/ALL` 收斂回 `.tf` 定義的 `DESCRIBE/SELECT`——這是跟本次改動無關的既有 drift（推測是先前排錯時透過 Console 手動 grant、事後沒有回寫 `.tf`），不在這次任務範圍內、也未確認收斂是否安全，因此改用 `-target` 只套用這次真正要改的 3 個資源，drift 留待另外處理，不隨這次 apply 一併變動。

## 驗證步驟與參考結果（2026-08-13 執行）

### 第一輪：全乾淨資料（`silver.stock` 沿用既有內容，不重新產生）

```bash
AWS_PROFILE=dt-lab-long-term-mfa aws glue start-job-run --job-name slice0-silver-stock --region ap-northeast-1
```

結果：`JobRunState=SUCCEEDED`，`ExecutionTime=104` 秒（`ErrorMessage=null`）——**這個數字直接回答未知項 #1**：`--additional-python-modules` 安裝 `great-expectations==1.19.1` 沒有失敗、沒有跟 Glue 內建套件衝突，安裝 + 執行合計遠低於 10 分鐘的 timeout。

CloudWatch log（`/aws-glue/jobs/output`，log stream = job run id）：

```
[Audit] cwd=/tmp
[Audit] staging validation success=True
```

`cwd=/tmp` 也順便回答了「`--extra-files` 實際把檔案放在哪裡」這個原本沒把握的問題：確認落地在 `/tmp`，`Path("silver_stock_suite.json")`（相對路徑）直接讀得到，不需要額外組路徑。

### 第二輪：故意灌髒資料

```bash
uv run python src/ingestion/generate_stock_data.py \
  --years 0.3 --dirty-rate 0.4 --seed 1 --output-dir /tmp/dirty-check
# 79 個交易日、249 列（[generate-stock-data.md](generate-stock-data.md) 驗證過這組參數涵蓋全部六種髒資料 kind）

AWS_PROFILE=dt-lab-long-term-mfa aws s3 sync /tmp/dirty-check/ s3://danny-data-engineering/raw/market/stock/ --region ap-northeast-1

AWS_PROFILE=dt-lab-long-term-mfa aws glue start-job-run --job-name slice0-bronze-stock --region ap-northeast-1
# 等待 SUCCEEDED（ExecutionTime=89s）後再觸發 Silver

AWS_PROFILE=dt-lab-long-term-mfa aws glue start-job-run --job-name slice0-silver-stock --region ap-northeast-1
```

Silver 這輪：`JobRunState=SUCCEEDED`，`ExecutionTime=132` 秒。CloudWatch log：

```
[Audit] cwd=/tmp
[Audit] staging validation success=False
[Audit] FAILED: expect_column_values_to_not_be_null kwargs={'column': 'symbol', ...}
[Audit] FAILED: expect_column_values_to_be_in_set kwargs={'column': 'symbol', 'value_set': ['2330', '2454', '3653'], ...}
[Audit] FAILED: expect_column_values_to_not_be_null kwargs={'column': 'trade_date', ...}
[Audit] FAILED: expect_column_values_to_not_be_null kwargs={'column': 'volume', ...}
[Audit] FAILED: expect_compound_columns_to_be_unique kwargs={'column_list': ['symbol', 'trade_date'], ...}
```

`success=False` 且明確列出被違反的規則——Audit 端到端在 Glue 上正確運作，確認未知項 #1/#2/#3 全數解除。

**觀察到的重要現象（不是 bug，記錄下來供未來設計參考）**：六種髒資料 kind 裡，只有 4 種（`invalid_symbol`、`invalid_date`、部分 `empty_field`、`duplicate`）在 Audit 端出現違規；`negative_price` 與 `high_lt_low` 沒有出現，因為 `silver_stock.py` 既有的手寫 quality filter（第 85-95 行：null/負值/`high>=low`）在 Write 階段就已經把這兩種髒資料濾掉了，Audit 看到的 staging 資料裡本來就不含這兩種違規。這代表 Write 階段的手寫 filter 跟 GX 規則有重疊——這次不動它（範圍見上方「範圍限制」），但值得在未來 item 4 最終定案或 item 5 Publish 設計時一併考慮：既然 GX 已完整涵蓋這些規則，手寫 filter 是否該移除、只靠 GX 把關。

## 相關文件

- [docs/specs/slice1-quality-contract.md](../specs/slice1-quality-contract.md) §4 項目 4 / §8 — 這份 runbook 對應的實作項目與風險項
- [docs/runbooks/slice1-wap-verification.md](slice1-wap-verification.md) — WAP staging（Write 階段）的正式環境驗證，本文件延伸驗證下一步的 Audit 階段
- [docs/runbooks/generate-stock-data.md](generate-stock-data.md) — 髒資料產生方式與涵蓋的六種 kind
- [tests/quality/test_gx_spark_validation.py](../../tests/quality/test_gx_spark_validation.py) — 本機 GX + Spark 驗證（未知項 #2、#3 的本機證據）
- [tests/quality/test_build_expectation_suite.py](../../tests/quality/test_build_expectation_suite.py) — 同一份 Suite 定義在 pandas 引擎的驗證
