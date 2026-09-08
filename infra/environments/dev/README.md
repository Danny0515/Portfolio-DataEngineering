# dev 環境白話說明（Terraform 轉譯）

> 由 `explain-infra` skill 從同目錄 `.tf` 自動轉譯，讓不熟 SRE 的 Data Engineer 不用讀 HCL 也能確認基礎設施跟預期一致。**內容一律以 `.tf` 原始碼為準，不編造程式碼中未出現的設定**，每列附檔名行號供回查。
>
> 這是「原始碼意圖」的轉譯，不是部署現況——實際 resource ID／endpoint／密碼等 apply 後才產生的值，見 [ai/contexts/infra_dev.md](../../../ai/contexts/infra_dev.md)。

**最後轉譯**：2026-09-08
**來源**：`infra/environments/dev/*.tf`（8 個檔案）

## 這個環境在做什麼

這個環境是 Slice 0 的批次市場資料架構：一個 S3 bucket 同時作為 raw landing 區與 Iceberg lakehouse 倉儲，透過三個依序執行的 Glue ETL Job（Bronze 落地 → Silver 轉換與資料品質檢查 → Gold 月頻聚合）把股票市場資料逐層清洗，寫入依 Medallion 分層（bronze/silver/gold）建立的 Glue Data Catalog database。三個 Job 共用同一個 IAM 執行角色，存取權限由 IAM Policy 與 Lake Formation 授權共同把關——因為本帳號的 Glue Catalog 沒有退回舊版 IAM_ALLOWED_PRINCIPALS 模式，每個 principal 都需要明確的 Lake Formation grant。

## 目錄

- [檔案總覽與相依關係](#檔案總覽與相依關係)
- [`versions.tf` — Terraform 版本與 State 設定](#versions-tf)
- [`provider.tf` — AWS Provider 設定](#provider-tf)
- [`variables.tf` — 輸入變數](#variables-tf)
- [`s3.tf` — 資料湖 Bucket](#s3-tf)
- [`iam.tf` — Glue 執行角色與權限](#iam-tf)
- [`glue.tf` — Glue Catalog 與 ETL Job](#glue-tf)
- [`lakeformation.tf` — Lake Formation 授權](#lakeformation-tf)
- [`outputs.tf` — 部署後才知道的值](#outputs-tf)

## 檔案總覽與相依關係

| 檔案 | 一句話職責 | 依賴 | 被誰依賴 |
| --- | --- | --- | --- |
| `versions.tf` | Terraform／provider 版本鎖定與 S3 backend 設定 | — | — |
| `provider.tf` | AWS Provider 設定（region） | `variables.tf`（`var.aws_region`） | — |
| `variables.tf` | 定義 5 個輸入變數 | — | `provider.tf`、`s3.tf`、`iam.tf`、`glue.tf`、`lakeformation.tf`、`outputs.tf` |
| `s3.tf` | 資料湖 bucket：版本控制、加密、封鎖公開存取 | `variables.tf` | `iam.tf`、`glue.tf`、`outputs.tf` |
| `iam.tf` | Glue Job 共用執行角色與資料存取政策 | `s3.tf`、`variables.tf` | `glue.tf`、`lakeformation.tf`、`outputs.tf` |
| `glue.tf` | Medallion Glue Catalog database 與三個 Glue ETL Job | `s3.tf`、`iam.tf`、`variables.tf` | `outputs.tf` |
| `lakeformation.tf` | 對 Glue 執行角色補上 Database／Table 層級授權 | `iam.tf`、`variables.tf` | — |
| `outputs.tf` | 吐出 8 個部署後可用的值 | `s3.tf`、`iam.tf`、`glue.tf`、`variables.tf` | — |

<a id="versions-tf"></a>
## `versions.tf` — Terraform 版本與 State 設定

**一句話**：鎖定 Terraform 與 AWS provider 版本，並把 state 存進本專案自己的 S3 bucket，用 S3 原生 lockfile 機制取代舊式的 DynamoDB lock table。

| 資源 | 白話說明 | 關鍵設定 | 出處 |
| --- | --- | --- | --- |
| Terraform 版本鎖定 | 要求的 Terraform CLI 版本 | `>= 1.10` | [versions.tf:2](versions.tf#L2) |
| AWS Provider 版本鎖定 | 鎖定 `hashicorp/aws` provider 主版本 | `~> 5.0` | [versions.tf:4-9](versions.tf#L4-L9) |
| S3 backend | state 檔案存放位置與鎖定方式 | bucket `danny-data-engineering`、key `terraform-state/dev/slice0.tfstate`、`use_lockfile = true` | [versions.tf:11-16](versions.tf#L11-L16) |

**對 Data Engineer 的意義**

| 你會問 | 答案 |
| --- | --- |
| state 放哪？ | 跟 `s3.tf` 建立的資料湖 bucket 是同一個（`danny-data-engineering`），但 key 前綴是 `terraform-state/`，不會跟資料混在一起 |
| 需要額外建 DynamoDB lock table 嗎？ | 不需要，`use_lockfile = true` 用 S3 原生鎖定機制 |

<a id="provider-tf"></a>
## `provider.tf` — AWS Provider 設定

**一句話**：設定 AWS Provider 要部署到哪個 region，值直接來自 `var.aws_region`。

| 資源 | 白話說明 | 關鍵設定 | 出處 |
| --- | --- | --- | --- |
| AWS Provider | 決定所有資源預設部署的 region | `var.aws_region`（見 `variables.tf`，預設與 `terraform.tfvars` 皆為 `ap-northeast-1`） | [provider.tf:1-3](provider.tf#L1-L3) |

<a id="variables-tf"></a>
## `variables.tf` — 輸入變數

**一句話**：定義 5 個輸入變數，涵蓋 region、bucket 名稱、S3 key prefix、與 Medallion database 命名；其中 3 個被 `terraform.tfvars` 覆蓋（覆蓋值與預設值相同），另外 2 個維持預設值。

| 資源 | 白話說明 | 關鍵設定 | 出處 |
| --- | --- | --- | --- |
| `aws_region` | AWS region | 預設 `ap-northeast-1`；`terraform.tfvars` 同值 | [variables.tf:1-5](variables.tf#L1-L5) |
| `bucket_name` | 資料湖 bucket 名稱 | 預設 `danny-data-engineering`；`terraform.tfvars` 同值 | [variables.tf:7-11](variables.tf#L7-L11) |
| `raw_landing_prefix` | Raw landing 資料的 S3 key prefix | 預設 `raw/market/stock/`；`terraform.tfvars` 同值 | [variables.tf:13-17](variables.tf#L13-L17) |
| `iceberg_warehouse_prefix` | Iceberg warehouse（Bronze/Silver/Gold table 資料與 metadata）落地位置的 S3 key prefix | 預設 `lakehouse/`；`terraform.tfvars` 未覆蓋 | [variables.tf:19-23](variables.tf#L19-L23) |
| `glue_databases` | Medallion 分層對應的 Glue Data Catalog database 名稱清單 | 預設 `["bronze", "silver", "gold"]`；`terraform.tfvars` 未覆蓋 | [variables.tf:25-29](variables.tf#L25-L29) |

**對 Data Engineer 的意義**

| 你會問 | 答案 |
| --- | --- |
| 這個環境用哪個 region？哪個 bucket？ | `ap-northeast-1`／`danny-data-engineering`，`variables.tf` 與 `terraform.tfvars` 兩邊值一致 |
| 資料落在 bucket 裡的哪個路徑？ | Raw：`raw/market/stock/`；Iceberg lakehouse：`lakehouse/` |

<a id="s3-tf"></a>
## `s3.tf` — 資料湖 Bucket

**一句話**：建一個資料湖 bucket，同時扮演 raw landing 區與 Iceberg lakehouse 倉儲，開啟版本控制與加密，並封鎖所有公開存取。

### 1. 儲存空間與版本控制

- **Bucket 名稱**：`danny-data-engineering`（來自 `var.bucket_name`）
- **版本控制**：已啟用（Enabled），物件被覆寫或刪除時保留歷史版本

### 2. 安全與存取控制

- **加密方式**：預設 SSE-S3（`AES256`），未使用 KMS 客戶自管金鑰
- **公開存取阻擋**：四項 public access block 全部開啟（`block_public_acls`、`block_public_policy`、`ignore_public_acls`、`restrict_public_buckets`），完全禁止任何公開存取設定生效

**對照表（原始碼出處）**

| 主題 | 項目 | 資源 | 出處 |
| --- | --- | --- | --- |
| 儲存空間與版本控制 | Bucket 名稱 | `aws_s3_bucket.data_engineering` | [s3.tf:1-3](s3.tf#L1-L3) |
| 儲存空間與版本控制 | 版本控制 | `aws_s3_bucket_versioning.data_engineering` | [s3.tf:5-11](s3.tf#L5-L11) |
| 安全與存取控制 | 加密方式 | `aws_s3_bucket_server_side_encryption_configuration.data_engineering` | [s3.tf:13-21](s3.tf#L13-L21) |
| 安全與存取控制 | 公開存取阻擋 | `aws_s3_bucket_public_access_block.data_engineering` | [s3.tf:23-30](s3.tf#L23-L30) |

**對 Data Engineer 的意義**

| 你會問 | 答案 |
| --- | --- |
| 這個 bucket 可以設公開讀取嗎？ | 不行，四個 public access block 全開，即使之後想加公開 bucket policy 也會被擋下 |
| raw 跟 lakehouse 資料放同一個 bucket？ | 對，靠 key prefix（`raw/`、`lakehouse/`）區分，不是分開的 bucket |

<a id="iam-tf"></a>
## `iam.tf` — Glue 執行角色與權限

**一句話**：建一個 Glue Job 共用的執行角色，掛官方 Glue Service Role 政策，再疊加一份客製政策，只放行到本專案 S3 前綴與三個 Medallion database 的存取。

### 1. 執行角色與信任關係

- **角色名稱**：`glue-market-job-role`
- **信任對象**：僅 `glue.amazonaws.com` 服務可以 assume 這個角色
- **用途**：Bronze/Silver/Gold 三個 Glue Job（見 `glue.tf`）共用同一個角色，避免每層各自維護一份幾乎相同的權限政策

### 2. 資料存取權限範圍

- **官方政策**：掛載 AWS 官方受管政策 `AWSGlueServiceRole`（Glue 執行的基本權限）
- **S3 讀寫範圍**：只放行 `raw/*`、Iceberg warehouse prefix（`lakehouse/*`）、`glue-temp/*`、`glue-scripts/*` 四個路徑的 `GetObject`／`PutObject`／`DeleteObject`；`ListBucket` 也用 `s3:prefix` condition 限制在同樣四個路徑
- **Glue Catalog 權限範圍**：只放行 catalog 本身與 `bronze`／`silver`／`gold` 三個 database（含其下所有 table）的 database／table／partition 操作，不含刪除 database 或建立新 database 的權限

**對照表（原始碼出處）**

| 主題 | 項目 | 資源 | 出處 |
| --- | --- | --- | --- |
| 執行角色與信任關係 | 角色與信任政策 | `aws_iam_role.glue_market` | [iam.tf:6-21](iam.tf#L6-L21) |
| 執行角色與信任關係 | 官方政策掛載 | `aws_iam_role_policy_attachment.glue_service_role` | [iam.tf:23-26](iam.tf#L23-L26) |
| 資料存取權限範圍 | S3 讀寫/列表範圍 | `data.aws_iam_policy_document.glue_market_data_access`（前兩個 statement） | [iam.tf:28-63](iam.tf#L28-L63) |
| 資料存取權限範圍 | Glue Catalog 範圍 | `data.aws_iam_policy_document.glue_market_data_access`（GlueCatalogMedallionDatabases statement） | [iam.tf:64-94](iam.tf#L64-L94) |
| 資料存取權限範圍 | 客製政策掛載 | `aws_iam_policy.glue_market_data_access`／`aws_iam_role_policy_attachment.glue_market_data_access` | [iam.tf:97-105](iam.tf#L97-L105) |

**對 Data Engineer 的意義**

| 你會問 | 答案 |
| --- | --- |
| Glue Job 可以讀寫 bucket 裡的任何路徑嗎？ | 不行，只有 `raw/`、`lakehouse/`、`glue-temp/`、`glue-scripts/` 四個路徑；其他路徑會被拒絕 |
| 這個角色可以自己建新的 Glue database 嗎？ | 不行，Catalog 權限只涵蓋 `bronze`／`silver`／`gold` 三個既有 database，沒有 `glue:CreateDatabase` |
| IAM policy 都放行了，為什麼 Glue Job 還是可能報權限錯誤？ | 本帳號的 Glue Catalog 需要額外的 Lake Formation 授權，IAM policy 不是唯一關卡，見 `lakeformation.tf` |

<a id="glue-tf"></a>
## `glue.tf` — Glue Catalog 與 ETL Job

**一句話**：建立 Medallion 三層的 Glue Catalog database，再串三個 Glue ETL Job（Bronze 落地 → Silver 轉換與資料品質檢查 → Gold 月頻聚合），全部讀寫同一個 bucket 裡的 Iceberg table。

### 1. Glue Catalog database 與 Medallion 分層

- **Database 數量與命名**：依 `var.glue_databases`（`bronze`／`silver`／`gold`）建立 3 個 Glue Catalog database，逐一對應 Medallion 分層
- **Location 刻意留白**：不設定 `location_uri`——Iceberg table 的實際 S3 位置是由 Glue Job 的 Spark catalog `warehouse` 設定決定（見下方主題 3），設在這裡只是裝飾性，還可能誤導讀者以為它控制資料落地位置

### 2. Job 執行規格

- **共用規格**：三個 Job（`slice0-bronze-stock`／`slice0-silver-stock`／`slice0-gold-monthly-ohlcv`）都用 Glue 5.0、`G.1X` worker、2 個 worker、逾時 10 分鐘、`max_retries = 0`（失敗不自動重試）
- **執行角色**：三個 Job 共用 `iam.tf` 定義的 `glue_market` 角色

### 3. Iceberg 目錄設定與資料流

- **Iceberg 啟用方式**：`--datalake-formats=iceberg` 搭配一組 Spark `--conf`（`IcebergSparkSessionExtensions`、`SparkCatalog`、Glue Catalog 整合、`S3FileIO`），warehouse 指向 `s3://danny-data-engineering/lakehouse/`
- **三層資料流**：
  - Bronze 讀 `raw/market/stock/`（`RAW_INPUT_PATH`）寫入 `bronze.stock`
  - Silver 讀 `bronze.stock`（`SOURCE_DB`/`SOURCE_TABLE`）寫入 `silver.stock`，並額外安裝 `great-expectations==1.19.1` 套件、掛載 Silver 的 Expectation Suite JSON 做資料品質檢查
  - Gold 讀 `silver.stock` 寫入 `gold.monthly_ohlcv`
- **監控**：三個 Job 都開啟 `--enable-continuous-cloudwatch-log` 與 `--enable-metrics`

### 4. 部署方式（Script 上傳與版本追蹤）

- **Script 來源**：三支轉換腳本（`bronze_stock.py`／`silver_stock.py`／`gold_monthly_ohlcv.py`）與 Silver 的 GX Expectation Suite JSON，皆從專案原始碼目錄（`src/transform/`、`src/quality/gx/expectations/`）上傳到 S3 的 `glue-scripts/` 前綴
- **變更偵測**：用 `filemd5()` 算 `etag`，程式碼內容變了就會觸發 Terraform 重新上傳，不需手動比對版本

**對照表（原始碼出處）**

| 主題 | 項目 | 資源 | 出處 |
| --- | --- | --- | --- |
| Glue Catalog database 與 Medallion 分層 | Database 建立 | `aws_glue_catalog_database.medallion` | [glue.tf:1-11](glue.tf#L1-L11) |
| Job 執行規格 | Bronze Job 規格 | `aws_glue_job.bronze_stock` | [glue.tf:59-86](glue.tf#L59-L86) |
| Job 執行規格 | Silver Job 規格 | `aws_glue_job.silver_stock` | [glue.tf:88-120](glue.tf#L88-L120) |
| Job 執行規格 | Gold Job 規格 | `aws_glue_job.gold_monthly_ohlcv` | [glue.tf:122-150](glue.tf#L122-L150) |
| Iceberg 目錄設定與資料流 | Iceberg Spark 設定 | `local.iceberg_spark_conf`／`local.iceberg_warehouse_s3_uri` | [glue.tf:44-57](glue.tf#L44-L57) |
| Iceberg 目錄設定與資料流 | 資料品質檢查套件與 Suite | Silver Job 的 `--additional-python-modules`／`--extra-files` | [glue.tf:115-118](glue.tf#L115-L118) |
| 部署方式 | Script 上傳與 etag | `aws_s3_object.bronze_script`／`silver_script`／`silver_stock_suite`／`gold_script` | [glue.tf:13-42](glue.tf#L13-L42) |

**對 Data Engineer 的意義**

| 你會問 | 答案 |
| --- | --- |
| Job 失敗會自動重試嗎？ | 不會，`max_retries = 0`，失敗要手動重跑 |
| 資料品質檢查在哪一層做？ | Silver Job，用 Great Expectations，Suite 定義在 `silver_stock_suite.json` |
| 改了 `bronze_stock.py` 要手動重新上傳嗎？ | 不用，`etag = filemd5(...)` 會偵測內容變更，`terraform apply` 自動重傳 |

**⚠️ 注意 / 限制**

- Glue database 的 `description` 目前寫死為 `"danny-test"`，不是描述性文字（[glue.tf:5](glue.tf#L5)）

<a id="lakeformation-tf"></a>
## `lakeformation.tf` — Lake Formation 授權

**一句話**：因為本帳號的 Glue Catalog 不會自動退回舊版 IAM_ALLOWED_PRINCIPALS 模式，這裡另外對 Glue 執行角色補一組 Lake Formation 授權，涵蓋三個 Medallion database 與其下所有 table。

### 1. Database 與 Table 授權範圍

- **Database 層級**：對 `bronze`／`silver`／`gold` 三個 database，給予 `glue_market` 角色 `DESCRIBE`、`CREATE_TABLE` 權限
- **Table 層級**：用 database 萬用字元（`wildcard = true`）授予 `DESCRIBE`、`SELECT`、`INSERT`、`ALTER`、`DROP`，涵蓋目前還不存在的 table（例如 `bronze.stock` 第一次 `CREATE TABLE` 時），因為本專案讓 Iceberg 動態建表，Terraform 不逐一管理 table 資源

**對照表（原始碼出處）**

| 主題 | 項目 | 資源 | 出處 |
| --- | --- | --- | --- |
| Database 與 Table 授權範圍 | Database 層級授權 | `aws_lakeformation_permissions.glue_market_database` | [lakeformation.tf:10-19](lakeformation.tf#L10-L19) |
| Database 與 Table 授權範圍 | Table 層級授權 | `aws_lakeformation_permissions.glue_market_tables` | [lakeformation.tf:25-35](lakeformation.tf#L25-L35) |

**對 Data Engineer 的意義**

| 你會問 | 答案 |
| --- | --- |
| IAM policy 都放行了，為什麼 Glue Job 還是報 Lake Formation 權限錯誤？ | 這個帳號的 Glue Catalog 沒有繼承舊版 IAM_ALLOWED_PRINCIPALS，新建的 database 一律需要獨立的 Lake Formation grant，這份檔案就是在補這一塊 |
| 這裡有幫「總架構師帳號」設定權限嗎？ | 沒有，該帳號的權限由組織層級的 Lake Formation Data Lake Admin 身分治理，刻意不寫進本專案 Terraform（見 ADR-0005） |

**⚠️ 注意 / 限制**

- 這個帳號的 `CreateDatabaseDefaultPermissions`／`CreateTableDefaultPermissions` 皆為空（已用 `aws lakeformation get-data-lake-settings` 確認），這是本檔案存在的根本原因——若不是這個設定，原則上不需要這份額外授權
- 總架構師帳號（chief-architect account）刻意不在此宣告：曾嘗試明確授權給該帳號，但 Lake Formation 對 Data Lake Admin 的自我授權行為，會把任何自我授予的權限自動升級為 `ALL` 加上更廣的 grant-option，導致 `terraform plan` 永遠無法收斂到穩定狀態；因此該帳號的權限完全交由組織層級治理，不進版控（避免把真實人員 email 寫進 `.tf`），詳見 ADR-0005

<a id="outputs-tf"></a>
## `outputs.tf` — 部署後才知道的值

**一句話**：吐出 8 個部署後可用的值，涵蓋 bucket 名稱、S3 路徑、Glue database 清單、IAM 角色 ARN、與三個 Glue Job 名稱，供驗證與後續操作（如 `aws glue start-job-run`）使用。

| 資源 | 白話說明 | 關鍵設定 | 出處 |
| --- | --- | --- | --- |
| `bucket_name` | 資料湖 bucket 名稱 | 直接回傳 `aws_s3_bucket.data_engineering.id` | [outputs.tf:1-4](outputs.tf#L1-L4) |
| `raw_landing_s3_uri`／`iceberg_warehouse_s3_uri`（2 個） | Raw landing 與 Iceberg warehouse 的完整 S3 URI | 組合 bucket id 與對應 prefix 變數 | [outputs.tf:6-14](outputs.tf#L6-L14) |
| `glue_databases` | 已建立的 Glue database 名稱清單 | `for` 迴圈取 `aws_glue_catalog_database.medallion` 的 `name` | [outputs.tf:16-19](outputs.tf#L16-L19) |
| `glue_execution_role_arn` | Medallion Glue Job 共用執行角色 ARN | `aws_iam_role.glue_market.arn` | [outputs.tf:21-24](outputs.tf#L21-L24) |
| `glue_bronze_job_name`／`glue_silver_job_name`／`glue_gold_job_name`（3 個） | 三個 Glue Job 名稱，供手動觸發 | 各自對應 `aws_glue_job.*.name` | [outputs.tf:26-39](outputs.tf#L26-L39) |

**對 Data Engineer 的意義**

| 你會問 | 答案 |
| --- | --- |
| 怎麼手動觸發某一層的轉換？ | `aws glue start-job-run --job-name <對應 output 的值>`（`glue_bronze_job_name`／`glue_silver_job_name`／`glue_gold_job_name`） |
| 資料實際的 S3 完整路徑？ | 看 `raw_landing_s3_uri`／`iceberg_warehouse_s3_uri` 兩個 output |
