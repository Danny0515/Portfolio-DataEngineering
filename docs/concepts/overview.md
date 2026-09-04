# 概念解說總覽 (Concepts Overview)

> 這份文件是「總覽層」：收錄開發過程中針對特定技術概念寫的零基礎解說／學習筆記，服務對象包含未來接手的開發者，也包含開發者自己——**不是**專案的正式規格或決策紀錄（那些見 [docs/specs/](../specs/)、[docs/architecture/adr/](../architecture/adr/)），純粹是「這個概念是什麼、為什麼需要」的入門說明。
>
> 格式不限於 markdown：圖解類內容刻意用自包含的 `.html`（含 inline SVG）保留視覺化效果，直接用瀏覽器開啟即可閱讀，不用額外工具；純文字說明可用一般 markdown。

---

## AWS 網路架構 (VPC / Subnet / Security Group / VPC Endpoint)

- **檔案**：[aws-network-eli5.html](aws-network-eli5.html)
- **內容**：用「蓋一個私人社區」的比喻，圖解 Slice 2a §4 項目 1/2 實際建立的 VPC、私有子網、Security Group、VPC Endpoint（Gateway 型 vs Interface 型）如何組成一個私有網路，含實際 apply 過程遇到的兩個意外（可用區代碼不可用、Security Group description 只接受 ASCII）
- **對應**：[docs/specs/slice2a-cdc-ingestion.md](../specs/slice2a-cdc-ingestion.md) §4 項目 1/2

## Terraform：環境分帳號 vs 同環境拆 state

- **檔案**：[terraform-account-vs-state-eli5.html](terraform-account-vs-state-eli5.html)
- **內容**：用「城市與工地」的比喻，釐清兩條常被混在一起的分割線——軸線一「dev/uat/prod 要不要分 AWS account」跟軸線二「同一個環境內，state 要不要依生命週期拆成多組」，並說明為何 Terraform Workspace 不適合本專案的 `dev/` vs `dev-slice2/` 情境，兩者本質是可疊加、非互斥的決策
- **對應**：`infra/environments/dev/`、`infra/environments/dev-slice2/`；[docs/specs/slice2a-cdc-ingestion.md](../specs/slice2a-cdc-ingestion.md) §3.3(b)

## RDS 與 Lambda（檔案室與派遣工）

- **檔案**：[rds-lambda-eli5.html](rds-lambda-eli5.html)
- **內容**：用「檔案室搬進來、派遣工用傳送門進出」的比喻，圖解 Slice 2a §4 項目 3/4 新增的 RDS（來源 OLTP DB）、Lambda（generator，VPC 內執行）、IAM Role、Security Group 新規則與 CloudWatch Logs VPC Endpoint；重點說明 Lambda 為何不需要 bastion／VPN 就能存取私有子網內的 RDS，附實際執行結果
- **對應**：[docs/specs/slice2a-cdc-ingestion.md](../specs/slice2a-cdc-ingestion.md) §4 項目 3/4
