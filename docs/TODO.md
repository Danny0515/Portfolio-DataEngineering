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
