# Spec: Slice 2a — CDC 交易事件擷取（來源 DB → Kafka）

> 對應 [execution-roadmap.md](../../execution-roadmap.md) Slice 2 的前半段。
> 對應 [plan.md](../../plan.md) §7 分階段交付：Phase 1b（Streaming 主幹）。
> 後半段見 [slice2b-streaming-upsert.md](slice2b-streaming-upsert.md)。
> 狀態：**§3 待確認事項已全數拍板** — 以下 §4 實作項目清單即為實作依據。

---

## 1. 目標 (Goal)

把「交易狀態的每一次變更」從 OLTP 來源系統送進 Kafka，而**不去輪詢來源資料表**。這是本專案第一條即時路徑的上半段：管線的入口。

本片結束時能 demo 的事：在來源 DB 對一筆交易做 insert / update / delete，Kafka topic 上立刻出現對應的 CDC 事件，帶著 before / after 影像；而且註冊一個破壞性的 schema 變更會當場被 Schema Registry 擋下。

資料流（本片範圍以 `▓` 標示）：

```
▓ Trade DB (OLTP)                              ← 模擬交易狀態機：NEW → PARTIALLY_FILLED → FILLED / CANCELLED
▓   → CDC 擷取 (Debezium / DMS)                ← insert / update / delete，保留 before/after 影像
▓   → MSK topic (Avro + Glue Schema Registry)  ← 契約的技術強制點；違約訊息 → DLQ topic
      → 串流運算 → bronze.trade_events / silver.trade → Athena   ← Slice 2b
```

**為什麼上半段值得獨立成一片**：CDC 的判斷題（為何不定時撈整張表、為何選 MSK、Schema Registry 憑什麼算契約強制點）全部在這一段就能回答完，不需要等下游的表寫出來。而它引入的基礎設施（VPC、RDS、MSK、MSK Connect）是本專案至今最大的一塊新面積，單獨一片才驗得乾淨。

---

## 2. 範圍 (Scope) / 非範圍 (Non-Goals)

**範圍內**：
- 模擬交易來源：OLTP 資料表 + 交易狀態機 generator（產生 insert / update / delete 三種變更）
- 網路層基礎設施（VPC / 子網 / Security Group / VPC Endpoint）——本專案首次
- CDC 擷取管線：來源 DB → Kafka topic，含 before/after 影像與操作類型（`c`/`u`/`d`）
- Avro + Schema Registry 與相容性規則，含**破壞性變更被擋下的實測**
- DLQ（Dead Letter Queue）topic 與違約訊息的去向
- `contracts/trade-events.contract.yaml` **第一版**：topic 的 schema、違約行為
- 成本與資源生命週期控管（本專案首次出現常駐計費資源）

**刻意不做 (Out of Scope)**：
- **CDC 事件寫進 Iceberg（Bronze append / Silver MERGE INTO）** → Slice 2b。本片的下游終點就是 Kafka topic，用 consumer 印出訊息即為驗收
- **串流運算引擎的選型與部署** → Slice 2b（這正是 2a／2b 的切分點）
- **端到端延遲 SLA 的實測與寫回契約** → Slice 2b（本片只量得到「來源 DB → topic」這一段）
- 視窗聚合、即時風控、即時 OLAP → Slice 3
- 血緣、CI/CD、多環境、Airflow 編排 → Slice 4
- 修改 Slice 0/1 既有的 `bronze.stock` / `silver.stock` / `gold.monthly_ohlcv` 與 WAP Gate 邏輯

---

## 3. 待確認事項

性質同 slice0 §3 / slice1 §3：決定結果會直接決定 §4 實作項目怎麼展開。

> 註：plan.md §2.1 / §8 已把 MSK、Debezium 列為主選，本節不重新推翻藍圖，而是把「藍圖沒回答的實作級取捨」（佈署形態、成本、卡關時的降級路徑）攤開來拍板。

### 3.1 交易來源：真 OLTP DB vs 直接 producer 寫 Kafka

✅ **決定：A. RDS PostgreSQL**（`db.t4g.micro`，開啟 logical replication）。理由：唯一能讓「CDC vs 定時輪詢」的敘事有真實對照組的選項——若選 D，本片份量最重的 ADR（§9 的 `0007`）會失去論證基礎；同時維持專案一貫的「代管服務」展示定位（優於 C 的自架 EC2）。選 PostgreSQL 而非 MySQL（B）純粹因為 `pgoutput` 是 Debezium 原生支援、免裝外掛的路徑，兩者在 CDC 能力上本質相當。

| 選項 | 說明 | 取捨 |
| --- | --- | --- |
| **A. RDS PostgreSQL**（已選） | `db.t4g.micro`，開啟 logical replication（`rds.logical_replication=1` + `pgoutput`），Debezium 支援最成熟 | 最貼近真實 CDC 情境；需處理 parameter group 與 VPC |
| B. RDS MySQL | 以 binlog（`ROW` 格式）擷取 | 與 A 相當，選 A 只因 PostgreSQL 的 `pgoutput` 不需額外外掛 |
| C. EC2 自架 PostgreSQL | 裝在既有 bastion（`danny-ops`）或新 EC2 | 省 RDS 費用，但要自己顧 DB 生命週期，且偏離「代管服務」的展示定位 |
| D. 不用真 DB，generator 直接產 CDC 格式訊息寫入 Kafka | 成本最低、最快看到端到端 | **不建議**：CDC vs batch polling 的敘事會失去對照組——沒有真的 OLTP，就無法論證「為何不定時撈整張表」，本片最有份量的那份 ADR（§9 的 `0007`）會變成紙上談兵 |

✅ **交易資料模型決定**：欄位採用 plan.md §4.2 契約範例作為起點（`trade_id` / `account_id` / `symbol` / `price` / `quantity` / `side` / `status` / `event_time` / `updated_at`），`symbol` 沿用 Slice 0 的 `2330` / `2454` / `3653` 三檔，讓兩條路徑之後（Slice 3）能 join。plan.md 的範例僅為規劃期臨時參考、非最終定案；開發過程如需調整欄位（新增/刪除/型別修正），以當下實作為準，不需回頭修改 plan.md。

### 3.2 CDC 擷取方式：Debezium on MSK Connect vs AWS DMS vs 自架 Debezium Server

✅ **決定：A. Debezium + MSK Connect**。理由：符合 plan.md §2.1 / §8 主選；相對 B（DMS）維持 Debezium 開放的訊息格式與設定介面，行為可控性與可攜性較高（DMS 是 AWS 專有黑盒引擎、格式不通用）；相對 C（自架）則把 worker 維運負擔交給 AWS 代管，只需自己顧 connector 設定。

**風險與降級路徑**：plugin 打包、VPC 連線、IAM 授權三項目前均未驗證，性質同 Slice 1 的 GX 依賴打包，這正是 §4 項目 6 獨立 spike 的設計目的。若 spike 過程發現環境（Control Tower SCP、VPC 限制等）無法支援這條路徑，則**重新選型**降級為 B（DMS）或 C（自架）——這屬於較大幅度變動，需使用者確認並留 ADR 記錄改選原因（呼應 §8 風險段落既有結論）。

| 選項 | 說明 | 取捨 |
| --- | --- | --- |
| **A. Debezium + MSK Connect**（已選） | 代管的 Kafka Connect，Debezium plugin 打包成 zip 上傳 S3 後建 custom plugin | 符合藍圖；未知項：plugin 打包、VPC 連線、IAM 授權（性質同 Slice 1 的 GX 依賴打包，需要一次獨立 spike 驗證） |
| B. AWS DMS | 全代管，設定簡單 | 訊息格式非 Debezium 標準、可控性低，展示價值較弱 |
| C. Debezium Server / Kafka Connect 自架於 EC2 或 ECS | 完全可控、可省 MSK Connect 費用 | 要自己顧容器與重啟，維運成本轉嫁到自己身上 |

### 3.3 Kafka 佈署形態與資源生命週期

本片是專案第一次出現**常駐計費資源**（Slice 0/1 的 S3/Glue/Athena 幾乎是用多少算多少）。兩件事要一起拍板：

**(a) 佈署形態**

✅ **決定：A. MSK Provisioned**。理由：小流量 side project，provisioned 最小配置比 serverless 便宜；且 serverless 與 MSK Connect 搭配有僅限 IAM 認證的限制，provisioned 沒有這層額外未知數。

| 選項 | 說明 |
| --- | --- |
| **A. MSK Provisioned**（已選） | `kafka.t3.small` × 2 broker，最小可用配置 |
| B. MSK Serverless | 免管理容量，但有每 cluster-hour 的固定基礎費用，**單價明顯高於最小 provisioned 配置**；且與 MSK Connect 的搭配限制（僅 IAM 認證）需先確認 |

> 實際單價需在拍板前查一次官方價目表確認（本節不寫死數字），但方向明確：小流量 side project，provisioned 最小配置比 serverless 便宜。

**(b) 生命週期策略**

✅ **決定：A. 用完即拆**。理由：RDS/MSK/MSK Connect 是本專案第一批常駐計費資源，用完即拆能控制成本。不會有 Slice 1 branch 表那種「刪除等於燒掉證據」的風險——RDS 是 generator 可重現的輸入資料而非證明成果，Kafka topic 在本片的定位是中繼管線而非永久稽核記錄（retention 機制本來就不是為長期留存設計）；真正需要留存的證據落在 runbook 記錄（§4 項目 8/9 的驗證紀錄）與 2b 之後落地的 Iceberg 表。

| 選項 | 說明 |
| --- | --- |
| **A. 用完即拆**（已選） | Slice 2 的網路/MSK/RDS 獨立成一組 Terraform（獨立 state，如 `slice2.tfstate`），驗證期間 `apply`、驗證完 `destroy`；驗收證據靠 runbook 與（2b 之後）S3 上留存的 Iceberg 表 |
| B. 常駐 | 隨時可 demo，但持續計費 |

選 A 的話需要一份啟停 runbook（§4 項目 10），否則下次要 demo 時沒人記得開機順序。**注意 2a／2b 共用同一組資源**，這份 runbook 會被 2b 直接沿用。

### 3.4 序列化格式、Schema Registry 與違約行為

✅ **決定：A. Avro + AWS Glue Schema Registry**。理由：plan.md §2.1 已定為主選，且是本片「Schema Registry 作為契約強制點」展示重點的必要條件（選 B 這個重點會整個消失）。選 Avro 而非 Protobuf（C）純粹因為 Debezium 生態預設以 Avro 為主。

| 選項 | 說明 |
| --- | --- |
| **A. Avro + AWS Glue Schema Registry**（已選） | 契約的技術強制點：註冊相容性規則，破壞性變更在註冊時就被拒絕 |
| B. JSON（無 registry） | 最簡單，但本片「Schema Registry 作為契約強制點」的展示重點會整個消失 |
| C. Protobuf + Glue Schema Registry | 與 A 相當，選 A 只因 Debezium 生態預設以 Avro 為主 |

選 A 時一併決定：

- ✅ **相容性模式決定：`BACKWARD`**。允許刪除欄位（含必填欄位——新 schema 的讀取端本來就不找這個欄位，讀舊資料時直接忽略）、允許新增有 default 值的欄位；**禁止新增沒有 default 值的必填欄位**——舊資料沒有這個欄位又無 default 可補，這才是真正會被 Registry 擋下的破壞性變更，也是 §7／§4 項目 9 要用的測試案例（原先誤植為「刪除必填欄位」，已修正）。
- ✅ **違約訊息去向決定：送 DLQ topic**（`transaction.trade.v1.dlq`）而非阻塞主流程——「壞訊息不擋住好訊息」是串流版本的 WAP 精神（對照 [ADR-0004](../architecture/adr/0004-wap-quality-gate.md) 批次版本的「壞資料不進 Gold」）

---

## 4. 實作項目清單 (Implementation Checklist)

> 項目大致依序執行。

| # | 項目 | 說明 | 產出 | 完成 |
| --- | --- | --- | --- | --- |
| 1 | 網路層 spike | 先建一個最小 VPC + 私有子網 + S3 VPC Endpoint 再 destroy，確認 Control Tower SCP 是否限制 VPC/IGW/NAT（見 §8） | spike 紀錄 | ⬜ |
| 2 | 網路層 Terraform | VPC / 私有子網 / Security Group / VPC Endpoint（S3、Glue）正式化 | `vpc.tf`（獨立 state，依 §3.3(b)） | ⬜ |
| 3 | 交易資料模型與 generator | 依 §3.1 決定，實作交易狀態機 generator（NEW → PARTIALLY_FILLED → FILLED/CANCELLED），對來源 DB 產生 insert/update/delete；比照 `generate_stock_data.py` 保留「注入異常」開關供後續使用 | `src/ingestion/generate_trade_data.py` | ⬜ |
| 4 | 來源 OLTP DB | 依 §3.1 建立 RDS 與 parameter group（logical replication）、初始 schema | `rds.tf` + 建表 DDL | ⬜ |
| 5 | MSK + Schema Registry | 依 §3.3 建立 cluster、topic（`transaction.trade.v1` + DLQ）、Glue Schema Registry 與相容性模式（§3.4） | `msk.tf` / `schema_registry.tf` | ⬜ |
| 6 | Debezium plugin 打包 spike | 依 §3.2，獨立驗證 plugin zip 打包 → S3 → custom plugin 這條路徑（比照 Slice 1 GX 依賴打包的先 spike 後主線慣例） | spike 紀錄 + runbook | ⬜ |
| 7 | CDC connector 部署 | connector 設定（來源連線、topic 命名、Avro converter、DLQ）與 IAM/VPC 授權 | 運作中的 connector | ⬜ |
| 8 | CDC 事件驗證 | 來源 DB 的 insert / update / delete 三種操作都出現在 topic，且帶 before/after 與來源變更序（LSN） | 驗證紀錄 | ⬜ |
| 9 | Schema 破壞性變更驗證 | 註冊一個違反相容性規則的新版 schema（如新增沒有 default 值的必填欄位），確認被 Registry 擋下；違約訊息進 DLQ 而非阻塞主流程 | 驗證紀錄 | ⬜ |
| 10 | 資源啟停 runbook | 依 §3.3(b) 記錄建立/銷毀順序與成本注意事項（2b 沿用同一份） | `docs/runbooks/slice2-stack-lifecycle.md` | ⬜ |
| 11 | Data Contract 第一版 | `trade_events` model：Avro schema、品質規則、違約行為（DLQ）。**SLA（`servicelevels`）留待 2b 實測後補** | `contracts/trade-events.contract.yaml` | ⬜ |
| 12 | 端到端驗證 | 彙總 runbook + 衛星 runbook（依 execution-roadmap.md §3 命名慣例） | `docs/runbooks/slice2a-verification.md` | ⬜ |
| 13 | 文件產出 | 見下方 §9 | ADR / Decision Log | ⬜ |

---

## 5. 輸出 (Outputs)

| 產出 | 內容 | 備註 |
| --- | --- | --- |
| 來源 OLTP `trade` 表 | 模擬交易的當前狀態（含狀態機演進） | 本 Slice 的**來源**，非 Lakehouse 產出 |
| `transaction.trade.v1`（Kafka topic） | Debezium CDC 事件（Avro，含 before/after/op/source metadata） | append（Kafka log） |
| `transaction.trade.v1.dlq`（Kafka topic） | 反序列化失敗 / 違約訊息 | append |
| Glue Schema Registry schema | `trade_events` 的 Avro schema 與相容性模式 | 契約的技術強制點 |
| `contracts/trade-events.contract.yaml`（v1） | topic schema、品質規則、違約行為；SLA 留待 2b 補 | Git 版控 |

---

## 6. 資料品質規則 (Data Quality Rules)

本片的品質防線全部落在「**進 Kafka 前**」，由 Avro schema 與 Registry 相容性規則技術強制；違約者進 DLQ。這與 Slice 1 的 WAP Gate 是同一個精神（壞資料不流向下游），但強制點從「寫表前」前移到「進匯流排前」。

| 維度 | 規則 | 檢核落點 |
| --- | --- | --- |
| 完整性 (Completeness) | `trade_id` / `account_id` / `symbol` / `side` / `status` / `event_time` 不得為 null | Avro schema required |
| 有效性 (Validity) | `side ∈ {BUY, SELL}`；`status ∈ {NEW, PARTIALLY_FILLED, FILLED, CANCELLED}`；`price > 0`；`quantity > 0` | Avro enum + 契約規則 |
| 一致性 (Consistency) | `symbol` 需為 [slice0-batch-market-data.md §3.4](slice0-batch-market-data.md) 定義的合法代號（`2330`/`2454`/`3653`） | 契約規則 |
| 時效性 (Timeliness) | 來源 DB 變更到 topic 可消費的延遲——**本片只量得到這一段**，端到端 SLA 留待 2b | 驗證階段量測 |

> 唯一性 (Uniqueness) 在 topic 層沒有意義（同一 `trade_id` 本來就會有多個事件），留待 2b 的 `silver.trade` 檢核。準確性 (Accuracy) 同理留待 2b 與來源 DB 逐筆比對。

---

## 7. 驗收標準 (Acceptance Criteria)

- [ ] 在來源 DB 做 insert / update / delete，Kafka topic 上都能消費到對應的 CDC 事件，且帶 before / after 影像與來源變更序
- [ ] 一筆交易走完完整狀態機（NEW → PARTIALLY_FILLED → FILLED），topic 上能看到完整的三筆變更軌跡
- [ ] 註冊破壞性 schema 變更時被 Schema Registry 擋下（附錯誤訊息佐證）
- [ ] 違約 / 無法反序列化的訊息進入 DLQ topic，主流程不受阻塞
- [ ] `contracts/trade-events.contract.yaml`（v1）納入版控，與實際註冊的 Avro schema、§6 規則一致
- [ ] Slice 2 的資源可依 §4 項目 10 的 runbook 完整銷毀與重建
- [ ] 上述 §9 文件皆已產出

---

## 8. 相依 (Dependencies) / 風險 (Risks)

- **風險（網路層，本片最大的新面積）**：`infra/environments/dev/` 目前沒有任何 VPC 資源，而 RDS / MSK / MSK Connect 全部需要 VPC、子網與 Security Group，讀寫 S3 與 Glue Catalog 還需要 VPC Endpoint 或 NAT。組織帳號受 Control Tower 治理（見 CLAUDE.md），VPC/IGW/NAT 是否受 SCP 限制**尚未驗證**。→ §4 項目 1 的最小網路 spike 就是為此設計，先確認治理限制再往下做。

- **風險（MSK Connect × Debezium 打包）**：性質同 Slice 1 的 GX 依賴打包——Debezium plugin 需打包成 zip 上 S3 再建 custom plugin，connector 的 IAM 認證與 VPC 連線設定皆未驗證。→ §4 項目 6 獨立 spike 並留 runbook，不在主線實作中撞牆。若整條路徑卡關，降級為 §3.2 的 B（DMS）或 C（自架），屬較大幅度變動，需使用者確認並留 ADR。

- **風險（成本）**：MSK + MSK Connect + RDS 皆為常駐計費，量級與 Slice 0/1 完全不同。→ 由 §3.3(b) 的生命週期策略與 §4 項目 10 的啟停 runbook 控管；建議在第一次 `apply` 前先估一次月費上限。

- **風險（Terraform state 切分）**：§3.3(b) 若選「用完即拆」，Slice 2 資源需與 Slice 0/1 的長期資源分離到不同 state，否則 `destroy` 會誤傷既有 Lakehouse 資源。→ state 切分方式需在 §4 項目 2 動工前確定。

---

## 9. 相關文件 (Related ADR / Pattern / Contract)

本片完成時需產出：

- `docs/specs/slice2a-cdc-ingestion.md` — 本文件
- `docs/architecture/adr/0006-msk-vs-kinesis.md` — 為何選 MSK（生態、可重播、Connect）
- `docs/architecture/adr/0007-cdc-vs-batch-polling.md` — 為何用 CDC 而非定時撈整張表（來源負載、延遲、抓不到中間態、刪除偵測）
- `contracts/trade-events.contract.yaml`（v1）— 第二份生效契約，本專案第一份 streaming 契約
- `docs/runbooks/slice2-stack-lifecycle.md` — 資源啟停（2b 沿用）
- `docs/runbooks/slice2a-verification.md` — 本片定案驗證文件（衛星 runbook 由其彙總引用）
- Decision Log：§3 各項技術選型（來源 DB、CDC 方式、MSK 佈署形態、序列化格式）

> **ADR 編號**：`0004` 已被 Slice 1 的 `0004-wap-quality-gate.md` 佔用，`0005` 已被規劃期間額外產出的 [`0005-project-admin-permission-exemption.md`](../architecture/adr/0005-project-admin-permission-exemption.md) 佔用（Lake Formation 權限治理決策，非 Slice 2 敘事的一部分），故本片取下一個可用編號 `0006` / `0007`。execution-roadmap.md Slice 2 段落目前仍寫 `0004-msk-vs-kinesis.md`，需同步修正；Slice 3 之後的編號不預先調整，留待各該 Slice 開始時依當時可用編號決定（開發過程可能產出原規劃未涵蓋的 ADR）。修改 execution-roadmap.md 屬高風險操作，需經 `planning_project` skill 取得確認後執行。
