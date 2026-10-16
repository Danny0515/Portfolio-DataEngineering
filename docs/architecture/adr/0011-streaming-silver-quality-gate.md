# ADR-0011: 串流 Silver 的品質閘：Registry 管結構、Silver 管值，逐筆規則加隔離

| 屬性 | 值 |
| --- | --- |
| **狀態** | ✅ `Accepted` |
| **日期** | 2026-10-16 |
| **相關模組** | Slice 2b 串流 Silver（尚未實作；將位於 `src/transform/`、`src/quality/rules/silver_trade.yaml`、`contracts/trade-events.contract.yaml`） |
| **決策者** | Danny |

## 背景 (Context)

2a 把 CDC 事件送進 Kafka，品質防線只有 Glue Schema Registry（`BACKWARD` 相容性）與 DLQ（序列化失敗）。查證後發現，契約 `quality` 區塊的 11 條可執行規則，只有 1 條（`trade_id` 非空）在真實 schema 上被技術強制：真實的 `transaction.trade.v1` 是 Debezium 依來源表自動推出來的，欄位寬鬆（nullable、普通 string）。`schema_registry.tf` 裡較嚴格的 `trade_events` 只是測試替身，不被真實流量使用。Kafka 層保證的是結構合規，不是值合規。

2b 要把這些事件寫進 Silver。Silver 在本專案的定位是「清洗、標準化」的可信層，Slice 1 也是在 Silver 前加品質關卡。但批次的 WAP 是整批寫 staging、整批稽核、整批發布，串流沒有批次邊界，不能照搬。spec 原先把完整的串流品質留給 Slice 3/4，但 Slice 1 的 roadmap 寫的是留給 Slice 2/3，而 Silver 正是 2b 寫入，缺少這一道會讓 Silver 退化成來源 DB 的忠實鏡像，而不是合規資料。

## 決策 (Decision)

1. **分工**：Registry 保證「長得對」（結構、型別、schema 演進相容），Silver 保證「值對、狀態對、不重複」。進入 Silver 的資料必須符合 Silver 的完整規則集，不限於此處列出的項目。
2. **機制**：Silver 串流以**逐筆規則 + 隔離（quarantine）**實作，在 `foreachBatch` 內：合規列 `MERGE INTO silver.trade`，違規列寫入 `silver.trade_rejects`（原事件、違規原因、時間），**不擋住其他列**。Bronze 仍原樣保存所有事件。
3. **成員資格規則全部放在 2b**：型別轉換、完整性、有效性、一致性（含狀態轉移合法性，對 `op='u'` 檢查事件自帶的 `before.status → after.status`），唯一性由 `MERGE` 以 `trade_id` 為鍵保證，去重與冪等由 LSN 比較保證。`op='d'` 不驗證值，以軟刪除處理。
4. **規則單一來源**：規則寫成 `src/quality/rules/silver_trade.yaml`，沿用 Slice 1 的 GX 規則名稱與檔案格式；Glue job 以 `--extra-files` 載入。契約 v2 的 `quality` 區塊引用同一組規則並標註「強制位置」，另加 pytest 檢查兩者一致。
5. **執行引擎與批次不同**：批次（Slice 1）以 GX 引擎對整個 staging 表驗證；串流以一段輕量 PySpark 把同一套規則翻成 Spark 運算式，逐列判斷。規則定義共用，引擎不同。
6. **營運監控留 Slice 4**：排程批次稽核、定期對帳、`observe` + `StreamingQueryListener` 告警、CloudWatch 指標需要排程器與告警基礎設施。2b 只做每批次計數日誌（進來／合規／隔離各幾列）與驗證階段的一次性對帳。

## 理由 (Rationale)

1. **兩層各管擅長的事**：Registry 管結構與演進，無法逐筆檢查值域；Silver 管內容與語意。不在 Silver 重寫 Avro 已強制的型別與 enum；但因為真實 schema 寬鬆、幾乎沒有結構強制，目前兩邊沒有實質重疊，Silver 要完整驗證。
2. **符合「壞訊息不擋住好訊息」**：這是 2a 的串流版 WAP 精神；隔離表讓單筆違規不阻塞整個串流，同時不丟失資料（Bronze 保全）。
3. **規則單一來源避免漂移**：目前契約 `quality` 與 Slice 1 的 `rules/*.yaml` 是兩份各自維護的複本，無機制保證一致。2b 起規則檔為執行來源、契約引用，並以測試守住。這也讓契約第一次有系統實際執行其規則（目前契約只是宣告文件）。
4. **狀態轉移用 `before`**：CDC 事件自帶變更前影像，檢查「FILLED 不得退回 NEW」不需要 join 目標表，無狀態、易測。
5. **可在本機單元測試**：評估器是純 PySpark，repo 現有的 `pyspark` 開發依賴即可測，不需要 AWS 資源。
6. **範圍切分合理**：決定一筆資料能否進 Silver 的規則（成員資格）屬於 2b；排程、告警、對帳屬營運監控，需 Slice 4 的排程與可觀測性基礎。

**Alternatives considered**：

- **逐筆規則 + 隔離，規則共用、引擎不同**（選定）：理由如上。
- 沿用 2a，表層不加關卡（原 spec §3.4 選項 A）（未選）：Silver 退化為來源的忠實鏡像，髒值照樣進入，與 Silver 為可信層的定位不符。
- A + 定期對 `silver.trade` 跑 GX 批次稽核（原 spec §3.4 選項 B）（未選）：串流表的批次稽核語意不明（稽核哪個時間切片、失敗回滾什麼），且需要排程器，延至 Slice 4。
- 只標記不隔離，全部進 Silver 並加違規欄位（未選）：壞資料進了 Silver，使用者需自行過濾，Silver 不再是可信層；優點是準確性比對不受影響。
- 串流也用 GX 引擎執行，引擎統一（未選）：GX 為整批通過／失敗設計，逐列分流與每批次建立 context 的開銷未實測，狀態轉移規則需自訂 expectation；規則共用已達成語言統一，日後可只換評估器而不改規則檔。
- 來源 DB 加 NOT NULL／CHECK 約束，讓 Avro 變嚴格（未選）：會改變 2a「刻意不加約束，供髒資料測試」的設計，且無法涵蓋所有規則。

## 影響 (Consequences)

- ✅ **正面**：Silver 成為合規資料層，與批次路徑的定位一致；契約第一次有系統執行；壞資料可稽核（隔離表）而非靜默丟棄；規則評估器可本機測試。
- ⚠️ **注意**：Silver 的定義改為「來源的最新**合規**狀態」，準確性比對須改為「Silver 與來源的差異，恰好等於隔離表中的 `trade_id`」；若某筆交易的第一個事件違規被隔離，之後合規的更新會以新增一列進入 Silver，該筆交易在 Silver 看不到更早的歷史（歷史在 Bronze）；隔離表不自動重放，修復靠人工；規則評估器需要自行實作並維護規則詞彙（非空、值域、範圍、狀態轉移）。
- ❌ **負面/限制**：多一張隔離表與一段評估程式；批次與串流的執行引擎不同，需確保兩邊對同一條規則的語意一致；排程稽核、對帳與告警留 Slice 4，2b 期間若 `trade_rejects` 增長只能靠人工查詢發現。
