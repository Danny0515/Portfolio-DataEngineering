# Infra 現況 — dev-slice2 環境（Slice 2 CDC 網路層 + 來源 DB + generator + MSK/Connect）

> 記錄 Slice 2 網路層目前由 Terraform 實際管理、已部署的資源現況。**這是快照，每次 `terraform apply`／`terraform destroy` 後直接覆寫更新，不累加歷史**（歷史異動查 git log 或 changelog.md）。內容一律以 `terraform output` / `terraform state list` 的實際輸出為準，不手動編造。
>
> 依 §3.3(b)「用完即拆」策略，這組資源在 Slice 2a/2b 驗證期間維持運行，驗證全部完成後 destroy（見 §4 項目 10 的 [slice2-stack-lifecycle.md](../../docs/runbooks/slice2-stack-lifecycle.md)）——跟 [infra_dev.md](infra_dev.md)（Slice 0/1，長期持續運行）的生命週期不同，因此獨立成一份快照，不合併進同一份文件。

**最後更新**：2026-10-02
**Terraform 工作目錄**：`infra/environments/dev-slice2/`（依 RULE-002，優先在本機以 `AWS_PROFILE=dt-lab-long-term-mfa` 執行）
**State 位置**：`s3://danny-data-engineering/terraform-state/dev/slice2.tfstate`

## 目前狀態：**資源已銷毀**（`terraform state list` 為空）

§4 項目 12（端到端驗證）這次依 [slice2-stack-lifecycle.md](../../docs/runbooks/slice2-stack-lifecycle.md) 的正式三階段流程，實際執行了一輪完整的 destroy → 重建 → 煙霧測試 → destroy 循環，驗證整條 Slice 2a pipeline 真的可以從頭建起來、也能乾淨拆掉。驗證完成後依用完即拆慣例再次銷毀，目前這個環境**沒有任何資源在跑**，`terraform output`／`terraform state list` 皆為空。完整驗證過程與真實指令輸出見 [slice2a-verification.md](../../docs/runbooks/slice2a-verification.md)。

下次要重新建立時，依 [slice2-stack-lifecycle.md](../../docs/runbooks/slice2-stack-lifecycle.md) 的「建立流程（Cold Start）」三階段執行；`apply` 完成後記得回來覆寫本檔案的 Outputs／已管理資源清單。

## Outputs（apply 後才會有值，目前為空）

| Key | Value |
| --- | --- |
| （資源已銷毀，無輸出值） | — |

## 已管理資源（目前為空）

`terraform state list` 回傳空清單，無已管理資源。

> 這次 destroy→重建→destroy 循環過程中額外發現兩個跟本環境相關、已記入 [slice2-stack-lifecycle.md](../../docs/runbooks/slice2-stack-lifecycle.md) 故障排除的真實現象（供下次重建參考）：(1) MSK cluster 建立／銷毀時間明顯不對稱（這次實測建立約 27-28 分鐘，銷毀僅約 3-4 分鐘）；(2) 刪除有掛 VPC 的 Lambda 後，其 ENI 會先進入 `available`（已卸載但未釋放）狀態一段時間才被 AWS 自動回收，期間會卡住所屬子網路／Security Group 的刪除，可用 `aws ec2 delete-network-interface` 手動加速。
