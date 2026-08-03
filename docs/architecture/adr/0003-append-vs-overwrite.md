# ADR-0003: 批次管線的寫入模式（Append vs 全量覆寫）與 Partition 設計

| 屬性 | 值 |
| --- | --- |
| **狀態** | ✅ `Accepted` |
| **日期** | 2026-07-31 |
| **相關模組** | `src/transform` |
| **決策者** | Danny |

## 背景 (Context)

execution-roadmap.md 把「這裡為什麼用 append（不 upsert）？」與「partition 怎麼切？」都列為 Slice0 必須交代清楚的 DE 判斷（見 §2 Slice 0 段落），spec §9 也明確要求一份正式 ADR 記錄 append vs overwrite 的取捨（本文件之前只在 `docs/arc42/08_concepts.md` §8.5、程式碼註解裡非正式地寫過）。這份 ADR 把散落各處的理由收斂成一份正式決策紀錄，不是重新做決策。

Bronze/Silver/Gold 三層目前的實際寫入行為並不一致：Bronze 是字面上的 Spark `.append()`；Silver/Gold 是每次全量讀取來源層、處理後用 `createOrReplace()` 整表覆寫。這個不一致是刻意設計，不是疏漏，需要明確記錄下來，避免之後的開發者（或 Slice 2 開始做 CDC upsert 時）誤以為三層寫入邏輯應該統一。

## 決策 (Decision)

- **Bronze**：字面 Spark `.append()`。允許重跑（reprocess）時累積重複列，這是刻意接受的行為，由 Silver 的去重邏輯吸收。
- **Silver / Gold**：`createOrReplace()` 全量覆寫。每次執行都是「全量讀取來源層 → 處理 → 覆寫整張表」，不是 row-level upsert，也不是字面 Spark `.append()`。
- **Partition**：
  - **Silver**（`silver.stock`）：`partitionedBy(months(trade_date))`——`trade_date` 是型別校正後的 `date` 欄位，可以直接套用 Iceberg 的 hidden partitioning。
  - **Gold**（`gold.monthly_ohlcv`）：`partitionedBy(months(year_month))`——`year_month` 本身就是月粒度的 `date` 欄位，等同 identity partitioning。
  - **Bronze**（`bronze.stock`）：**不宣告 partition**。原因見下方理由段落。

三層的資料量（3 檔 symbol × 約 1 年交易日 ≈ 1000 列量級）都選擇月粒度而非日粒度，避免產生過多小 partition。

## 理由 (Rationale)

**為什麼 Silver/Gold 不能沿用 Bronze 的字面 append**：ADR-0002 已拍板 Bronze 允許重跑產生重複列，這些重複列的吸收責任在 Silver。如果 Silver 本身也用字面 `.append()`，重跑 Silver 會把去重後的乾淨結果疊加兩次——全量覆寫是唯一能同時滿足「Bronze 可以任意重跑」與「Silver/Gold 保持正確」這兩個要求的寫法，直接對應 spec §7 的驗收標準。

**為什麼稱為「append」卻不是字面 append**：spec §5 的 Outputs 表最初用「append」描述 Silver/Gold 的寫入模式，指的其實是「不做 row-level MERGE/upsert」——這是跟 Slice 2 交易資料的 CDC upsert 做對照：歷史行情是 **immutable 事實**，不會像交易紀錄一樣被事後修改，所以 Silver/Gold 每次都是「重新計算整個事實」而非「合併變更」。這正是 execution-roadmap.md 點名要交代的判斷。

**為什麼 Bronze 不做 partition**：Bronze 的 `date` 欄位是 `StringType`（見 ADR-0002 與 `bronze_stock.py`，全字串讀取是刻意設計，型別解析完全交給 Silver）。Iceberg 的 `months()`/`days()`/`years()` 這類 hidden-partition transform 只能套用在 `date`/`timestamp` 型別的欄位上，無法直接用在字串。要讓 Bronze 也有月粒度 partition，得改用字串前綴截斷（如 `truncate(7, date)`）這種較 hacky 的手法——但 Bronze 本身資料量小、設計哲學就是「盡量薄、不做非必要的事」，不值得為了 partition 引入這種變通做法。Silver/Gold 的日期欄位已經是正確型別，直接用 `months(...)` 是更乾淨的做法。

## 影響 (Consequences)

- ✅ **正面**：Silver/Gold 的全量覆寫語意單純、容易推理——每次執行後的結果只取決於當時的來源層內容，不需要追蹤「哪些筆是這次新增的」這種增量狀態。
- ✅ **正面**：Partition 只靠 `createOrReplace()` 就能生效，不需要額外的 `ALTER TABLE`／資料遷移步驟；重新部署程式碼、重跑 Glue Job 即可套用新的 partition spec。
- ⚠️ **注意**：Silver/Gold 每次都是全量重算，資料量變大後（例如涵蓋更多年份、更多 symbol）運算成本會線性增加；目前資料量小（約 1000 列量級）不是問題，資料量顯著成長後需要重新評估是否改為增量處理。
- ⚠️ **注意**：這個「Bronze=append／Silver,Gold=全量覆寫」的寫入模式，只適用於像市場行情這種「批次、不可變歷史事實」的資料域。Slice 2 的交易資料走 CDC + upsert，是完全不同的寫入模式策略，屆時會有自己的 ADR，不套用本 ADR 的結論。
- ❌ **負面/限制**：Bronze 沒有 partition，若之後這個資料域的資料量大幅成長（遠超過目前的 walking-skeleton 規模），Bronze 的全表掃描成本會隨之增加，屆時需要重新評估是否值得為了 partition 改變 Bronze 的型別策略或引入字串前綴 partition。
