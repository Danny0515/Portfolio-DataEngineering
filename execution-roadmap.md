# Execution Roadmap — 縱切執行路線 (Vertical Slice Roadmap)

> 本文件是 [plan.md](plan.md) 的**執行伴讀**。
> `plan.md` 是「地圖」(這個平台包含哪些能力),本文件是「路線」(實際用什麼順序走完它)。
> **plan.md 維持低頻不動;進度反映在 ADR 目錄與 Decision Log 的累積,而非改藍圖。**

---

## 0. 核心原則:縱切,不要橫切 (Vertical over Horizontal)

plan.md 的 Phase(0 / 1a-c / 2a-c)是**按能力層橫切**的分類,回答「平台有哪些東西」。

但**執行順序不照它橫著走**。若先做完所有 ingestion、再做完所有 transform,會堆出一堆半成品基礎設施,永遠沒有一條能端到端 demo 的路徑 —— 這是 side project 最常見的失焦陷阱。

**改用縱切**:每個 Slice 穿過 `ingestion → storage → transformation → serving` 一路到底,而且**每個 Slice 只新增一個核心觀念**。

```
橫切 (❌ 容易失焦)                     縱切 (✅ 每片都能 demo)
                                        Slice0  Slice1  Slice2  Slice3
Ingestion  ████████████               │ █    │ █    │ ███  │ █    │
Storage    ████████████               │ █    │ █    │ █    │ █    │
Transform  ████████████        vs     │ █    │ ██   │ ██   │ ███  │
Serving    ████████████               │ █    │ █    │ █    │ ███  │
                                       端到端  +品質  +CDC   +即時
```

**為什麼縱切對這個專案特別關鍵**:你要證明的不是「會用工具」,而是「懂得在什麼情境選什麼」。縱切讓每個 Slice 都留下一個**對照組**——Slice 0 有了「batch + append」的基準,Slice 2 才能對比出「這裡為什麼改用 CDC + upsert」。你的 ADR 是拿自己前一片做對照,而不是空談理論。

---

## 1. Slice 總覽 (Slice Overview)

| Slice | 主題 | 新增的核心觀念 | 對照/延續自 | 對應 plan.md Phase |
| --- | --- | --- | --- | --- |
| **0** | Walking Skeleton(批次骨架) | Lakehouse 端到端、Medallion、append | — (基準) | 0 + 1a |
| **1** | 資料品質 + 資料契約 | WAP Gate、品質維度、Data Contract | 疊在 Slice 0 | 2a + 4 (契約) |
| **2** | CDC 交易串流管線 | CDC、upsert/MERGE、真串流 | 對照 Slice 0 的 batch/append | 1b |
| **3** | 即時 Serving 與風控 | Windowing、延遲 vs 成本、即時 OLAP | 延續 Slice 2 的串流 | 1c |
| **4** | 治理與 DataOps | Lineage、IaC、CI/CD、可觀測性 | 橫向鋪在既有管線 | 2b + 2c |

> **執行紀律:一次只有一個 Slice 在 in-progress,絕不並行開兩條。**

---

## 2. Slice 明細 (Slice Details)

每個 Slice 用同一組欄位描述,方便當作 SDD 的任務單。

---

### Slice 0 — Walking Skeleton(批次骨架,刻意最薄)

**目標**:證明 Lakehouse 的水電管線通了。一條最薄的批次路徑,從檔案落地到查得到結果,不摻任何進階能力。

**資料流**:
```
第三方歷史行情檔 (每日 CSV/Parquet)
  → S3 (raw landing)
  → Bronze (Iceberg, append 原樣落地)
  → Silver (Iceberg, 去重 / 型別校正 / 標準化)
  → Gold  (Iceberg, 簡單日聚合,如每日 OHLCV)
  → Athena 查得到
```

**具體技術**:S3 + Apache Iceberg (Glue Catalog) + Spark 或 dbt(擇一,先簡單)+ Athena。編排先手動或單一 script,**先不上 Airflow**。

**證明的 DE 判斷**:
- **為什麼用 Iceberg 而非直接放 Parquet on S3?** —— schema evolution、time travel(審計)、ACID、避免小檔問題。
- **Medallion 為什麼要分三層?** —— 職責分離:Bronze 可重跑、Silver 可信、Gold 對接業務。
- **這裡為什麼用 append(不 upsert)?** —— 歷史行情是 immutable 事實,不會被更新;這是 Slice 2 的對照組。
- **partition 怎麼切?** —— 依交易日期,對應查詢模式。

**文件產出**:
- `docs/specs/slice0-batch-market-data.md`(本 Slice 的 Spec)
- `docs/architecture/adr/0001-use-iceberg.md`
- `docs/architecture/adr/0002-medallion-layering.md`
- Decision Log:append vs overwrite 的取捨

**完成定義 (DoD)**:資料端到端落到 Gold;Athena 查得到且數字正確;上述文件齊備;自己 review 過 AI 產出。

**刻意不做 (Out of Scope)**:串流、CDC、品質框架、catalog UI、IaC、多環境。全部留給後續 Slice。

---

### Slice 1 — 資料品質 + 資料契約(疊在批次路徑上)

**目標**:同一條批次路徑,加入「不合格資料進不了 Gold」的品質關卡,並為來源定義正式契約。

**資料流**(在 Slice 0 上插入品質關卡):
```
Bronze → Silver ──▶ [Write] 寫入 Iceberg 暫存分支
                    [Audit] 跑 Great Expectations / Soda 檢核
                    [Publish] 通過才 merge 到正式 Silver;失敗告警 + 擋下
```

**具體技術**:Great Expectations 或 Soda Core;利用 Iceberg branch 實作 WAP(Write-Audit-Publish);Data Contract 以 YAML 定義(datacontract.com spec)。

**證明的 DE 判斷**:
- **WAP Pattern 為什麼重要?** —— 品質檢核在「發布前」而非「發布後」,壞資料永遠不外流到下游。
- **品質六維度**:完整性 / 唯一性 / 時效性 / 有效性 / 一致性 / 準確性 —— 各對應什麼檢核。
- **Data Contract 到底強制了什麼?** —— schema、SLA、品質期望;違約時的行為(擋下 / 進 DLQ)。
- **檢核該放哪一層?** —— 為何放在 Bronze→Silver 之間而非最後。

**文件產出**:
- `docs/patterns/wap-quality-gate.md`(Pattern Card)
- `docs/contracts/market-data.contract.yaml`(第一份生效契約)
- `docs/architecture/adr/0003-wap-quality-gate.md`
- Decision Log:選 Great Expectations vs Soda 的理由

**完成定義 (DoD)**:故意灌一批壞資料,能被 Gate 擋下並告警;好資料正常 publish;契約檔納入版控。

**刻意不做**:串流的品質(留給 Slice 2/3)、Metadata 平台整合(留給 Slice 4)。

---

### Slice 2 — CDC 交易串流管線(第一條串流,重頭戲)

**目標**:引入即時路徑。從交易 DB 以 CDC 擷取變更,經串流處理,以 **upsert** 方式維護一張「當前狀態」表。這是整個作品集判斷力的核心展示。

**資料流**:
```
Trade DB (OLTP)
  → Debezium (CDC, 擷取 insert/update/delete)
  → MSK (Kafka topic: trade.events.v1, 以 Avro + Schema Registry)
  → Flink (串流消費)
  → Iceberg Silver (MERGE INTO / upsert,維護每筆交易當前狀態)
  → Athena
```

**具體技術**:Debezium + MSK Connect;Amazon MSK;Glue Schema Registry(Avro);Amazon Managed Service for Apache Flink;Iceberg MERGE INTO。

**證明的 DE 判斷**(這片的 ADR 最有份量,因為有 Slice 0 當對照):
- **CDC vs batch polling** —— 為何不定時撈整張表?(對來源負載、延遲、抓不到中間態、刪除偵測)。
- **upsert / MERGE vs append** —— Slice 0 用 append 因為資料 immutable;這裡交易狀態會變(下單→部分成交→成交/取消),所以要 upsert。**這個對比是敘事核心。**
- **為什麼這裡需要串流** —— 風控/部位需要低延遲,批次對帳仍保留在 Slice 0 風格。
- **MSK vs Kinesis** —— 為何選 MSK(生態、可重播、Connect)。
- **Schema Registry 作為契約強制點** —— 相容性規則如何擋下破壞性變更。
- **exactly-once / 冪等** —— CDC + upsert 如何避免重複。

**文件產出**:
- `docs/specs/slice2-cdc-trade-pipeline.md`
- `docs/architecture/adr/0004-msk-vs-kinesis.md`
- `docs/architecture/adr/0005-cdc-vs-batch-polling.md`
- `docs/patterns/cdc-merge-into.md`(Pattern Card)
- `docs/contracts/trade-events.contract.yaml`
- Decision Log:append(Slice 0)與 upsert(Slice 2)的完整對照

**完成定義 (DoD)**:在來源 DB 做 insert/update/delete,Silver 表能正確反映當前狀態;重播訊息不產生重複;schema 破壞性變更被 Registry 擋下。

**刻意不做**:即時聚合/視窗(留 Slice 3)、完整血緣(留 Slice 4)。

---

### Slice 3 — 即時 Serving 與風控(延續串流)

**目標**:在串流之上做即時聚合,產出低延遲可查的風控指標 / 交易儀表板。

**資料流**:
```
MSK (trade + market events)
  → Flink (視窗聚合:部位、曝險、異常偵測)
  → 即時 OLAP (Apache Pinot) 或先用 Iceberg + Athena
  → 儀表板 / API
```

**具體技術**:Flink Windowing;Apache Pinot(即時 OLAP)—— 此選型原本在 plan.md 標為 🧪 探索,於本 Slice 收斂;或先用 Athena 過渡再評估升級。

**證明的 DE 判斷**:
- **Windowing** —— tumbling / sliding / session window 各用在哪。
- **延遲 vs 成本 vs 新鮮度取捨** —— 什麼指標值得即時,什麼可退回批次。
- **即時 OLAP 選型** —— Pinot vs ClickHouse vs Druid,為何選定(先做 ADR spike)。
- **Serving 型態切分** —— 為何 ad-hoc 用 Athena、即時儀表板用 Pinot、監理報表用 Redshift。

**文件產出**:
- `docs/specs/slice3-realtime-risk.md`
- `docs/architecture/adr/0006-realtime-olap-engine.md`(收斂 🧪)
- Decision Log:即時 vs 批次的界線怎麼畫

**完成定義 (DoD)**:即時指標能在 sub-second ~ 秒級查到;注入異常交易能被偵測規則觸發告警。

**刻意不做**:ML 特徵庫(可列為後續延伸)。

---

### Slice 4 — 治理與 DataOps(橫向鋪在既有管線)

**目標**:把前面所有 Slice「工程化」與「可治理化」。這片是橫向的,因為它服務的是**已存在**的管線。

**內容**:
- **Lineage / Catalog**:OpenMetadata + OpenLineage,對 Airflow / Spark / dbt / Flink 發送血緣事件,呈現端到端欄位級血緣與影響分析。
- **IaC**:用 Terraform 把 S3 / MSK / Glue / EMR / Flink 全部宣告式化(可能需回頭補 Slice 0-3 手動建的資源)。
- **CI/CD**:GitHub Actions —— lint、dbt 測試、契約相容性檢查、IaC plan、部署。
- **可觀測性**:資料新鮮度 / volume / schema 變更監控 + CloudWatch/SNS 告警。
- **多環境**:dev / staging / prod。

**證明的 DE 判斷**:
- **Lineage 的價值** —— 影響分析、除錯、稽核、信任。
- **為何 IaC** —— 可重現、可審查、避免 snowflake 環境。
- **DataOps 成熟度路線** —— 手動 → 自動化 → 可觀測 → 自癒。

**文件產出**:對應 plan.md §5 與 §4.1 的完整治理文件、ADR、Runbook。

**完成定義 (DoD)**:OpenMetadata 可視化一條端到端血緣;至少一條管線由 CI/CD 自動測試部署;基礎設施可由 Terraform 重建。

**刻意不做**:過度工程化的自癒/自動回滾(列為未來展望即可)。

---

## 3. 每個 Slice 的完成 Gate(最重要的部分)

程式碼只是副產品,**這四步的軌跡才是作品集本體**。做完一個 Slice 才開下一個,這道 Gate 不可省:

| 步驟 | 動作 | 產出證據 |
| --- | --- | --- |
| 1. **實作 (Build)** | 依 Spec 開發(SDD) | 程式碼 + Spec |
| 2. **審查 (Review)** | 自己 review AI 產出,不照單全收 | Review 註記 / PR comment |
| 3. **驗證 (Verify)** | 真的跑起來、查得到、數字對 | 驗證步驟與結果 |
| 4. **決策紀錄 (Decision Log)** | 補「為何這樣選」,回答該 Slice 的判斷題 | ADR / Decision Log |

> Slice 寧可切小 —— 一個小 Slice 完整走完四步,勝過一個大 Slice 只做到「能動」。

---

## 4. 執行節奏與紀律 (Cadence & Discipline)

- **序列執行**:一次只有一個 Slice in-progress,不並行。
- **Slice 0 刻意作弊到最薄**:不碰串流/CDC/catalog/IaC,品質先手動。先證明骨架通,再逐片加真本事。
- **臨時發散有專屬出口**:想混 GCP、換引擎等,掛在對應 Slice 的 🧪,開一個 **ADR spike**,跑完再收斂,**不中途插隊另起爐灶**。
- **plan.md 不隨 Slice 改動**:進度由 ADR 目錄 + Decision Log 的累積體現。
- **每片都要能獨立 demo**:若一個 Slice 做完仍無法端到端展示,代表它被橫切了,需重新切分。

---

## 5. 與 plan.md 的關係(維護契約)

| 文件 | 角色 | 變動頻率 |
| --- | --- | --- |
| `plan.md` | 北極星:唯一目標、範圍、成功標準 | 低頻,只在範圍真的改變時 |
| `execution-roadmap.md`(本文件) | 執行路線:Slice 順序與細節 | 中頻,可隨學習調整 Slice 內容 |
| `docs/architecture/adr/*` | 決策軌跡:每個技術選擇一份 | 高頻,隨時新增,只被取代不覆寫 |

**任何調整只允許三種動作**:更新本文件的 Slice 內容、新增一份 ADR、或(極少數)更新 plan.md 的範圍。**禁止產生 plan-v2.md / roadmap-new.md 之類的分岔文件。**
