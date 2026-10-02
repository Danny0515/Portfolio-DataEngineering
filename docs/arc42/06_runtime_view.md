# 6. Runtime View (資料流 / 執行時期視角)

> 本章只呈現「目前實際怎麼跑」的執行流程圖。每一層的設計原則、取捨理由屬於通用架構規則，見 [08. Crosscutting Concepts](08_concepts.md)（Medallion Architecture）與 [ADR-0002](../architecture/adr/0002-medallion-layering.md)／[ADR-0003](../architecture/adr/0003-append-vs-overwrite.md)，本章不重複展開。

## 6.1 批次資料流：Market Data / Stock（Slice0~1）

```mermaid
flowchart LR
    RAW[/"S3 raw landing<br/>raw/market/stock/dt=YYYY-MM-DD/"/]

    subgraph Bronze["Bronze"]
        BJOB["bronze_stock.py"]
        BT[("bronze.stock")]
    end

    subgraph Silver["Silver"]
        SJOB["silver_stock.py"]
        STG["staging branch"]
        AUD{"GX Audit<br/>失敗則擋下，main 不動"}
        ST[("silver.stock<br/>main")]
        LOG[("silver.audit_log")]
    end

    subgraph Gold["Gold"]
        GJOB["gold_monthly_ohlcv.py"]
        GT[("gold.monthly_ohlcv")]
    end

    ATH{{"Athena 查詢"}}

    RAW -->|"CSV, inferSchema=false"| BJOB
    BJOB -->|"append"| BT
    BT -->|"全量讀取"| SJOB
    SJOB -->|"① Write：overwrite"| STG
    STG -->|"② Audit：讀回 staging"| AUD
    AUD -->|"成敗皆記"| LOG
    AUD -->|"③ 通過：fast_forward"| ST
    ST -->|"全量讀取"| GJOB
    GJOB -->|"createOrReplace"| GT
    GT --> ATH
    LOG --> ATH
```

| 節點 | 對應程式 / Table | 一句話說明 |
| --- | --- | --- |
| `BJOB` | [`src/transform/bronze_stock.py`](../../src/transform/bronze_stock.py) | 全字串讀取 + provenance 標記，寫入 `bronze.stock` |
| `SJOB` | [`src/transform/silver_stock.py`](../../src/transform/silver_stock.py) | 去重 + 型別 cast + 欄位正規（不做人工品質過濾），先寫入 staging branch，通過 GX Audit 才 `fast_forward` 到 `silver.stock` main（WAP，見 [Pattern Card](../patterns/wap-quality-gate.md)），每輪 Audit 結果寫入 `silver.audit_log`；逐步細節見 6.2 |
| `GJOB` | [`src/transform/gold_monthly_ohlcv.py`](../../src/transform/gold_monthly_ohlcv.py) | 月頻聚合（`min_by`/`max_by`），寫入 `gold.monthly_ohlcv` |

## 6.2 批次資料流細節：處理邏輯與 WAP 品質關卡

回答「一批資料進來後，每一步做什麼、什麼條件走哪條路」。

```mermaid
flowchart 
    subgraph RAW["Raw landing"]
        A[S3]
    end

    subgraph BRONZE["Glue job: bronze-{domain}"]
        B1["全欄位以 string 讀取"]
        B2["增加來源資訊欄位: ingest_time、source_file"]
        B3{"bronze table</br>已存在?"}
        B4["append"]
        B5["create<br/>Iceberg v2"]
        B1 --> B2 --> B3
        B3 -->|"是"| B4
        B3 -->|"否"| B5
    end

    BT[("bronze.{domain}<br/>重跑會累積重複列")]

    subgraph SILVER["Glue job: silver-{domain}"]
        S1["整表讀取"]
        S2["只做「去重、cast、欄位正規」不做人工品質過濾"]
        S3{"silver table</br>已存在?"}
        S4["直接建新表在 main，跳過 WAP</br>(TODO: 未來改成建立空表，不跳過 WAP)"]
        subgraph as["WAP（Write-Audit-Publish）"]
            S5["① Write<br/>CREATE BRANCH IF NOT EXISTS staging<br/>整批 overwrite 到 staging"]
            S6["② Audit<br/>讀回 staging，跑 GX suite"]
            S7["寫 audit_log<br/>batch_id = staging snapshot_id<br/>成敗皆記"]
            S8{"Audit 通過？"}
            S9["③ Publish<br/>fast_forward（main → staging）"]
            S10["擋下<br/>main 不動"]
        end 
        S1 --> S2 --> S3
        S3 -->|"否（第一次執行）"| S4
        S3 -->|"是"| S5
        S5 --> S6 --> S7 --> S8
        S8 -->|"是"| S9
        S8 -->|"否"| S10
    end

    SM[("silver.{domain}<br/>main branch")]
    SL[("silver.audit_log")]

    subgraph GOLD["Gold Job: gold-{business requirement}"]
        G1["根據業務邏輯讀取"]
        G2["根據業務邏輯更新(replace/upsert/overwrite)"]
        G1 --> G2 
    end

    GT[("gold.monthly_ohlcv")]
    ATH["Athena 查詢"]

    A --> B1
    B4 --> BT
    B5 --> BT
    BT --> S1
    S4 --> SM
    S9 --> SM
    S7 --> SL
    SM --> G1
    G2 --> GT
    GT --> ATH
    SL --> ATH
```

## 6.3 目前執行方式

- Slice0 沒有 Airflow，三個 Glue Job 目前是人工依序觸發（`aws glue start-job-run`），順序固定 Bronze → Silver → Gold，中間沒有自動相依/重試機制。
- 圖中未畫出 partition：Silver（`months(trade_date)`）、Gold（`months(year_month)`）都已宣告月粒度 partition，Bronze 因 `date` 欄位是 string 型別而不宣告 partition，完整理由見 [ADR-0003](../architecture/adr/0003-append-vs-overwrite.md) 與 [08_concepts.md §8.6](08_concepts.md#86-partition-設計)。
- 圖中的 `Athena 查詢` 節點已完成正式驗證（筆數、schema、去重、品質規則、聚合正確性皆通過），對應 [spec §4 item 8](../specs/slice0-batch-market-data.md)，驗證 SQL 見 [docs/runbooks/slice0-verification.md](../runbooks/slice0-verification.md)。
