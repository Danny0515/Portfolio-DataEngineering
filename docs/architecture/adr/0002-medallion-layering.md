# ADR-0002: 為何分 Bronze/Silver/Gold 三層

| 屬性 | 值 |
| --- | --- |
| **狀態** | ✅ `Accepted` |
| **日期** | 2026-07-28 |
| **相關模組** | `src/transform` |
| **決策者** | Danny |

## 背景 (Context)

Slice0 的資料流是「第三方歷史行情檔 → S3 raw landing → Bronze → Silver → Gold → Athena 查得到」（spec §1）。原始 CSV 資料品質無法保證乾淨（Slice1 會刻意注入髒資料測試品質關卡），如果讓「原始落地」跟「品質/型別校正」混在同一個步驟做，一旦上游清洗邏輯改版，就沒辦法重現「原始收到的資料長怎樣」，除錯回溯到源頭會變困難，品質規則邏輯也會分散在多處各自維護。

## 決策 (Decision)

採用 Medallion Architecture，分三層 Iceberg table：

- **Bronze**（`bronze.stock`）：只做 provenance 標記（`ingest_time`、`source_file`），append-only，全欄位以字串讀取（`inferSchema=false`），不手寫 schema、不做任何型別解析；不做任何去重、負值過濾、`high >= low` 檢查
- **Silver**（`silver.stock`，spec item 6，尚未實作）：負責去重（`(symbol, date)` unique）、型別校正（price → decimal、date → date type）、標準化欄位命名
- **Gold**（`gold.monthly_ohlcv`，spec item 7，尚未實作）：對外可查詢的月頻行情聚合寬表

## 理由 (Rationale)

- Bronze 作為不可變的 ingestion log：保留「系統當初真正收到的原始資料」，即使 Silver 的清洗/去重邏輯之後改版，仍可從 Bronze 重新 reprocess，不會遺失原始事實
- 品質/型別邏輯集中在單一層維護：所有「什麼算乾淨資料」的判斷只寫在 Silver 一處，避免同樣的檢查邏輯散落在 ingestion 腳本、Bronze 腳本、下游查詢等多個地方各自維護、容易漂移
- 呼應 spec §7 驗收標準：「Bronze 層資料可被重跑（reprocess）而不影響 Silver/Gold 的正確性」——這個保證只有在 Bronze 不做任何有副作用的轉換（去重、過濾）時才成立：Bronze 全量重跑本來就會在 Bronze 自己產生重複列，但這些重複列會被 Silver 的去重邏輯正確吸收，不會外溢到 Silver/Gold
- 分層職責清楚，方便未來 Slice1 在 Silver 前面插入 WAP Gate（先寫 Bronze「原始快照」、通過驗證才進到下一層），不需要更動 Bronze 本身的邏輯

## 影響 (Consequences)

- ✅ **正面**：Bronze 的實作極度單純（純 provenance tagging），降低 Slice0 落地的複雜度與出錯機會
- ✅ **正面**：之後要加資料品質框架（Great Expectations/WAP，Slice1）時，切入點明確就是 Bronze→Silver 之間，不需要重新設計分層
- ⚠️ **注意**：Bronze 重跑會累積重複列（同一份原始資料多次 append），這是刻意接受的行為，不是 bug；若之後資料量變大需要控制 Bronze 儲存成本，可以考慮加 Glue Job Bookmark（目前刻意不用，理由見 `src/transform/bronze_stock.py`）
- ⚠️ **注意**：目前 Silver/Gold 的 Iceberg table 還沒建立（只有 Glue Database namespace 先建好），這兩層的實際實作是 spec item 6/7，本 ADR 先把分層理由記錄下來
