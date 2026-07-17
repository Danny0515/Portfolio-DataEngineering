# CLAUDE.md — Repository Guidance

## 文件治理規則 (Document Governance)

本專案的頂層規劃文件為 [plan.md](plan.md)（藍圖/北極星）與 [execution-roadmap.md](execution-roadmap.md)（執行路線/Slice 順序）。兩者的維護契約定義在 execution-roadmap.md §5：

> `plan.md` 維持低頻不動；進度反映在 ADR 目錄與 Decision Log 的累積，而非改藍圖。

### 如何使用這兩份文件（地圖 vs 決策細節）

`plan.md` 與 `execution-roadmap.md` 的定位是**全貌地圖**：實作進行到細節、忘記最初動機或架構全貌時，應該直接回來查這兩份文件，而不是翻遍 `docs/architecture/adr/*` 才拼得出需求全貌。分工原則：

- **plan.md / execution-roadmap.md**：回答「整體是什麼、順序怎麼走」——全貌參考，凍結後極少變動。
- **ADR / Decision Log**：回答「為什麼選這個」——單一決策的局部理由，高頻新增。

兩份文件文末都有 **Changelog** 區塊，只記錄「實質修訂」（範圍/架構真的改變），不記錄規劃期例行討論或每次 ADR。需要追溯「這份地圖何時、為何變成現在這樣」時查 Changelog；平常閱讀全貌不需要看它。

### 現階段例外：規劃設計期 (Planning Phase)

目前專案**仍處於規劃設計階段**（尚未開始 Slice 0 實作）。在此階段：

- `plan.md` 與 `execution-roadmap.md` **允許且預期會**隨使用者與 Claude Code 的討論同步修改——這是規劃期把想法收斂進文件的正常流程。
- 情境：使用者與 Claude Code 討論架構、Slice 拆分、技術選型等議題後，討論結論需要**回寫**至這兩份文件。

### 進入實作階段後

一旦開發者開始實作第一個 Slice（Slice 0 動工），`plan.md` 與 `execution-roadmap.md` **不再隨 Slice 進度調整而改動**。此後：

- 進度與決策透過 `docs/architecture/adr/*`（ADR）與 Decision Log 累積呈現，而非回頭改這兩份頂層文件。
- 若範圍真的需要變動（極少數情況），僅允許直接更新既有文件，**禁止**產生 `plan-v2.md` / `roadmap-new.md` 之類的分岔文件（見 execution-roadmap.md §5）。
- 對這兩份文件的修改視為高風險操作，需要使用者明確確認才能進行（見 `planning_project` skill）。
- 每次透過 `planning_project` skill 實際寫入變更後，需在對應文件的 Changelog 區塊補一行紀錄（日期／修改章節／原因），確保「地圖」的修訂軌跡可回溯。
