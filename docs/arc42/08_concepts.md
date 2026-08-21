# 8. Crosscutting Concepts (跨領域概念)

> 本章收錄跨 building block、跨資料域通用的架構模式與規則。本章回答**跨資料域通用**的架構規則，之後新增任何資料域（期貨、交易資料、使用者行為……）都應該比照本章的分層職責設計，不需要每個 domain 各自重新發明一套轉換邏輯。理由不在本章重複展開，只連結 ADR。目前「這套規則實際怎麼跑」的具體執行流程圖，見 [06. Runtime View](06_runtime_view.md)。

## 目錄

- [8.1 Medallion Architecture 總覽](#81-medallion-architecture-總覽)
  - [8.1.1 Bronze 層：設計原則](#811-bronze-層設計原則)
  - [8.1.2 Silver 層：設計原則](#812-silver-層設計原則)
  - [8.1.3 Gold 層：設計原則](#813-gold-層設計原則)
- [8.5 寫入模式策略（Append vs Overwrite）](#85-寫入模式策略append-vs-overwrite)
- [8.6 Partition 設計](#86-partition-設計)
- [8.7 目前已實作的具體案例：Market Data / Stock（Slice0）](#87-目前已實作的具體案例market-data--stockslice0)
- [8.8 與 ADR 的關係 / 尚未涵蓋的範圍](#88-與-adr-的關係--尚未涵蓋的範圍)

---

## 8.1 Medallion Architecture 總覽

本專案的 Lakehouse 用 Bronze / Silver / Gold 三層 Iceberg table 組織所有資料域（Market Data／Transaction Data／User Behavior，見 [plan.md](../../plan.md) §0）。三層的角色分工是固定的架構規則，跟資料域無關：

| 層級 | 角色 | 是否做資料清洗/轉換 | 寫入模式 |
| --- | --- | --- | --- |
| Bronze | Landing（原始落地） | 否，只做 provenance 標記 | append（允許重跑累積重複列） |
| Silver | Cleanse & Standardize（清洗/標準化） | 是：去重、型別校正、欄位命名標準化 | 全量覆寫（createOrReplace） |
| Gold | Aggregate（業務聚合） | 是：依業務需求做聚合/寬表 | 全量覆寫（createOrReplace） |

命名慣例（見 [plan.md](../../plan.md) §2.2）：每個資料域內部依資產類別/子類型再細分一層 table，例如 `bronze.stock`／`bronze.futures`；三層都遵守 `<layer>.<子類型>` 這個 pattern，不加多餘的 `_data` 尾綴（這是資料湖倉，裡面本來就是資料），新增子類型時不需要重新設計命名規則。

所有層都用同一套 Iceberg/Glue Catalog 設定執行（`glue_catalog`，見 [glue.tf](../../infra/environments/dev/glue.tf) 的 `local.iceberg_spark_conf`），PySpark 程式放在 `src/transform/`。

### 8.1.1 Bronze 層：設計原則

- **職責邊界**：只做 provenance 標記（`ingest_time`、`source_file`），不做任何有副作用的轉換（去重、過濾負值/空值等）、不宣告 partition。全欄位以字串讀取（`inferSchema=false`），schema 因此完全固定，不受來源資料髒污程度影響。刻意設計成這麼薄的理由見 [ADR-0002](../architecture/adr/0002-medallion-layering.md)，不在此重複展開。
- **寫入模式**：`DESCRIBE TABLE` 判斷表格是否存在，不存在則 `create()`，存在則 Spark `.append()`。重跑會累積重複列，這是刻意接受的行為，吸收責任在 Silver（見 8.5）。

### 8.1.2 Silver 層：設計原則

> Silver 是整個湖倉「什麼算乾淨資料」規則的唯一集中維護點，職責固定包含以下三件事：

1. **去重（Deduplication）**：依自然鍵（natural key）去重，用 `Window.partitionBy(<natural key>).orderBy(ingest_time desc)` 取 `row_number() == 1`，保留 Bronze 重跑後最新一批的版本。
2. **型別校正（Type Correction）**：Bronze 全欄位皆為字串（見 8.2），型別解析 100% 由 Silver 負責，cast 成業務上正確的型別（如金額類用 `decimal`、日期轉 `date` type）。cast 失敗會變 `null`，交由品質過濾統一擋掉。
3. **欄位命名標準化（Column Standardization）**：改成明確、跨表 join 不易混淆的名稱，且**不帶出 Bronze 的 provenance 欄位**——Silver 對外呈現乾淨的業務資料，lineage 屬於 Bronze 的職責。

**寫入模式**：全量覆寫（`createOrReplace()`），不是字面 Spark `.append()`，理由見 8.5——這是 Silver 層的通用規則，任何資料域的 Silver table 都適用。

**具體案例**：`silver.stock`（[`src/transform/silver_stock.py`](../../src/transform/silver_stock.py)）自然鍵 `(symbol, date)`；型別校正 `open/high/low/close` → `decimal(10,2)`、`date` → Spark `date`、`volume` → `integer`；欄位標準化 `date` → `trade_date`；另加品質過濾（非空非負、`high >= low`，對應 [spec §6](../specs/slice0-batch-market-data.md)），處理順序「去重 → 型別 cast → 品質過濾」，確保過濾套用在已轉型的欄位上。未來新增資料域各自訂定自然鍵與型別規則，但仍遵守這三件事的職責邊界。

### 8.1.3 Gold 層：設計原則

- **職責邊界**：對外可查詢的業務聚合寬表，把 Silver 的明細資料依業務需求聚合成更粗粒度的檢視。
- **選粒度的原則**：聚合粒度必須比上游明細粒度更粗——跟 Silver 自然鍵一樣細的話，聚合就是每組固定 1 列的 no-op，無法驗證聚合邏輯，也不是 Gold 層該做的事。
- **寫入模式**：全量覆寫（`createOrReplace()`），理由同 Silver（見 8.5）。
- **具體案例**：`gold.monthly_ohlcv`（[`src/transform/gold_monthly_ohlcv.py`](../../src/transform/gold_monthly_ohlcv.py)）把 Silver 的 `(symbol, trade_date)` 明細聚合成 `(symbol, year_month)` 月頻寬表：`open`/`close` 用 `min_by`/`max_by`（依 `trade_date` 取該月最早/最晚交易日的值），`high`/`low` 用 `max`/`min`，`volume` 用 `sum`。用 `min_by`/`max_by` 而非 `first()`/`last()`，是因為分組後每組多列時 `first()`/`last()` 排序不保證，容易安靜地拿到錯值。

## 8.2 寫入模式策略（Append vs Overwrite）

| 層級 | 寫入模式 | 字面 Spark 語意 | 適用範圍 |
| --- | --- | --- | --- |
| Bronze | `append` | 真的是 Spark `.append()`，重跑會累積重複列（刻意接受，由 Silver 吸收） | 所有資料域通用 |
| Silver | `createOrReplace()` | 每次執行「全量讀取 Bronze → 處理 → 覆寫整張表」，非 row-level upsert，也不是字面 append | 批次、不可變事實類資料域（如市場行情）通用 |
| Gold | `createOrReplace()` | 同 Silver，全量讀取 Silver → 聚合 → 覆寫整張表 | 同上 |

這是為什麼 Silver/Gold 必須是全量覆寫而非字面 append：Bronze 層的設計就是刻意允許重跑產生重複列（8.2），這些重複必須被 Silver 的去重邏輯完全吸收、不得外溢——如果 Silver 本身也用字面 `.append()`，重跑 Silver 會把去重後的乾淨結果疊加兩次。全量覆寫是唯一能保證「Bronze 可以任意重跑，而不影響 Silver/Gold 正確性」這個架構承諾的寫法，適用於任何走這套 Bronze→Silver→Gold 批次管線的資料域。

[spec §5](../specs/slice0-batch-market-data.md) 早期版本用「append」描述 Silver/Gold 的寫入模式，指的是「不做 row-level MERGE/upsert」（跟 Slice 2 的 upsert 對照），**不是字面 Spark 寫入模式**——spec 文字已同步更新為「全量覆寫（createOrReplace）」以避免用詞混淆。

> **範圍限制**：這個「Bronze=append／Silver,Gold=全量覆寫」的寫入模式策略，適用對象是像市場行情這種「批次、不可變歷史事實」的資料域。Slice 2 的交易資料走 CDC + upsert，屬於不同的寫入模式策略，屆時會有自己的 ADR/spec，不套用本節規則。

## 8.3 Partition 設計

- **原則**：partition 粒度依實際資料量決定，避免產生過多小 partition。例如 stock 資料: 3 檔 symbol × 約 1 年交易日 ≈ 1000 列量級，選擇月粒度而非日粒度。
- **Silver/Gold**：用 Iceberg 的 hidden partitioning，`partitionedBy(months(<date 欄位>))`——兩層的日期欄位（`trade_date`／`year_month`）都已經是型別校正後的 `date` type，可以直接套用 `months()` transform。
- **Bronze 不宣告 partition**：Bronze 的日期欄位是 `StringType`（見 8.2 全字串讀取設計），Iceberg 的 `months()`/`days()`/`years()` 只能套用在 date/timestamp 型別，無法直接用在字串上；要繞過這個限制得用字串前綴截斷（如 `truncate(7, date)`）這類變通手法，但 Bronze 資料量小、設計哲學是「盡量薄、不做非必要的事」，不需要為了 partition 引入這種手法。
- **透過 `createOrReplace()` 自然生效**：Silver/Gold 每次執行都是全量覆寫（見 8.5），`partitionedBy(...)` 直接寫進 `.writeTo(...)` chain 即可在下次執行時套用新的 partition spec，不需要額外的 `ALTER TABLE` 遷移步驟。
- 完整決策紀錄見 [ADR-0003](../architecture/adr/0003-append-vs-overwrite.md)。

## 8.4 目前已實作的具體案例：Market Data / Stock（Slice0）

上面幾節是通用架構規則，本節整理「目前唯一已實作」的具體實例，方便對照抽象規則與實際程式碼；實際執行流程圖見 [06. Runtime View](06_runtime_view.md)：

| 層級 | Table | 程式 |
| --- | --- | --- |
| Bronze | `bronze.stock` | [`src/transform/bronze_stock.py`](../../src/transform/bronze_stock.py) |
| Silver | `silver.stock` | [`src/transform/silver_stock.py`](../../src/transform/silver_stock.py) |
| Gold | `gold.monthly_ohlcv` | [`src/transform/gold_monthly_ohlcv.py`](../../src/transform/gold_monthly_ohlcv.py) |

未來新增資料域（如期貨、交易資料、使用者行為）時，應該先參考 8.1~8.6 的通用規則設計三層職責，再視該資料域的特性（自然鍵、型別、聚合粒度、寫入模式策略、partition 粒度）填入具體實作，不需要重新討論分層邊界本身。

## 8.5 與 ADR 的關係 / 尚未涵蓋的範圍

- 本章是 ADR-0002（分層職責）與 ADR-0003（寫入模式、partition 設計）決策的落地細節，取捨理由仍以這兩份 ADR 為準，本章不重複展開。
- **Athena 查詢驗證**（spec §4 item 8）不在本章範圍，是實際部署後的驗證步驟，不是轉換邏輯的一部分，見 [docs/runbooks/slice0-verification.md](../runbooks/slice0-verification.md)。
