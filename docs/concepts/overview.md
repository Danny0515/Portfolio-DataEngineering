# 概念解說總覽 (Concepts Overview)

> 這份文件是「總覽層」：收錄開發過程中針對特定技術概念寫的零基礎解說／學習筆記，服務對象包含未來接手的開發者，也包含開發者自己——**不是**專案的正式規格或決策紀錄（那些見 [docs/specs/](../specs/)、[docs/architecture/adr/](../architecture/adr/)），純粹是「這個概念是什麼、為什麼需要」的入門說明。
>
> 格式不限於 markdown：圖解類內容刻意用自包含的 `.html`（含 inline SVG）保留視覺化效果，直接用瀏覽器開啟即可閱讀，不用額外工具；純文字說明可用一般 markdown。

---

## AWS 網路架構 (VPC / Subnet / Security Group / VPC Endpoint)

- **檔案**：[aws-network-eli5.html](aws-network-eli5.html)
- **內容**：用「蓋一個私人社區」的比喻，圖解 Slice 2a §4 項目 1/2 實際建立的 VPC、私有子網、Security Group、VPC Endpoint（Gateway 型 vs Interface 型）如何組成一個私有網路，含實際 apply 過程遇到的兩個意外（可用區代碼不可用、Security Group description 只接受 ASCII）
- **對應**：[docs/specs/slice2a-cdc-ingestion.md](../specs/slice2a-cdc-ingestion.md) §4 項目 1/2
