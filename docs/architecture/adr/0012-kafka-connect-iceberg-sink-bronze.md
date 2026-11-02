# ADR-0012: Slice 2b 的 Kafka → Bronze 改由 Iceberg Kafka Connect sink 負責，Silver 由 Glue Streaming 讀 Bronze

| 屬性 | 值 |
| --- | --- |
| **狀態** | ✅ `Accepted`（spec §4 項目 1 的 (a)(b) spike 已於 2026-10-30 通過，使用者已確認） |
| **日期** | 2026-10-22 |
| **相關模組** | `infra/environments/dev-slice2/`（MSK Connect 上的 Iceberg sink；spike 版不保留，正式版於 spec §4 項目 3 重建）、`src/transform/`（Silver 串流作業；spike 版不保留，正式版於項目 4 實作） |
| **決策者** | Danny |

## 背景 (Context)

[ADR-0010](0010-glue-streaming-vs-managed-flink.md) 選定 Glue Streaming 作為 2b 的串流運算引擎，原設計是**同一支作業直連 Kafka**，同時寫 `bronze.trade_events`（append）與 `silver.trade`（`MERGE INTO`）。重新檢視 spec §8 的風險後發現：

- 最大的未知項全部集中在「Glue Streaming × 私有子網 MSK × Glue Schema Registry」：Glue connection 與 Security Group、在 Spark 內解 Debezium Avro（含 tombstone）、Glue 5.0 `MERGE INTO` 的別名解析。
- 單一作業同時負責「擷取」與「解讀」，同一個故障域：Silver 的規則或 `MERGE` 出問題，連帶卡住 Bronze 落地；若停機超過 Kafka retention，事件在進 Bronze 前就過期。Slice 2 資源採用完即拆，topic 不是永久紀錄，**Bronze 是唯一長期、可重播的事件紀錄**（spec §3.2）。
- 「Kafka → Iceberg append」本身不需要自訂邏輯，是業界常見的現成元件（Kafka Connect 的 Iceberg sink）可處理的工作；2b 真正需要自訂邏輯的是 Silver 的規則、LSN 比較與軟刪除。

## 決策 (Decision)

1. **Kafka → Bronze 改由 Apache Iceberg Kafka Connect sink 負責**，部署在 MSK Connect（custom plugin，與 Glue Schema Registry converter 合併打包成單一 plugin，沿用 Pattern Card [`msk-connect-single-plugin-per-connector`](../../patterns/msk-connect-single-plugin-per-connector.md)），以 append 方式寫入 `bronze.trade_events`（Glue Catalog）。
2. **Silver 的 Glue Streaming 作業改以 Bronze 為串流來源**（讀 Iceberg 的 append 快照，不再連 Kafka），在 `foreachBatch` 內做逐筆規則、隔離與 `MERGE INTO`。[ADR-0010](0010-glue-streaming-vs-managed-flink.md) 的引擎選擇、[ADR-0011](0011-streaming-silver-quality-gate.md) 的品質閘、spec §3.3 的 LSN 排序與軟刪除**皆不變**。
3. **Bronze 採 connector 依 Avro schema 寫出的有型別欄位**（含 `before`／`after` 結構），不套用 Slice 0 的「全字串」原則：Avro 已保證型別，該原則所防的 `inferSchema` 偏移在此不成立。spike（2026-10-30）實測結果：自動建出的表有 `before`／`after`（結構欄位，`price` 為 `decimal(38,2)`，`event_time`／`updated_at` 為字串）、`source`、`transaction` 結構與 `op`、`ts_ms`／`ts_us`／`ts_ns`，**沒有** Kafka partition／offset／寫入時間這類 provenance 欄位；tombstone（value 為 null）**不會**落地到 Bronze。表的建立方式（auto-create 或預先建表）見下方「影響」與 [08_concepts.md §8.6](../../arc42/08_concepts.md#86-table-建立與-schema-管控原則依層級)。
4. **退路**：spike 不通過時，回到 ADR-0010 的原設計（Glue Streaming 直連 Kafka，同時寫 Bronze 與 Silver）。

## 理由 (Rationale)

1. **最大未知項移出關鍵路徑**：Glue 作業不再連 MSK，也不在 Spark 內解 Avro；Silver 作業讀的是 Iceberg，沿用 Slice 0/1 已驗證的 Glue＋Iceberg＋Lake Formation 技術棧。
2. **擷取與解讀的故障域分離**：事件落地由獨立、單純的 consumer 負責，Silver 的 bug 或停機不會阻擋擷取，降低「落後超過 retention 而遺失事件」的風險。
3. **擷取段沒有自訂程式**：由託管 connector 以 commit 搭配 offset 記錄來避免重複寫入（細節以官方文件為準），不必自己維護 `foreachBatch` 的冪等。
4. **重用既有模式**：MSK Connect、合併單一 plugin 的打包方式都已在 2a 走過一次。
5. **保留 2b 的核心展示**：Silver 仍是字面上的 `MERGE INTO`，LSN 嚴格大於的冪等證明不受影響，與 Slice 0 的 append 對照敘事不變。

**Alternatives considered**：

- **維持 ADR-0010 原設計（Glue Streaming 直連 Kafka）**（未選，作為退路）：未知項集中且擷取與解讀同一故障域。
- **connector 直接以 upsert 模式寫 `silver.trade`，不用 Spark**（未選）：upsert 為「後到者贏」、不比較 LSN；刪除走硬刪除；沒有地方放逐筆規則與隔離表，等於放棄 spec §3.3 與 §3.4 的核心決策。
- **Spark 薄作業連 Kafka，只寫 Bronze**（未選）：同樣的 Glue × MSK × Glue SR 未知項仍在關鍵路徑上。
- **另以 S3 sink 保存解碼前的原始 bytes**（未選，另案）：解決的是「解碼邏輯有 bug 時的重解碼」與閘門前資料保存，與本次簡化目標不同，需要另外評估維運成本。
- **Managed Flink**（未選）：理由見 [ADR-0010](0010-glue-streaming-vs-managed-flink.md)。

## 影響 (Consequences)

- ✅ **正面**：風險移出關鍵路徑；擷取與解讀故障域分離；Bronze 擷取不需維護自訂程式。
- ⚠️ **注意（spike 2026-10-30 實測結果，細節見 [slice2b-iceberg-sink-spike-verification.md](../../runbooks/slice2b-iceberg-sink-spike-verification.md)）**：
  - **套件與版本**：Confluent Hub 的 Iceberg sink 1.9.2 zip 已含 `iceberg-aws` 與 AWS SDK v2（glue／s3／sts／lakeformation），不需另補 AWS bundle；與 Glue Streaming 讀取互通（Glue 5.0 內建 Iceberg 1.7.1 讀 sink 寫的表成功）。與 Glue Schema Registry converter 合併成單一 plugin 後可解 Debezium Avro。
  - **控制 topic 與交易**：sink 用交易式 producer 寫控制 topic，**2-broker 的 MSK 必須在 broker 設定加 `transaction.state.log.replication.factor=2`、`transaction.state.log.min.isr=1`**，否則 task 卡在 `InitProducerId` 逾時被殺（`dev-slice2/msk.tf` 已調整，MSK configuration 為 revision 2）。
  - **權限**：connector 執行角色需要 Glue Catalog 對目標表的存取、warehouse 的 S3 權限，以及 Lake Formation 的資料庫與表層級 grant（本帳號預設權限為空，每個 principal 都要明確授權）。
  - **auto-create 需要過寬權限**：開啟 auto-create 時，sink 建表前會無條件嘗試建立 namespace（`bronze` 已存在也一樣，先過授權才吃 `AlreadyExists`），需要 catalog 層級的 `glue:CreateDatabase` 與 Lake Formation `CREATE_DATABASE`。關閉 auto-create 預先建表是否即可免除這組權限**尚未實測**。表的建立原則見 [08_concepts.md §8.6](../../arc42/08_concepts.md#86-table-建立與-schema-管控原則依層級)，本專案 Bronze trade 事件具體採哪一種，待 Lake Formation 搭配建表原則討論後定案。
  - **tombstone**：不落地到 Bronze（sink 預設行為），Silver 的刪除語意只依 `op='d'` 事件。
  - **commit 與小檔**：`iceberg.control.commit.interval-ms=60000` 時，每個有資料的週期產生一個小檔與一個 append 快照，空週期不產生快照；事件從 topic 到 Bronze 觀察到 1～3 分鐘（後續事件最長約 3 分鐘，原因未釐清），長期需要 compaction。
  - **compaction 與串流讀取**：對 Bronze 做 `OPTIMIZE`（12 個檔案合併為 1 個，產生 `replace` 快照）後，串流中的 Silver job 沒有失敗、也沒有重送已壓縮的舊資料；compaction 之後從頭重讀仍能讀到完整歷史。
  - **Silver 串流（(b)）**：Glue 5.0 `gluestreaming`、G.025X × 2 可用；`MERGE INTO` 以完整限定名成功；LSN 嚴格大於、重播冪等、軟刪除與「Silver 已有較新狀態時舊事件不覆蓋」皆通過；不需新增 IAM／Lake Formation。
  - **維運陷阱**：MSK Connect 的 connector 狀態可能維持 `RUNNING` 而 task 已死，且不會自動重啟 task，監控要看 task 或實際資料，不能只看 connector 狀態。
- ⚠️ **注意**：Bronze 的保存形式從全字串改為有型別欄位，需同步修改 spec §3.2 與 [08_concepts.md](../../arc42/08_concepts.md)。
- ❌ **負面/限制**：延遲由秒級拉長到分鐘級（仍符合 spec §6「先訂分鐘級 SLA」）；多一個 connector 與 custom plugin 需要維運；sink 的成熟度與長時間執行的行為仍只有短時間（數小時）的第一手驗證，斷點續傳、真實資料量與快照過期對串流讀取的影響尚未驗證。
