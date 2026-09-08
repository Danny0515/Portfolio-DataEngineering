---
name: explain-infra
description: 把 Terraform .tf 轉譯成 Data Engineer 看得懂的白話 markdown（表格為主），寫入 infra/environments/<env>/README.md；也支援用自然語言提問掃描 infra/，例如「dev 環境中有關 MSK 的所有服務」。
when_to_use: 使用者寫完或改完 .tf 想確認內容跟預期一致、問某個 .tf 在做什麼、或問某個環境有哪些某類服務時。
allowed-tools: Read Grep Glob
argument-hint: [tf檔路徑 | 環境目錄 | 自然語言問題]
---

# Terraform 白話轉譯 (Explain Infra)

把 `.tf` 的內容轉譯成「不熟 SRE 的 Data Engineer 也看得懂」的統一白話格式，輸出到該環境目錄下的 `README.md`。

## 為什麼要有這個 skill

本專案的使用者是 Data Engineer（熟 Kafka／Glue 等數據領域架構），不是專業 SRE。過去每寫完一個 `.tf`，都要跟 AI 來回問很多輪才能確認「這段 HCL 跟我預期的一致嗎」，成本高且每次得到的格式都不一樣。

同時，`.tf` 裡的繁體中文註解密度很高（30–40%），把「為什麼這樣設定」寫得很清楚，但這些高價值 context 散在程式碼裡，沒有被整理成可快速掃視的形式。

這個 skill 把那段來回問答收斂成一個指令，並固定輸出格式，讓每次轉譯的結果可以互相比對。

## 職責邊界：這份文件不是「部署現況」

| 文件 | 回答什麼 | 資料來源 | 誰維護 |
| --- | --- | --- | --- |
| `infra/environments/<env>/README.md`（本 skill） | 程式碼宣告了什麼、為什麼 | `.tf` 原始碼 | 本 skill |
| [ai/contexts/infra_<env>.md](../../../ai/contexts/) | 現在實際跑著什麼 | `terraform output`／`state list` | [check-infra-snapshot.sh](../../hooks/check-infra-snapshot.sh) hook |

**本 skill 絕對不修改 `ai/contexts/infra_<env>.md`**，只在產出中交叉連結它。

## 零雲端依賴

**全程不執行任何 `terraform` 指令、不呼叫任何 AWS API、不需要 MFA session。** 只讀本機 `.tf` 檔。

- 「程式碼宣告了什麼」不需要連線就能回答；`terraform plan` 回答的是另一個問題（程式碼與現實的差異）
- 純本機讀取可離線跑、第一次 `apply` 之前就能跑、不會因 MFA 過期或 state lock 失敗
- 完全繞開 RULE-001／RULE-002 的憑證流程，不需要任何 AWS 權限

代價是有些值 `.tf` 裡根本不存在（apply 後才產生的 computed 值）——處理方式見 [references/output-format.md](references/output-format.md) 的準確性規則。

---

## 模式派發

依傳入參數的形態自動判斷，不需要使用者指定模式：

| 參數形態 | 模式 | 行為 |
| --- | --- | --- |
| 存在的 `.tf` 檔路徑 | 單檔轉譯 | 只重寫該檔對應的 H2 章節 |
| 存在的目錄路徑 | 全環境轉譯 | 產生／重建整份 `README.md` |
| 其他文字 | 提問掃描 | 掃描後只回在對話，**不寫檔** |
| 無參數 | — | 用 AskUserQuestion 問要哪一種 |

判斷方式：先用 `test -f`／`test -d` 檢查參數是否為存在的路徑，都不是才視為自然語言問題。

---

## 模式一：單檔／全環境轉譯

### 步驟一：載入輸出規範

讀取 [references/output-format.md](references/output-format.md)，取得完整的輸出模板與準確性規則。**這一步不可略過**——模板與準確性規則都在那份文件裡，憑印象產出會格式不一致。

### 步驟二：讀取目標 `.tf`

讀取全文，**包含所有註解**。註解是「為什麼這樣設定」的主要來源，是本 skill 最高價值的輸入，不可只看 resource 區塊。

全環境模式時，讀取該目錄下所有 `.tf`。每個檔案都各自成一個 H2 章節並列在「檔案總覽」表中——`provider.tf` 這類短檔案不併入其他章節、不省略，只是套用較簡化的 meta 檔模板（見步驟四）。

### 步驟三：解析跨檔引用

遇到以下形式時，**必須實際讀被引用的檔案解析出真值**，不可推測、不可寫「參照 xxx.tf」：

- 資源引用：`aws_subnet.private`、`aws_security_group.slice2_internal.id`
- `local.*`：例如 `local.msk_kafka_version` → 讀 `locals` 區塊取得 `"3.9.x"`
- `var.*`：讀 `variables.tf` 的 `default`；若有 `terraform.tfvars` 也要讀（tfvars 覆蓋 default）
- comprehension：`[for s in aws_subnet.private : s.id]` → 解析出實際有幾個子網、哪幾個 AZ

### 步驟四：寫入

判斷檔案屬於哪一類，決定要不要切主題：

- **服務檔**（`vpc.tf`／`rds.tf`／`lambda.tf`／`msk.tf`／`schema_registry.tf`）→ 用 `references/output-format.md` 的「服務檔模板」，主要內容是固定主題的白話敘述（`### N. 主題`），表格降級為查表用的「對照表」
- **meta 檔**（`versions.tf`／`provider.tf`／`variables.tf`／`outputs.tf`）→ 用「meta 檔模板」，維持簡化的一句話＋資源表，不切主題
- 每個服務檔要用哪幾個固定主題，直接查 `references/output-format.md` 的「固定主題對照表」，**不要臨場現想**——同一個檔案每次重新轉譯，主題標題不應該變來變去

每個 per-`.tf` 的 H2 標題前都要加 `<a id="...">` 錨點（id 規則：檔名的 `.` 換成 `-`，例 `msk.tf` → `msk-tf`），詳見 `references/output-format.md`「目錄與錨點規則」——不要自己手推 GitHub 的 slug 演算法，本專案的標題樣式已知會推算錯連字號數量。

檢查目標環境目錄下的 `README.md`：

- **不存在** → 產生完整文件，含 `## 目錄` 區塊（列出「檔案總覽與相依關係」+ 每個 `.tf` 的 H2 章節連結）與所有 `.tf` 的章節
- **存在，且為單檔模式** → 用 Edit **只置換該檔的 H2 章節**
  - 章節邊界：從 <code>## \`&lt;filename&gt;\`</code>（含前面的 `<a id="...">` 那一行）起，到下一個 `## ` 開頭的行為止（不含）；章節內的所有 `### N. 主題` 子區塊都跟著這次置換一起換掉
  - 同步更新「檔案總覽與相依關係」表中該檔那一列
  - 同步更新檔頭的「最後轉譯」日期
  - **目錄只在檔案有增減時才需要同步**；只是重新轉譯既有檔案（標題文字不變）不用動目錄
  - **其他章節與目錄必須逐字不動**——這是本設計的重點，改一個 `.tf` 不該污染整份文件的 diff
- **存在，且為全環境模式** → 重建整份文件（含目錄）

若 `.tf` 檔有新增或刪除，同步「檔案總覽與相依關係」表的列，並同步「## 目錄」的清單。

---

## 模式二：提問掃描

### 步驟一：問題不夠具體就先追問

使用者要求此行為。判斷標準：問題若沒有指明「想知道什麼面向」，就先追問。

- ❌ 太模糊：「MSK」、「網路」、「dev 環境」
- ✅ 夠具體：「dev 環境中有關 MSK 的所有服務」、「RDS 是怎麼被保護的」、「Lambda 怎麼連到 RDS」

追問時提供具體選項（例如：想知道設定細節？網路可達性？還是連線方式？），不要只丟一句「請說清楚一點」。

### 步驟二：決定掃描範圍

預設掃 `infra/`。若 `infra/` 不存在，用 AskUserQuestion 提供兩個選項：

1. 請使用者提供要掃描的目錄
2. 掃描整個專案

### 步驟三：掃描與回答

1. Grep 相關的 resource type 與關鍵字（例如問 MSK → `aws_msk`、`9094`、`kafka`、`bootstrap`）
2. Read 命中的檔案，並依模式一步驟三的規則解析跨檔引用
3. 以**表格**回在對話中，每列附 `檔名:行號`
4. 涵蓋範圍要跨檔完整：問「MSK 相關的所有服務」時，除了 `msk.tf` 本身，也要包含 `vpc.tf` 裡放行 9094 的 Security Group 規則、`outputs.tf` 裡的相關 output

### 步驟四：不寫檔

**模式二不產生任何檔案。** 臨時提問是一次性的，寫成檔案只會在 repo 累積問答垃圾檔。若使用者看完後明確要求存檔，才另外討論放哪裡。

---

## 安全檢查

- **純讀取工具**：只讀 `.tf` 與既有 `README.md`，不修改任何 AWS 資源，不需要額外確認門檻
- **不執行 terraform／aws 指令**：如果覺得「需要 `terraform plan` 才能確定」，那代表該值是 computed 值，應標記為「部署後才決定」，而不是去跑指令
- **寫入範圍限定**：只寫 `infra/environments/<env>/README.md`。不碰 `ai/contexts/infra_<env>.md`（屬 `check-infra-snapshot.sh` 職責）、不碰 `plan.md`／`execution-roadmap.md`（屬 `planning_project`）、不碰 ADR（屬 `add_adr`）
- **不編造**：準確性規則見 [references/output-format.md](references/output-format.md)。一份會腦補的翻譯比沒有翻譯更糟——本 skill 的存在意義就是讓使用者能信任這份文件而不用回頭讀 HCL
- **語言規範**：依 CLAUDE.md 全域規則，產出一律繁體中文，技術術語／資源位址／檔案路徑保留英文
