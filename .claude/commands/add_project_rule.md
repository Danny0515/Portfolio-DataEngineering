---
description: 將討論出的新規則追加到 ai/contexts/rules.md，並同步在 CLAUDE.md 補上對照條目，執行前需先取得使用者確認
---

# 專案規則新增工作流程 (Add Project Rule)

此 skill 用於把使用者與 Claude Code 討論出的「Agent 執行規則」（例如部署方式限制、禁止事項等）以一致的格式寫入：

- [ai/contexts/rules.md](../../ai/contexts/rules.md)（規則本體）
- [CLAUDE.md](../../CLAUDE.md)「專案規則」章節（對照清單，確保每個 session 都會被提醒）

---

## 強制要求：每次執行都必須先告知並確認

**在做任何修改之前**，必須先列出：

- 規則編號（`RULE-00N`，讀取 `ai/contexts/rules.md` 現有最大編號 + 1；若檔案不存在則為 `RULE-001`）
- 規則標題、規則內容、Why、How to apply
- 即將加到 `CLAUDE.md`「專案規則」清單的那一行文字

並**等待使用者明確同意（例如「好」、「確認」、「可以」）後才可執行寫入**。未取得確認前，不得呼叫 Edit/Write 修改這兩份文件。

---

## 執行步驟

### 步驟一：確認 `ai/contexts/rules.md` 現況

執行 `test -f ai/contexts/rules.md`：

- 不存在：視為建立第一條規則（`RULE-001`），需一併補上檔案 header。
- 存在：執行 `grep -n '^## RULE-' ai/contexts/rules.md` 取得現有最大編號，新規則編號為該編號 + 1。

### 步驟二：整理規則內容

從當前對話中萃取：

- **規則本體**：Agent 該做什麼／不該做什麼
- **Why**：動機、依據（例如呼應哪個 spec / ADR / plan.md / execution-roadmap.md 章節）
- **How to apply**：Agent 在什麼情境下該套用這條規則

### 步驟三：呈現摘要並取得確認

依前述「強制要求」列出摘要，等待使用者確認。

### 步驟四：套用修改

1. 使用 Edit 工具於 `ai/contexts/rules.md` **檔尾**新增規則區塊（不重寫既有規則、不變更既有編號）。
2. 使用 Edit 工具於 `CLAUDE.md`「專案規則」清單新增一行；若該章節尚不存在，先建立（置於「環境限制」之後、「文件治理規則」之前）。
3. 修改完成後，簡短總結實際寫入的規則編號與內容。

---

## 安全檢查與驗證

- **未確認不可寫入**：沒有取得使用者明確同意前，絕不呼叫 Edit/Write 修改 `ai/contexts/rules.md` 或 `CLAUDE.md`
- **規則一律累加**：`RULE-00N` 只會遞增新增，不覆寫、不刪除既有編號；如規則需要廢止，另開一則規則註記取代關係，不直接刪除舊規則
- **語言規範**：文件內容遵循 CLAUDE.md 全域語言規則（繁體中文撰寫，技術術語保留英文並附中文解釋）
