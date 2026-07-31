# 6. Runtime View (資料流 / 執行時期視角)

> 本章只呈現「目前實際怎麼跑」的執行流程圖。每一層的設計原則、取捨理由屬於通用架構規則，見 [08. Crosscutting Concepts](08_concepts.md)（Medallion Architecture）與 [ADR-0002](../architecture/adr/0002-medallion-layering.md)，本章不重複展開。

## 6.1 批次資料流：Market Data / Stock（Slice0）

```mermaid
flowchart LR
    RAW[/"S3 raw landing<br/>raw/market/stock/dt=YYYY-MM-DD/"/]

    subgraph Bronze["Bronze"]
        BJOB["bronze_stock.py"]
        BT[("bronze.stock")]
    end

    subgraph Silver["Silver"]
        SJOB["silver_stock.py"]
        ST[("silver.stock")]
    end

    subgraph Gold["Gold"]
        GJOB["gold_monthly_ohlcv.py"]
        GT[("gold.monthly_ohlcv")]
    end

    ATH{{"Athena 查詢"}}

    RAW -->|"CSV, inferSchema=false"| BJOB
    BJOB -->|"append"| BT
    BT -->|"全量讀取"| SJOB
    SJOB -->|"createOrReplace"| ST
    ST -->|"全量讀取"| GJOB
    GJOB -->|"createOrReplace"| GT
    GT --> ATH
```

| 節點 | 對應程式 / Table | 一句話說明 |
| --- | --- | --- |
| `BJOB` | [`src/transform/bronze_stock.py`](../../src/transform/bronze_stock.py) | 全字串讀取 + provenance 標記，寫入 `bronze.stock` |
| `SJOB` | [`src/transform/silver_stock.py`](../../src/transform/silver_stock.py) | 去重 + 型別 cast + 品質過濾，寫入 `silver.stock` |
| `GJOB` | [`src/transform/gold_monthly_ohlcv.py`](../../src/transform/gold_monthly_ohlcv.py) | 月頻聚合（`min_by`/`max_by`），寫入 `gold.monthly_ohlcv` |

## 6.2 目前執行方式

- Slice0 沒有 Airflow，三個 Glue Job 目前是人工依序觸發（`aws glue start-job-run`），順序固定 Bronze → Silver → Gold，中間沒有自動相依/重試機制。
- 圖中未畫出 partition：Bronze/Silver/Gold 目前都沒有宣告 `partitionedBy(...)`，屬於 [spec §4 item 9](../specs/slice0-batch-market-data.md) 尚未處理的範圍。
- 圖中的 `Athena 查詢` 節點目前尚未實際驗證，對應 [spec §4 item 8](../specs/slice0-batch-market-data.md)，留待之後部署後執行。
