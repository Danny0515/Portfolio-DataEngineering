# dev-slice2 環境白話說明（Terraform 轉譯）

> 由 `explain-infra` skill 從同目錄 `.tf` 自動轉譯，讓不熟 SRE 的 Data Engineer 不用讀 HCL 也能確認基礎設施跟預期一致。**內容一律以 `.tf` 原始碼為準，不編造程式碼中未出現的設定**，每列附檔名行號供回查。
>
> 這是「原始碼意圖」的轉譯，不是部署現況——實際 resource ID／endpoint／密碼等 apply 後才產生的值，見 [ai/contexts/infra_dev_slice2.md](../../../ai/contexts/infra_dev_slice2.md)。

**最後轉譯**：2026-09-15
**來源**：`infra/environments/dev-slice2/*.tf`（12 個檔案）

## 這個環境在做什麼

這組資源架起 Slice 2a 的 CDC（Change Data Capture，異動資料擷取）擷取管線：私有 VPC 網路地基上，跑一個模擬交易系統的 RDS Postgres（由 Lambda generator 驅動 NEW→PARTIALLY_FILLED→FILLED／CANCELLED 狀態機），搭配 MSK Kafka 叢集與 Glue Schema Registry 定義事件契約。Debezium（透過 MSK Connect）持續監看 Postgres 的 WAL（Write-Ahead Log，預寫日誌），把每一筆 insert/update/delete 轉成帶 before/after 影像的 Avro 事件送進 Kafka topic，違反 Schema 相容性或無法序列化的訊息則轉進 DLQ topic 而不擋住主流程。另一支驗證用 Lambda 負責消費並解碼這些事件，供人工確認管線行為正確。`msk_connect_plugin.tf` 是項目 6 的歷史 spike，其打包出的兩個 plugin 不被實際 connector 引用，只留作打包驗證的證據。

## 目錄

- [檔案總覽與相依關係](#檔案總覽與相依關係)
- [`versions.tf` — 版本鎖定](#versions-tf)
- [`provider.tf` — AWS Provider 設定](#provider-tf)
- [`variables.tf` — 輸入變數](#variables-tf)
- [`vpc.tf` — 網路地基](#vpc-tf)
- [`rds.tf` — 來源 OLTP DB](#rds-tf)
- [`lambda.tf` — 交易資料 generator](#lambda-tf)
- [`msk.tf` — Kafka 叢集](#msk-tf)
- [`schema_registry.tf` — Schema Registry](#schema_registry-tf)
- [`msk_connect_plugin.tf` — Plugin 打包 spike](#msk_connect_plugin-tf)
- [`msk_connector.tf` — CDC Connector 部署](#msk_connector-tf)
- [`msk_event_verifier.tf` — CDC 事件驗證 Lambda](#msk_event_verifier-tf)
- [`outputs.tf` — 部署後才知道的值](#outputs-tf)

## 檔案總覽與相依關係

| 檔案 | 一句話職責 | 依賴 | 被誰依賴 |
| --- | --- | --- | --- |
| `versions.tf` | 鎖定 Terraform／provider 版本、S3 backend 設定 | — | 全部（間接） |
| `provider.tf` | AWS provider 的 region 設定 | `variables.tf` | 全部（間接） |
| `variables.tf` | 輸入變數：region、私有子網 CIDR | — | 全部（間接） |
| `vpc.tf` | 網路地基：私有子網、路由、防火牆、VPC Endpoint | — | `rds.tf`、`lambda.tf`、`msk.tf`、`msk_connector.tf`、`msk_event_verifier.tf` |
| `rds.tf` | 來源 OLTP DB：RDS PostgreSQL + logical replication | `vpc.tf` | `lambda.tf`、`msk_connector.tf` |
| `lambda.tf` | 交易資料 generator（模擬交易狀態機寫入來源表） | `vpc.tf`、`rds.tf` | — |
| `msk.tf` | Kafka 叢集本體 | `vpc.tf` | `msk_connector.tf`、`msk_event_verifier.tf` |
| `schema_registry.tf` | Glue Schema Registry 與測試用 schema | — | `msk_connector.tf`、`msk_event_verifier.tf` |
| `msk_connect_plugin.tf` | 項目 6 歷史 spike：Debezium／converter 各自打包驗證 | — | `msk_connector.tf`（共用 S3 bucket） |
| `msk_connector.tf` | 合併版 plugin 打包 + Debezium CDC connector 部署 | `vpc.tf`、`rds.tf`、`msk.tf`、`schema_registry.tf`、`msk_connect_plugin.tf` | — |
| `msk_event_verifier.tf` | 驗證用 Lambda：消費並解碼 CDC／DLQ 事件 | `vpc.tf`、`msk.tf`、`schema_registry.tf` | — |
| `outputs.tf` | 部署後才知道的值（ID／ARN／endpoint） | 全部 | — |

<a id="versions-tf"></a>
## `versions.tf` — 版本鎖定

**總結**：鎖定 Terraform ≥1.10、AWS provider 5.x 系列、random／archive provider，state 存在 S3（跟 `dev` 環境共用 bucket、獨立 key，依 §3.3(b) 用完即拆的切分策略）。

| 資源 | 白話說明 | 關鍵設定 | 出處 |
| --- | --- | --- | --- |
| Terraform 版本 | 最低需要 1.10 | `required_version = ">= 1.10"` | [versions.tf:2](versions.tf#L2) |
| AWS provider | 5.x 系列 | `hashicorp/aws ~> 5.0` | [versions.tf:5-8](versions.tf#L5-L8) |
| random／archive provider | 產生密碼、打包 zip 用 | `hashicorp/random ~> 3.6`、`hashicorp/archive ~> 2.4` | [versions.tf:9-16](versions.tf#L9-L16) |
| State 後端 | S3，跟 `dev` 環境共用 bucket、獨立 key，避免 destroy 互相影響 | `s3://danny-data-engineering/terraform-state/dev/slice2.tfstate` | [versions.tf:19-24](versions.tf#L19-L24) |

<a id="provider-tf"></a>
## `provider.tf` — AWS Provider 設定

**總結**：AWS provider 的 region 完全交給 `var.aws_region`（預設 `ap-northeast-1`），沒有其他設定。

| 資源 | 白話說明 | 關鍵設定 | 出處 |
| --- | --- | --- | --- |
| AWS provider | region 由變數決定，不寫死 | `region = var.aws_region` | [provider.tf:2](provider.tf#L2) |

<a id="variables-tf"></a>
## `variables.tf` — 輸入變數

**總結**：2 個變數——region 與私有子網 CIDR；子網固定用 `a`／`c` 兩個 AZ（這個帳號在 `ap-northeast-1` 沒有 `b`，實測得知）。

| 資源 | 白話說明 | 關鍵設定 | 出處 |
| --- | --- | --- | --- |
| `aws_region` | 部署 region，預設 `ap-northeast-1` | 可覆寫 | [variables.tf:1-5](variables.tf#L1-L5) |
| `private_subnet_cidrs` | 私有子網 CIDR，key 為 AZ 代碼後綴 | 固定 `a="10.20.1.0/24"`、`c="10.20.2.0/24"`——RDS 跟 MSK 都要求至少 2 個 AZ，這個帳號在 `ap-northeast-1` 沒有 `b` 可用（實測得知） | [variables.tf:7-14](variables.tf#L7-L14) |

<a id="vpc-tf"></a>
## `vpc.tf` — 網路地基

**總結**：一個獨立的私有 VPC，沒有對外網路（沒有 IGW/NAT），所有資源只能透過 VPC Endpoint 或彼此直連互通，存取控制完全交給一個共用的 Security Group。

### 1. 網路範圍與子網配置

- **VPC 網段**：`10.20.0.0/16`，開啟 DNS 支援與 DNS 主機名稱解析
- **私有子網**：橫跨 `ap-northeast-1a`／`1c` 兩個可用區（`10.20.1.0/24`／`10.20.2.0/24`），這個帳號在此 region 沒有 `1b` 可用（實測得知，見 `variables.tf`）——RDS 的 DB Subnet Group 與 MSK Provisioned 的 broker 佈署都要求至少 2 個 AZ
- **路由**：一張私有路由表，兩個子網都掛上；沒有對外路由（沒有 Internet Gateway／NAT Gateway）

### 2. 對外連線能力（路由與 VPC Endpoint）

- **S3**：Gateway 型 VPC Endpoint，免費，直接掛在路由表上生效——generator／驗證 Lambda 部署包若需要讀 S3 會走這條路
- **CloudWatch Logs**：Interface 型 VPC Endpoint——VPC 內的 Lambda 若沒有這個 endpoint，執行紀錄完全看不到（沒有 IGW/NAT 就連不到 CloudWatch Logs 的公開端點）
- **Glue**：Interface 型 VPC Endpoint——供 Schema Registry 相關 API 呼叫使用
- Interface 型 endpoint 跟 S3 的 Gateway 型不同機制：需要佔用子網 IP、掛 Security Group，且持續計費

### 3. 內部防火牆規則（Security Group）

- **`slice2_internal`**：RDS／MSK／MSK Connect／驗證 Lambda 共用的唯一內部 Security Group，用 self-referencing 規則（同一個 SG 成員互放行）取代逐一開放個別來源
  - 放行 443（給 Interface VPC Endpoint 存取）
  - 放行 5432（Postgres，給 generator Lambda 連 RDS）
  - 放行 9094（Kafka TLS broker 埠，給 MSK Connect／驗證用 Kafka client 連 broker）
  - 出站規則全開，但因為沒有 IGW/NAT，實際上只能到達 VPC Endpoint 或 VPC 內的其他資源

**對 Data Engineer 的意義**

| 你會問 | 答案 |
| --- | --- |
| 我要新增一個需要連 RDS/MSK 的 Lambda，要開新的 SG 規則嗎？ | 不用，把它掛進 `slice2_internal` 這個共用 SG 就自動放行 |
| 本機可以直接連進這個 VPC 嗎？ | 不行，沒有 IGW/NAT/bastion peering，所有互動都要透過部署在 VPC 內的 Lambda（走 Lambda 公開 API 觸發） |

**對照表（原始碼出處）**

| 主題 | 項目 | 資源 | 出處 |
| --- | --- | --- | --- |
| 網路範圍與子網配置 | VPC 網段、DNS 設定 | `aws_vpc.slice2` | [vpc.tf:3-7](vpc.tf#L3-L7) |
| 網路範圍與子網配置 | 私有子網、路由表 | `aws_subnet.private`、`aws_route_table.private` | [vpc.tf:9-24](vpc.tf#L9-L24) |
| 對外連線能力 | S3 Gateway Endpoint | `aws_vpc_endpoint.s3` | [vpc.tf:27-32](vpc.tf#L27-L32) |
| 對外連線能力 | Glue／Logs Interface Endpoint | `aws_vpc_endpoint.glue`、`aws_vpc_endpoint.logs` | [vpc.tf:80-98](vpc.tf#L80-L98) |
| 內部防火牆規則 | 共用 Security Group 與三條 ingress／一條 egress | `aws_security_group.slice2_internal` | [vpc.tf:37-77](vpc.tf#L37-L77) |

<a id="rds-tf"></a>
## `rds.tf` — 來源 OLTP DB

**總結**：一個開了 logical replication 的最小規格 RDS PostgreSQL，扮演 Debezium CDC 擷取的來源系統，密碼直接產生、寫進環境變數，不透過 Secrets Manager。

### 1. 規格與儲存

- **引擎版本**：PostgreSQL 16
- **規格**：`db.t4g.micro`（最小可用規格，cost-conscious lab 環境）
- **儲存**：20GB gp3

### 2. CDC／複寫設定

- **Logical Replication**：透過專屬 parameter group（`slice2-trade-pg16`）開啟 `rds.logical_replication=1`——這是 Debezium CDC 擷取的前提；因為 instance 建立當下就掛上這個 parameter group，不會遇到「改參數要重開機」的問題

### 3. 安全與存取控制

- **網路**：不開放公開存取（`publicly_accessible=false`），只掛在 `slice2_internal` 這個共用 Security Group 底下，透過 5432 埠的 self-referencing 規則放行同組成員
- **密碼管理**：主密碼由 `random_password` 產生，直接寫進 RDS 與 generator Lambda 的環境變數，不透過 Secrets Manager——因為 Lambda 要讀 Secrets Manager 一樣需要對應的 VPC Endpoint，對這個 lab/demo 環境不值得多開一個常駐計費資源

### 4. 生命週期策略（用完即拆）

- **不做高可用**：`multi_az=false`，依 §3.3(b) 用完即拆策略，不做 HA
- **不保留最終快照**：`skip_final_snapshot=true`、`deletion_protection=false`——RDS 是 generator 可重現的輸入資料而非證明成果，刪除不等於燒掉證據

**對 Data Engineer 的意義**

| 你會問 | 答案 |
| --- | --- |
| 密碼在哪裡拿？ | 部署後才決定的隨機值，直接寫進 `aws_lambda_function.trade_generator` 的環境變數，不查 Secrets Manager |
| 這個 DB 可以直接用 psql 連嗎？ | 不行，沒有對外網路，只能透過 VPC 內的 Lambda 存取 |

**對照表（原始碼出處）**

| 主題 | 項目 | 資源 | 出處 |
| --- | --- | --- | --- |
| 規格與儲存 | 引擎、規格、儲存 | `aws_db_instance.trade` | [rds.tf:31-53](rds.tf#L31-L53) |
| CDC／複寫設定 | logical replication | `aws_db_parameter_group.trade` | [rds.tf:17-29](rds.tf#L17-L29) |
| 安全與存取控制 | 密碼產生、SG | `random_password.trade_db`、`aws_db_instance.trade.vpc_security_group_ids` | [rds.tf:7-10](rds.tf#L7-L10), [rds.tf:45](rds.tf#L45) |
| 生命週期策略 | multi_az／快照／刪除保護 | `aws_db_instance.trade` | [rds.tf:49-52](rds.tf#L49-L52) |

<a id="lambda-tf"></a>
## `lambda.tf` — 交易資料 generator

**總結**：一支跑在 VPC 內的 Lambda，模擬交易訂單狀態機、對來源 RDS 表做 insert/update/delete，是整條 CDC 管線的「源頭活水」。

### 1. 執行環境規格

- **Runtime**：Python 3.12
- **Timeout**：300 秒（迴圈式多次 DB 呼叫，逐筆交易之間可插入延遲）
- **記憶體**：256MB

### 2. 網路與身分權限

- **VPC 部署**：掛在兩個私有子網＋`slice2_internal` 共用 SG——因為 RDS 在私有子網（無 IGW/NAT），本機沒有路徑直接連進去，Lambda 掛在同一個 VPC/SG 裡才連得到
- **IAM**：只掛 AWS 受管政策 `AWSLambdaVPCAccessExecutionRole`（含基本執行權限＋VPC ENI 管理權限），沒有額外自訂政策
- **觸發方式**：本機透過 `aws lambda invoke` 觸發，走 Lambda 的公開 API，不需要 bastion／peering／SSM

### 3. 部署流程與資料流

- **打包**：純 Python 的 `pg8000`（不需要跨平台編譯的 C 擴充套件）直接 `pip install` 進部署目錄，來源碼與 SQL 檔一併打包成 zip
- **環境變數**：DB 連線資訊（host／port／name／user／password）全部來自 `aws_db_instance.trade` 與 `random_password.trade_db`，沒有寫死任何值

**對 Data Engineer 的意義**

| 你會問 | 答案 |
| --- | --- |
| 怎麼觸發這個 generator？ | `aws lambda invoke --function-name slice2-trade-generator --payload '{...}'`，不需要額外網路設定 |
| 部署包多大、有沒有跨平台編譯風險？ | 沒有，`pg8000` 是純 Python，不像 `aws-glue-schema-registry`（見 `msk_event_verifier.tf`）那樣有編譯依賴 |

**對照表（原始碼出處）**

| 主題 | 項目 | 資源 | 出處 |
| --- | --- | --- | --- |
| 執行環境規格 | runtime／timeout／記憶體 | `aws_lambda_function.trade_generator` | [lambda.tf:61-91](lambda.tf#L61-L91) |
| 網路與身分權限 | VPC config、IAM role | `aws_lambda_function.trade_generator.vpc_config`、`aws_iam_role.trade_generator` | [lambda.tf:49-59](lambda.tf#L49-L59), [lambda.tf:72-75](lambda.tf#L72-L75) |
| 部署流程與資料流 | 打包腳本、環境變數 | `null_resource.build_trade_generator`、`data.archive_file.trade_generator` | [lambda.tf:15-37](lambda.tf#L15-L37), [lambda.tf:77-85](lambda.tf#L77-L85) |

<a id="msk-tf"></a>
## `msk.tf` — Kafka 叢集

**總結**：開一組 2 台機器的 Provisioned Kafka 叢集，只收 TLS 加密連線，關在私有子網裡，靠 Security Group 而不是帳號密碼來擋人；topic 刻意不由 Terraform 建立，留給 MSK Connect 第一次寫入時自動產生。

### 1. 叢集規模與硬體規格

- **Kafka 版本**：3.9.x（AWS MSK 官方文件目前標示的 Recommended 版本，尚無 end-of-support 日期；3.6.0／3.7.x 已過或即將過保護期，故不選）
- **Broker 數量與規格**：2 個 broker 節點，對應 2 個私有子網/AZ，規格為低成本的 `kafka.t3.small`
- **儲存空間**：每個 broker 配置 20GB gp3（比照 `rds.tf` 的儲存量級）

### 2. 資安與存取控制

- **傳輸加密**：只開 TLS 加密埠（9094），不開未加密的 PLAINTEXT 埠（9092）；叢集內部 broker 間傳輸也強制加密
- **身分驗證**：`unauthenticated`，不採用 SASL 或 IAM 簽章——存取控制完全交給 `vpc.tf` 的 Security Group，跟 `rds.tf` 保護 RDS 的哲學一致，也避免 `msk_connector.tf` 設定 connector 時要多處理一層 IAM 簽章

### 3. Kafka 行為與 Topic 邏輯設定

- **自動建立 Topic**：`auto.create.topics.enable=true`——`transaction.trade.v1`／`transaction.trade.v1.dlq` 兩個 topic 刻意不由 Terraform 管理，延後到 `msk_connector.tf` 的 Debezium connector 第一次寫入時自動建立
- **副本容錯機制**：自動建立的 topic 預設副本數 2（對應 2 台 broker 各一份）；最低同步副本數設為 1，demo 用途刻意寬鬆，一台 broker 掛掉仍可寫入

**對 Data Engineer 的意義**

| 你會問 | 答案 |
| --- | --- |
| producer／consumer 要連哪個 port？ | 9094（TLS）。bootstrap 位址部署後才決定，見 infra 快照 |
| 要先手動建 topic 嗎？ | 不用，broker 開了 `auto.create.topics.enable=true` |

**對照表（原始碼出處）**

| 主題 | 項目 | 資源 | 出處 |
| --- | --- | --- | --- |
| 叢集規模與硬體規格 | Kafka 版本 | `local.msk_kafka_version` | [msk.tf:18](msk.tf#L18) |
| 叢集規模與硬體規格 | Broker 規格、儲存、網路部署 | `aws_msk_cluster.trade` | [msk.tf:36-51](msk.tf#L36-L51) |
| 資安與存取控制 | 身分驗證 | `client_authentication` | [msk.tf:53-55](msk.tf#L53-L55) |
| 資安與存取控制 | 傳輸加密 | `encryption_info` | [msk.tf:59-64](msk.tf#L59-L64) |
| Kafka 行為與 Topic 邏輯設定 | 自動建立 Topic、副本容錯機制 | `aws_msk_configuration.trade` | [msk.tf:21-34](msk.tf#L21-L34) |

<a id="schema_registry-tf"></a>
## `schema_registry.tf` — Schema Registry

**總結**：建立 Glue Schema Registry 與一個「攤平版」的 `trade_events` schema——這不是 Debezium 真正送出的 CDC envelope 格式，而是項目 9（破壞性變更驗證）刻意預留、不被真實流量使用的測試對象。

### 1. Schema 格式與欄位定義

- **格式**：Avro，採用攤平的 trade 資料列形狀（對應 `src/ingestion/sql/create_trade_table.sql` 的欄位），不是 Debezium CDC envelope（`before`/`after`/`source`/`op`/`ts_ms` 那層包裝）——因為 Debezium 實際輸出的 envelope 形狀要等 plugin 打包與 connector 部署才會定案，現在猜測容易猜錯
- **必填欄位**：`trade_id`／`account_id`／`symbol`／`side`／`status`／`event_time`（無 null union）——直接對應 §6 完整性規則
- **可選欄位**：`price`／`quantity`／`updated_at`（nullable，預設 `null`）

### 2. 相容性策略與治理規則

- **相容性模式**：`BACKWARD`——允許刪除欄位、允許新增有 default 值的欄位；禁止新增沒有 default 值的必填欄位（這正是項目 9 拿來測試 Registry 有沒有正常擋下違規的案例）
- **用途定位**：這個 schema 刻意不被真實 Debezium 流量使用，是項目 5/6 手動註冊、專門留給項目 9 直接對 Registry API 測試相容性檢查機制的測試對象——不需要等 connector 真的跑起來才能驗證這條驗收標準

**⚠️ 注意 / 限制**

- 若未來 connector 被明確設定成用固定 schema 名稱 `trade_events`（而非預設的 topic-based 命名策略），可能會跟這裡的 `schema_name="trade_events"` 撞名，導致第一筆真實訊息就被 `BACKWARD` 規則擋下；目前 `msk_connector.tf` 用的是預設命名策略，實測會另外註冊成獨立的 `transaction.trade.v1` schema，不會撞名

**對照表（原始碼出處）**

| 主題 | 項目 | 資源 | 出處 |
| --- | --- | --- | --- |
| Schema 格式與欄位定義 | Registry、schema 本體與欄位 | `aws_glue_registry.trade_events`、`aws_glue_schema.trade_events` | [schema_registry.tf:24-74](schema_registry.tf#L24-L74) |
| 相容性策略與治理規則 | 相容性模式 | `compatibility = "BACKWARD"` | [schema_registry.tf:33](schema_registry.tf#L33) |

<a id="msk_connect_plugin-tf"></a>
## `msk_connect_plugin.tf` — Plugin 打包 spike

**總結**：項目 6 的歷史 spike——分別把 Debezium 本體與 Glue Schema Registry converter 各自打包成獨立 custom plugin，驗證「zip 打包 → S3 → MSK Connect 能否建到 ACTIVE」這條路徑；這兩個 plugin 最終**不會**被真正的 connector 引用，只作為歷史證據保留。

### 1. 打包來源與內容

- **Debezium plugin**：從 Maven Central 下載 `debezium-connector-postgres` 3.1.1.Final 的 `-plugin` classifier tar.gz（已實測確認是自帶完整依賴的自包含 bundle，解壓後是單一目錄、5 個 jar，不需要另外湊依賴）
- **Glue Schema Registry converter plugin**：下載 `schema-registry-kafkaconnect-converter` 1.1.25 的 jar（已用 `curl --head` 實測確認檔案大小 67MB，加上其 pom 綁定 `maven-shade-plugin`，強烈推論是自帶依賴的 uber jar）

### 2. 儲存與 MSK Connect 註冊

- **S3 bucket**：專屬 bucket `danny-data-engineering-slice2-msk-connect`（刻意不跨 state 借用 `dev` 環境既有 bucket，避免兩個 state 的 destroy 互相顧慮），封鎖所有公開存取
- **Custom Plugin**：兩個各自獨立的 `aws_mskconnect_custom_plugin`（Debezium 本體、converter）

### 3. 範圍界線與生命週期

- **不建立 connector**：這裡只驗證 plugin 能否打包成功並建到 `ACTIVE`，VPC 連線／IAM 授權這些未知數留給 `msk_connector.tf`（項目 7）處理
- **不會被實際流量使用**：這兩個 plugin 原本設計成分開打包（誤以為 `CreateConnector` API 接受多個 plugin 清單），後來查證官方文件才發現 MSK Connect 一個 connector 只能掛一個 plugin——`msk_connector.tf` 因此另外合併打包了第三個 plugin 供 connector 實際使用，這裡兩個保留下來只作為「各元件個別能打包成功」的歷史 spike 證據，不刪除

**對照表（原始碼出處）**

| 主題 | 項目 | 資源 | 出處 |
| --- | --- | --- | --- |
| 打包來源與內容 | Debezium 下載與解壓 | `null_resource.build_debezium_postgres_plugin` | [msk_connect_plugin.tf:45-61](msk_connect_plugin.tf#L45-L61) |
| 打包來源與內容 | Converter jar 下載 | `null_resource.build_glue_schema_registry_converter_plugin` | [msk_connect_plugin.tf:94-108](msk_connect_plugin.tf#L94-L108) |
| 儲存與 MSK Connect 註冊 | S3 bucket | `aws_s3_bucket.msk_connect_plugins` | [msk_connect_plugin.tf:30-41](msk_connect_plugin.tf#L30-L41) |
| 儲存與 MSK Connect 註冊 | 兩個 custom plugin | `aws_mskconnect_custom_plugin.debezium_postgres`、`aws_mskconnect_custom_plugin.glue_schema_registry_converter` | [msk_connect_plugin.tf:77-87](msk_connect_plugin.tf#L77-L87), [msk_connect_plugin.tf:127-137](msk_connect_plugin.tf#L127-L137) |
| 範圍界線與生命週期 | 不建 connector、歷史證據定位 | 檔頭註解 | [msk_connect_plugin.tf:1-18](msk_connect_plugin.tf#L1-L18) |

<a id="msk_connector-tf"></a>
## `msk_connector.tf` — CDC Connector 部署

**總結**：真正在跑的 Debezium PostgreSQL connector——合併打包 Debezium 本體與 Glue Schema Registry converter 成單一 zip（修正項目 6 誤判「一個 connector 可以掛多個 plugin」的假設），設定來源連線、topic 改名、Avro 序列化與 DLQ，並用一個 IAM Role 讓 MSK Connect 可以扮演成這個 connector 執行。

### 1. 合併版 Plugin 打包

- **為何要合併**：官方 API 文件明載 MSK Connect 的 `CreateConnector` 不支援指定多個 plugin，`plugins` 必須恰好一個元素——要用多個 plugin 必須先合併成同一個 zip
- **內容**：Debezium `debezium-connector-postgres` 3.1.1.Final ＋ Glue Schema Registry converter 1.1.25 的 jar，全新獨立下載（不依賴 `msk_connect_plugin.tf` 那兩個 spike 用的 build 目錄，避免可重現性耦合到不相關資源的 apply 順序）

### 2. IAM 執行角色與權限

- **信任關係**：允許 `kafkaconnect.amazonaws.com` 扮演這個角色，用 `SourceAccount` 精確比對＋`SourceArn` 萬用字元比對 connector 名稱的妥協方案（官方建議精確比對 connector ARN，但那個 ARN 帶隨機 UUID、要 connector 建立後才存在，跟「先有 Role 才能建 connector」的 Terraform 順序衝突，詳見 ADR-0009）
- **權限範圍**：CloudWatch Logs 寫入（限定這個 connector 的專屬 log group）＋ Glue Schema Registry 完整讀寫（`GetSchemaByDefinition`／`GetSchemaVersion`／`GetSchema`／`ListSchemaVersions`／`CreateSchema`／`RegisterSchemaVersion`，範圍鎖定 `schema_registry.tf` 的 registry），不需要 `kafka-cluster:*` 權限（MSK cluster 是 unauthenticated），也不需要 S3 讀取權限（custom plugin 建立當下 MSK Connect 就把內容複製進自己的儲存，不維持連結）

### 3. Connector 容量與叢集連線

- **容量**：不用 autoscaling，固定 1 MCU／1 worker——Debezium 關聯式來源連接器天生單 task／單 replication slot，autoscaling 只會多出沒意義的設定面
- **Kafka Connect 版本**：3.7.x（MSK Connect 目前僅支援 2.7.1／3.7.x，已即時查證）
- **叢集連線**：TLS 加密、`unauthenticated`（對應 `msk.tf` 的設定），VPC 掛在 `slice2_internal` 共用 SG，不需要新增額外 SG 規則（self-referencing 規則本來就涵蓋）

### 4. Debezium 擷取設定與資料流

- **來源**：Postgres 邏輯複寫（`plugin.name=pgoutput`），監看 `public.trade` 單一資料表，複寫槽 `slice2_trade_slot`
- **Topic 命名**：Debezium 預設命名是 `<topic.prefix>.<schema>.<table>`（會產生 `transaction.public.trade`），不是規格書承諾的 `transaction.trade.v1`——用 `RegexRouter` SMT 在序列化前改名
- **Key／Value 序列化**：key 用純字串（`StringConverter`，判斷取捨、非定案——2b 若需要直接解析 key 的結構化欄位再回頭改成 Avro）；value 用 `AWSKafkaAvroConverter`（Glue Schema Registry），開啟自動註冊 schema
- **錯誤處理／DLQ**：`errors.tolerance=all`——序列化失敗的訊息轉進 `transaction.trade.v1.dlq`（複本數 2、附帶錯誤 context header），不阻塞主流程

**對 Data Engineer 的意義**

| 你會問 | 答案 |
| --- | --- |
| 這個 connector 實際監看哪張表、輸出到哪個 topic？ | `public.trade` → `transaction.trade.v1`（經 RegexRouter 改名） |
| 違約訊息去哪裡？ | `transaction.trade.v1.dlq`，主流程不受影響 |
| 要另外設定 IAM 簽章連 Kafka 嗎？ | 不用，cluster 是 unauthenticated，靠 Security Group 擋 |

**對照表（原始碼出處）**

| 主題 | 項目 | 資源 | 出處 |
| --- | --- | --- | --- |
| 合併版 Plugin 打包 | 下載與打包 | `null_resource.build_debezium_combined_plugin`、`aws_mskconnect_custom_plugin.debezium_combined` | [msk_connector.tf:22-67](msk_connector.tf#L22-L67) |
| IAM 執行角色與權限 | 信任政策、權限政策 | `aws_iam_role.msk_connect_debezium`、`data.aws_iam_policy_document.msk_connect_permissions` | [msk_connector.tf:74-152](msk_connector.tf#L74-L152) |
| Connector 容量與叢集連線 | 容量、版本 | `aws_mskconnect_connector.debezium_postgres.capacity` | [msk_connector.tf:154-166](msk_connector.tf#L154-L166) |
| Connector 容量與叢集連線 | 叢集連線設定 | `kafka_cluster`／`kafka_cluster_client_authentication`／`kafka_cluster_encryption_in_transit` | [msk_connector.tf:206-225](msk_connector.tf#L206-L225) |
| Debezium 擷取設定與資料流 | connector_configuration 全部設定 | `aws_mskconnect_connector.debezium_postgres.connector_configuration` | [msk_connector.tf:167-204](msk_connector.tf#L167-L204) |

<a id="msk_event_verifier-tf"></a>
## `msk_event_verifier.tf` — CDC 事件驗證 Lambda

**總結**：一支跑在 VPC 內的 Lambda，消費並解碼 `transaction.trade.v1`（或 DLQ topic）上的 CDC 事件，用來人工驗證管線行為正確——項目 8／9 都直接重用同一支 Lambda，不需要另外建資源。

### 1. 打包與部署

- **Runtime**：Python 3.12，timeout 90 秒（TLS 交握＋consumer group join＋呼叫端給的 poll 時間窗，預設 20 秒，不需要像 `trade_generator` 那樣的 300 秒），記憶體 256MB
- **依賴套件**：純 Python 的 `kafka-python-ng`（`kafka-python` 停更後的維護分支）＋ `aws-glue-schema-registry`；後者間接依賴 `orjson`（編譯過的 Rust extension，不是純 Python）——本機 macOS 直接打包會抓到不相容的 macOS 版 `.so`，已實測撞到 `ImportModuleError`，修法是加 `--platform manylinux2014_x86_64 --only-binary=:all:` 強制抓 Linux 版預編譯 wheel

### 2. IAM 唯讀權限

- **唯讀 Glue 權限**：`GetSchemaVersion`／`GetSchema`／`ListSchemaVersions`，範圍鎖定 `schema_registry.tf` 的 registry——consume 端只需要查回 schema 定義做解碼，不需要 `msk_connector.tf` 那組 producer／auto-registration 才要的 `CreateSchema`／`RegisterSchemaVersion`／`GetSchemaByDefinition`

### 3. Consumer 邏輯與重用設計

- **連線方式**：跟 `trade_generator` 同一個理由（MSK broker 在私有子網，本機沒有路徑直接連進去）——Lambda 掛在同一個 VPC/SG，本機用 `aws lambda invoke` 觸發
- **可重用設計**：呼叫時傳入的 `topic` 參數預設 `transaction.trade.v1`，但可以直接改傳 `transaction.trade.v1.dlq` 重用同一支 Lambda 消費 DLQ topic（項目 9 已實測驗證這個重用路徑），不需要修改程式碼或另外部署資源

**對 Data Engineer 的意義**

| 你會問 | 答案 |
| --- | --- |
| 怎麼驗證 DLQ 有沒有收到違約訊息？ | 呼叫 `slice2-cdc-event-verifier`，payload 傳 `{"topic": "transaction.trade.v1.dlq"}` |
| 每次呼叫都會看到完整歷史嗎？ | 會，consumer group 每次呼叫都是全新的，`auto_offset_reset` 設定會讀最舊訊息（見 `src/ingestion/verify_cdc_events.py`） |

**對照表（原始碼出處）**

| 主題 | 項目 | 資源 | 出處 |
| --- | --- | --- | --- |
| 打包與部署 | runtime／timeout／依賴打包 | `aws_lambda_function.cdc_event_verifier`、`null_resource.build_cdc_event_verifier` | [msk_event_verifier.tf:97-108](msk_event_verifier.tf#L97-L108), [msk_event_verifier.tf:17-38](msk_event_verifier.tf#L17-L38) |
| IAM 唯讀權限 | 唯讀 Glue 政策 | `data.aws_iam_policy_document.cdc_event_verifier_permissions` | [msk_event_verifier.tf:71-85](msk_event_verifier.tf#L71-L85) |
| Consumer 邏輯與重用設計 | VPC config、環境變數 | `aws_lambda_function.cdc_event_verifier.vpc_config`／`environment` | [msk_event_verifier.tf:110-122](msk_event_verifier.tf#L110-L122) |

<a id="outputs-tf"></a>
## `outputs.tf` — 部署後才知道的值

**總結**：把 25 個「寫程式碼時還不知道、apply 之後才產生」的值吐出來，供驗證與後續 slice 接手使用。

| 資源 | 白話說明 | 關鍵設定 | 出處 |
| --- | --- | --- | --- |
| 網路類（6 個） | `vpc_id`、`private_subnet_ids`、`s3_vpc_endpoint_id`、`glue_vpc_endpoint_id`、`internal_security_group_id`、`logs_vpc_endpoint_id` | 全部是部署後才配發的 AWS 資源 ID | [outputs.tf:1-23](outputs.tf#L1-L23) |
| 來源 DB／generator（2 個） | `trade_db_endpoint`、`trade_generator_function_name` | RDS endpoint、Lambda 函式名稱 | [outputs.tf:25-31](outputs.tf#L25-L31) |
| MSK／Schema Registry（5 個） | `msk_cluster_arn`、`msk_bootstrap_brokers_tls`、`glue_schema_registry_name`、`glue_schema_registry_arn`、`trade_events_schema_arn` | Kafka 叢集與 Registry 的 ARN／endpoint | [outputs.tf:33-51](outputs.tf#L33-L51) |
| MSK Connect Plugin（歷史 spike，5 個） | `msk_connect_plugin_bucket_name`、`debezium_postgres_plugin_arn`／`_latest_revision`、`glue_schema_registry_converter_plugin_arn`／`_latest_revision` | 項目 6 spike 的 plugin ARN／revision，不對應真正在跑的 connector | [outputs.tf:53-71](outputs.tf#L53-L71) |
| Connector 與合併版 Plugin（6 個） | `msk_connector_arn`、`msk_connector_name`、`msk_connect_worker_log_group_name`、`debezium_combined_plugin_arn`／`_latest_revision`、`msk_connect_execution_role_arn` | 真正在跑的 connector 與其引用的合併版 plugin | [outputs.tf:73-95](outputs.tf#L73-L95) |
| 驗證用 Lambda（1 個） | `cdc_event_verifier_function_name` | 項目 8／9 共用的驗證 Lambda 函式名稱 | [outputs.tf:97-99](outputs.tf#L97-L99) |
