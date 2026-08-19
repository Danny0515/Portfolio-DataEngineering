# ADR-0004: 為何用 WAP (Write-Audit-Publish) Pattern 而非事後檢核

| 屬性 | 值 |
| --- | --- |
| **狀態** | ✅ `Accepted` |
| **日期** | 2026-08-19 |
| **相關模組** | `src/transform/silver_stock.py`、`src/quality/` |
| **決策者** | Danny |

## 背景 (Context)

Slice0 證明批次管線水電通了，但沒有任何品質關卡——Bronze→Silver→Gold 一路直通，壞資料（null、負值、重複鍵、非法代號）一旦混入來源就會直接流到 Gold，被下游查到。Slice1 要補上「不合格資料進不了 Gold」這道關卡，關鍵設計問題是：品質檢核要放在資料「已經寫入正式表之後」（事後檢核，寫完再驗、驗不過再想辦法補救/告警）還是「寫入正式表之前」（WAP，先寫暫存、驗證通過才讓正式表看到）？ADR-0001 已把 Iceberg 選為 table format，其中一個理由就是「為 Slice1 WAP Gate 鋪路」——這份 ADR 補上真正拍板「為何用 WAP 而非事後檢核」的完整理由。

## 決策 (Decision)

Bronze→Silver 之間插入 WAP（Write-Audit-Publish）Gate：Silver 每次執行先把資料整批 `overwrite()` 寫入 Iceberg 的 staging branch（Write），讀回 staging 內容跑 Great Expectations 品質規則（Audit），通過才用 `fast_forward` 把 main 指標推進到 staging 當輪 snapshot（Publish）；失敗則 main 完全不動，稽核紀錄寫入 `audit_log` 表。正式 `silver.stock`（下游 Gold 與 Athena 查詢的對象）全程只會看到通過稽核的資料，不採用「先寫入 main、事後跑排程檢查、發現問題再補救或標記」的事後檢核模式。

## 理由 (Rationale)

- 事後檢核的根本問題是「壞資料已經流到下游了」：即使排程檢查跑得再快，Gold 聚合、Athena 查詢在檢查跑完前這段時間窗口都可能已經讀到壞資料，補救只能靠事後修正或重跑，無法「防止」壞資料被看到——這正是 spec §1 開頭講的「Slice1 證明的是管線會自己擋下壞資料，而不是讓壞資料悄悄流到 Gold」
- WAP 把「驗證」放在「發布」之前，天生不會有這個時間窗口：main 指標只有在 Audit 通過後才移動，下游任何時間點查到的 main 都是已驗證過的狀態
- Iceberg 的 branch + fast_forward 機制讓這個 pattern 的實作成本很低，不需要額外的 staging table 與資料搬移（見 ADR-0001「為 Slice1 WAP Gate 鋪路」）；具體 branch vs 手動 staging table 的取捨記錄在 [Decision Log](../../decision-log.md)
- 稽核紀錄（audit_log）不論通過失敗都寫一筆，讓「哪個批次被擋下、觸犯哪條規則」永遠可查，不會因為擋下就沒有留下痕跡——這也是事後檢核模式很難做到的：事後檢核如果選擇「檢查失敗就丟告警」，容易變成只留下告警訊息而沒有結構化、可查詢的稽核軌跡

## 影響 (Consequences)

- ✅ **正面**：下游（Gold、Athena、未來的任何 consumer）永遠只會看到已驗證過的 Silver 資料，品質保證從「靠紀律」變成「靠機制」
- ✅ **正面**：稽核紀錄結構化落地在 Iceberg 表，Athena 直接可查，不需要額外的日誌系統
- ⚠️ **注意**：每次執行多了一趟「寫暫存 + 讀回驗證」，比直接覆寫 main 多消耗一些時間與 I/O（Slice1 端到端驗證實測 Silver Job 執行時間落在 130-145 秒，仍遠低於 10 分鐘 timeout，量體變大後需留意）
- ⚠️ **注意**：WAP 依賴儲存層支援暫存分支語意；若換一個不支援 branch 的儲存格式，需要降級為手動 staging table（見 spec §3.2、Decision Log）
- ❌ **負面/限制**：目前只覆蓋 Bronze→Silver 這一段，Silver→Gold 之間沒有對應的品質關卡（依 spec §3.4 決定，Gold 目前只有 schema 契約，沒有聚合一致性驗證，留給 Slice3）

## 相關文件

- [docs/decision-log.md](../../decision-log.md) — §3.1 GX vs Soda Core、§3.2 Iceberg branch vs 手動 staging table 的技術選型細節
- [docs/patterns/wap-quality-gate.md](../../patterns/wap-quality-gate.md) — 本決策的可複用實作樣式
- [contracts/market-data.contract.yaml](../../../contracts/market-data.contract.yaml) — 本 Gate 保護的第一份 Data Contract
- [docs/runbooks/slice1-verification.md](../../runbooks/slice1-verification.md) — 端到端驗證證據
