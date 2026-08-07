# Spec: Slice 1 — 資料品質 + 資料契約（疊在批次路徑上）

> 對應 [execution-roadmap.md](../../execution-roadmap.md) Slice 1。
> 對應 [plan.md](../../plan.md) §7 分階段交付：Phase 2a（Data Quality）+ Phase 4 的契約部分。
> 狀態：**§3 待確認事項已全數拍板** — 以下 §4 實作項目清單即為實作依據。

---

## 1. 目標 (Goal)

在 Slice 0 已經跑通的批次路徑上，疊加一個「不合格資料進不了 Gold」的品質關卡，並為市場行情資料定義第一份正式的 Data Contract。

Slice 0 證明的是「水電管線通了」；Slice 1 證明的是「管線會自己擋下壞資料，而不是讓壞資料悄悄流到 Gold」。這是本專案第一次把「資料品質」與「資料契約」從 plan.md §3 / §4.2 的概念，變成可執行的關卡與可版控的檔案。

資料流（在 Slice 0 的 Bronze → Silver 之間插入品質關卡，Gold 邏輯不變）：

```
Bronze (Iceberg, append 原樣落地 — 沿用 Slice 0，不變動)
  → Silver ──▶ [Write]   寫入 Iceberg 暫存分支 (staging branch)
              [Audit]   跑資料品質檢核 (Great Expectations / Soda Core)
              [Publish] 通過 → merge 到正式 Silver；失敗 → 擋下 + 告警，正式 Silver 不受影響
  → Gold (沿用 Slice 0 聚合邏輯，不變動)
  → Athena 查得到 Gold 結果，並可查到「哪些批次被擋下、為什麼」的稽核紀錄
```

---

## 2. 範圍 (Scope) / 非範圍 (Non-Goals)

**範圍內**：
- 延續 Slice 0 的 `bronze.stock` / `silver.stock` / `gold.monthly_ohlcv` 三層，不更動其既有 schema 或聚合邏輯
- 在 Bronze → Silver 之間新增 WAP（Write-Audit-Publish）品質關卡
- 品質規則工具化，涵蓋 plan.md §3 六維度中與批次歷史行情相關的子集（完整性、唯一性、有效性、一致性；時效性/準確性留待有即時路徑後的 Slice 再展開）
- 第一份正式 Data Contract（市場行情），YAML 格式，納入版控
- 刻意灌入壞資料的驗證路徑（沿用 Slice 0 §8 風險預留的「髒資料開關」）
- 品質檢核結果的稽核紀錄（哪些筆被擋下、觸犯哪條規則）

**刻意不做 (Out of Scope)**：
- 串流資料的品質檢核（留給 Slice 2/3，屆時面對的是 Kafka/Flink 情境而非批次）
- Metadata 平台整合、品質分數視覺化（留給 Slice 4，需要 OpenMetadata）
- Data Contract 的 CI 自動相容性檢查（留給 Slice 4 DataOps，需要 GitHub Actions）
- 修改 Bronze 或 Gold 層既有邏輯、schema、partition 設計

---

## 3. 待確認事項

這幾題是「地基」層級的選擇，跟 slice0 §3 性質一樣：決定結果會直接決定後續實作項目怎麼展開。

### 3.1 品質檢核工具：Great Expectations vs Soda Core

✅ **決定：A. Great Expectations**。理由：plan.md §3 已將其列為主選，且 Data Docs（HTML 品質報告）產出剛好呼應本 Slice「品質可視化」的展示目的。

| 選項 | 說明 | 適合情境 |
| --- | --- | --- |
| **A. Great Expectations**（已選） | 規則表達力強、社群大、可產生 Data Docs（HTML 品質報告），但設定較重 | 想要作品集展示「品質報告」這個可視化產出 |
| B. Soda Core | YAML 定義檢核規則，設定輕量、上手快 | 想把力氣留給 WAP 機制本身，品質規則越簡單越好 |

### 3.2 WAP 暫存分支機制：Iceberg 原生 branch vs 手動 staging table

✅ **決定：A. Iceberg 原生 branch**。理由：更貼近 WAP pattern 的原始設計。若實作時發現目前 AWS Glue Catalog + Spark/Iceberg 版本組合不支援或操作卡關，降級為手動 staging table 並在 ADR 記錄原因（呼應 CLAUDE.md RULE-003 精神：best practice 優先，卡關才討論特例）。

| 選項 | 說明 |
| --- | --- |
| **A. Iceberg 原生 branch**（已選，`CREATE BRANCH` / `.branch_staging`） | 用 Iceberg table branching 功能，Audit 通過後 `fast-forward` 或 `cherry-pick` 到 main branch |
| B. 手動 staging table（卡關時的降級方案） | 建一張 `silver_staging.stock`，Audit 通過後用 Spark 讀出重寫進 `silver.stock` |

### 3.3 壞資料如何注入

✅ **決定：A. 擴充 Slice 0 的 generator**。理由：Slice 0 §8 風險已預留這個接口（"需在 generator 中預留『注入髒資料』的開關"），沿用可維持單一資料產生入口。

| 選項 | 說明 |
| --- | --- |
| **A. 擴充 Slice 0 的 generator**（已選） | 在 `generate_stock_data.py` 加一個 `--inject-dirty` 開關，產生負值/空值/重複 (symbol, date) 等髒資料 |
| B. 獨立注入 script | 另開一支 script，直接對已落地的 raw CSV 做污染，不動 Slice 0 既有 generator |

### 3.4 Data Contract 範圍

✅ **決定：B（限縮版）。同時涵蓋 Silver 與 Gold 層的 schema 定義，但不加聚合一致性規則。**

理由：契約要保護的是實際查詢的下游（Athena 查的是 Gold，對應 plan.md §2.4 的定位），只寫 Silver 等於只把 WAP Gate 形式化，涵蓋不到「使用者實際看到的東西」。但 Silver→Gold 的聚合一致性驗證（例如某月 close 需等於該月最後交易日的 Silver close）複雜度超出本 Slice 聚焦的「Bronze→Silver 品質關卡」，留給有真正下游 consumer 的 Slice 3 再補。

因此 `market-data.contract.yaml` 會有兩個 `models`：
- `stock`（Silver）：完整帶 §6 的品質規則（not null、valid range、unique key、enum）
- `monthly_ohlcv`（Gold）：只定義欄位 schema（型別、required），不附加品質規則或聚合一致性檢查

| 選項 | 說明 |
| --- | --- |
| A. 只涵蓋 Silver 層 `stock` | 契約只約束「進入 Silver 前必須滿足什麼」，對應本 Slice 品質關卡（WAP Gate）的實際作用位置 |
| **B（已選，限縮版）. Silver 品質規則 + Gold schema-only** | Gold 只描述「長怎樣」，不描述「怎麼驗證」，聚合一致性檢查留給 Slice 3 |

---

## 4. 實作項目清單 (Implementation Checklist)

> 項目大致依序執行。

| # | 項目 | 說明 | 產出 | 完成 |
| --- | --- | --- | --- | --- |
| 1 | 髒資料注入開關 | 依 §3.3 決定，擴充 generator 或新增 script | 可產生違反 §6 規則的資料 | ✅ |
| 2 | 品質規則定義 | 用 §3.1 選定工具，定義 §6 的檢核規則 | Expectation Suite / Soda check YAML | ✅ |
| 3 | WAP staging 機制 | 依 §3.2 決定，實作 Write 階段（寫入 staging） | staging branch/table | ✅ |
| 4 | Audit 執行 | 對 staging 資料跑品質規則，產出通過/失敗結果 | 檢核結果（pass/fail + 明細） | |
| 5 | Publish / 擋下邏輯 | 通過 → merge 到正式 Silver；失敗 → 不 merge + 寫入稽核紀錄 | 正式 `silver.stock` 更新 或 擋下紀錄 | |
| 6 | 稽核紀錄落地 | 被擋下的批次與觸犯規則寫入可查詢的地方（表或檔案） | 稽核紀錄（Athena 可查） | |
| 7 | Data Contract 撰寫 | 依 §3.4 決定，`stock`（Silver）帶完整品質規則，`monthly_ohlcv`（Gold）只定義 schema | `docs/contracts/market-data.contract.yaml` | |
| 8 | 端到端驗證 | 分別跑一次「全乾淨資料」與「含髒資料」批次，確認 Gate 行為符合預期 | 驗證紀錄 | |
| 9 | 文件產出 | 依 execution-roadmap.md Slice 1 要求 | 見下方 §9 | |

---

## 5. 輸出 (Outputs)

| 產出 | 內容 | 備註 |
| --- | --- | --- |
| Silver staging（branch 或 table，依 §3.2） | Write 階段落地，尚未經 Audit | 僅本 Slice 內部使用，不對外查詢 |
| `silver.stock`（正式） | Audit 通過後 publish 的結果，schema 與 Slice 0 相同 | 沿用 Slice 0 既有表，本 Slice 只改「怎麼寫進去」 |
| 稽核紀錄 | 每次 Audit 的結果：批次識別、通過/失敗、觸犯規則明細 | 供 Athena 查詢，作為驗收證據 |
| `docs/contracts/market-data.contract.yaml` | 第一份生效的 Data Contract：`stock`（Silver，含品質規則）+ `monthly_ohlcv`（Gold，僅 schema） | 納入 Git 版控 |

---

## 6. 資料品質規則 (Data Quality Rules)

對應 plan.md §3 品質六維度中，本 Slice 涵蓋的子集：

| 維度 | 規則 |
| --- | --- |
| 完整性 (Completeness) | `symbol`、`date`、`open`、`high`、`low`、`close`、`volume` 不得為 null |
| 有效性 (Validity) | `open`/`high`/`low`/`close` 不得為負值；`high >= low`；`date` 需為合法交易日格式 |
| 唯一性 (Uniqueness) | 每個 (symbol, date) 在 Silver 層不得重複 |
| 一致性 (Consistency) | `symbol` 需為 [slice0-batch-market-data.md §3.4](slice0-batch-market-data.md) 定義的合法代號（`2330`/`2454`/`3653`），不接受未知代號 |

> 時效性 (Timeliness)、準確性 (Accuracy) 兩維度在純批次、無外部真實來源比對的情境下難以有意義地定義，留待 Slice 2/3 有即時路徑或外部資料來源比對時再納入。

---

## 7. 驗收標準 (Acceptance Criteria)

- [ ] 故意灌一批違反 §6 任一規則的資料，能被 Gate 擋下，且正式 `silver.stock` 不受影響（Bronze 仍保留原樣，可重跑）
- [ ] 正常乾淨資料能正確通過 Audit 並 publish 到正式 Silver，Gold 層數字與 Slice 0 驗收邏輯一致
- [ ] 稽核紀錄可在 Athena 查到「哪個批次被擋下、觸犯哪條規則」
- [ ] `docs/contracts/market-data.contract.yaml` 納入版控，`stock` model 與 §6 規則、Silver schema 一致，`monthly_ohlcv` model 與 Gold 既有 schema 一致
- [ ] 上述 §9 文件皆已產出

---

## 8. 相依 (Dependencies) / 風險 (Risks)

- **相依**：Slice 0 的 Silver（[slice0-batch-market-data.md](slice0-batch-market-data.md) 項目 6）與 Gold（項目 7）需先完成，本 Slice 才有正式 Silver/Gold 可以疊加關卡與定義契約
- **風險**：§3.2 選定 Iceberg 原生 branch，需先確認目前 AWS Glue Catalog + Spark/Iceberg 版本組合是否完整支援 branch 操作，卡關需降級為手動 staging table 並留 ADR 記錄
- **風險**：§3.1 選定 Great Expectations，在 Spark on Glue 環境的整合複雜度未知，需預留 spike 時間

---

## 9. 相關文件 (Related ADR / Pattern / Contract)

依 execution-roadmap.md 要求，Slice 1 完成時需產出：

- `docs/patterns/wap-quality-gate.md` — WAP Pattern Card
- `docs/contracts/market-data.contract.yaml` — 第一份生效契約
- `docs/architecture/adr/0003-wap-quality-gate.md` — 為何用 WAP 而非事後檢核
- Decision Log：Great Expectations vs Soda Core 的取捨（§3.1）、Iceberg branch vs 手動 staging 的取捨（§3.2）、Data Contract 涵蓋 Gold schema-only 的取捨（§3.4）
