# ADR-0007: 為何用 CDC 而非定時撈整張表

| 屬性 | 值 |
| --- | --- |
| **狀態** | ✅ `Accepted` |
| **日期** | 2026-08-21 |
| **相關模組** | `infra/environments/dev-slice2/rds.tf`（§4 項目 4，尚未建立）、Debezium connector 設定（§4 項目 7，尚未建立） |
| **決策者** | Danny |

## 背景 (Context)

Slice 2a 的目標是把交易狀態變更即時送進 Kafka（對應 plan.md §7 Phase 1b「Streaming 主幹」）。要達到這個目標，來源擷取方式有兩種基本策略：定時輪詢來源表（batch polling，依 watermark 比對找出變更）vs CDC（持續監聽底層 WAL/logical replication，捕捉每一次變更）。§3.1 已拍板採用真實 OLTP DB（RDS PostgreSQL）而非讓 generator 直接產生器寫 Kafka，正是為了保留這個對照組，讓 CDC vs batch polling 的判斷題能被具體驗證，而不是紙上談兵。

## 決策 (Decision)

Slice 2a 採用 CDC（Debezium + PostgreSQL logical replication）擷取交易變更，不採用定時輪詢來源表。

## 理由 (Rationale)

1. **來源負載**：Batch polling 需要週期性查詢整張表（或依 watermark 篩選），對 OLTP 資料庫造成額外讀取負擔，且隨表成長而惡化；CDC 讀取的是資料庫原生的 WAL/logical replication stream，幾乎不對交易查詢造成額外負載。
2. **延遲**：Batch polling 的延遲下限就是輪詢間隔（例如每 5 分鐘），CDC 則接近即時（毫秒~秒級），直接服務 Slice 2 的「即時路徑」定位。
3. **抓不到中間態**：若一筆交易在兩次輪詢間變更多次（例如 NEW → PARTIALLY_FILLED → FILLED 發生在同一輪詢區間內），batch polling 只看得到輪詢當下的最終狀態，中間態會遺失。這點對本專案是關鍵差異：§7 驗收標準明確要求「一筆交易走完完整狀態機，topic 上能看到完整的三筆變更軌跡」——只有 CDC（逐筆捕捉每次 WAL 寫入）做得到，batch polling 在架構上就無法滿足這項驗收。
4. **刪除偵測**：以 `updated_at` watermark 為基礎的 batch polling 完全偵測不到 DELETE——刪除的資料列直接從查詢結果消失，沒有任何訊號顯示發生過刪除（除非額外導入 soft-delete 標記，增加來源 schema 複雜度且非通用做法）。CDC 直接捕捉 delete 操作本身並帶著 before image，讓 insert/update/delete 三種操作都有明確的 before/after 語意。

**Alternatives considered**：

- **CDC（Debezium + logical replication）**（選定）：理由如上。
- 定時輪詢來源表（batch polling，依 `updated_at` watermark）（未選）：實作簡單、不需開啟 logical replication 或處理 replication slot，但在來源負載、延遲、中間態、刪除偵測四個維度都有結構性缺陷；且若只是要抓最終狀態，§3.1 選擇「真實 OLTP DB」的理由本身會失去意義（不如直接用 generator 寫 Kafka）。

## 影響 (Consequences)

- ✅ **正面**：達成 Slice 2「不輪詢來源表」的目標（§1），且能完整展示交易狀態機的每一次變更軌跡，是 CDC 相對 batch polling 最有說服力的差異化展示。
- ⚠️ **注意**：CDC 依賴來源資料庫的 replication slot 機制，若 consumer（Debezium connector）長時間離線未消費，replication slot 會持續累積 WAL、佔用來源 DB 儲存空間——這也是為什麼 §3.3(b) 選擇「用完即拆」時，網路層/RDS/MSK 要整組一起拆建，避免留下孤兒 replication slot。
- ❌ **負面/限制**：CDC 的實作複雜度明顯高於 batch polling——需要開啟 logical replication、處理 Debezium plugin 部署（§4 項目 6 的獨立 spike）、管理 replication slot 生命週期；相較之下 batch polling 只需要一支排程 script 定期下 SQL 查詢。
