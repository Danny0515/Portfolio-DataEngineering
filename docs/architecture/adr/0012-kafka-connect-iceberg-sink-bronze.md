# ADR-0012: Slice 2b 的 Kafka → Bronze 改由 Iceberg Kafka Connect sink 負責，Silver 由 Glue Streaming 讀 Bronze

| 屬性 | 值 |
| --- | --- |
| **狀態** | 💬 `Proposed`（待 spec §4 項目 1 spike 通過後轉 ✅ `Accepted`） |
| **日期** | 2026-10-22 |
| **相關模組** | `infra/environments/dev-slice2/`（MSK Connect 上的 Iceberg sink，尚未實作）、`src/transform/`（Silver 串流作業，尚未實作） |
| **決策者** | Danny |

## 背景 (Context)

[ADR-0010](0010-glue-streaming-vs-managed-flink.md) 選定 Glue Streaming 作為 2b 的串流運算引擎，原設計是**同一支作業直連 Kafka**，同時寫 `bronze.trade_events`（append）與 `silver.trade`（`MERGE INTO`）。重新檢視 spec §8 的風險後發現：

- 最大的未知項全部集中在「Glue Streaming × 私有子網 MSK × Glue Schema Registry」：Glue connection 與 Security Group、在 Spark 內解 Debezium Avro（含 tombstone）、Glue 5.0 `MERGE INTO` 的別名解析。
- 單一作業同時負責「擷取」與「解讀」，同一個故障域：Silver 的規則或 `MERGE` 出問題，連帶卡住 Bronze 落地；若停機超過 Kafka retention，事件在進 Bronze 前就過期。Slice 2 資源採用完即拆，topic 不是永久紀錄，**Bronze 是唯一長期、可重播的事件紀錄**（spec §3.2）。
- 「Kafka → Iceberg append」本身不需要自訂邏輯，是業界常見的現成元件（Kafka Connect 的 Iceberg sink）可處理的工作；2b 真正需要自訂邏輯的是 Silver 的規則、LSN 比較與軟刪除。

## 決策 (Decision)

1. **Kafka → Bronze 改由 Apache Iceberg Kafka Connect sink 負責**，部署在 MSK Connect（custom plugin，與 Glue Schema Registry converter 合併打包成單一 plugin，沿用 Pattern Card [`msk-connect-single-plugin-per-connector`](../../patterns/msk-connect-single-plugin-per-connector.md)），以 append 方式寫入 `bronze.trade_events`（Glue Catalog）。
2. **Silver 的 Glue Streaming 作業改以 Bronze 為串流來源**（讀 Iceberg 的 append 快照，不再連 Kafka），在 `foreachBatch` 內做逐筆規則、隔離與 `MERGE INTO`。[ADR-0010](0010-glue-streaming-vs-managed-flink.md) 的引擎選擇、[ADR-0011](0011-streaming-silver-quality-gate.md) 的品質閘、spec §3.3 的 LSN 排序與軟刪除**皆不變**。
3. **Bronze 採 connector 依 Avro schema 寫出的有型別欄位**（含 `before`／`after` 結構），不套用 Slice 0 的「全字串」原則：Avro 已保證型別，該原則所防的 `inferSchema` 偏移在此不成立。細節（欄位、provenance、tombstone）於 spike 定案。
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
- ⚠️ **注意（尚未驗證，spec §4 項目 1 spike 要回答）**：
  - Iceberg sink 的 runtime 套件是否已含 Glue Catalog 所需的 AWS bundle，與目前 Iceberg 版本是否相容
  - 控制 topic 的建立與權限；connector 執行角色在 IAM 與 Lake Formation 各需要補一組 grant
  - tombstone（value 為 null）的處理方式；表由 connector auto-create 或預先建立（對照 [docs/TODO.md](../../TODO.md)「建表與寫資料拆分」）
  - commit 間隔預設為分鐘級，調小會增加小檔與 snapshot 數量
  - Iceberg 串流讀取只能乾淨處理 append 快照；Bronze 為 append-only 故成立，但 compaction 產生的 replace 快照對串流讀取的影響需實測
- ⚠️ **注意**：Bronze 的保存形式從全字串改為有型別欄位，需同步修改 spec §3.2 與 [08_concepts.md](../../arc42/08_concepts.md)。
- ❌ **負面/限制**：延遲由秒級拉長到分鐘級（仍符合 spec §6「先訂分鐘級 SLA」）；多一個 connector 與 custom plugin 需要維運；對這個 sink connector 的成熟度與 MSK Connect 上的實際行為，目前沒有第一手驗證。
