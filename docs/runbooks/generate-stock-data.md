# Runbook: 模擬股票資料 Generator（`generate_stock_data.py`）

## 背景 (Why)

`src/ingestion/generate_stock_data.py` 是整條批次管線唯一的資料產生入口，對應 [docs/specs/slice0-batch-market-data.md](../specs/slice0-batch-market-data.md) §4 項目 2。它同時扮演兩種角色：

- **Slice 0**：產生全乾淨的模擬 OHLCV 資料，落地到 raw landing（`<output-dir>/dt=YYYY-MM-DD/market.csv`），供 Bronze → Silver → Gold 管線使用
- **Slice 1**：透過 `--dirty-rate` 開關注入違反 [docs/specs/slice1-quality-contract.md](../specs/slice1-quality-contract.md) §6 品質規則的髒資料，供 WAP Gate 的 Audit/擋下邏輯測試用

這份 runbook 只涵蓋「怎麼跑這支 script、參數怎麼調」，不涉及 WAP Gate 本身的實作（見 slice1 spec §4 項目 3-5）。

## 前置條件

- 已安裝 `uv`（見 CLAUDE.md「可用工具」，執行路徑 `/opt/homebrew/bin/uv`）
- 在專案根目錄下執行（script 用相對路徑寫入 `--output-dir`）
- 純 stdlib 實作，不需要額外安裝套件（no pandas/numpy/boto3，見程式檔頭註解）

## 參數說明

| 參數 | 型別 | 預設值 | 說明 |
| --- | --- | --- | --- |
| `--symbols` | str | `2330,2454,3653` | 逗號分隔的股票代號清單。合法代號定義見 [slice0-batch-market-data.md §3.4](../specs/slice0-batch-market-data.md) |
| `--start-date` | str（`YYYY-MM-DD`） | 未指定 | 起始日期；不指定時用 `today - --years` 回推 |
| `--end-date` | str（`YYYY-MM-DD`） | 未指定 | 結束日期；**必須搭配 `--start-date` 一起用**，單獨給會在 `parse_args()` 階段報錯（`--end-date requires --start-date`，exit code 2）。`--start-date` 有給但 `--end-date` 未給時，沿用舊行為（`end` = 今天） |
| `--years` | float | `1.0` | `--start-date` 未指定時，回推的歷史年數 |
| `--output-dir` | str | `data/raw/market/stock` | 輸出根目錄，會依交易日建立 `dt=YYYY-MM-DD/` 分區，每個分區一個 `market.csv` |
| `--dirty-rate` | float `[0, 1]` | `0.0` | 每一列被注入髒資料的機率。`0.0` = 全乾淨（Slice 0 用法），`> 0` = 供 Slice 1 WAP Gate 測試用 |
| `--seed` | int | `42` | 亂數種子，固定即可重現同一批資料（含髒資料的位置與內容） |

只產生 Mon-Fri 的交易日（`trading_days()`），**不套用台股假日曆**，純週末排除。

## 常見使用情境

### 1. 產生 Slice 0 標準乾淨資料（管線預設輸入）

```bash
uv run python src/ingestion/generate_stock_data.py
```

等同 `--symbols 2330,2454,3653 --years 1.0 --output-dir data/raw/market/stock --dirty-rate 0.0 --seed 42`。輸出直接落在管線讀取的 `data/raw/market/stock/`（此目錄已 gitignore，不會進版控）。

### 2. 產生含髒資料的小批次，測試 WAP Gate

```bash
uv run python src/ingestion/generate_stock_data.py \
  --years 0.3 --dirty-rate 0.4 --seed 1 \
  --output-dir /tmp/dirty-check
```

指到 `/tmp/dirty-check` 之類的暫存目錄，避免覆蓋 `data/raw/market/stock/` 既有的乾淨資料。上面這組參數（79 個交易日、40% 注入機率）已實測過，一次執行即可涵蓋全部六種髒資料 kind，適合拿來快速肉眼檢查或接 Audit 流程做端到端測試。

### 3. 自訂代號或時間區間

```bash
# 只產生 2330 一檔，過去半年
uv run python src/ingestion/generate_stock_data.py --symbols 2330 --years 0.5

# 只給 --start-date：end 固定是「今天」（往前跑到現在）
uv run python src/ingestion/generate_stock_data.py --start-date 2026-01-01

# 給明確的起訖區間 [--start-date, --end-date]
uv run python src/ingestion/generate_stock_data.py --start-date 2026-01-01 --end-date 2026-01-31

# 錯誤示範：單獨給 --end-date 會被拒絕
uv run python src/ingestion/generate_stock_data.py --end-date 2026-01-31
# error: --end-date requires --start-date
```

## 髒資料種類對照表（`--dirty-rate > 0` 時）

每列被選中注入髒資料時，會從六種 kind 中均勻隨機挑一種（`inject_dirty()`，[generate_stock_data.py:117](../../src/ingestion/generate_stock_data.py)）。對應 slice1 spec §6 的四個品質維度：

| kind | 對應 §6 維度 | 效果 |
| --- | --- | --- |
| `negative_price` | 有效性 Validity | 隨機把 `open`/`high`/`low`/`close` 其中一欄轉負值 |
| `high_lt_low` | 有效性 Validity | 強制 `high = low - 1`，違反 `high >= low` |
| `invalid_date` | 有效性 Validity | `date` 從 `YYYY-MM-DD` 轉成 `YYYY/MM/DD`，格式不合法 |
| `empty_field` | 完整性 Completeness | 隨機把任一欄位（含 `symbol`、`date`）清空為空字串 |
| `duplicate` | 唯一性 Uniqueness | 同一列原樣複製兩次，造成 `(symbol, date)` 重複 |
| `invalid_symbol` | 一致性 Consistency | `symbol` 換成白名單外的代號（`9999`/`0000`/`ABCD`） |

由於是機率式、均勻隨機挑選，`--years`/`--dirty-rate` 太小的批次不保證六種都出現；情境 2 給的參數組合已驗證過會涵蓋全部六種。

## 如何檢查產出

```bash
# 看某個分區的原始內容
cat <output-dir>/dt=<yyyy-mm-dd>/market.csv

# 掃過整批輸出，人工比對是否符合預期的髒資料樣態
grep -rH "" <output-dir>/dt=*/market.csv
```

肉眼比對重點：負值價格（如 `-159.3`）、空欄位（連續兩個逗號或欄位為空）、`high` 數值小於 `low`、同一個 `(symbol, date)` 出現兩次、代號是 `9999`/`0000`/`ABCD`、日期格式變成 `2026/04/22`（非 ISO）。

**列數基準值**：乾淨情境下總列數應等於「交易日數 × symbol 數」。`--dirty-rate > 0` 時，六種 kind 裡只有 `duplicate` 會讓一列變兩列（其餘 kind 都是原地修改同一列，列數不變），所以總列數會是「基準值 + 命中 `duplicate` 的列數」，**大於基準值是預期行為，不是 bug**——列數超標本身就是「這批資料含重複列」的訊號，剛好可以用來快速確認 `--dirty-rate` 有生效。

## 相關文件

- [docs/specs/slice0-batch-market-data.md](../specs/slice0-batch-market-data.md) §3.4 / §4 項目 2 — 合法代號範圍、generator 作為 Slice 0 交付項目的定位
- [docs/specs/slice1-quality-contract.md](../specs/slice1-quality-contract.md) §3.3 / §4 項目 1 / §6 — 髒資料注入開關的決策理由與品質規則定義
- [docs/runbooks/slice0-verification.md](slice0-verification.md) — 產生資料後，如何用 Athena 驗證 Bronze/Silver/Gold 三層結果
