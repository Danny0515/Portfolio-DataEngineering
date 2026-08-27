---
description: 將討論出的架構決策以 ADR 格式寫入 docs/architecture/adr/，並同步更新 docs/arc42/09_architecture_decisions.md 決策總表，執行前需先呈現草稿供使用者確認
---

# 新增架構決策紀錄工作流程 (Add ADR)

此 skill 用於把使用者與 Claude Code 討論出的「架構/技術決策」（例如為何選某個工具、為何採用某種分層方式）以 ADR (Architecture Decision Record) 格式寫入：

- `docs/architecture/adr/000N-<slug>.md`（決策本體，一個決策一個檔案）
- `docs/arc42/09_architecture_decisions.md`（決策摘要總表，連結回上述本體檔案）

依 [plan.md §6.1](../../plan.md) 的文件架構設計：ADR 回答「為什麼選這個」，屬於**單一決策的局部理由，高頻新增**，跟 `plan.md`/`execution-roadmap.md`（低頻不動的地圖）分屬不同治理層級——因此本 skill 的確認步驟採**輕量單次確認**，不做逐段審核。

---

## 執行步驟

### 步驟一：確認目錄與現有編號

1. 執行 `test -d docs/architecture/adr`：
   - 不存在：視為第一則 ADR（`0001`），待步驟四一併建立目錄。
   - 存在：執行 `ls docs/architecture/adr/ | grep -E '^[0-9]{4}-'` 取得現有最大編號，新 ADR 編號為該編號 + 1（4 位數，補零，如 `0002`）。
2. 執行 `test -f docs/arc42/09_architecture_decisions.md`：
   - 不存在：待步驟四一併建立骨架（狀態圖例 + 空的決策總表）。
   - 存在：讀取現有決策總表，確認新增列要插入的位置（依編號遞增排序）。

### 步驟二：整理決策內容

從當前對話中萃取：

- **決策標題**：簡短一句話
- **狀態**：💬 `Proposed`（討論中，尚未拍板）／✅ `Accepted`（已拍板）／❌ `Rejected`／🔄 `Superseded by ADR-XXX`（取代舊決策時，另需回頭把舊 ADR 狀態改為此）
- **相關模組**：對應的 `src/` 目錄或元件名稱，不確定可留 `-`
- **決策者**：對話中的使用者，不確定可留 `-`
- **背景 (Context)**：為什麼需要做這個決策
- **決策 (Decision)**：具體決策內容
- **理由 (Rationale)**：為什麼選這個
- **影響 (Consequences)**：✅ 正面／⚠️ 需注意／❌ 負面或限制，三類至少各寫一點，沒有的類別可省略

若對話中資訊不足以填滿背景/理由/影響任一段落，直接詢問使用者補充，不要自行腦補內容。

### 步驟三：呈現草稿並取得確認

用以下格式呈現完整草稿（即步驟四要寫入的實際內容），詢問使用者「內容無誤，可以寫入嗎？」，取得明確同意（如「好」、「確認」、「可以」）後才進入步驟四：

```
ADR-000N：<決策標題>
檔案：docs/architecture/adr/000N-<slug>.md
狀態：<狀態>

背景：...
決策：...
理由：...
影響：...

同步更新：docs/arc42/09_architecture_decisions.md 決策總表新增一列
```

### 步驟四：套用修改

1. 若 `docs/architecture/adr/` 目錄不存在，先建立。
2. 建立 `docs/architecture/adr/000N-<slug>.md`（`<slug>` 為英文 kebab-case，摘要決策標題，例如 `use-iceberg`），內容格式：

   ```markdown
   # ADR-000N: <決策標題>

   | 屬性 | 值 |
   | --- | --- |
   | **狀態** | <💬/✅/❌/🔄 對應標記> |
   | **日期** | YYYY-MM-DD |
   | **相關模組** | `module_name` |
   | **決策者** | - |

   ## 背景 (Context)
   <內容>

   ## 決策 (Decision)
   <內容>

   ## 理由 (Rationale)
   <內容>

   ## 影響 (Consequences)
   - ✅ **正面**：<內容>
   - ⚠️ **注意**：<內容>
   - ❌ **負面/限制**：<內容>
   ```

3. 若 `docs/arc42/09_architecture_decisions.md` 不存在，先建立骨架：

   ```markdown
   # 9. Architecture Decisions (架構決策)

   此文件彙整本專案的重大架構決策摘要，完整推理過程見各 ADR 文件（[docs/architecture/adr/](../architecture/adr/)）。

   ## 決策狀態表

   | 狀態 | 說明 |
   | --- | --- |
   | 💬 `Proposed` | 正在討論 |
   | ✅ `Accepted` | 已拍板並實施中 |
   | 🔄 `Superseded` | 已被更新的 ADR 取代，需註明新 ADR 代號 |
   | ❌ `Deprecated` | 該決策已移除 |

   ## 決策總表

   | ID | 決策標題 | 狀態 |
   | --- | --- | --- |
   ```

4. 在決策總表新增一列：`| [ADR-000N](../architecture/adr/000N-<slug>.md) | <決策標題> | <狀態標記> |`，依編號遞增插入正確位置。
5. 若本次決策是「取代舊決策」（狀態為 🔄 或使用者說明是 supersede 某個既有 ADR）：回頭把被取代的舊 ADR 檔案狀態列改為 `🔄 \`Superseded by ADR-000N\``，並在決策總表對應列同步更新狀態，**不刪除舊檔內容**。
6. 修改完成後，簡短總結：新增的 ADR 編號、檔案路徑、決策總表的變更（含是否有連動修改舊 ADR 狀態）。

### 步驟五：詢問是否同步 Decision Log

ADR 記的是大架構決策，通常有對應的 spec 章節（`docs/specs/*.md` 的 §3.x）記錄了支撐這個決策的具體技術選型細節。ADR 寫入完成後：

1. 檢查 `docs/decision-log.md` 是否已有列指向本次 ADR 對應的 spec 章節（用 ADR 編號或對應 spec 檔名比對）。
2. 若沒有對應列，主動詢問使用者：「這則 ADR 對應的技術選型，要不要順便補一筆 Decision Log 索引？」
3. 取得使用者同意後，依 `docs/decision-log.md` 開頭定義的格式（日期／決策／隸屬 ADR／詳細理由連結）新增一列並寫入。
4. 若使用者婉拒，或本次 ADR 沒有對應的 spec 章節（例如純粹治理性決策），略過即可，不強迫寫入。

---

## 安全檢查與驗證

- **未確認不可寫入**：沒有取得使用者明確同意前，絕不呼叫 Write/Edit 建立或修改 ADR 檔案、決策總表或 Decision Log
- **編號一律遞增**：`000N` 只會遞增新增，不重複、不覆寫既有編號
- **取代不刪除**：決策被新 ADR 取代時，舊 ADR 檔案標記 `Superseded`，內容保留，不刪除、不覆寫舊決策的背景/理由
- **不觸碰 plan.md / execution-roadmap.md**：這兩份文件的變更屬於 `planning_project` skill 的職責，本 skill 不處理
- **語言規範**：文件內容遵循 CLAUDE.md 全域語言規則（繁體中文撰寫，技術術語保留英文並附中文解釋）
- **表格保護**：修改決策總表或 Decision Log 時只新增/更新列，不因視覺對齊調整既有 `|`／`-` 數量
