# dev-slice2 環境白話說明（Terraform 轉譯）

> 由 `explain-infra` skill 從同目錄 `.tf` 自動轉譯，讓不熟 SRE 的 Data Engineer 不用讀 HCL 也能確認基礎設施跟預期一致。**內容一律以 `.tf` 原始碼為準，不編造程式碼中未出現的設定**，每列附檔名行號供回查。
>
> 這是「原始碼意圖」的轉譯，不是部署現況——實際 resource ID／endpoint／密碼等 apply 後才產生的值，見 [ai/contexts/infra_dev_slice2.md](../../../ai/contexts/infra_dev_slice2.md)。

**最後轉譯**：2026-09-14
**來源**：`infra/environments/dev-slice2/*.tf`（11 個檔案）

## 這個環境在做什麼

這是 Slice 2 CDC 管線的來源端。一台 PostgreSQL 當作交易系統的 OLTP 資料庫，一支 Lambda 定期往裡面塞模擬的交易資料（新增／更新／刪除都有，才有 CDC 可以擷取），旁邊架一組 Kafka（MSK）等著接 CDC 訊息，另外在 Glue Schema Registry 註冊了交易事件的 Avro schema 來管控欄位變更。

再往下一步，Debezium PostgreSQL connector 跟 AWS Glue Schema Registry 的 Kafka Connect converter 已經合併打包成 MSK Connect 看得懂的格式，正式建成一個 connector 掛上去跑——RDS 的異動現在會即時被擷取，經 `RegexRouter` 改名、`AWSKafkaAvroConverter` 序列化後送進 `transaction.trade.v1` 這個 Kafka topic，已用唯讀 CLI 交叉驗證為 `RUNNING`。

整組資源關在一個沒有對外通道的私有 VPC 裡——沒有 Internet Gateway 也沒有 NAT，要連 AWS 服務只能走 VPC Endpoint。這也是為什麼資料 generator 做成 Lambda 而不是本機腳本：你的筆電沒有任何路徑可以直接連進去。

依 spec §3.3(b)「用完即拆」策略，這組資源只在 Slice 2a/2b 驗證期間運行，驗證完就 destroy。

## 目錄

- [檔案總覽與相依關係](#檔案總覽與相依關係)
- [`versions.tf` — 版本鎖定與 state 位置](#versions-tf)
- [`provider.tf` — Region 設定](#provider-tf)
- [`variables.tf` — 可調參數](#variables-tf)
- [`vpc.tf` — 網路地基](#vpc-tf)
- [`rds.tf` — 來源 OLTP 資料庫](#rds-tf)
- [`lambda.tf` — 交易資料 generator](#lambda-tf)
- [`msk.tf` — Kafka 叢集](#msk-tf)
- [`schema_registry.tf` — 交易事件 Schema 治理](#schema_registry-tf)
- [`msk_connect_plugin.tf` — Debezium plugin 打包（歷史 spike，未被使用）](#msk_connect_plugin-tf)
- [`msk_connector.tf` — CDC connector 部署](#msk_connector-tf)
- [`outputs.tf` — 部署後才知道的值](#outputs-tf)

## 檔案總覽與相依關係

| 檔案 | 一句話職責 | 依賴 | 被誰依賴 |
| --- | --- | --- | --- |
| `versions.tf` | 鎖定 Terraform／provider 版本，指定 state 存哪裡 | — | 全部 |
| `provider.tf` | 指定資源要開在哪個 region | `variables.tf` | 全部 |
| `variables.tf` | 可調參數：region 與私有子網網段 | — | `provider.tf`、`vpc.tf` |
| `vpc.tf` | 網路地基：私有網段、路由、防火牆、對外通道 | `variables.tf` | `rds.tf`、`lambda.tf`、`msk.tf`、`msk_connector.tf` |
| `rds.tf` | 來源 OLTP 資料庫（PostgreSQL），已開 CDC 前提 | `vpc.tf` | `lambda.tf`、`msk_connector.tf` |
| `lambda.tf` | 模擬交易資料的 generator，跑在 VPC 內 | `vpc.tf`、`rds.tf` | — |
| `msk.tf` | Kafka 叢集本體，等著接 CDC 訊息 | `vpc.tf` | `msk_connector.tf` |
| `schema_registry.tf` | 交易事件的 Avro schema 與相容性規則 | — | `msk_connector.tf` |
| `msk_connect_plugin.tf` | 把 Debezium／Glue SR converter 打包成 MSK Connect plugin（歷史 spike，未被使用） | — | `msk_connector.tf`（共用 S3 bucket） |
| `msk_connector.tf` | 合併打包真正會用的 plugin，建 IAM Role 與 CDC connector 本體 | `vpc.tf`、`rds.tf`、`msk.tf`、`schema_registry.tf`、`msk_connect_plugin.tf` | — |
| `outputs.tf` | 把部署後才知道的值（ID／endpoint）吐出來 | 全部 | — |

<a id="versions-tf"></a>
## `versions.tf` — 版本鎖定與 state 位置

**總結**：規定要用哪個版本的 Terraform 跟 AWS provider，以及這個環境的狀態檔存在哪。

| 資源 | 白話說明 | 關鍵設定 | 出處 |
| --- | --- | --- | --- |
| `terraform.required_version` | 最低 Terraform 版本 | `>= 1.10` | [versions.tf:2](versions.tf#L2) |
| `required_providers` | 用到三個 provider：AWS 本體、產亂數密碼、打包 zip | `aws ~> 5.0`、`random ~> 3.6`、`archive ~> 2.4` | [versions.tf:4-17](versions.tf#L4-L17) |
| `backend "s3"` | 狀態檔存 S3，跟 Slice 0/1 是**分開的兩份 state** | `s3://danny-data-engineering/terraform-state/dev/slice2.tfstate`，開啟 lockfile 防併發 | [versions.tf:19-24](versions.tf#L19-L24) |

**對 Data Engineer 的意義**

| 你會問 | 答案 |
| --- | --- |
| 這裡 destroy 會不會炸到 Slice 0/1 的資源？ | 不會。state key 是 `slice2.tfstate`，跟 `dev/` 環境的 state 完全獨立，兩邊互不可見 |

<a id="provider-tf"></a>
## `provider.tf` — Region 設定

**總結**：所有資源都開在 `variables.tf` 指定的 region。

| 資源 | 白話說明 | 關鍵設定 | 出處 |
| --- | --- | --- | --- |
| `provider "aws"` | AWS provider 的 region 設定 | `region = var.aws_region`，實際值為 `ap-northeast-1`（東京） | [provider.tf:1-3](provider.tf#L1-L3) |

<a id="variables-tf"></a>
## `variables.tf` — 可調參數

**總結**：只有兩個參數，region 跟私有子網網段，都有預設值（本環境沒有 `terraform.tfvars`，一律走預設）。

| 資源 | 白話說明 | 關鍵設定 | 出處 |
| --- | --- | --- | --- |
| `var.aws_region` | 資源要開在哪個 region | 預設 `ap-northeast-1` | [variables.tf:1-5](variables.tf#L1-L5) |
| `var.private_subnet_cidrs` | 私有子網網段，key 是可用區代碼後綴 | 預設兩個：`a` → `10.20.1.0/24`、`c` → `10.20.2.0/24` | [variables.tf:7-14](variables.tf#L7-L14) |

**⚠️ 注意 / 限制**

- 為什麼一定要 2 個 AZ：RDS 的 DB Subnet Group 規定至少橫跨 2 個 AZ；MSK Provisioned 的 broker 數量也必須是 AZ 數的倍數（已定 2 個 broker）
- 為什麼選 a 跟 c 而不是 a 跟 b：**此帳號在 `ap-northeast-1` 實際可用的 AZ 只有 a/c/d，`b` 不可用**——這是實測撞到才知道的，不是文件寫的

<a id="vpc-tf"></a>
## `vpc.tf` — 網路地基

**總結**：開一個對外完全封閉的私有網路，裡面的東西只能透過 VPC Endpoint 這種「地下通道」連到 AWS 服務，彼此之間則靠同一張防火牆卡互相放行。

### 1. 網路範圍與子網配置

- **VPC 網段**：`10.20.0.0/16`，開啟 DNS 支援與 DNS 主機名稱（Interface VPC Endpoint 的 private DNS 需要這個設定才能生效）
- **子網分布**：兩個私有子網，跨 2 個可用區——`ap-northeast-1a`（`10.20.1.0/24`）、`ap-northeast-1c`（`10.20.2.0/24`）
- **路由表**：一張路由表給兩個子網共用，**刻意沒有任何對外路由**（沒有 IGW、沒有 NAT）

### 2. 對外連線能力（路由與 VPC Endpoint）

- **對外現況**：整個 VPC 沒有 Internet Gateway 也沒有 NAT Gateway，子網內的東西**上不了公網**；要碰 AWS 服務只能走 VPC Endpoint 這種內網通道
- **S3 Endpoint（Gateway 型）**：免費，掛在路由表上就生效，不佔用子網 IP
- **Glue／Logs Endpoint（Interface 型）**：機制跟 Gateway 不同，各佔用兩個子網的 IP、掛防火牆、開啟 private DNS，且**持續按小時計費**；其中 Logs 這個是 Lambda 唯一能把執行紀錄送出去的路徑，沒有它就完全看不到 Lambda 的輸出

### 3. 內部防火牆規則（Security Group）

- **共用一張 SG**：`slice2_internal`，RDS／MSK／Lambda／Interface Endpoint 全部掛同一張，用「同一張 SG 的成員互相放行」這個邏輯做存取控制，不是靠傳統的來源 IP 白名單
- **入站規則（3 條，全部 self-referencing）**：443（給 Interface VPC Endpoint）、5432（給 RDS，讓 Lambda 連得到 Postgres）、9094（給 MSK TLS broker，讓未來的 MSK Connect／驗證用 client 連得到）——都只放行「同一張 SG 的成員」，不對外開放任何一個
- **出站規則**：`0.0.0.0/0` 全開，但因為沒有 IGW/NAT，實際能到的地方只有 VPC Endpoint 跟同 VPC 內的鄰居

**對照表（原始碼出處）**

| 主題 | 項目 | 資源 | 出處 |
| --- | --- | --- | --- |
| 網路範圍與子網配置 | VPC 網段 | `aws_vpc.slice2` | [vpc.tf:3-7](vpc.tf#L3-L7) |
| 網路範圍與子網配置 | 子網分布 | `aws_subnet.private` | [vpc.tf:9-14](vpc.tf#L9-L14) |
| 網路範圍與子網配置 | 路由表 | `aws_route_table.private` | [vpc.tf:16-24](vpc.tf#L16-L24) |
| 對外連線能力 | S3 Endpoint | `aws_vpc_endpoint.s3` | [vpc.tf:27-32](vpc.tf#L27-L32) |
| 對外連線能力 | Glue／Logs Endpoint | `aws_vpc_endpoint.glue`、`aws_vpc_endpoint.logs` | [vpc.tf:80-98](vpc.tf#L80-L98) |
| 內部防火牆規則 | 入站規則（443／5432／9094） | `aws_security_group.slice2_internal` | [vpc.tf:37-68](vpc.tf#L37-L68) |
| 內部防火牆規則 | 出站規則 | `aws_security_group.slice2_internal` | [vpc.tf:70-76](vpc.tf#L70-L76) |

**對 Data Engineer 的意義**

| 你會問 | 答案 |
| --- | --- |
| 我可以從筆電直接連這裡的 RDS／Kafka 嗎？ | **不行。** 沒有 IGW／NAT／bastion，唯一進入方式是跑在同一個 VPC＋SG 內的運算資源（例如 `lambda.tf` 的 generator） |
| 我加了新元件連不上，先檢查什麼？ | 它有沒有掛上 `slice2-internal` 這張 SG。所有放行規則都是 self-referencing，不在這張 SG 裡就一律不通 |

**⚠️ 注意 / 限制**

- SG 的 description 欄位（含 group 層級與規則層級）**只接受 ASCII**，看到英文說明不是風格不一致，是 AWS 的硬限制

<a id="rds-tf"></a>
## `rds.tf` — 來源 OLTP 資料庫

**總結**：一台最小規格的 PostgreSQL 16，開機時就把 CDC 的前提參數打開，關在私有子網裡。

### 1. 規格與儲存

- **引擎與版本**：PostgreSQL 16
- **執行規格**：`db.t4g.micro`，20GB gp3 儲存
- **識別資訊**：AWS 上叫 `slice2-trade`，資料庫名稱 `trade`，帳號 `trade_admin`
- **子網群組**：橫跨兩個私有子網（`1a`／`1c`）

### 2. CDC／複寫設定

- **Logical Replication**：透過 parameter group 開啟 `rds.logical_replication=1`，這是 Debezium CDC 擷取變更的前提；因為在 instance 建立時就掛上這個 parameter group，不會遇到「改參數要重開機」的問題（`apply_method` 只在既有 instance 上修改參數時才有意義）

### 3. 安全與存取控制

- **網路隔離**：`publicly_accessible = false`，只能從掛同一張 SG（`slice2_internal`）的資源連進來（5432）
- **主密碼**：由 Terraform 用 `random_password` 產生（20 碼、不含特殊字元），**沒有走 Secrets Manager**，直接寫進 Lambda 環境變數——這是刻意簡化：Lambda 要讀 Secrets Manager 一樣得多開一個 VPC Endpoint，對這個 lab 環境不值得多一個常駐計費資源

### 4. 生命週期策略（用完即拆）

- **高可用性**：`multi_az = false`，沒有備援，機房掛了就沒了，依「用完即拆」策略刻意省成本
- **銷毀行為**：`skip_final_snapshot = true`、`deletion_protection = false`，destroy 時**不留最終快照，資料直接消失**，不會被保護機制擋下

**對照表（原始碼出處）**

| 主題 | 項目 | 資源 | 出處 |
| --- | --- | --- | --- |
| 規格與儲存 | 引擎、規格、識別資訊 | `aws_db_instance.trade` | [rds.tf:31-46](rds.tf#L31-L46) |
| 規格與儲存 | 子網群組 | `aws_db_subnet_group.trade` | [rds.tf:12-15](rds.tf#L12-L15) |
| CDC／複寫設定 | Logical Replication | `aws_db_parameter_group.trade` | [rds.tf:20-29](rds.tf#L20-L29) |
| 安全與存取控制 | 主密碼 | `random_password.trade_db` | [rds.tf:7-10](rds.tf#L7-L10) |
| 安全與存取控制 | 網路隔離 | `aws_db_instance.trade` | [rds.tf:44-48](rds.tf#L44-L48) |
| 生命週期策略 | 高可用性、銷毀行為 | `aws_db_instance.trade` | [rds.tf:48-52](rds.tf#L48-L52) |

**對 Data Engineer 的意義**

| 你會問 | 答案 |
| --- | --- |
| 連線資訊是什麼？ | 資料庫 `trade`、帳號 `trade_admin`、port 5432。**host 與密碼都是部署後才決定**，見 [infra 快照](../../../ai/contexts/infra_dev_slice2.md) |
| CDC 需要的設定做好了嗎？ | 是。`rds.logical_replication=1` 在 instance 建立時就掛上，不會有「改參數要重開機」的問題 |
| 密碼放在哪？ | 由 Terraform 產生後**直接寫進 Lambda 的環境變數**，沒有走 Secrets Manager |

<a id="lambda-tf"></a>
## `lambda.tf` — 交易資料 generator

**總結**：一支跑在 VPC 內的 Python Lambda，負責往 RDS 塞模擬交易資料；做成 Lambda 是因為你的筆電根本連不進那個私有子網。

### 1. 執行環境規格

- **執行環境**：Python 3.12，逾時 300 秒，記憶體 256MB
- **進入點**：`generate_trade_data.lambda_handler`
- **相依套件**：`pg8000`（純 Python 的 PostgreSQL client）——選它是因為不用處理 manylinux wheel 或跨平台編譯，直接 `pip install` 進部署目錄就能用

### 2. 網路與身分權限

- **網路位置**：跟 RDS／MSK 掛同一個 VPC、同一張 SG（`slice2_internal`），這樣才連得到私有子網裡的 RDS
- **執行身分**：`slice2-trade-generator-lambda` 這個 IAM Role，信任 `lambda.amazonaws.com`，掛 AWS 受管政策 `AWSLambdaVPCAccessExecutionRole`（基本執行權限 + VPC ENI 管理權限，在 VPC 內執行的 Lambda 都需要後者）

### 3. 部署流程與資料流

- **打包流程**：用原始碼與 SQL 檔案的 sha256 當觸發條件，改了才重新 `pip install` + 打包成 zip，來源是 `src/ingestion/`
- **連線資訊傳遞**：資料庫的 host／port／name／user／password 全部經環境變數傳入，值直接從 `rds.tf` 帶過來
- **觸發方式**：本機下 `aws lambda invoke` 觸發，走的是 Lambda 的公開 API，不需要 bastion／peering／SSM——這正是為什麼 generator 做成 Lambda 而不是本機腳本：本機在私有子網外面，根本連不進 RDS

**對照表（原始碼出處）**

| 主題 | 項目 | 資源 | 出處 |
| --- | --- | --- | --- |
| 執行環境規格 | 執行環境、進入點 | `aws_lambda_function.trade_generator` | [lambda.tf:61-70](lambda.tf#L61-L70) |
| 執行環境規格 | 相依套件 | `null_resource.build_trade_generator` | [lambda.tf:15-30](lambda.tf#L15-L30) |
| 網路與身分權限 | 網路位置 | `aws_lambda_function.trade_generator.vpc_config` | [lambda.tf:72-75](lambda.tf#L72-L75) |
| 網路與身分權限 | 執行身分 | `aws_iam_role.trade_generator` | [lambda.tf:49-59](lambda.tf#L49-L59) |
| 部署流程與資料流 | 打包流程 | `data.archive_file.trade_generator` | [lambda.tf:32-37](lambda.tf#L32-L37) |
| 部署流程與資料流 | 連線資訊傳遞 | `aws_lambda_function.trade_generator.environment` | [lambda.tf:77-85](lambda.tf#L77-L85) |

**對 Data Engineer 的意義**

| 你會問 | 答案 |
| --- | --- |
| 怎麼觸發它產資料？ | 從本機下 `aws lambda invoke` |
| 為什麼相依套件是 `pg8000` 而不是 `psycopg2`？ | `pg8000` 是純 Python，直接 `pip install` 進部署目錄就能用，不必處理跨平台編譯 |
| 看不到執行 log 怎麼辦？ | 先確認 `vpc.tf` 的 `aws_vpc_endpoint.logs` 還在——沒有那個 endpoint 就送不出 CloudWatch Logs |

**⚠️ 注意 / 限制**

- 資料庫密碼以**明文存在 Lambda 環境變數**（原因見 `rds.tf` 的安全與存取控制），在 Console 上看得到

<a id="msk-tf"></a>
## `msk.tf` — Kafka 叢集

**總結**：開一組 2 台機器的 Kafka，只收 TLS 加密連線，關在私有子網裡，靠防火牆而不是帳密來擋人。

### 1. 叢集規模與硬體規格

- **Kafka 版本**：Apache Kafka 3.9.x（AWS 官方目前標示的 Recommended 版本，尚無 end-of-support 日期）
- **Broker 數量與規格**：共 2 個 broker 節點，採用低成本的 `kafka.t3.small` 規格
- **儲存空間**：每個 broker 配置 20GB 的 EBS gp3 空間
- **網路部署**：跨 2 個私有子網（`ap-northeast-1a`／`1c`），具備基礎的單區故障容錯能力

### 2. 資安與存取控制

- **傳輸加密**：對外只開放 TLS 加密埠（9094），未加密的 PLAINTEXT 埠（9092）沒開；叢集內部 broker 間傳輸也強制加密
- **身分驗證**：`unauthenticated`，不採用 SASL 或 IAM 簽章機制
- **存取防護**：完全依賴 Security Group（`slice2_internal`）在網路層過濾，跟 `rds.tf` 保護 RDS 的哲學一致

### 3. Kafka 行為與 Topic 邏輯設定

- **自動建立 Topic**：`auto.create.topics.enable=true`，producer（未來的 Debezium）第一次寫入時自動建立，不需要額外手動建立
- **副本容錯機制**：自動建立的 topic 預設副本數 2（對應 2 台 broker 各一份）；最低同步副本數設為 1，demo 用途刻意寬鬆，一台 broker 掛掉仍可寫入，正式環境不該這樣設

**對照表（原始碼出處）**

| 主題 | 項目 | 資源 | 出處 |
| --- | --- | --- | --- |
| 規模與硬體規格 | Kafka 版本 | `local.msk_kafka_version` | [msk.tf:13-19](msk.tf#L13-L19) |
| 規模與硬體規格 | Broker 規格、儲存空間、網路部署 | `aws_msk_cluster.trade` | [msk.tf:36-51](msk.tf#L36-L51) |
| 資安與存取控制 | 身分驗證 | `client_authentication` | [msk.tf:53-55](msk.tf#L53-L55) |
| 資安與存取控制 | 傳輸加密 | `encryption_info` | [msk.tf:59-64](msk.tf#L59-L64) |
| Kafka 行為與 Topic 邏輯設定 | 自動建立 Topic、副本容錯機制 | `aws_msk_configuration.trade` | [msk.tf:21-34](msk.tf#L21-L34) |

**對 Data Engineer 的意義**

| 你會問 | 答案 |
| --- | --- |
| producer／consumer 要連哪裡、哪個 port？ | **9094（TLS）**。9092 明碼埠沒開。bootstrap 位址是部署後才決定的值，見 [infra 快照](../../../ai/contexts/infra_dev_slice2.md) |
| 要先建 topic 嗎？ | **不用。** broker 開了 `auto.create.topics.enable=true`，第一次寫入時自動建 |
| 要準備 SASL／IAM 憑證嗎？ | 不用，叢集是 unauthenticated。只要你的 client 掛在 `slice2-internal` 這張 SG 裡就連得到，但**連線本身仍必須走 TLS** |

**⚠️ 注意 / 限制**

- Topic（`transaction.trade.v1` / `.dlq`）**刻意不在 Terraform 管理**，延後到部署 Debezium connector 時自然建立（見 [docs/TODO.md](../../../docs/TODO.md)「Kafka topic 改為正式 Terraform 管理」）

<a id="schema_registry-tf"></a>
## `schema_registry.tf` — 交易事件 Schema 治理

**總結**：在 Glue Schema Registry 註冊交易事件的 Avro schema，並設定成「只准往回相容」，用來擋掉會弄壞下游的欄位變更。

### 1. Schema 格式與欄位定義

- **格式**：Avro，record 名稱 `TradeEvent`，namespace `com.portfolio.trade`
- **形狀**：攤平的交易資料列（對應 `create_trade_table.sql` 的欄位），**不是** Debezium CDC envelope（`before`/`after`/`op`/`ts_ms` 那層包裝）——因為 envelope 形狀要等 connector 部署才會定案，現在猜錯的機率遠高於直接照抄 table schema
- **必填欄位（6 個）**：`trade_id`／`account_id`／`symbol`（string）、`side`（enum `BUY`/`SELL`）、`status`（enum `NEW`/`PARTIALLY_FILLED`/`FILLED`/`CANCELLED`）、`event_time`（timestamp-millis）——直接對應 spec §6 完整性規則
- **可為 null 欄位（3 個）**：`price`（decimal 12,2）、`quantity`（int）、`updated_at`（timestamp-millis）

### 2. 相容性策略與治理規則

- **相容性模式**：`BACKWARD`——允許刪欄位、允許新增「有 default 的欄位」，**禁止新增沒有 default 的必填欄位**
- **潛在撞名風險（留給後續項目處理）**：Debezium 若用預設的 topic-based 命名策略，schema 名稱會對應 topic 名（如 `transaction.trade.v1`），不會跟這裡的 `trade_events` 撞名；只有 connector 被明確設成用固定名稱 `trade_events` 時才可能撞名，並在第一筆訊息就被 `BACKWARD` 規則擋下

**對照表（原始碼出處）**

| 主題 | 項目 | 資源 | 出處 |
| --- | --- | --- | --- |
| Schema 格式與欄位定義 | Registry | `aws_glue_registry.trade_events` | [schema_registry.tf:24-27](schema_registry.tf#L24-L27) |
| Schema 格式與欄位定義 | 欄位定義 | `aws_glue_schema.trade_events.schema_definition` | [schema_registry.tf:37-73](schema_registry.tf#L37-L73) |
| 相容性策略與治理規則 | 相容性模式 | `aws_glue_schema.trade_events.compatibility` | [schema_registry.tf:33](schema_registry.tf#L33) |

**對 Data Engineer 的意義**

| 你會問 | 答案 |
| --- | --- |
| 這個 schema 是 CDC envelope 還是原始資料列？ | **是攤平的資料列形狀**，不是 Debezium 的 `before`/`after`/`op`/`ts_ms` 包裝 |
| `BACKWARD` 相容性實際擋掉什麼？ | 允許刪欄位、允許新增「有 default 的欄位」；**禁止新增沒有 default 的必填欄位** |
| 哪些欄位不可為 null？ | `trade_id`、`account_id`、`symbol`、`side`、`status`、`event_time` |
| `side` 跟 `status` 可以填什麼值？ | `side`：`BUY`／`SELL`。`status`：`NEW`／`PARTIALLY_FILLED`／`FILLED`／`CANCELLED` |

<a id="msk_connect_plugin-tf"></a>
## `msk_connect_plugin.tf` — Debezium plugin 打包（歷史 spike，未被使用）

**總結**：把 Debezium PostgreSQL connector 跟 AWS Glue Schema Registry 的 Kafka Connect converter 各自打包成 zip 上傳 S3，註冊成兩個 MSK Connect custom plugin——這一步只是「備料」，還沒有真的接上 Kafka 去跑。**這兩個 plugin 最終沒有被真正的 connector 引用**，詳見下方 ⚠️ 與 [`msk_connector.tf`](#msk_connector-tf)。

### 1. 打包來源與內容

- **Debezium PostgreSQL connector**：直接從 Maven Central 下載官方 `-plugin` classifier 的 tar.gz（版本 `3.1.1.Final`），這包本身已經自帶完整依賴（`debezium-core`／`debezium-api`／PostgreSQL driver／`protobuf-java` 等 5 個 jar），不需要另外湊——已用 curl 實測驗證過解壓結構
- **AWS Glue Schema Registry converter**：從 Maven Central 下載 `software.amazon.glue:schema-registry-kafkaconnect-converter`（版本 `1.1.25`），是一顆 67MB 的 uber jar，已經打包好所有依賴（AWS SDK／Avro／Jackson 等），不需要額外用 Maven 湊 transitive dependency——這個推論已經過實際 apply 驗證成立，兩個 plugin 第一次嘗試就都到 `ACTIVE`
- **兩者分開打包，不合併成一個 zip**：當時的判斷是「MSK Connect 的 connector 本來就能同時掛多個 plugin」，分開後如果其中一個出問題能立刻孤立問題範圍——**這個判斷事後查證是錯的**，見下方 ⚠️ 注意

### 2. 儲存與 MSK Connect 註冊

- **專屬 S3 bucket**：新建 `danny-data-engineering-slice2-msk-connect`，不是跟 Slice 0/1 共用的 `danny-data-engineering`——這個專案刻意把 `dev`／`dev-slice2` 兩個 Terraform state 切乾淨，跨 state 借用 bucket 會讓其中一邊的 `destroy` 要顧慮到另一邊
- **兩個 custom plugin 資源**：`slice2-debezium-postgres-plugin`、`slice2-glue-schema-registry-converter-plugin`，都是 `content_type = "ZIP"`，各自指向 S3 上的 zip

### 3. 範圍界線與生命週期

- **只做到「plugin 可用」，不建 connector**：這兩個 custom plugin 建好之後，還沒有任何東西真的在消費 Kafka 訊息——接上真正的 CDC pipeline（連線 RDS、寫進 topic）是下一步（spec §4 項目 7）的工作。**項目 7 實際上另外合併打包了第三個 plugin 才接上**，這裡的兩個 plugin 本身沒被引用
- **不碰 VPC、不需要新的 IAM Role**：註冊 custom plugin 純粹是 S3 + MSK Connect 的 control plane 操作，跟這個環境已有的 VPC／Security Group 完全無關
- **保留、不銷毀**：這兩個 plugin 是「各元件個別能打包成功」的歷史 spike 證據，會留到整個 Slice 2 都驗收完才收尾，不是驗完即丟的 spike 資源

**對照表（原始碼出處）**

| 主題 | 項目 | 資源 | 出處 |
| --- | --- | --- | --- |
| 打包來源與內容 | Debezium 版本與下載 | `null_resource.build_debezium_postgres_plugin` | [msk_connect_plugin.tf:37-53](msk_connect_plugin.tf#L37-L53) |
| 打包來源與內容 | Converter 版本與下載 | `null_resource.build_glue_schema_registry_converter_plugin` | [msk_connect_plugin.tf:86-100](msk_connect_plugin.tf#L86-L100) |
| 儲存與 MSK Connect 註冊 | S3 bucket | `aws_s3_bucket.msk_connect_plugins` | [msk_connect_plugin.tf:22-24](msk_connect_plugin.tf#L22-L24) |
| 儲存與 MSK Connect 註冊 | Custom plugin 註冊 | `aws_mskconnect_custom_plugin.debezium_postgres`、`.glue_schema_registry_converter` | [msk_connect_plugin.tf:69-79](msk_connect_plugin.tf#L69-L79)、[msk_connect_plugin.tf:119-129](msk_connect_plugin.tf#L119-L129) |

**對 Data Engineer 的意義**

| 你會問 | 答案 |
| --- | --- |
| 這步做完，Debezium 就開始擷取 CDC 了嗎？ | **沒有，而且永遠不會**——這裡只是把兩個 plugin 準備好、註冊到 MSK Connect，真正接上 RDS／Kafka 用的是 `msk_connector.tf` 另外合併打包的第三個 plugin |
| 我要另外準備 IAM Role 給這個檔案用嗎？ | 不用，這個檔案完全沒有 IAM／VPC 資源，全部在 `msk_connector.tf` 處理 |
| plugin 的實際 ARN／revision 在哪查？ | 部署後才決定，見 [infra 快照](../../../ai/contexts/infra_dev_slice2.md) 或 `outputs.tf` 的對應 output |

**⚠️ 注意 / 限制**

- S3 bucket 名稱是全球唯一，`danny-data-engineering-slice2-msk-connect` 這個名字理論上有極小機率被其他 AWS 帳號搶先使用，若真的撞名需要改名重 apply
- **這兩個 plugin 最終沒有被使用**：當初「分開打包」的理由（`CreateConnector` API 接受多個 plugin 清單）事後查證是錯的——MSK Connect 一個 connector 只能掛一個 custom plugin。`msk_connector.tf` 因此另外合併打包成第三個 plugin，這裡的兩個 plugin 只作為「個別元件能打包成功」的歷史 spike 證據保留，不會被任何 connector 引用（背景與未來重用方式見 [docs/patterns/msk-connect-single-plugin-per-connector.md](../../../docs/patterns/msk-connect-single-plugin-per-connector.md)）

<a id="msk_connector-tf"></a>
## `msk_connector.tf` — CDC connector 部署

**總結**：把項目 6 兩個各自打包的 plugin 合併成一個真正能用的 plugin，配一個專屬 IAM Role，正式建立一個會執行的 Debezium connector，把 RDS 的異動即時送進 Kafka——已用 `aws kafkaconnect describe-connector` 交叉驗證為 `RUNNING`。

### 1. 合併版 Plugin 打包

- **為什麼要重新打包**：MSK Connect 的 `CreateConnector` 一個 connector 只能引用一個 plugin，`msk_connect_plugin.tf` 分開打包的兩個獨立 plugin 用不了，這裡重新獨立下載、合併成第三個 plugin
- **內容**：跟 `msk_connect_plugin.tf` 用同一組來源（Debezium `3.1.1.Final` tar.gz + Glue Schema Registry converter `1.1.25` jar），但不依賴那兩個既有的 build 目錄，避免耦合到不相關資源的 apply 順序
- **上傳位置**：沿用 `msk_connect_plugin.tf` 建立的同一個 S3 bucket，新的 key

### 2. IAM 執行角色與權限

- **Trust policy 的妥協設計**：AWS 官方建議精確比對 connector 自己的 ARN，但那個 ARN 要 connector 建立後才存在，Terraform 沒辦法在建 Role 當下就知道；改成 `SourceAccount` 精確比對 + `SourceArn` 只在隨機 UUID 段用萬用字元，connector 名稱本身仍是固定字串（決策記錄見 [ADR-0009](../../../docs/architecture/adr/0009-msk-connect-trust-policy-sourcearn-tradeoff.md)）
- **因為 MSK cluster 是 unauthenticated**：不需要官方文件裡那一大段 `kafka-cluster:*` 權限，也不需要 S3 讀取權限（plugin 內容在建立當下就被複製走了，不維持連結）
- **實際權限只有兩塊**：CloudWatch Logs（範圍鎖定到專屬 log group）、Glue Schema Registry 查找與自動註冊（範圍鎖定到 `slice2-trade-events` registry）

### 3. Connector 容量與叢集連線

- **容量**：`provisioned_capacity`，1 個 worker、1 個 MCU——不用 autoscaling，因為 Debezium 這類關聯式來源 connector 天生只能單 task／單 replication slot，多 worker 用不到
- **Kafka Connect 版本**：`3.7.x`（MSK Connect 目前只支援 `2.7.1` 或 `3.7.x`，已即時查證）
- **連線設定對應既有 MSK cluster**：`bootstrap_servers` 用 `aws_msk_cluster.trade` 的 TLS 端點、VPC 用既有兩個私有子網 + `slice2_internal` SG（沒有新增 SG 規則，既有 self-referencing 規則已涵蓋）、認證 `NONE`、加密 `TLS`，皆對應 `msk.tf` 現有設定

### 4. Debezium 擷取設定與資料流

- **來源**：`io.debezium.connector.postgresql.PostgresConnector`，連到 `aws_db_instance.trade`，用 `pgoutput` 邏輯解碼外掛，只抓 `public.trade` 這張表
- **Topic 改名**：Debezium 預設會產生 `transaction.public.trade`，用 `RegexRouter` SMT 改寫成 spec 承諾的 `transaction.trade.v1`
- **序列化**：value 用 `AWSKafkaAvroConverter`（連到 `slice2-trade-events` registry，允許自動註冊新 schema——實測會註冊成一個獨立的 `transaction.trade.v1` schema，不會跟既有的 `trade_events` 撞名）；key 刻意用純字串 `StringConverter`，避免另外處理 key schema（非定案，2b 有需要再改）
- **違約訊息**：`errors.tolerance=all` 搭配 DLQ 設定，送進 `transaction.trade.v1.dlq`，不阻塞主流程

**對照表（原始碼出處）**

| 主題 | 項目 | 資源 | 出處 |
| --- | --- | --- | --- |
| 合併版 Plugin 打包 | 下載與合併 | `null_resource.build_debezium_combined_plugin` | [msk_connector.tf:22-41](msk_connector.tf#L22-L41) |
| 合併版 Plugin 打包 | 打包與註冊 | `aws_mskconnect_custom_plugin.debezium_combined` | [msk_connector.tf:43-67](msk_connector.tf#L43-L67) |
| IAM 執行角色與權限 | Trust policy | `data.aws_iam_policy_document.msk_connect_trust` | [msk_connector.tf:74-97](msk_connector.tf#L74-L97) |
| IAM 執行角色與權限 | 權限範圍 | `data.aws_iam_policy_document.msk_connect_permissions` | [msk_connector.tf:114-142](msk_connector.tf#L114-L142) |
| Connector 容量與叢集連線 | 容量、版本 | `aws_mskconnect_connector.debezium_postgres`（`capacity`／`kafkaconnect_version`） | [msk_connector.tf:154-165](msk_connector.tf#L154-L165) |
| Connector 容量與叢集連線 | 叢集連線 | `kafka_cluster`／`kafka_cluster_client_authentication`／`kafka_cluster_encryption_in_transit` | [msk_connector.tf:206-225](msk_connector.tf#L206-L225) |
| Debezium 擷取設定與資料流 | 來源、Topic 改名、序列化、DLQ | `connector_configuration` | [msk_connector.tf:167-204](msk_connector.tf#L167-L204) |

**對 Data Engineer 的意義**

| 你會問 | 答案 |
| --- | --- |
| connector 現在真的在動嗎？ | 是。已用 `aws kafkaconnect describe-connector` 交叉驗證 `connectorState: RUNNING`，且 Glue Schema Registry 真的多了一個 `transaction.trade.v1` schema |
| 我要怎麼查 connector 的執行紀錄？ | CloudWatch Logs，log group 名稱是部署後才決定的值，見 `outputs.tf` 的 `msk_connect_worker_log_group_name` |
| 為什麼 key 不是 Avro？ | 判斷取捨，不是限制——目前用純字串省去處理 key schema 的複雜度，2b 若需要直接解析 key 結構再回頭改 |

**⚠️ 注意 / 限制**

- `msk_connect_plugin.tf` 那兩個獨立 plugin **不會**被這個 connector 使用，純粹保留作歷史 spike 證據，不要誤以為要一起維護
- Trust policy 的 `SourceArn` 用萬用字元比對隨機 UUID 段，是 AWS 官方建議與 Terraform 建立順序限制之間的妥協，不是精確比對，決策記錄見 [ADR-0009](../../../docs/architecture/adr/0009-msk-connect-trust-policy-sourcearn-tradeoff.md)

<a id="outputs-tf"></a>
## `outputs.tf` — 部署後才知道的值

**總結**：把 24 個「寫程式碼時還不知道、apply 之後才產生」的值吐出來，供驗證與後續 slice 接手使用。

| 資源 | 白話說明 | 關鍵設定 | 出處 |
| --- | --- | --- | --- |
| 網路類（6 個） | `vpc_id`、`private_subnet_ids`、`s3_vpc_endpoint_id`、`glue_vpc_endpoint_id`、`logs_vpc_endpoint_id`、`internal_security_group_id` | 全部是部署後才配發的 AWS 資源 ID | [outputs.tf:1-23](outputs.tf#L1-L23) |
| 資料庫與運算（2 個） | `trade_db_endpoint`（RDS 連線位址）、`trade_generator_function_name` | endpoint 部署後才決定 | [outputs.tf:25-31](outputs.tf#L25-L31) |
| Kafka（2 個） | `msk_cluster_arn`、`msk_bootstrap_brokers_tls` | **bootstrap 位址就是 producer／consumer 要連的地方**，部署後才決定 | [outputs.tf:33-39](outputs.tf#L33-L39) |
| Schema Registry（3 個） | `glue_schema_registry_name`、`glue_schema_registry_arn`、`trade_events_schema_arn` | registry 名稱固定為 `slice2-trade-events`，ARN 部署後才決定 | [outputs.tf:41-51](outputs.tf#L41-L51) |
| MSK Connect Plugin（歷史 spike，5 個） | `msk_connect_plugin_bucket_name`、`debezium_postgres_plugin_arn`、`debezium_postgres_plugin_latest_revision`、`glue_schema_registry_converter_plugin_arn`、`glue_schema_registry_converter_plugin_latest_revision` | 兩個 plugin 的 ARN 與 revision——未被真正的 connector 使用，見 `msk_connect_plugin.tf` 章節 | [outputs.tf:53-71](outputs.tf#L53-L71) |
| MSK Connect Connector（6 個） | `msk_connector_arn`、`msk_connector_name`、`msk_connect_worker_log_group_name`、`debezium_combined_plugin_arn`、`debezium_combined_plugin_latest_revision`、`msk_connect_execution_role_arn` | 真正在跑的 connector／合併版 plugin／IAM Role，項目 8 驗證 CDC 事件時要用這些值 | [outputs.tf:73-95](outputs.tf#L73-L95) |

**對 Data Engineer 的意義**

| 你會問 | 答案 |
| --- | --- |
| 我要去哪裡拿這些值？ | 跑 `terraform output`，或直接看已經整理好的 [infra 快照](../../../ai/contexts/infra_dev_slice2.md) |

**⚠️ 注意 / 限制**

- 所有 output 都沒有標 `sensitive`。`trade_db_endpoint` 會以明文顯示在 `terraform output` 與 CI log 中（資料庫密碼本身沒有被 output，但存在 Lambda 環境變數裡）
