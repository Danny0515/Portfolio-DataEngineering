# Spec: Slice 2b — 串流 upsert 落地（Kafka → Iceberg 當前狀態表）

> 對應 [execution-roadmap.md](../../execution-roadmap.md) Slice 2 的後半段。
> 對應 [plan.md](../../plan.md) §7 分階段交付：Phase 1b（Streaming 主幹）。
> 前半段見 [slice2a-cdc-ingestion.md](slice2a-cdc-ingestion.md)。
> 狀態：**§3 待確認事項已全數拍板** — 以下 §4 實作項目清單即為實作依據。
> 修訂註記：Kafka → Bronze 這一段已依 [ADR-0012](../architecture/adr/0012-kafka-connect-iceberg-sink-bronze.md)（💬 `Proposed`，待 §4 項目 1 spike 通過後轉 `Accepted`）改由 Iceberg Kafka Connect sink 負責，§1、§2、§3.1、§3.2、§4、§5、§8、§9 已同步調整；spike 不通過則回到 [ADR-0010](../architecture/adr/0010-glue-streaming-vs-managed-flink.md) 的原設計。

---

## 1. 目標 (Goal)

把 Slice 2a 送進 Kafka 的 CDC 事件，用串流運算落進 Lakehouse：Bronze 原樣 append 保留完整變更軌跡，Silver 以 **MERGE INTO（upsert）** 維護每筆交易的當前狀態。

**這片是整個作品集判斷力的核心展示**，因為它有 Slice 0 當對照組：

| Slice | 證明的事 | 寫入模式 | 為何是這個模式 |
| --- | --- | --- | --- |
| 0 | 水電管線通了 | append / 全量覆寫 | 歷史行情是 immutable 事實，不會被更新 |
| 1 | 管線會自己擋下壞資料 | 同上，加 WAP Gate | 同上 |
| 2a | 變更擷取得到、契約強制得了 | Kafka append | 事件本身是 immutable |
| **2b** | **管線能反映「會變的事實」** | **MERGE INTO（upsert）** | **交易狀態本質上會演進：下單 → 部分成交 → 成交/取消** |

Slice 0 用 append 不是因為簡單，是因為資料不會變；2b 用 upsert 不是因為進階，是因為資料會變。**這個對比就是本片 Decision Log 的主軸**。

資料流（本片範圍以 `▓` 標示）：

```
  Trade DB → Debezium → MSK topic (Avro + Schema Registry)   ← Slice 2a
▓   → Iceberg Kafka Connect sink (MSK Connect)             ← 擷取：無自訂程式，ADR-0012
▓       → bronze.trade_events (append)     ← CDC 事件落地（Avro 型別），可重播、可回溯「這筆單怎麼一步步變成現在這樣」
▓   → 串流運算 (Glue Streaming / Spark Structured Streaming，以 Bronze 為來源)
▓       ├→ silver.trade         (MERGE INTO) ← 每個 trade_id 一列，反映當前合規狀態
▓       └→ silver.trade_rejects (append)     ← 違規事件隔離
▓   → Athena 查得到當前狀態，且與來源 DB 逐筆一致
```

---

## 2. 範圍 (Scope) / 非範圍 (Non-Goals)

**範圍內**：
- Iceberg Kafka Connect sink（MSK Connect）與 Silver 串流作業（Glue Streaming，讀 Bronze）的部署與最小 spike（引擎選型見 §3.1、擷取段見 [ADR-0012](../architecture/adr/0012-kafka-connect-iceberg-sink-bronze.md)）
- Bronze：CDC 事件 append-only 落地，由 connector 負責（延續 Slice 0 的 Bronze 職責：不清洗、可重跑；保存形式改為有型別欄位，見 §3.2）
- Silver：以 MERGE INTO 維護當前狀態表，含亂序 / 重播的冪等處理與刪除事件處理
- Silver 品質閘：逐筆規則 + 隔離表（`silver.trade_rejects`），規則與批次共用 GX 規則格式（見 §3.4、[ADR-0011](../architecture/adr/0011-streaming-silver-quality-gate.md)）
- 端到端延遲實測，並把 SLA 寫回 `contracts/trade-events.contract.yaml`
- 契約補上 Silver 層 model（2a 只寫了 topic 層）
- 準確性驗證：`silver.trade` 與來源 OLTP DB 逐筆比對——**本專案第一次做得到**（Slice 0/1 沒有外部真實來源可比對）

**刻意不做 (Out of Scope)**：
- **視窗聚合、即時風控指標、即時 OLAP（Pinot）** → Slice 3。本片只做「狀態正確」，不做「指標即時」
- **Gold 層交易寬表** → §3.2 已決定不做（與 Slice 3 的即時聚合高度重疊）
- **串流路徑的營運監控與排程稽核** → Slice 1 的 WAP Gate 是為批次設計的（整批寫 staging → 整批稽核 → 整批發布），串流沒有「批次邊界」這個概念，不照搬；本片改採逐筆規則 + 隔離表（見 §3.4）。排程批次稽核、定期對帳、`observe` + `StreamingQueryListener` 告警與 CloudWatch 指標需要排程器與告警基礎設施，留 Slice 4
- 交易資料與市場行情的 join、對帳 → 需要兩條路徑都成熟，留待 Slice 3 之後
- 血緣、CI/CD、多環境、Airflow 編排 → Slice 4
- 修改 Slice 0/1 既有的 `bronze.stock` / `silver.stock` / `gold.monthly_ohlcv` 與 WAP Gate 邏輯

---

## 3. 待確認事項

### 3.1 串流運算引擎：Managed Flink vs Glue Streaming（本片最重要的取捨）

| 選項 | 說明 | 取捨 |
| --- | --- | --- |
| **A. Amazon Managed Service for Apache Flink**（plan.md 主選） | PyFlink/Java 應用打包上傳 S3，Flink 消費 Kafka → Iceberg sink（upsert mode） | 符合藍圖、真串流語意（event time、watermark、狀態管理），且 Slice 3 的視窗聚合本來就要用 Flink，這裡先建立技術棧不會白做；未知項：Flink Iceberg connector 對 **Glue Catalog** 的支援度、upsert mode 設定、PyFlink 依賴打包 |
| B. AWS Glue Streaming（Spark Structured Streaming） | 沿用 Slice 0/1 已建立的 Glue + PySpark + Iceberg + IAM/Lake Formation 技術棧，用 `foreachBatch` 內做 `MERGE INTO` | 未知項最少、成本最低、最快跑通；代價是「微批次」而非真串流，Slice 3 的視窗運算仍得換 Flink，等於這條路要走兩次 |
| C. Iceberg Kafka Connect sink 寫 Bronze ＋ Glue Streaming 讀 Bronze 做 Silver（見下方補充決定） | Kafka → Bronze 由託管的 sink connector（MSK Connect）負責，Silver 的 Glue Streaming 作業改以 Bronze 為來源，不連 Kafka | 把 B 路線最大的未知項（Glue × 私有子網 MSK × Glue SR 解碼）移出關鍵路徑，且擷取與解讀故障域分離；代價是多一個 connector 與 plugin、延遲拉長到分鐘級、sink 在 MSK Connect 上的行為尚未驗證 |

✅ **決定：B. AWS Glue Streaming**（Spark Structured Streaming，`foreachBatch` 內 `MERGE INTO`）。理由：
- 本片核心是 append 對 `MERGE INTO` 的對照，B 字面上就是 `MERGE INTO`，且可明寫 `WHEN MATCHED AND s.lsn > t.lsn`，重播冪等最好證明；A 的 Iceberg sink 是「後到者贏」不比較 LSN，需自行補排序邏輯。
- A 沒有現成可解 Glue Schema Registry Debezium Avro 的 SQL format，可能要寫 Java，且有多項需實測的未知項（Iceberg sink × Glue Catalog、hidden partitioning、Athena 讀 equality delete、版本相容、打包）。
- B 沿用 Slice 0/1 的 Glue + PySpark + Iceberg + Lake Formation 技術棧，未知項明顯較少。
- 本片只是把 topic 的來源資料納入 Lakehouse，可接受秒級延遲誤差；Flink 優於 Glue Streaming 的視窗運算要到 Slice 3 才真正需要。

**Slice 3 的引擎不在此決定**：兩者銜接點是 Kafka topic 與 Iceberg 表，皆引擎中立，本片的選擇不會鎖死 Slice 3；該 Slice 的 spec §3 再重新評估（Flink 或 Glue Streaming）。完整論述與替代方案見 [ADR-0010](../architecture/adr/0010-glue-streaming-vs-managed-flink.md)。

**補充決定（💬 Proposed，[ADR-0012](../architecture/adr/0012-kafka-connect-iceberg-sink-bronze.md)）：採 C**。選 B 的結論不變（Silver 仍由 Glue Streaming 以 `MERGE INTO` 維護），但**職責範圍縮小為「Bronze → Silver」**：Kafka → Bronze 改由 Iceberg Kafka Connect sink 負責。理由：
- B 路線的未知項集中在 Glue 作業連 MSK 與在 Spark 內解 Glue SR 的 Debezium Avro；改為讀 Bronze 後，Glue 作業只碰 Iceberg，沿用 Slice 0/1 已驗證的技術棧。
- 擷取與解讀分屬不同故障域：Silver 的 bug 或停機不再阻擋事件落地，降低落後超過 Kafka retention 而遺失事件的風險（Slice 2 用完即拆，Bronze 是唯一長期事件紀錄）。
- LSN 排序、軟刪除（§3.3）、逐筆規則與隔離（§3.4）完全不變。

退路：§4 項目 1 的 spike 若不通過，回到 B 的原設計（Glue Streaming 直連 Kafka，同時寫 Bronze 與 Silver），並將 ADR-0012 標為 Rejected。

> 決策提醒：Slice 1 的經驗是「未知項要用一次獨立 spike 提前解除，而不是在主線實作中撞牆」，且「本機驗證不能替代正式環境驗證」（Iceberg branch 在本機 Hadoop catalog 能用，不代表 Glue Catalog 能用）。→ §4 項目 1 的最小 spike 為此而設，需驗證兩件事：(1) Iceberg sink 在 MSK Connect 上的 plugin 打包、解 Glue SR、寫入 Glue Catalog 且 Athena 讀得到、Lake Formation 授權；(2) Glue Streaming 讀 Bronze（Iceberg）並 `MERGE INTO` 寫 Silver、Athena 讀得到。

### 3.2 目標表分層與命名

比照 plan.md §2.2 的命名模式（Glue database 即層級 `bronze` / `silver` / `gold`，表名為子類型、不加 `_data` 尾綴），交易領域的子類型為 `trade`。注意：Slice 0 的 S3 路徑 `raw/market/stock/` 是 raw landing，2b 沒有對應的 raw landing（Kafka topic 本身就是 raw），Iceberg 表的實際位置由 Glue Catalog 的 warehouse 決定，不另訂 S3 路徑。

| 選項 | 說明 |
| --- | --- |
| **A. Bronze（事件 append）+ Silver（當前狀態 upsert）**（建議） | `bronze.trade_events`（每個 CDC 事件一列，append）+ `silver.trade`（每個 `trade_id` 一列，MERGE INTO）。Bronze 保留完整變更歷史，正是「可重播、可稽核」的證據 |
| B. 只做 Silver（Kafka → 直接 upsert） | 少一層、實作快；但失去可重播來源，且違反 Slice 0 已確立的 Bronze 職責（[ADR-0002](../architecture/adr/0002-medallion-layering.md)） |
| C. A + Gold（部位/成交彙總） | 與 Slice 3 的即時聚合高度重疊，建議不做 |

✅ **決定：A. Bronze（`bronze.trade_events`）+ Silver（`silver.trade`），不做 Gold**。理由：
- Slice 2 資源採「用完即拆」，Kafka topic 是中繼管線而非永久紀錄（[slice2a §3.3(b)](slice2a-cdc-ingestion.md)），stack 銷毀後事件就消失，**Bronze 是唯一可重播、可稽核的事件紀錄**，也延續 [ADR-0002](../architecture/adr/0002-medallion-layering.md) 的 Bronze 職責。
- 2b 的 Silver 直接給 Athena 查詢（不經 Gold），與 Slice 0 由 Gold 對外服務不同；Gold 的部位／成交彙總與 Slice 3 的即時聚合高度重疊，不做。

**命名**：Glue database 沿用既有的 `bronze` / `silver`，不新增。`bronze.trade_events` 保留 `_events` 尾綴，是**對 plan.md §2.2 `<layer>.<子類型>` 模式的刻意例外**——兩層粒度不同（Bronze 是一事件一列、Silver 是一交易一列），尾綴用來標明粒度；Silver 為 `silver.trade`。

**Bronze 保存形式（有型別欄位，不清洗；依 [ADR-0012](../architecture/adr/0012-kafka-connect-iceberg-sink-bronze.md) 調整，取代原本的「全字串」設計）**：一個事件一列，由 Iceberg sink 依 topic 上的 Avro schema 寫出有型別的欄位，涵蓋 `op`、`before`、`after`（結構欄位，`price` 等 decimal 維持 decimal）、來源變更序（`source.lsn`）與事件時間。Avro 已保證型別，Slice 0 Bronze「全字串」原則所防的 `inferSchema` 偏移在這裡不成立，故不套用；Bronze 仍不去重、不過濾、不做任何值規則，型別以外的清洗與規則由 Silver 負責。確切欄位、可取得的 provenance（Kafka partition／offset／寫入時間）、tombstone（value 為 null）是否落地、表由 connector auto-create 或預先建立（對照 [docs/TODO.md](../TODO.md)「建表與寫資料拆分」），均於 §4 項目 1 spike 定案。串流為至少一次傳遞，重播時 Bronze 預期累加。

**契約**：Bronze 不納入契約（同 Slice 1 的 `market-data.contract.yaml` 只含 Silver／Gold）。契約 v2 於項目 9 新增指向 Glue／Iceberg 的 server 與 Silver model；現有 model `trade` 已用來描述 topic 上 `before` / `after` 的一列交易，Silver model 需避開此名稱（暫定 `silver_trade`，於項目 9 定案）。

### 3.3 「最新版本」的判定與冪等策略

CDC + upsert 最容易出錯的地方：**同一個 `trade_id` 的多個事件亂序抵達或被重播時，MERGE INTO 憑什麼決定誰是最新？**

| 選項 | 說明 |
| --- | --- |
| **A. 來源 DB 的變更序（LSN / binlog position）**（建議） | Debezium 會帶 `source.lsn`；單調遞增、與來源系統的真實順序一致，重播不會覆蓋成舊值 |
| B. 事件時間 `updated_at` | 語意直覺，但同毫秒內多次更新無法決勝負 |
| C. Kafka offset | 同一 partition 內有序，但跨 partition 無意義（需先保證 `trade_id` 作為 partition key） |

不論選哪個，MERGE 前都要先在批次內對 `trade_id` 做「取最新一筆」的 dedup（`row_number()` over 排序鍵），否則同一批次內的多筆變更會讓 MERGE 語意不確定。

**刪除事件（`op='d'`）的處理方式一併決定**：

| 選項 | 說明 |
| --- | --- |
| **A. 軟刪除**（建議） | Silver 保留該列並標記 `is_deleted = true`，可稽核、可回答「這筆單什麼時候被刪的」 |
| B. 硬刪除 | `MERGE ... WHEN MATCHED THEN DELETE`，Silver 與來源 DB 完全一致，但下游查不到刪除事實 |

✅ **決定：排序鍵 A（`source.lsn`）、刪除 A（軟刪除）**。

**MERGE 規則**：
- 批次內先以 `row_number() over (partition by trade_id order by source_lsn desc)` 取每個 `trade_id` 的最新一筆。
- `WHEN MATCHED AND s.source_lsn > t.source_lsn THEN UPDATE`、`WHEN NOT MATCHED THEN INSERT`。用**嚴格大於**，同一事件重播時比較結果為相等、不更新，即為冪等。
- `op` 為 `r`（初始快照）、`c`、`u` 皆視為 upsert；tombstone 先濾掉；`op='d'` 以 `before` 的欄位值寫入並標 `is_deleted = true`、更新 `source_lsn`。
- 排序與去重一律用 payload 內的 `trade_id` 與 `source.lsn`，不依賴 Kafka key 或 partition（2a 的 key 是 `StringConverter` 套在主鍵結構上，實際內容尚未驗證）。
- Silver 作業的來源是 Bronze（[ADR-0012](../architecture/adr/0012-kafka-connect-iceberg-sink-bronze.md)），`trade_id`、`source.lsn` 取自 Bronze 的有型別欄位；排序與 `MERGE` 規則本身不受來源改變影響。

**為何刪除選軟刪除**：硬刪除會讓重播時舊的 insert / update 事件因「找不到」而被重新寫入，**復活已刪除的資料，違反 §7 的重播冪等**；軟刪除下舊事件的 LSN 較小，比較後被忽略。另外軟刪除不需要 Lake Formation 的 `DELETE` 權限，且同一 `trade_id` 日後若重新 insert，LSN 較大，會自然把 `is_deleted` 改回 false。

**Silver 額外欄位**：`source_lsn`、`is_deleted`（其餘欄位於項目 2 設計）。

**代價**：Athena 使用者需加 `WHERE NOT is_deleted` 才看得到當前存在的交易（可日後提供 view）；§4 項目 7 與來源 DB 比對時需排除 `is_deleted` 的列。

**前提與待實測**：此決定依賴三項前提（同交易內 LSN 是否各不相同、重建後 `trade_id` 不重複、`op='r'` 的 LSN 順序），已列於 §4 項目 1 下方，於 spike 階段實測。

### 3.4 串流路徑的品質防線是否延伸到表層

| 選項 | 說明 |
| --- | --- |
| **A. 沿用 2a 的 Schema Registry + DLQ，表層不再加關卡**（建議） | 品質防線落在「進 Kafka 前」；Silver 的正確性由 §7 的逐筆比對驗證，而非常駐關卡 |
| B. A ＋ 對 `silver.trade` 定期跑 GX 批次稽核 | 複用 Slice 1 的 GX 資產，但「串流表的批次稽核」語意曖昧（稽核的是哪個時間切片？失敗要回滾什麼？），建議留待 Slice 3/4 想清楚再做 |

✅ **決定：不採上列 A／B，改採「Registry 管結構、Silver 管值」的逐筆規則 + 隔離**（A 的擴充）。查證後發現 A 的前提不成立：2a 契約 `quality` 區塊的 11 條可執行規則，真實 schema 上只有 `trade_id` 非空被強制，其餘值規則（非空、值域、`price`／`quantity` 大於 0、`symbol` 代號）沒有任何系統執行；Silver 又是本專案的可信層，不能只是來源的忠實鏡像。完整論述與替代方案見 [ADR-0011](../architecture/adr/0011-streaming-silver-quality-gate.md)。

- **分工**：Registry 保證「長得對」（結構、型別、schema 演進相容），Silver 保證「值對、狀態對、不重複」；進入 Silver 的資料必須符合 Silver 的完整規則集，不限於下列項目。
- **機制**：在 `foreachBatch` 內逐列判斷，合規列 `MERGE INTO silver.trade`，違規列寫入 `silver.trade_rejects`（原事件、違規原因、時間），不擋住其他列；Bronze 仍保留所有事件。串流來源為 Bronze 的 Iceberg append 快照（[ADR-0012](../architecture/adr/0012-kafka-connect-iceberg-sink-bronze.md)），逐筆規則與隔離機制不變。
- **規則集（成員資格規則，全部在 2b）**：型別轉換（失敗即隔離）；完整性（`trade_id`、`account_id`、`symbol`、`side`、`status`、`event_time` 非空）；有效性（`side`、`status` 值域，`price`、`quantity` 大於 0）；一致性（`symbol` 合法代號；`op='u'` 以 `before.status → after.status` 檢查狀態轉移，不得從 `FILLED` 退回 `NEW`）；唯一性由 `MERGE` 以 `trade_id` 為鍵保證；去重與冪等由 §3.3 的 LSN 比較保證。`op='d'` 不驗證值，以軟刪除處理。
- **規則單一來源**：規則寫成 `src/quality/rules/silver_trade.yaml`，沿用 Slice 1 的 GX 規則名稱與檔案格式，Glue job 以 `--extra-files` 載入；契約 v2 的 `quality` 區塊引用同一組規則並標註強制位置，另以 pytest 檢查兩者一致。
- **執行引擎與批次不同**：批次（Slice 1）以 GX 引擎對整個 staging 表驗證；串流以輕量 PySpark 把同一套規則翻成 Spark 運算式逐列判斷。規則定義共用，引擎不同，評估器可用本機 `pyspark` 單元測試。
- **邊界**：營運監控（排程批次稽核、定期對帳、`observe` + Listener 告警、CloudWatch 指標）留 Slice 4；2b 只做每批次計數日誌與驗證階段的一次性對帳（§4 項目 7）。
- **對 Silver 定義的影響**：`silver.trade` 是「來源的最新**合規**狀態」；若某筆交易的第一個事件違規被隔離，之後合規的更新會以新增一列進入 Silver，更早的歷史只在 Bronze；隔離表不自動重放，修復靠人工。

---

## 4. 實作項目清單 (Implementation Checklist)

> 項目大致依序執行。前置條件：Slice 2a 全部完成（topic 上有可消費的 CDC 事件）。Slice 2 的雲端資源依「用完即拆」目前為已銷毀狀態，開工前需依 [slice2-stack-lifecycle.md](../runbooks/slice2-stack-lifecycle.md) 三階段冷啟動，topic 內容需重新用 generator 產生。

| # | 項目 | 說明 | 產出 | 完成 |
| --- | --- | --- | --- | --- |
| 1 | 擷取與串流 spike | 依 §3.1 的補充決定（[ADR-0012](../architecture/adr/0012-kafka-connect-iceberg-sink-bronze.md)），分兩個獨立最小 spike，通過後才接真實資料。**(a) Iceberg Kafka Connect sink on MSK Connect**：plugin 打包（與 Glue SR converter 合併成單一 plugin，沿用 [Pattern Card](../patterns/msk-connect-single-plugin-per-connector.md)）、runtime 套件含 Glue Catalog 所需 AWS bundle 且與 Iceberg 版本相容、能解 Glue Schema Registry 的 Debezium Avro、寫入 Glue Catalog 且 Athena 讀得到、控制 topic 與 IAM／Lake Formation 授權、commit 間隔取捨、tombstone 處理、表由 connector auto-create 或預先建立。**(b) Silver 串流作業**：Glue Streaming 以 Bronze（Iceberg）為串流來源，`foreachBatch` 內 `MERGE INTO` 寫入 Glue Catalog 且 Athena 讀得到，並實測 G.025X worker 在 Glue 5.0 是否可用、compaction 產生的 replace 快照對串流讀取的影響。**任一 spike 不通過，回到 ADR-0010 的原設計**；**另有附帶的實測確認項，見表格下方** | spike 腳本 + runbook | ⬜ |
| 2 | 表結構與權限 | 建立 `bronze.trade_events` / `silver.trade` 的 Glue database/table 權限（Lake Formation grant，比照 Slice 0 既有模式；connector 的執行角色另需一組 grant），partition 設計依查詢模式決定 | Terraform 資源 | ⬜ |
| 3 | Bronze CDC 事件落地 | 部署 Iceberg sink connector，把 CDC 事件 append 進 `bronze.trade_events`（有型別欄位，見 §3.2），保留 `op` / `before` / `after` / 來源變更序 | Iceberg table `bronze.trade_events` + connector 設定 | ⬜ |
| 4 | Silver MERGE INTO | 以 Bronze 為來源，依 §3.3 的排序鍵做批次內 dedup 後 `MERGE INTO silver.trade`，含刪除事件處理；僅合規列進入 MERGE（見項目 5） | Iceberg table `silver.trade` | ⬜ |
| 5 | Silver 品質規則與隔離 | 依 §3.4 與 [ADR-0011](../architecture/adr/0011-streaming-silver-quality-gate.md)：建立 `src/quality/rules/silver_trade.yaml`（沿用 Slice 1 的 GX 規則名稱）、規則評估器（把規則翻成 Spark 運算式逐列判斷，含 `op='u'` 以 `before.status → after.status` 檢查狀態轉移）、隔離表 `silver.trade_rejects`、每批次計數日誌（進來／合規／隔離各幾列）；評估器以本機 `pyspark` 單元測試，另加 pytest 檢查規則檔與契約 `quality` 區塊一致 | 規則檔 + 評估器 + Iceberg table `silver.trade_rejects` + 測試 | ⬜ |
| 6 | 冪等 / 重播驗證 | 重播同一批事件，確認 `silver.trade` 筆數與內容不變：重置 Silver 串流作業的 checkpoint 從 Bronze 重讀，並重置 sink 的 offset 重播 Kafka（Bronze 則預期累加，同 Slice 0 的重跑語意） | 驗證紀錄 | ⬜ |
| 7 | 準確性比對 | `silver.trade` 與來源 OLTP DB 逐筆比對（筆數 + 抽樣欄位值）；差異須恰好等於 `silver.trade_rejects` 內的 `trade_id`，並排除 `is_deleted` 的列 | 驗證紀錄 | ⬜ |
| 8 | 端到端延遲實測 | 量測來源 DB 變更 → `silver.trade` 可查詢的延遲（含 sink 的 commit 間隔與 Silver 作業的觸發間隔），訂出可達成的 SLA | 實測數字 | ⬜ |
| 9 | Data Contract 補完 | 契約補上 Silver model（避開現有的 `trade`，暫定 `silver_trade`）與 `servicelevels`（依項目 8 實測值）；每條 `quality` 規則標註強制位置（Registry／Silver 隔離／未強制）並引用 `silver_trade.yaml`；修正 `trade` model 上不適用於 topic 層的 `unique: true` | `contracts/trade-events.contract.yaml`（v2） | ⬜ |
| 10 | 端到端驗證 | 彙總 runbook + 衛星 runbook（依 execution-roadmap.md §3 命名慣例） | `docs/runbooks/slice2b-verification.md` | ⬜ |
| 11 | 文件產出 | 見下方 §9 | Pattern Card / ADR / Decision Log | ⬜ |

**項目 1 spike 附帶的實測確認項**（§3.3 排序鍵選 `source.lsn`、刪除選軟刪除，以下三項是該決定成立的前提，需在 Slice 2 stack 冷啟動後的 spike 階段實測，結果寫進 spike runbook；任一項不成立就回頭修訂 §3.3 與項目 4 的 MERGE 條件）：

1. **同一交易內多筆變更的 LSN 是否各不相同**：讓 generator（或手動）在單一交易內對來源表做多筆變更，檢查 topic 上這些事件的 `source.lsn` / `source.sequence` / `source.txId`。各不相同，則 MERGE 條件維持嚴格大於（`s.source_lsn > t.source_lsn`）；若會相同，需補 tie-break（`source.sequence`、`txId` 或 Kafka offset）並同步修訂項目 4。
2. **重建後 `trade_id` 不重複**：「stack 重建後 LSN 歸零不影響 MERGE」依賴「同一個 `trade_id` 只存在於一個 DB 生命週期」。需確認 generator 的 `trade_id`（目前觀察到的格式 `T<epoch 秒>-<序號>`）在固定 `seed` 參數下，跨多次執行與跨重建都不會重複；若會重複，重建後新事件的 LSN 會比 Silver 內舊列小而被忽略，需改排序鍵或在重建時清空 Silver。
3. **`op='r'`（初始快照）的 LSN 與後續變更的相對順序**：確認 `r` 事件的 `source.lsn` 小於其後同一筆交易的 `c`/`u`/`d` 事件，以及 connector 重新 snapshot 後，同一 `trade_id` 的 `r` 事件不會把 Silver 較新的狀態蓋回舊值（`r` 視同 upsert，與 `c`/`u` 走同一個比較條件）。

**2a 證據缺口補查**（stack 冷啟動後順手確認，不阻擋 2b；2b 的值規則由 Silver 強制，不依賴這兩項）：

1. **真實 schema `transaction.trade.v1` 的相容性模式**：2a 項目 9 的 `BACKWARD` 拒絕實測是對測試替身 `trade_events` 做的，runbook 以「同一個 registry、同一個模式」推論兩者相同，但 Glue 的相容性是依 schema 設定，真實 schema 由 converter 自動註冊、`msk_connector.tf` 沒有明確設定。用 `aws glue get-schema` 確認，若不是 `BACKWARD` 需修正契約與 Terraform。
2. **DLQ 端到端觸發**：2a 只確認了 DLQ 的設定與可達性，從未真的讓一筆訊息進 DLQ（Postgres 不允許對有資料的表新增無預設值的 `NOT NULL` 欄位，造不出真實的序列化失敗）。若有可行的低風險觸發方式則補做，否則維持現況並在驗證 runbook 據實註明。

---

## 5. 輸出 (Outputs)

| 表 | 層級 | 內容 | 寫入模式 |
| --- | --- | --- | --- |
| `bronze.trade_events` | Bronze | CDC 事件落地，一個事件一列（含 `op`/`before`/`after`/來源變更序，有型別欄位，見 §3.2） | append，由 Iceberg sink connector 寫入（職責與 Slice 0 `bronze.stock` 一致：不清洗、可重跑） |
| `silver.trade` | Silver | 每個 `trade_id` 一列的「最新合規狀態」（含 §3.3 決定的刪除標記；違規事件隔離在 `silver.trade_rejects`） | **MERGE INTO（upsert）** ← 與 Slice 0 `silver.stock` 的全量覆寫形成對照 |
| `silver.trade_rejects` | Silver | 違反 Silver 規則的事件（原事件、違規原因、時間），不進 `silver.trade`，供稽核與人工修復 | append |
| `src/quality/rules/silver_trade.yaml` | 規則 | Silver 逐筆規則的單一來源（沿用 Slice 1 的 GX 規則名稱），契約 v2 引用 | Git 版控 |
| `contracts/trade-events.contract.yaml`（v2） | 契約 | 2a 的 topic model + 本片補上的 Silver model、實測 SLA 與每條規則的強制位置標註 | Git 版控 |

---

## 6. 資料品質規則 (Data Quality Rules)

本片首次讓 plan.md §3 的**時效性 (Timeliness)** 與**準確性 (Accuracy)** 兩個維度變得可定義——批次路徑（Slice 1）沒有有意義的延遲概念，也沒有外部真實來源可比對，串流 + CDC 兩者都有。

| 維度 | 規則 | 檢核落點 |
| --- | --- | --- |
| 唯一性 (Uniqueness) | `silver.trade` 中每個 `trade_id` 恰好一列 | 由 `MERGE` 以 `trade_id` 為鍵保證（批次內先去重），驗證階段再以 SQL 確認 |
| 一致性 (Consistency) | 狀態轉移需符合 [slice2a §3.1](slice2a-cdc-ingestion.md) 的狀態機（不得從 `FILLED` 退回 `NEW`）；`symbol` 為 Slice 0 定義的合法代號 | Silver 逐筆規則：`op='u'` 以 `before.status → after.status` 檢查，違規列進 `silver.trade_rejects`（見 §3.4、[ADR-0011](../architecture/adr/0011-streaming-silver-quality-gate.md)） |
| **時效性 (Timeliness)** | 來源 DB 變更到 `silver.trade` 可查詢的端到端延遲，建議先訂寬鬆的分鐘級 SLA，實測後再收斂並寫入契約 `servicelevels` | §4 項目 8 |
| **準確性 (Accuracy)** | `silver.trade` 與來源 OLTP DB 逐筆一致，差異僅限 `silver.trade_rejects` 內被隔離的 `trade_id`（排除 `is_deleted` 的列） | §4 項目 7 |
| 完整性 / 有效性 | `trade_id`、`account_id`、`symbol`、`side`、`status`、`event_time` 非空；`side`、`status` 值域；`price`、`quantity` 大於 0。2a 的 Avro schema 與 Registry 實際只強制 `trade_id` 非空（見 [slice2a §6](slice2a-cdc-ingestion.md) 與契約「誠實落差」），其餘由 Silver 強制 | Silver 逐筆規則，違規列進 `silver.trade_rejects`（見 §3.4） |

---

## 7. 驗收標準 (Acceptance Criteria)

- [ ] 在來源 DB 做 insert / update / delete，`silver.trade` 能在 SLA 內正確反映當前狀態（逐筆與來源 DB 比對，差異僅限被隔離的 `trade_id`）
- [ ] 同一批訊息重播後，`silver.trade` 筆數與內容不變（冪等），`bronze.trade_events` 則如預期累加
- [ ] 一筆交易走完完整狀態機（NEW → PARTIALLY_FILLED → FILLED），`silver.trade` 只留最終狀態一列，`bronze.trade_events` 保留完整三筆變更軌跡
- [ ] 刪除事件依 §3.3 決定的方式正確反映在 `silver.trade`
- [ ] 注入異常資料（generator 的注入異常開關）後，違規事件進入 `silver.trade_rejects`（含違規原因），`silver.trade` 不含這些資料，且同批的合規列照常更新、不被阻塞；包含非法狀態轉移（例如 `FILLED` 退回 `NEW`）被隔離
- [ ] 規則檔 `silver_trade.yaml` 與契約 v2 的 `quality` 區塊一致（pytest 驗證），評估器通過本機 `pyspark` 單元測試
- [ ] 端到端延遲有實測數字並寫回契約 `servicelevels`
- [ ] `contracts/trade-events.contract.yaml`（v2）的 Silver model 與 `silver.trade` 實際 schema 一致
- [ ] 上述 §9 文件皆已產出

---

## 8. 相依 (Dependencies) / 風險 (Risks)

- **相依**：Slice 2a 需全部完成——topic 上要有帶 before/after 與來源變更序的 CDC 事件，本片才有東西可消費。
- **相依**：Slice 0 的 Bronze/Silver 分層職責（[ADR-0002](../architecture/adr/0002-medallion-layering.md)）與 append/覆寫取捨（[ADR-0003](../architecture/adr/0003-append-vs-overwrite.md)）已定案——本片的 upsert 論述完全建立在這兩份 ADR 的對照上。

- **風險（Iceberg sink × MSK Connect × Glue Catalog）**：本片最大的未知項（依 [ADR-0012](../architecture/adr/0012-kafka-connect-iceberg-sink-bronze.md)，取代原本的「Glue Streaming × MSK × Glue SR」）。Iceberg Kafka Connect sink 需打包成 custom plugin（與 Glue SR converter 合併成單一 plugin），runtime 套件是否含 Glue Catalog 所需的 AWS bundle、與目前 Iceberg 版本是否相容、控制 topic 與 IAM／Lake Formation 授權、tombstone 處理、commit 間隔取捨，皆未驗證。Slice 1 已有前例：本機可用不代表 Glue Catalog 可用。→ §4 項目 1(a) 的最小 spike 就是為此設計。
- **風險（Silver 串流作業讀 Iceberg）**：Iceberg 串流讀取只能乾淨處理 append 快照，Bronze 為 append-only 故成立，但 compaction 產生的 replace 快照對串流讀取的影響、Glue 5.0（Spark 3.5.4）`MERGE INTO` 對別名解析與 4.0 不同（需用完整限定名）、G.025X worker 在 Glue 5.0 是否可用，皆未驗證。這段不再需要連私有子網的 MSK 或在 Spark 內解 Glue SR，風險較原設計小。→ §4 項目 1(b)。
- **退路**：項目 1 的任一 spike 不通過，回到 [ADR-0010](../architecture/adr/0010-glue-streaming-vs-managed-flink.md) 的原設計（Glue Streaming 直連 Kafka，同時寫 Bronze 與 Silver），屆時原設計的未知項（Glue connection 與 SG 全埠 self-reference、Spark 內解 Glue SR 含 tombstone）需重新評估，並將 ADR-0012 標為 Rejected。

- **風險（exactly-once 的實際邊界）**：「CDC + upsert 不重複」在實務上是「至少一次傳遞 + 冪等寫入」的組合結果，而非端到端 exactly-once。→ 驗收（§7）以「重播後結果不變」的可觀測行為為準；ADR / Pattern Card 中據實說明語意邊界，不宣稱做到端到端 exactly-once。

- **風險（小檔與效能）**：Silver 串流微批次頻繁 MERGE 會產生大量小檔與 delete file；Bronze 端的 sink 以固定間隔 commit，間隔調小會增加小檔與 snapshot 數量。Iceberg 需要定期 compaction / expire snapshots。→ 本片先確認正確性，維護作業若成為問題，記錄為 runbook 或列入 `docs/TODO.md` 待 Slice 4 的維運議題處理，不在本片過度工程化。

- **風險（Lake Formation 權限）**：新增 `bronze.trade_events` / `silver.trade` 兩張表，Session 003 兩次踩到的 Lake Formation 授權坑（Glue Job 執行角色、人身帳號各需一組 grant）會再遇到一次。→ 比照既有模式一次補齊（既有 `lakeformation.tf` 的表層 wildcard grant 已涵蓋 `bronze` / `silver` 新表，但新建的 connector 執行角色與 Silver 串流作業的執行角色各需另補一組）。先前的 `athena_reader_tables["bronze"]` drift 已由 [ADR-0005](../architecture/adr/0005-project-admin-permission-exemption.md) 收斂；現行表 grant 不含 `DELETE`；§3.3 已決定軟刪除，`MERGE` 只做 UPDATE／INSERT，預期不需要 `DELETE`，spike 時確認。

- **風險（2a 的 Registry 與 DLQ 證據缺口）**：2a 項目 9 的 `BACKWARD` 拒絕實測是對測試替身 `trade_events` 做的，真實 schema `transaction.trade.v1` 的相容性模式未直接驗證；DLQ 只確認設定與可達性，未端到端觸發過。→ 列入 §4 項目 1 下方的「2a 證據缺口補查」。2b 的值規則由 Silver 強制，不依賴這兩項，故不阻擋本片。

- **風險（Silver 規則與契約漂移）**：規則在 `silver_trade.yaml`、契約 `quality` 區塊、批次的 `rules/*.yaml` 三處各有定義，Slice 1 之前沒有一致性保證。→ 本片以 `silver_trade.yaml` 為執行來源、契約引用並加 pytest 檢查（§4 項目 5、9）；批次側既有的重複定義不在本片處理。

---

## 9. 相關文件 (Related ADR / Pattern / Contract)

本片完成時需產出：

- `docs/specs/slice2b-streaming-upsert.md` — 本文件
- `docs/architecture/adr/0010-glue-streaming-vs-managed-flink.md` — 為何 2b 串流運算選 Glue Streaming（已產出）
- `docs/architecture/adr/0011-streaming-silver-quality-gate.md` — 串流 Silver 的品質閘：Registry 管結構、Silver 管值，逐筆規則加隔離（已產出）
- `docs/architecture/adr/0012-kafka-connect-iceberg-sink-bronze.md` — Kafka → Bronze 改由 Iceberg Kafka Connect sink 負責，Silver 由 Glue Streaming 讀 Bronze（已產出，💬 `Proposed`，待項目 1 spike 通過轉 `Accepted`）
- `src/quality/rules/silver_trade.yaml` — Silver 逐筆規則的單一來源
- `docs/patterns/cdc-merge-into.md` — Pattern Card（本專案第四份，繼 `wap-quality-gate.md`、`lambda-vpc-access-gateway.md`、`msk-connect-single-plugin-per-connector.md`）
- `contracts/trade-events.contract.yaml`（v2）— 補上 Silver model 與實測 SLA
- `docs/runbooks/slice2b-verification.md` — 本片定案驗證文件（衛星 runbook 由其彙總引用）
- Decision Log：**append（Slice 0）與 upsert（Slice 2b）的完整對照**（本 Slice 敘事核心）、§3 各項技術選型（串流引擎、排序鍵、刪除處理）

> **ADR**：execution-roadmap.md 原規劃的兩份 Slice 2 ADR（MSK vs Kinesis、CDC vs batch polling）都屬 2a 的擷取層議題，已列在 [slice2a §9](slice2a-cdc-ingestion.md)。串流引擎選型已獨立成 [ADR-0010](../architecture/adr/0010-glue-streaming-vs-managed-flink.md)，串流 Silver 的品質閘獨立成 [ADR-0011](../architecture/adr/0011-streaming-silver-quality-gate.md)，Kafka → Bronze 改由 connector 負責獨立成 [ADR-0012](../architecture/adr/0012-kafka-connect-iceberg-sink-bronze.md)；本片若在實作中發現 upsert 語意的取捨值得獨立成 ADR（例如軟刪除 vs 硬刪除的決定夠有份量），屆時取當時的下一個可用編號，不預先保留號碼。
