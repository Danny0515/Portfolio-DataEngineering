---
description: 將整個專案同步到 bastion(danny-ops),取代個別目錄各自的 rsync 指令,避免 bastion 上專案結構跟本機失去一致性
---

# 同步專案到 Bastion (rsync_to_bastion)

執行 [scripts/rsync_to_bastion.sh](../../scripts/rsync_to_bastion.sh)，把整個專案同步到 bastion 的 `~/Portfolio-DataEngineering/`。

## 為什麼要有這個 skill

過去 Terraform、raw landing 資料等不同用途各自用不同的 rsync 指令、不同的 exclude 規則，曾經因為 exclude 沒設好，誤刪 bastion 上剛產生的 Terraform local state（見 [docs/runbooks/aws-access-via-bastion.md](../../docs/runbooks/aws-access-via-bastion.md) 故障排除表）。改成「一個專案只有一種同步方式」，把 exclude 規則收斂到單一腳本維護，避免 bastion 上的專案結構跟本機長期漂移不一致。

## 使用時機

任何需要在 bastion 上執行操作之前（`terraform apply`、`aws s3 sync` 上傳資料、之後的 Spark job 等），先跑這個 skill 同步最新程式碼，再 SSH 進去執行。

## 執行步驟

1. 執行 `bash scripts/rsync_to_bastion.sh`
2. 檢查 rsync 輸出，確認沒有非預期的 `deleting ...` 項目
3. 如需手動驗證或操作，`ssh danny-ops` 進去，專案在 `~/Portfolio-DataEngineering/`

## 安全檢查

- 這是操作型工具，不涉及修改 `plan.md`／`execution-roadmap.md`／`ai/contexts/rules.md`，執行前不需要額外確認門檻
- exclude 清單獨立維護在 [scripts/rsync_to_bastion.sh](../../scripts/rsync_to_bastion.sh) 內，不是重用 `.gitignore`——因為兩者語意不同（例如 `data/` 要同步到 bastion 供上傳 S3，但不進 git 版控）
