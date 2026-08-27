# ADR-0006: 為何選 MSK 而非 Kinesis

| 屬性 | 值 |
| --- | --- |
| **狀態** | ✅ `Accepted` |
| **日期** | 2026-08-21 |
| **相關模組** | `infra/environments/dev-slice2/msk.tf`（§4 項目 5，尚未建立） |
| **決策者** | Danny |

## 背景 (Context)

plan.md §2.1 / §8 已將 AWS MSK（Managed Streaming for Kafka）列為 Slice 2 串流訊息中介的主選，但當時沒有把「為什麼是 MSK 而不是 Kinesis Data Streams」這個判斷題的具體理由攤開——Kinesis 表面上是 AWS 原生的另一個串流服務，容易被誤認為「AWS 自己的 Kafka」可以直接取代。Slice 2a 開發期間（尤其 §4 項目 6 的 Debezium plugin 打包 spike 若卡關、需要考慮降級路徑時）需要一份明確的理由依據，避免中途重新評估這個選型時要重新推導一次。

## 決策 (Decision)

Slice 2 的串流訊息中介採用 AWS MSK（含 MSK Connect），不採用 Kinesis Data Streams。

## 理由 (Rationale)

1. **生態相容性**：Debezium（§3.2 已選 Debezium + MSK Connect 作為 CDC 擷取方式）沒有原生 Kinesis 輸出，只支援 Kafka Connect 框架。Kinesis 不是 Kafka 的直接替代品——架構模型（shard vs partition）、API、生態圈都不同。MSK Connect 本質上是「代管的 Kafka Connect」執行環境，可以直接使用 Kafka Connect 生態的 Debezium source connector；改用 Kinesis 等於要放棄已拍板的 Debezium CDC 工具鏈。
2. **Replay / consumer 語意**：Kafka 的 consumer group 模型讓多個下游可以各自獨立 seek、消費同一份事件流，互不干擾。未來 Slice 3 若需要多個下游（例如即時 upsert 到 Iceberg、即時風控）各自消費同一個 topic，這是原生支援的。Kinesis 是 shard 模型，每個 shard 有固定吞吐上限，scale 心智（shard splitting/merging）跟 Kafka partition 不對等。
3. **下游延續性**：Slice 2b 要把 CDC 事件寫進 Iceberg（`bronze.trade_events` / `silver.trade`），很可能沿用 Kafka Connect 生態的 sink connector。選 MSK 讓 2a／2b 整條管線留在同一個技術棧，不用中途切換。
4. **可攜性與作品集展示價值**：Kafka 是業界事實標準，展示的技能（topic / partition / consumer group / Kafka Connect / Schema Registry）可以遷移到任何雲端或自架環境。Kinesis 是 AWS 專屬服務，學到的操作模型比較鎖定在 AWS 生態內，可攜性較低。

**Alternatives considered**：

- **MSK（含 MSK Connect）**（選定）：理由如上。
- Kinesis Data Streams（未選）：全代管、免管理容量，但不支援 Debezium 原生輸出、shard 模型與 Kafka 不對等、無法沿用 Kafka Connect 生態，會讓已拍板的 Debezium CDC 工具鏈失去落地位置。

## 影響 (Consequences)

- ✅ **正面**：CDC 擷取（Debezium + MSK Connect）、Schema Registry（Glue Schema Registry 原生支援 Kafka/Avro 生態）、未來 Slice 2b/3 的下游消費，都能留在同一套 Kafka 生態圈，技術棧一致。
- ⚠️ **注意**：MSK Connect × Debezium 的 plugin 打包路徑（§4 項目 6）目前仍是未驗證風險；若該 spike 卡關且無法降級為自架 Debezium（§3.2 選項 C），才需要重新評估整個 MSK 路線是否可行，屆時本 ADR 的結論可能需要被新 ADR 取代。
- ❌ **負面/限制**：MSK Provisioned 是常駐計費資源（§3.3(a) 已選最小配置 `kafka.t3.small` × 2 broker），相較 Kinesis 的無伺服器計費模型，需要自行控管生命週期（§3.3(b) 用完即拆）以避免不必要的持續費用。
