# 輸出格式規範與準確性規則

本文件定義 `explain-infra` skill 模式一（單檔／全環境轉譯）的輸出模板與硬性約束。**產出前必須先讀完這份文件。**

---

## 一、整份文件的骨架

```markdown
# <env> 環境白話說明（Terraform 轉譯）

> 由 `explain-infra` skill 從同目錄 `.tf` 自動轉譯，讓不熟 SRE 的 Data Engineer 不用讀 HCL 也能確認基礎設施跟預期一致。**內容一律以 `.tf` 原始碼為準，不編造程式碼中未出現的設定**，每列附檔名行號供回查。
>
> 這是「原始碼意圖」的轉譯，不是部署現況——實際 resource ID／endpoint／密碼等 apply 後才產生的值，見 [ai/contexts/infra_<env>.md](../../../ai/contexts/infra_<env>.md)。

**最後轉譯**：YYYY-MM-DD
**來源**：`infra/environments/<env>/*.tf`（N 個檔案）

## 這個環境在做什麼

<3–5 句白話。說明這組資源「合起來」提供什麼能力，用資料流的語言描述，不要逐檔複述。>

## 目錄

- [檔案總覽與相依關係](#檔案總覽與相依關係)
- [`<file1>` — <說明>](#<file1的錨點id>)
- [`<file2>` — <說明>](#<file2的錨點id>)
- ...（依序列出所有 .tf 的 H2 章節，含 meta 檔案）

## 檔案總覽與相依關係

| 檔案 | 一句話職責 | 依賴 | 被誰依賴 |
| --- | --- | --- | --- |
| `vpc.tf` | 網路地基：私有網段、路由、防火牆、對外通道 | — | `rds.tf`、`lambda.tf`、`msk.tf` |
| `msk.tf` | Kafka 叢集本體 | `vpc.tf`（子網、SG） | — |

<接著每個 .tf 一個 H2 章節，順序依相依關係由底層排到上層（網路 → 資料源 → 運算 → 輸出）>
```

「檔案總覽與相依關係」表是**單檔視角看不到的資訊**，也是選擇「一個環境一份文件」而非「一個 tf 一份文件」的主要理由——不可省略。

### 目錄（TOC）與錨點規則

**不要手動推算 GitHub 的 slug 演算法**——本專案標題慣用 `` `<filename>` — <說明> `` 這種「backtick + 被空格包夾的 em dash」組合，正是最容易推算錯連字號數量的樣式（曾在 `docs/arc42/08_concepts.md` 因此斷過連結，見 memory `feedback-markdown-anchor-links`）。

改用**明確、由檔名決定**的錨點 id，完全繞開這個問題：

```markdown
<a id="msk-tf"></a>
## `msk.tf` — Kafka 叢集
```

- 錨點 id 規則：把檔名的 `.` 換成 `-`，底線不變。例：`vpc.tf` → `vpc-tf`、`schema_registry.tf` → `schema_registry-tf`、`outputs.tf` → `outputs-tf`
- 每一個 per-`.tf` 的 H2 標題前都要加這個 `<a id="...">` 標籤（服務檔、meta 檔都要加，因為它們的標題都是同一種有風險標點的樣式）
- 「這個環境在做什麼」「檔案總覽與相依關係」這兩個標題是純中文、沒有 backtick／em dash，維持一般的自動 slug 即可，不用加錨點
- **目錄只列到 `.tf` 層級**，不深入列每個檔案內的主題子標題（`### 1. ...` 那些），避免目錄本身太長
- **何時要同步目錄**：只有在 `.tf` 檔案有新增或刪除時才需要跟著改目錄清單；單檔模式若只是改某個既有檔案的內容（標題文字不變），目錄不用動

---

## 二、每個 `.tf` 的章節模板

**先分兩類**：

- **服務檔**（`vpc.tf`／`rds.tf`／`lambda.tf`／`msk.tf`／`schema_registry.tf`，即實際部署的 AWS 服務）→ 用下方「服務檔模板」，主要內容是主題式白話敘述
- **meta 檔**（`versions.tf`／`provider.tf`／`variables.tf`／`outputs.tf`，即版本鎖定／provider／變數／output 這類非服務性質的設定檔）→ 維持簡化格式，不切主題（見「meta 檔模板」）。這幾個檔案沒有「規模」「資安」這種可以講的服務屬性，硬套主題只會湊出空話

### 服務檔模板

閱讀順序是**先讀懂、再查表**：主要內容是固定主題的白話敘述，表格降級為「讀完之後回頭核對出處」的索引，不是主要內容。

```markdown
<a id="msk-tf"></a>
## `msk.tf` — Kafka 叢集

**總結**：開一組 2 台機器的 Kafka，只收 TLS 加密連線，關在私有子網裡，靠防火牆而不是帳密來擋人。

### 1. 叢集規模與硬體規格

- **Kafka 版本**：Apache Kafka 3.9.x（AWS 官方目前標示的 Recommended 版本，尚無 end-of-support 日期）
- **Broker 數量與規格**：共 2 個 broker 節點，採用低成本的 `kafka.t3.small` 規格
- **儲存空間**：每個 broker 配置 20GB 的 EBS gp3 空間
- **網路部署**：跨 2 個私有子網（`ap-northeast-1a`／`1c`），具備基礎的單區故障容錯能力

### 2. 資安與存取控制

- **傳輸加密**：對外只開放 TLS 加密埠（9094），未加密的 PLAINTEXT 埠（9092）沒開；叢集內部 broker 間傳輸也強制加密
- **身分驗證**：`unauthenticated`，不採用 SASL 或 IAM 簽章機制
- **存取防護**：完全依賴 Security Group（`slice2_internal`）在網路層過濾，跟 `rds.tf` 保護 RDS 的哲學一致

### 3. Kafka 行為與 Topic 邏輯設定

- **自動建立 Topic**：`auto.create.topics.enable=true`，producer（未來的 Debezium）第一次寫入時自動建立，不需要額外手動建立
- **副本容錯機制**：自動建立的 topic 預設副本數 2（對應 2 台 broker 各一份）；最低同步副本數設為 1，demo 用途刻意寬鬆，一台 broker 掛掉仍可寫入，正式環境不該這樣設

**對照表（原始碼出處）**

| 主題 | 項目 | 資源 | 出處 |
| --- | --- | --- | --- |
| 規模與硬體規格 | Kafka 版本 | `local.msk_kafka_version` | [msk.tf:13-19](msk.tf#L13-L19) |
| 規模與硬體規格 | Broker 規格、儲存空間、網路部署 | `aws_msk_cluster.trade` | [msk.tf:36-51](msk.tf#L36-L51) |
| 資安與存取控制 | 身分驗證 | `client_authentication` | [msk.tf:53-55](msk.tf#L53-L55) |
| 資安與存取控制 | 傳輸加密 | `encryption_info` | [msk.tf:59-64](msk.tf#L59-L64) |
| Kafka 行為與 Topic 邏輯設定 | 自動建立 Topic、副本容錯機制 | `aws_msk_configuration.trade` | [msk.tf:21-34](msk.tf#L21-L34) |

**對 Data Engineer 的意義**

| 你會問 | 答案 |
| --- | --- |
| producer／consumer 要連哪裡、哪個 port？ | 9094（TLS）。bootstrap 位址部署後才決定，見 infra 快照 |
| 要先建 topic 嗎？ | 不用，broker 開了 `auto.create.topics.enable=true` |

**⚠️ 注意 / 限制**

- Topic（`transaction.trade.v1` / `.dlq`）刻意不在 Terraform 管理，延後到部署 Debezium connector 時自然建立
```

（`min.insync.replicas=1` 的寬鬆設定直接寫進第 3 個主題的 bullet 裡，沒有另外進「⚠️」——能掛在某個項目上的注意事項優先掛上去；只有「topic 不給 Terraform 管」這種跨主題的決策才留在「⚠️」，見下方 Block 說明。）

#### Block 拆解

**總結**：跟舊版一樣，一句話講完這個檔案做了什麼，不要出現 HCL 欄位名。

**`### N. 主題`（主要內容）**：每個主題底下是 bullet list，格式固定 `- **<欄位標籤>**：<白話說明>（<實際數值/理由>）`。標籤跟說明都要是人話，不要複述 resource type 或 argument 名稱本身。每個服務固定用哪幾個主題見下方「固定主題對照表」——**不要每次轉譯都臨場現想主題名稱**，同一個檔案重跑要用同一套標題，這是「互相比對」的前提。

**對照表（原始碼出處）**：欄位是「主題 / 項目 / 資源 / 出處」。「項目」的文字**必須**跟上面對應主題裡某個 bullet 的粗體標籤一致（或明顯對得起來），這樣讀者讀到一個詞，才能直接在表格裡搜同一個詞找到行號。這張表**不重複**白話說明，只負責「這件事在哪裡設定的」。

**對 Data Engineer 的意義**（條件式）：跟舊版一樣保留，回答「我要接這個東西，需要知道什麼」（連線資訊、要不要先建 topic/table、限制的實際意涵）。這塊回答的問題跟上面「這裡設定了什麼」不同，兩者都留，不是重複資訊。沒有可操作資訊的檔案就整塊省略。

**⚠️ 注意 / 限制**（條件式，降頻使用）：多數風險/取捨現在應該直接寫進對應主題的 bullet 裡（跟設定值放在一起講，例如「demo 用途刻意寬鬆」）。只有**無法歸到單一項目**的整體性風險或決策（例如「這個資源刻意不由 Terraform 管理」這種跨主題的安排）才留在這個獨立區塊。沒有這種內容就整塊省略。

### 固定主題對照表（每個服務檔用哪幾個主題）

| 檔案 | 固定主題（依序） |
| --- | --- |
| `vpc.tf` | 1. 網路範圍與子網配置　2. 對外連線能力（路由與 VPC Endpoint）　3. 內部防火牆規則（Security Group） |
| `rds.tf` | 1. 規格與儲存　2. CDC／複寫設定　3. 安全與存取控制　4. 生命週期策略（用完即拆） |
| `lambda.tf` | 1. 執行環境規格　2. 網路與身分權限　3. 部署流程與資料流 |
| `msk.tf` | 1. 叢集規模與硬體規格　2. 資安與存取控制　3. Kafka 行為與 Topic 邏輯設定 |
| `schema_registry.tf` | 1. Schema 格式與欄位定義　2. 相容性策略與治理規則 |
| `msk_connect_plugin.tf` | 1. 打包來源與內容　2. 儲存與 MSK Connect 註冊　3. 範圍界線與生命週期 |
| `msk_connector.tf` | 1. 合併版 Plugin 打包　2. IAM 執行角色與權限　3. Connector 容量與叢集連線　4. Debezium 擷取設定與資料流 |
| `msk_event_verifier.tf` | 1. 打包與部署　2. IAM 唯讀權限　3. Consumer 邏輯與重用設計 |

主題數量**允許依服務不同**（2–4 個），不強迫每個服務都湊滿一樣的格數——`schema_registry.tf` 沒有「硬體規格」可講，硬湊會變成空話。每個服務的主題清單一旦定案就固定，同一個檔案每次重新轉譯，區塊標題不應該變來變去。

**新增服務時**（未來 Slice 加了不屬於這 5 種已知類型的 `.tf`）：比照最接近的既有服務挑 2–3 個主題，並把新主題加進這張表，讓下次轉譯有依據可循，不要每次都重新發明。

### meta 檔模板

`versions.tf`／`provider.tf`／`variables.tf`／`outputs.tf` 維持簡化格式，**不切主題**：

```markdown
<a id="outputs-tf"></a>
## `outputs.tf` — 部署後才知道的值

**總結**：把 13 個「寫程式碼時還不知道、apply 之後才產生」的值吐出來，供驗證與後續 slice 接手使用。

| 資源 | 白話說明 | 關鍵設定 | 出處 |
| --- | --- | --- | --- |
| 網路類（6 個） | `vpc_id`、`private_subnet_ids`... | 全部是部署後才配發的 AWS 資源 ID | [outputs.tf:1-23](outputs.tf#L1-L23) |

**對 Data Engineer 的意義**（條件式）
**⚠️ 注意 / 限制**（條件式）
```

即沿用舊版的「資源表」格式：資源／白話說明／關鍵設定／出處四欄，因為這幾個檔案本來就短，逐條列表已經是最短路徑，不需要額外的敘述層。

---

## 三、準確性規則（硬性約束）

一份會腦補的翻譯比沒有翻譯更糟。以下規則沒有例外：

### 1. 不編造

只翻譯 `.tf` 裡**真實存在**的設定。不可因為「AWS 這個欄位預設值是 X」就把 X 寫進去。確有必要提及預設行為時，必須明確標註「未設定，採 AWS 預設 X」。

### 2. computed 值標記為「部署後才決定」

以下值在 `.tf` 裡根本不存在，是 `apply` 後才產生的。一律**不填猜測值**，寫「部署後才決定」並指向 `ai/contexts/infra_<env>.md`：

- `random_password` 產生的密碼
- endpoint／bootstrap broker 字串（RDS endpoint、MSK bootstrap servers）
- 各種 ARN 與資源 ID（VPC ID、Subnet ID、Security Group ID、VPC Endpoint ID）
- `data.archive_file` 的 hash

### 3. 跨檔引用必須實際解析

`local.*`、`var.*`、`aws_subnet.private`、`[for s in ... : s.id]` 一律讀原始檔取真值。

- ✅ 「跨 `ap-northeast-1a`／`1c` 兩個機房」
- ❌ 「使用 `vpc.tf` 定義的私有子網」（等於沒翻譯，使用者還是得自己去翻檔案）

### 4. 保留註解裡的「為什麼」

本專案 `.tf` 註解密度高（30–40%）且多為決策理由，是最高價值的輸入。註解說明了取捨、踩過的坑、或延後處理的項目時，必須翻進白話——服務檔優先直接掛進對應主題的 bullet（跟設定值寫在一起），無法歸到單一項目的才落在「⚠️ 注意/限制」；meta 檔則跟舊版一樣落在 Block 3/4。不可丟棄。

### 5. 每列可回查

服務檔的「對照表」、meta 檔的「資源表」，每一列都要有 `檔名#Lx-Ly` 連結。使用者要能一秒跳回原始碼驗證。

### 6. 不複製 HCL 語法

敘述與表格內都是人話。不要貼 heredoc 原文、不要貼 `jsonencode({...})`、不要貼 `for` 運算式。Avro schema 這類結構化內容，用文字描述欄位數與關鍵型別，需要細節時讓使用者點行號連結回去看。

### 7. 表格保護（CLAUDE.md 全域規則）

更新既有章節時，不得為了視覺對齊增減 `|` 或 `-` 的數量，不得重排未變動的內容。

### 8. 章節就地置換

單檔模式只能改該檔的章節（含它底下所有 `### N. 主題` 子區塊）、總覽表對應列、與檔頭日期；檔案有增減才需要同步目錄清單。**其他章節必須逐字不動**——用 `git diff` 應該只看得到預期的變動。

---

## 四、語言

依 CLAUDE.md 全域規則：

- 正文一律繁體中文
- 技術術語保留英文並在必要時附中文解釋，例如「Gateway Endpoint（走 AWS 內網的免費通道）」
- 資源位址、檔案路徑、CLI 指令、設定值保留英文，用 backtick 包起來
- 標題用「中文 — 英文名詞」形式，例如 <code>## \`msk.tf\` — Kafka 叢集</code>
