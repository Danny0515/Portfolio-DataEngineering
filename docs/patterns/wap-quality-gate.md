# Pattern Card: WAP (Write-Audit-Publish) Quality Gate

| 屬性 | 值 |
| --- | --- |
| **狀態** | ✅ `Accepted`（本專案第一份 Pattern Card） |
| **相關模組** | `src/transform/silver_stock.py`、`src/quality/` |
| **對應決策** | [ADR-0004](../architecture/adr/0004-wap-quality-gate.md) |
| **決策者** | Danny |

## 適用情境 (When to Use)

任何「上游資料不可信、但下游不能容忍壞資料流入」的批次寫入場景，都適用這個樣式，而不是直接寫入正式表：

- 資料來源可能含 null、負值、重複鍵、不在白名單內的枚舉值等品質問題
- 下游（Gold、Serving、外部 consumer）一旦讀到壞資料就難以事後補救或難以追責
- 使用的儲存層支援「暫存分支 + 事後合併」語意（本專案是 Iceberg branch + `fast_forward`；不支援時可降級為手動 staging table，見 [docs/specs/slice1-quality-contract.md](../specs/slice1-quality-contract.md) §3.2）

**不適用**的情境：資料本身已經過上游系統驗證保證乾淨（例如內部服務間的強型別 API）、或延遲要求極低到無法負擔「先寫暫存再稽核」這一趟額外的讀寫（真正即時的串流路徑，見 Slice 2/3 的品質策略留待另外設計）。

## 核心機制 (Write → Audit → Publish)

```
Bronze/來源
   │
   ▼
[Write]   整批 overwrite() 寫入暫存分支（Iceberg staging branch）
          main 完全不受影響，即使這次寫入內容有問題
   │
   ▼
[Audit]   讀回暫存分支的資料，跑品質規則引擎（本專案用 Great Expectations）
          產出 pass/fail + 明細，並寫一筆稽核紀錄（不論通過或失敗）
   │
   ├─ 通過 ──▶ [Publish] fast_forward(main, staging)：把 main 指標推進到
   │                     staging 目前 snapshot，正式資料就緒
   │
   └─ 失敗 ──▶ [擋下] main 指標完全不動；印出/記錄違規明細供追查
```

### 關鍵設計決策（對照 `silver_stock.py` 行號）

1. **暫存分支用 `overwrite()` 整批覆寫，不是 `append()`**（[silver_stock.py:139](../../src/transform/silver_stock.py#L139)）：每次執行都讓 staging 線性往前推進，這樣 main 全程是 staging 每個新 snapshot 的祖先，`fast_forward`（而非 `cherry-pick`）才能成立。若改成累加式寫入，這個樣式就要換一種 Publish 語意。

2. **`CREATE BRANCH IF NOT EXISTS` 天生冪等**（[silver_stock.py:138](../../src/transform/silver_stock.py#L138)）：重跑不會重置 staging 的 HEAD，即使前一輪 Audit 失敗、staging 留在「壞資料」狀態，下一輪執行只是把 staging 覆寫成這輪的新內容，不需要額外的清理步驟。

3. **Audit 用讀回來的資料驗證，不是驗證記憶體中尚未落地的 DataFrame**（[silver_stock.py:146](../../src/transform/silver_stock.py#L146)）：確保驗證的是「真的寫進儲存層的東西」，避免 Spark 惰性求值或寫入過程中的型別轉換造成驗證結果與實際落地資料不一致。

4. **稽核紀錄不論成功失敗都寫一筆**（[write_audit_log(), silver_stock.py:75-92](../../src/transform/silver_stock.py#L75-L92)）：`batch_id` 用 staging 當輪的 snapshot_id 當識別碼，`violations` 存 JSON 明細。這讓「哪個批次被擋下、為什麼」永遠可查，不會因為擋下就沒有留下痕跡。

5. **沒有逐列靜默丟棄的手寫過濾**（見 [silver_stock.py:108-112](../../src/transform/silver_stock.py#L108-L112) 註解）：型別轉換失敗（如不合法日期格式）故意讓值變成 `null`，交給 Audit 統一攔下整批，而不是在 cast 階段就悄悄濾掉個別壞列——後者會讓壞資料「消失」而非「被擋下」，稽核紀錄也就抓不到。

6. **Bootstrap（表尚不存在）是死路徑，繞過整個 WAP 流程**（[silver_stock.py:176-182](../../src/transform/silver_stock.py#L176-L182)）：第一次建表時沒有 main 可保護、也沒有表可以 `CREATE BRANCH`，直接建表。套用這個樣式到新表時，必須同樣先處理「表不存在」的初始化分支，不能假設 WAP 三階段從第一次執行就適用。

## 如何在未來 Slice/其他表重用此樣式

新增一張需要品質關卡的表時，依序检查：

1. **定義品質規則**：比照 [src/quality/rules/silver_stock.yaml](../../src/quality/rules/silver_stock.yaml) 的宣告式 YAML 格式，依 plan.md §3 品質六維度分類規則，而不是把規則硬寫進 Python
2. **確認儲存層支援暫存分支**：Iceberg branch 是本專案的預設選擇；若換成不支援 branch 的儲存格式，降級為手動 staging table（見 ADR-0004「理由」段落的取捨）
3. **複製 Write→Audit→Publish 三段式骨架**：`silver_stock.py` 第 129-182 行是可直接參考的骨架，重點是保持「每輪整批覆寫暫存分支」與「Audit 讀回落地資料」這兩個設計決策，不要為了圖方便改成增量寫入或驗證記憶體中的 DataFrame
4. **稽核紀錄表跟著複製**：`write_audit_log()` 與 `get_staging_snapshot_id()` 兩個 helper 是通用邏輯，不含表特定內容，可直接搬到新的 transform script
5. **跑一輪端到端驗證**：比照 [docs/runbooks/slice1-verification.md](../runbooks/slice1-verification.md) 的模式，分別跑一次全乾淨資料與含髒資料，確認 Gate 行為符合預期，不能只看 Job 回報 `SUCCEEDED` 就假設邏輯正確

## 相關文件

- [docs/specs/slice1-quality-contract.md](../specs/slice1-quality-contract.md) — 本樣式第一次落地的 Spec，§3.1/§3.2 記錄了工具與暫存機制的選型過程
- [docs/architecture/adr/0004-wap-quality-gate.md](../architecture/adr/0004-wap-quality-gate.md) — 為何用 WAP 而非事後檢核
- [contracts/market-data.contract.yaml](../../contracts/market-data.contract.yaml) — 本樣式保護的第一份 Data Contract
- [docs/runbooks/slice1-verification.md](../runbooks/slice1-verification.md) — 端到端驗證證據（全乾淨資料 + 含髒資料各一輪）
- [docs/runbooks/slice1-wap-verification.md](../runbooks/slice1-wap-verification.md)、[slice1-gx-audit-verification.md](../runbooks/slice1-gx-audit-verification.md)、[slice1-publish-verification.md](../runbooks/slice1-publish-verification.md) — Write/Audit/Publish 三階段各自的正式環境驗證細節
- [docs/decision-log.md](../decision-log.md) — GX vs Soda Core、Iceberg branch vs 手動 staging table 的取捨記錄
