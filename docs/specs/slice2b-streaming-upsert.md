# Spec: Slice 2b — 串流 upsert 落地（Kafka → Iceberg 當前狀態表）

> 對應 [execution-roadmap.md](../../execution-roadmap.md) Slice 2 的後半段。
> 對應 [plan.md](../../plan.md) §7 分階段交付：Phase 1b（Streaming 主幹）。
> 前半段見 [slice2a-cdc-ingestion.md](slice2a-cdc-ingestion.md)。
> 狀態：**§3 待確認事項尚未拍板** — 待 §3 全數決定後，§4 實作項目清單才成為實作依據。

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
▓   → 串流運算 (Flink / Spark Structured Streaming)
▓       ├→ bronze.trade_events (append)     ← CDC 事件原樣落地，可重播、可回溯「這筆單怎麼一步步變成現在這樣」
▓       └→ silver.trade        (MERGE INTO) ← 每個 trade_id 一列，反映當前狀態
▓   → Athena 查得到當前狀態，且與來源 DB 逐筆一致
```

---

## 2. 範圍 (Scope) / 非範圍 (Non-Goals)

**範圍內**：
- 串流運算引擎的選型、部署與最小寫入 spike
- Bronze：CDC 事件 append-only 落地（延續 Slice 0 的 Bronze 職責定義：原樣、可重跑）
- Silver：以 MERGE INTO 維護當前狀態表，含亂序 / 重播的冪等處理與刪除事件處理
- 端到端延遲實測，並把 SLA 寫回 `contracts/trade-events.contract.yaml`
- 契約補上 Silver 層 model（2a 只寫了 topic 層）
- 準確性驗證：`silver.trade` 與來源 OLTP DB 逐筆比對——**本專案第一次做得到**（Slice 0/1 沒有外部真實來源可比對）

**刻意不做 (Out of Scope)**：
- **視窗聚合、即時風控指標、即時 OLAP（Pinot）** → Slice 3。本片只做「狀態正確」，不做「指標即時」
- **Gold 層交易寬表** → 除非 §3.2 決定納入，預設不做（與 Slice 3 的即時聚合高度重疊）
- **串流路徑的完整品質框架** → Slice 1 的 WAP Gate 是為批次設計的（整批寫 staging → 整批稽核 → 整批發布），串流沒有「批次邊界」這個概念，直接套用會失真。本片的品質防線預設沿用 2a 的 schema 強制 + DLQ（見 §3.4），完整串流品質留 Slice 3/4
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

**建議**：選 A，並把 B 明確定位為**卡關時的降級方案**（比照 Slice 1 §3.2「Iceberg branch 卡關才降級為手動 staging table」的處理方式）。若降級，需留 ADR 記錄原因。

> 決策提醒：Slice 1 的經驗是「未知項要用一次獨立 spike 提前解除，而不是在主線實作中撞牆」，且「本機驗證不能替代正式環境驗證」（Iceberg branch 在本機 Hadoop catalog 能用，不代表 Glue Catalog 能用）。→ §4 項目 1 的最小 spike 為此而設。

### 3.2 目標表分層與命名

依 plan.md §2.2 命名慣例（三大領域內部依子類型再分一層、不加 `_data` 尾綴），交易領域對應 `transaction/trade/`（S3 路徑）。

| 選項 | 說明 |
| --- | --- |
| **A. Bronze（事件 append）+ Silver（當前狀態 upsert）**（建議） | `bronze.trade_events`（每個 CDC 事件一列，append）+ `silver.trade`（每個 `trade_id` 一列，MERGE INTO）。Bronze 保留完整變更歷史，正是「可重播、可稽核」的證據 |
| B. 只做 Silver（Kafka → 直接 upsert） | 少一層、實作快；但失去可重播來源，且違反 Slice 0 已確立的 Bronze 職責（[ADR-0002](../architecture/adr/0002-medallion-layering.md)） |
| C. A + Gold（部位/成交彙總） | 與 Slice 3 的即時聚合高度重疊，建議不做 |

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

### 3.4 串流路徑的品質防線是否延伸到表層

| 選項 | 說明 |
| --- | --- |
| **A. 沿用 2a 的 Schema Registry + DLQ，表層不再加關卡**（建議） | 品質防線落在「進 Kafka 前」；Silver 的正確性由 §7 的逐筆比對驗證，而非常駐關卡 |
| B. A ＋ 對 `silver.trade` 定期跑 GX 批次稽核 | 複用 Slice 1 的 GX 資產，但「串流表的批次稽核」語意曖昧（稽核的是哪個時間切片？失敗要回滾什麼？），建議留待 Slice 3/4 想清楚再做 |

---

## 4. 實作項目清單 (Implementation Checklist)

> 項目大致依序執行。前置條件：Slice 2a 全部完成（topic 上有可消費的 CDC 事件）。

| # | 項目 | 說明 | 產出 | 完成 |
| --- | --- | --- | --- | --- |
| 1 | 串流引擎 spike | 依 §3.1 決定引擎後，先做**最小寫入 spike**（Kafka → Iceberg 一張測試表），單獨驗證引擎 × Iceberg × Glue Catalog 的相容性與 upsert 設定方式，再接真實資料 | spike 腳本 + runbook | ⬜ |
| 2 | 表結構與權限 | 建立 `bronze.trade_events` / `silver.trade` 的 Glue database/table 權限（Lake Formation grant，比照 Slice 0 既有模式），partition 設計依查詢模式決定 | Terraform 資源 | ⬜ |
| 3 | Bronze CDC 事件落地 | CDC 事件原樣 append 進 `bronze.trade_events`，保留 `op` / `before` / `after` / 來源變更序 | Iceberg table `bronze.trade_events` | ⬜ |
| 4 | Silver MERGE INTO | 依 §3.3 的排序鍵做批次內 dedup 後 `MERGE INTO silver.trade`，含刪除事件處理 | Iceberg table `silver.trade` | ⬜ |
| 5 | 冪等 / 重播驗證 | 重置 consumer offset 重播同一批訊息，確認 `silver.trade` 筆數與內容不變（Bronze 則預期累加，同 Slice 0 的重跑語意） | 驗證紀錄 | ⬜ |
| 6 | 準確性比對 | `silver.trade` 與來源 OLTP DB 逐筆比對（筆數 + 抽樣欄位值） | 驗證紀錄 | ⬜ |
| 7 | 端到端延遲實測 | 量測來源 DB 變更 → `silver.trade` 可查詢的延遲，訂出可達成的 SLA | 實測數字 | ⬜ |
| 8 | Data Contract 補完 | 契約補上 `trade`（Silver）model 與 `servicelevels`（依項目 7 實測值） | `contracts/trade-events.contract.yaml`（v2） | ⬜ |
| 9 | 端到端驗證 | 彙總 runbook + 衛星 runbook（依 execution-roadmap.md §3 命名慣例） | `docs/runbooks/slice2b-verification.md` | ⬜ |
| 10 | 文件產出 | 見下方 §9 | Pattern Card / ADR / Decision Log | ⬜ |

---

## 5. 輸出 (Outputs)

| 表 | 層級 | 內容 | 寫入模式 |
| --- | --- | --- | --- |
| `bronze.trade_events` | Bronze | CDC 事件原樣落地，一個事件一列（含 `op`/`before`/`after`/來源變更序） | append（職責與 Slice 0 `bronze.stock` 一致） |
| `silver.trade` | Silver | 每個 `trade_id` 一列的當前狀態（含 §3.3 決定的刪除標記） | **MERGE INTO（upsert）** ← 與 Slice 0 `silver.stock` 的全量覆寫形成對照 |
| `contracts/trade-events.contract.yaml`（v2） | 契約 | 2a 的 topic model + 本片補上的 Silver model 與實測 SLA | Git 版控 |

---

## 6. 資料品質規則 (Data Quality Rules)

本片首次讓 plan.md §3 的**時效性 (Timeliness)** 與**準確性 (Accuracy)** 兩個維度變得可定義——批次路徑（Slice 1）沒有有意義的延遲概念，也沒有外部真實來源可比對，串流 + CDC 兩者都有。

| 維度 | 規則 | 檢核落點 |
| --- | --- | --- |
| 唯一性 (Uniqueness) | `silver.trade` 中每個 `trade_id` 恰好一列 | MERGE 後 SQL 驗證 |
| 一致性 (Consistency) | 狀態轉移需符合 [slice2a §3.1](slice2a-cdc-ingestion.md) 的狀態機（不得從 `FILLED` 退回 `NEW`）；`symbol` 為 Slice 0 定義的合法代號 | 驗證階段 SQL 核對 |
| **時效性 (Timeliness)** | 來源 DB 變更到 `silver.trade` 可查詢的端到端延遲，建議先訂寬鬆的分鐘級 SLA，實測後再收斂並寫入契約 `servicelevels` | §4 項目 7 |
| **準確性 (Accuracy)** | `silver.trade` 與來源 OLTP DB 逐筆一致 | §4 項目 6 |
| 完整性 / 有效性 | 由 2a 的 Avro schema 與 Registry 相容性規則在「進 Kafka 前」強制，本片不重複檢核 | 見 [slice2a §6](slice2a-cdc-ingestion.md) |

---

## 7. 驗收標準 (Acceptance Criteria)

- [ ] 在來源 DB 做 insert / update / delete，`silver.trade` 能在 SLA 內正確反映當前狀態（逐筆與來源 DB 比對一致）
- [ ] 同一批訊息重播後，`silver.trade` 筆數與內容不變（冪等），`bronze.trade_events` 則如預期累加
- [ ] 一筆交易走完完整狀態機（NEW → PARTIALLY_FILLED → FILLED），`silver.trade` 只留最終狀態一列，`bronze.trade_events` 保留完整三筆變更軌跡
- [ ] 刪除事件依 §3.3 決定的方式正確反映在 `silver.trade`
- [ ] 端到端延遲有實測數字並寫回契約 `servicelevels`
- [ ] `contracts/trade-events.contract.yaml`（v2）的 Silver model 與 `silver.trade` 實際 schema 一致
- [ ] 上述 §9 文件皆已產出

---

## 8. 相依 (Dependencies) / 風險 (Risks)

- **相依**：Slice 2a 需全部完成——topic 上要有帶 before/after 與來源變更序的 CDC 事件，本片才有東西可消費。
- **相依**：Slice 0 的 Bronze/Silver 分層職責（[ADR-0002](../architecture/adr/0002-medallion-layering.md)）與 append/覆寫取捨（[ADR-0003](../architecture/adr/0003-append-vs-overwrite.md)）已定案——本片的 upsert 論述完全建立在這兩份 ADR 的對照上。

- **風險（串流引擎 × Iceberg × Glue Catalog）**：本片最大的未知項。若 §3.1 選 Managed Flink，Flink Iceberg connector 對 Glue Catalog 的支援度與 upsert mode 設定皆未驗證。Slice 1 已有前例：Iceberg branch 在本機 Hadoop catalog 可用，不代表 Glue Catalog 可用。→ §4 項目 1 的最小 spike 就是為此設計；卡關則依 §3.1 降級為 Glue Streaming 並留 ADR。

- **風險（exactly-once 的實際邊界）**：「CDC + upsert 不重複」在實務上是「至少一次傳遞 + 冪等寫入」的組合結果，而非端到端 exactly-once。→ 驗收（§7）以「重播後結果不變」的可觀測行為為準；ADR / Pattern Card 中據實說明語意邊界，不宣稱做到端到端 exactly-once。

- **風險（MERGE INTO 的小檔與效能）**：串流微批次頻繁 MERGE 會產生大量小檔與 delete file，Iceberg 需要定期 compaction / expire snapshots。→ 本片先確認正確性，維護作業若成為問題，記錄為 runbook 或列入 `docs/TODO.md` 待 Slice 4 的維運議題處理，不在本片過度工程化。

- **風險（Lake Formation 權限）**：新增 `bronze.trade_events` / `silver.trade` 兩張表，Session 003 兩次踩到的 Lake Formation 授權坑（Glue Job 執行角色、人身帳號各需一組 grant）會再遇到一次。→ 比照既有模式一次補齊，並確保 2a 項目 0.3 的 drift 已先收斂。

---

## 9. 相關文件 (Related ADR / Pattern / Contract)

本片完成時需產出：

- `docs/specs/slice2b-streaming-upsert.md` — 本文件
- `docs/patterns/cdc-merge-into.md` — Pattern Card（本專案第二份，繼 `wap-quality-gate.md`）
- `contracts/trade-events.contract.yaml`（v2）— 補上 Silver model 與實測 SLA
- `docs/runbooks/slice2b-verification.md` — 本片定案驗證文件（衛星 runbook 由其彙總引用）
- Decision Log：**append（Slice 0）與 upsert（Slice 2b）的完整對照**（本 Slice 敘事核心）、§3 各項技術選型（串流引擎、排序鍵、刪除處理）

> **ADR**：execution-roadmap.md 原規劃的兩份 Slice 2 ADR（MSK vs Kinesis、CDC vs batch polling）都屬 2a 的擷取層議題，已列在 [slice2a §9](slice2a-cdc-ingestion.md)。本片若在實作中發現 upsert 語意的取捨值得獨立成 ADR（例如 Flink 降級為 Glue Streaming、或軟刪除 vs 硬刪除的決定夠有份量），屆時取當時的下一個可用編號，不預先保留號碼。
