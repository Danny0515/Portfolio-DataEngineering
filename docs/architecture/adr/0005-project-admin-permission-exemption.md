# ADR-0005: 專案總架構師帳號的 Lake Formation 權限不受本專案 Terraform 管理

| 屬性 | 值 |
| --- | --- |
| **狀態** | ✅ `Accepted` |
| **日期** | 2026-08-20 |
| **相關模組** | `infra/environments/dev/{variables.tf,lakeformation.tf}` |
| **決策者** | Danny |

## 背景 (Context)

Session 008 起，`terraform plan` 持續顯示 `aws_lakeformation_permissions.athena_reader_tables["bronze"]` 有 drift——實際授權（`ALTER`/`DELETE`/`DROP`/`INSERT`，且對 `SELECT` 帶 grant option）比 `.tf` 宣告的（`DESCRIBE`/`SELECT`）寬，當時判定為「開發期為方便手動放寬、忘記收斂」，列為待處理項目（見 [changelog.md](../../../ai/contexts/changelog.md) Session 008/009/011 Next Steps）。

規劃 Slice2 前重新檢視時，釐清本專案需要有總架構師特權帳號，用途是驗證與維護；查證 `aws lakeformation get-data-lake-settings` 確認他本來就是這個 AWS 帳號的 Lake Formation Data Lake Admin，權限邊界應由組織層級機制把關，不該是本專案 `.tf` 的 RULE-003 最小權限規則管轄範圍。這推翻了「這是需要收斂的 drift」的原判斷。

## 決策 (Decision)

對於「權限邊界由組織治理、非專案治理」的 principal，本專案的 RULE-003（IAM 最小權限原則）不適用。原先計畫仍在 Terraform 明確宣告其存取（例如宣告為 `ALL`），但實際 rollout 時發現這在技術上無法穩定收斂（見下方「rollout 過程的發現」），因此最終決策改為：**這類 principal 的 Lake Formation 授權完全不由本專案的 Terraform 管理**，其存取權完全交由 AWS 組織層級機制（Lake Formation Data Lake Admin 身份）把關與呈現，不在本專案版控範圍內宣告或追蹤。

落地為 `infra/environments/dev/{variables.tf,lakeformation.tf}` 的調整：移除對應的 `aws_lakeformation_permissions` 資源與變數宣告，並以 `terraform state rm` 把既有資源從 state 移除（**不是 destroy**——AWS 上該 principal 現有的實際授權原封不動保留，只是 Terraform 不再追蹤/管理它）。

### Rollout 過程的發現

實作時本來嘗試在 Terraform 宣告明確權限（先試 `permissions = ["ALL"]`，後改試明確展開的權限清單），但兩種寫法 `terraform plan` 都持續顯示 `-/+`（永久 drift），追查後發現兩個疊加的成因：

1. **AWS 自動加註 `"ALL"` 標籤**：只要宣告的權限清單剛好等於某資源類型能給的全部權限，`aws lakeformation list-permissions` 讀回來就會自動在陣列裡多加一個 `"ALL"` 字串，跟宣告內容（沒有這個字面值）永遠對不上——這在 bronze/silver/gold 三個 database 與 table 層級全部重現。
2. **Lake Formation Data Lake Admin 的自我授權升級行為**：這個 principal 本身是這個 AWS 帳號的 Data Lake Admin；當他（透過 `terraform apply` 執行者身分）對自己執行 grant 時，AWS 會把授權自動升級成更寬的權限集合＋grant option，不論 API 呼叫實際請求的是什麼子集——這點在 bronze database 上重現（宣告的窄權限被自動擴大，且新增了先前沒有的 grant option）。
3. 另外 bronze table 層級還疊了一筆**真正的孤兒授權殘留**：Session 008/009 當時透過 Console 手動加的 grant option，從未被 Terraform state 追蹤過，因此這次不管怎麼重建 `.tf` 宣告的資源，Terraform 的 revoke 呼叫都撤銷不到它。

三者疊加的結論是：對「同時是 Data Lake Admin、且用自己身分執行 Terraform」的 principal 而言，不存在任何 Terraform 宣告內容能讓 `terraform plan` 穩定收斂到 `No changes`——這不是寫法錯誤，是 AWS 對這種自我授權情境的固有行為。

### 另一項考量：不把真人 email 放進版控

規劃移除方案時同時發現，原本的 `var.project_admin_user_name` 預設值直接寫死這個 principal 的真實 email，會讓一個真人的個資明文留在版控歷史裡。完全移出 `.tf` 一併解決了這個問題——這個 principal 的身分不需要出現在任何本專案的程式碼或文件裡。

## 理由 (Rationale)

- 這個帳號的權限上限本來就由組織層級機制把關（Lake Formation Data Lake Admin 身份），專案層級再疊一層限制沒有實質防禦效果，只會製造「`.tf` 宣告 vs 實際需要」的長期拉鋸——這正是最初那筆 drift 的成因
- 實測證實，因為 Data Lake Admin 自我授權升級行為，這類 principal 的 Lake Formation 授權**在技術上無法用 Terraform 穩定管理**（見上方「rollout 過程的發現」）；繼續嘗試只會製造永久性的假 drift 噪音，掩蓋真正需要注意的 drift
- 移出 `.tf` 同時解決了版控裡出現真人 email 的個資疑慮，一次處理兩個問題

## 影響 (Consequences)

- ✅ **正面**：`terraform plan` 對這三個 database 完全收斂到 `No changes`，不再有假 drift 干擾真正需要注意的 drift 訊號
- ✅ **正面**：不再有真人 email 出現在版控的 `.tf` 檔案裡
- ⚠️ **注意**：這個 principal 的實際授權現在完全不受 Terraform 追蹤——查詢其目前確切權限只能靠 `aws lakeformation list-permissions`（見 [docs/TODO.md](../../TODO.md)「Lake Formation／IAM 權限 drift 偵測自動化」項目，留待 Slice4 評估是否需要輔助查詢工具）
- ⚠️ **注意**：這個 principal 目前對本專案三個 database 事實上有完整權限（含 `DELETE`/`DROP`）；若之後有其他人也共用同一個 AWS user 但不該有這麼大權限，需要重新拆分 principal，目前僅此一人使用，暫不構成問題
- ❌ **負面/限制**：本決策只適用於「組織層級已治理、且會用自己身分執行 Terraform 的特權帳號」這一類 principal，不代表 RULE-001/RULE-003 對其他 principal 失效——Glue Job 執行角色（`glue-market-job-role`）仍完整由 Terraform 管理、維持最小權限模式，不受本 ADR 影響

## 相關文件

- [ai/contexts/rules.md](../../../ai/contexts/rules.md) RULE-003 — 本決策記錄的例外條款
- [ai/contexts/changelog.md](../../../ai/contexts/changelog.md) Session 008/009/011 — drift 最初被記為待處理項目的脈絡
