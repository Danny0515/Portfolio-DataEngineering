# TODO

> 記錄開發過程中發現、但非當前 Slice 需要立即處理的項目。目的是**最小 context**：正式文件（plan.md / execution-roadmap.md / Spec）只保留當下決策需要的資訊，暫不處理但之後需要重新評估的項目集中在這裡，避免污染主線文件。

## 使用規則（新增項目前必讀）

- 每個項目一個 `##` 標題，簡短描述待辦主題
- 每個項目至少含 `### 背景與原因`、`### 執行內容` 兩個子區塊，各區塊內容精簡在 300 字以內，只留下之後回頭看得懂的最少資訊
- 項目完成或不再需要時，**直接刪除整個區塊**，不標記完成、不保留歷史（歷史交給 git log 追溯）
- 新增前先判斷：這是「現在不用做，但之後某個時間點需要重新評估」的事嗎？是才放進來，否則不需要記錄
- 新增或刪除項目時，需同步更新下方目錄

## 目錄

- [如何驗證 Data Contract schema](#如何驗證-data-contract-schema)
- [開發 Data Contract 轉換成 GX 設定的功能](#開發-data-contract-轉換成-gx-設定的功能)
- [開發讀取 Data Contract 轉換成配置的功能](#開發讀取-data-contract-轉換成配置的功能)
- [把 Pattern 封裝成 Skill](#把-pattern-封裝成-skill)
- [arc42 08_concepts.md 內容通用化](#arc42-08_conceptsmd-內容通用化)
- [Lake Formation／IAM 權限 drift 偵測自動化](#lake-formationiam-權限-drift-偵測自動化)
- [Python 套件跨執行環境部署的選型原則](#python-套件跨執行環境部署的選型原則)
- [generate_trade_data.py 改為交錯執行多筆交易生命週期](#generate_trade_datapy-改為交錯執行多筆交易生命週期)
- [新增整合測試](#新增整合測試)

---

## 如何驗證 Data Contract schema

### 背景與原因
`contracts/market-data.contract.yaml` 宣告 `dataContractSpecification: 0.9.3`，但其中 `quality` 區塊改用 `rule/dimension/field/kwargs` 客製欄位，對應 Great Expectations 語法，並非官方規格原生的 quality schema 寫法。若直接套用官方 `datacontract` CLI 驗證，可能無法通過 schema 檢查，需評估是否改寫成官方格式，或自行開發驗證工具維持目前客製寫法。

### 執行內容
到 slice4 再評估是否要使用官方 CLI 還是自行開發 data contract schema 驗證工具

---

## 開發 Data Contract 轉換成 GX 設定的功能

### 背景與原因
`contracts/market-data.contract.yaml` 的 `quality` 區塊與 `src/quality/rules/silver_stock.yaml` 的 GX 規則內容重複，因為 GX 無法直接讀取 Data Contract 格式來執行品質驗證，目前兩份文件要手動同步維護同樣的規則內容，容易出現不一致。

### 執行內容
留到 Slice4 評估開發「Data Contract → GX Expectation Suite」的轉換工具，讓契約檔案成為唯一事實來源，`src/quality/rules/` 底下的 YAML 改為由轉換工具自動產生，不再手動維護兩份。

---

## 開發讀取 Data Contract 轉換成配置的功能

### 背景與原因
`contracts/*.contract.yaml` 目前各 key 皆手動與程式碼同步：`models.<name>.fields` 對應 Silver/Gold transform 程式的 schema、`models.stock.quality` 對應 GX 規則（見前一項）、`servers`/`models.<name>.physicalName` 目前只是文件描述，沒有程式依此判斷該執行哪個 transformation job。契約尚未成為 SSOT，改一處要記得手動改多處，容易遺漏。

### 執行內容
待 Slice4 評估開發「Data Contract 讀取器」，讓契約成為 SSOT：依 `physicalName`/`servers` 對應到要執行的 transformation job、`fields` 自動產生或比對目標表 schema、`quality` 自動轉換成 GX config（沿用前一項的轉換工具），逐步取代目前手動維護的重複設定。

---

## 把 Pattern 封裝成 Skill

### 背景與原因
`docs/patterns/*.md` 記錄的是可重現的技術棧與實作樣式，目前只是文件，套用時要人工或 Agent 讀文件後手動實作。封裝成 skill 能更精準控制產出格式，也讓 pattern 的演進可被版控追蹤。

### 執行內容
留到整個 plan.md 規劃的所有 Slice/Phase 都完成後再評估是否實踐；除非中途某個 Pattern 需要被大量複現（多個 Slice 重複套用同一樣式），才提前考慮實作對應 skill。

---

## arc42 08_concepts.md 內容通用化

### 背景與原因
`docs/arc42/08_concepts.md` 目前 8.1~8.5 節（含 8.4「目前已實作的具體案例」）都以唯一已實作的 stock（Slice0/1）為例撰寫，尚未驗證這套分層規則能否原樣套用到其他資料域；TOC 的錨點連結也曾寫錯（標題含 `/` 時應產生 `--` 雙連字號而非單一 `-`），已由使用者手動修正。

### 執行內容
待 Slice2（trade 資料域）實作完成、有第二個具體案例可對照後，回頭檢視本文件是否需要從「stock 專屬描述」抽象成真正跨資料域的通用規則；目前保留現有 stock 階段的具體描述，作為後續改寫時的參考起點，不現在動。

---

## Lake Formation／IAM 權限 drift 偵測自動化

### 背景與原因
處理 Slice1 遺留的 `athena_reader_tables["bronze"]` drift 時，發現目前只能靠人工跑 `terraform plan` + `aws lakeformation list-permissions` 交叉比對，才能確認實際授權跟 `.tf` 宣告是否一致；隨 Glue Job／資料域增加（Slice2 起新增 trade），純人工比對會越來越吃力。討論後認為業界作法是 CI 排程 drift 偵測（`terraform plan` on cron）＋ AWS IAM Access Analyzer 的 unused/external access findings，而非手寫維護一份權限矩陣文件；曾考慮新增 `query_lakeformation_permissions` skill 做即時查詢輔助，但屬於 Slice4 DataOps（CI/CD、可觀測性）範疇，不在目前階段實作。

### 執行內容
待 Slice4 規劃 CI/CD 與可觀測性時一併評估：(1) 是否排程化 `terraform plan` drift 偵測、(2) 是否啟用 AWS IAM Access Analyzer 的 unused/external access findings、(3) 是否仍需要一個查詢型 skill（如 `query_lakeformation_permissions`）作為輔助工具，三者一起決定，不個別零散導入。

---

## Python 套件跨執行環境部署的選型原則

### 背景與原因
Slice 2a 交易 generator 原規劃用 `psycopg[binary]` 連 RDS，改部署成 Lambda（VPC 內存取私有 RDS）後，發現本機 macOS 開發環境跟 Lambda 的 Amazon Linux runtime 之間，帶 C extension 的套件需處理跨平台編譯／manylinux wheel 相容性問題，改用純 Python 的 `pg8000` 繞開。這類「開發機跟部署環境不同 runtime」的情境未來可能再遇到，但目前只有這一個案例，該提煉成 `ai/contexts/rules.md` 通用規則、還是留在程式碼註解就好，需要更多案例才能判斷，先不急著定案。

### 執行內容
待專案出現第二個「部署到跟開發機不同執行環境」的案例時，一併評估是否該提煉成 `ai/contexts/rules.md` 的通用規則；決定後視需要用 `add_project_rule` skill 寫入。

---

## generate_trade_data.py 改為交錯執行多筆交易生命週期

### 背景與原因
`src/ingestion/generate_trade_data.py` 的 `generate()` 目前逐筆交易處理：每筆交易完整的生命週期（INSERT → 之後所有 UPDATE/DELETE）依序執行完才開始下一筆，多筆交易之間完全不交錯。真實市場是很多筆交易同時處於不同階段（A 剛下單、B 已成交、C 剛被取消同時發生），目前寫法對「驗證 CDC 抓不抓得到 insert/update/delete」這個核心目的沒有影響，但若之後想用 `--delay-seconds` 做即時展示（邊跑邊看 Kafka 事件流入），畫面會不夠像真實盤面。

### 執行內容
待需要更真實的即時展示效果時，把 `generate()` 的迴圈邏輯改成維護一個「進行中交易」池，每一步隨機挑一筆既有交易往下推進一個狀態（或開一筆新交易），讓多筆交易的操作在時間軸上交錯出現；`generate_trade_lifecycle()` 的純邏輯與 pytest 覆蓋不受影響，只改 `generate()` 呼叫順序。

---

## 新增整合測試

### 背景與原因
目前專案的測試（`tests/quality/`、`tests/ingestion/`）都只是「鏡射 `src/` 目錄結構」的單元/純邏輯測試，沒有真正碰外部系統（資料庫、AWS 等）的整合測試分類與對應慣例。已知的具體缺口之一：`src/ingestion/generate_trade_data.py` 裡真的會寫入資料庫的函式（`execute_operation`／`run_ddl`／`fetch_rows`）目前完全沒有自動化測試覆蓋，只靠手動 `aws lambda invoke` 驗證過一次，不是可重複執行的回歸測試。

### 執行內容
待評估是否要在這個專案引入「整合測試」這個分類與對應慣例（例如用本機 Docker Postgres 起一個真的資料庫來測 `execute_operation` 等函式），決定後可能需要一併定義 `pytest.ini` 的新 marker 或獨立目錄慣例。`generate_trade_data.py` 的 DB 寫入邏輯補測試只是目前唯一已知的具體案例，之後若有更多類似需求（例如碰 S3/Kafka 的邏輯）一併納入這個分類評估，不要為了單一案例就零散決定慣例。
