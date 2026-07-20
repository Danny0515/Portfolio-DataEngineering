# Runbook: 透過 SSH Bastion 存取 AWS 資源

## 背景 (Why)

組織 AWS 帳號由 **Control Tower** 統一治理，本機無法直接以 AWS CLI / SDK 操作雲端資源。所有需要 AWS 憑證的操作（`aws cli`、日後的 `terraform apply` 等）都必須先 SSH 進 bastion EC2 instance，於該 instance 上執行。

Bastion instance 別名：`danny-ops`（Amazon Linux，預設帳號 `ec2-user`）。

---

## 前置設定

### 1. `/etc/hosts` 加入 bastion IP

```
<bastion Public IP> danny-ops
```

> 常見錯誤：把 `user@域名` 整串塞進第一欄（例如 `ec2-user@ec2-....amazonaws.com danny-ops`）。`/etc/hosts` 第一欄必須是**純 IP 位址**，否則整行會被解析器忽略，導致 `ping danny-ops` / `ssh danny-ops` 出現 `Unknown host`。
>
> Bastion 若未配置 Elastic IP，重啟後 Public IP 會變動，需重新更新這行。

### 2. `~/.ssh/config` 設定別名，避免每次打完整參數

```
Host danny-ops
    HostName <bastion Public IP>
    User ec2-user
    IdentityFile ~/.ssh/danny_ops.pem
```

設定後可直接執行 `ssh danny-ops`，不用再帶 `-i` 與帳號。

---

## 連線與操作步驟

```bash
# 1. 連進 bastion
ssh danny-ops

# 2. 在 bastion 上確認 AWS CLI 可用（bastion instance 已綁定具備所需權限的 IAM Role）
aws sts get-caller-identity

# 3. 執行實際的 AWS CLI 操作（僅限查詢/驗證，見 RULE-001）
aws s3 ls
aws glue get-databases
```

---

## 透過 Terraform 部署 AWS 資源

依 [ai/contexts/rules.md](../../ai/contexts/rules.md) RULE-001，所有 AWS 資源的建立/修改/刪除一律用 Terraform（`infra/`），禁止用 aws cli 部署。本機沒有 AWS 憑證，`terraform apply` 也必須在 bastion 上執行；程式碼透過 rsync 從本機同步過去（本機 repo 是唯一事實來源，不在 bastion 上直接修改 `.tf` 檔案）。

### Bootstrap（僅第一次，建立 state 存放用的 bucket 本身）

```bash
# 1. 本機同步程式碼（此時 versions.tf 還沒有 backend "s3" 區塊，用預設 local backend）
rsync -av --delete --exclude='.terraform/' --exclude='terraform.tfstate*' infra/ danny-ops:~/Portfolio-DataEngineering/infra/

# 2. bastion 上建立 bucket
ssh danny-ops
cd ~/Portfolio-DataEngineering/infra/environments/dev
terraform init
terraform apply   # 建立 danny-data-engineering bucket + versioning/加密/public access block

# 3. 本機：把 versions.tf 裡的 backend "s3" 區塊取消註解，再次 rsync 上去

# 4. bastion 上把 local state 遷移進 S3
terraform init -migrate-state
```

### 日常流程（之後每次變更）

```bash
rsync -av --delete --exclude='.terraform/' --exclude='terraform.tfstate*' infra/ danny-ops:~/Portfolio-DataEngineering/infra/
ssh danny-ops
cd ~/Portfolio-DataEngineering/infra/environments/dev
terraform plan
terraform apply
terraform output          # 記下這兩個指令的結果
terraform state list
```

### apply 後：更新 infra 現況快照

`apply` 成功後，把上面 `terraform output` / `terraform state list` 的結果拿回本機，**覆寫**（不是累加）對應環境的 `ai/contexts/infra_<env>.md`（目前只有 dev，即 [ai/contexts/infra_dev.md](../../ai/contexts/infra_dev.md)），更新「最後更新」日期、Outputs 表格、已管理資源清單。

- 這是**現況快照**，不是歷史紀錄——目的是讓人不用 SSH 進 bastion 也能知道目前實際部署了什麼
- 只寫 `output`／`state list` 這類**非機密摘要**，絕對不要把 `terraform.tfstate` 原始內容貼進版控（state 可能含明文機密，見 RULE-001 精神）
- 歷史異動（何時新增/移除了哪些資源）留給 git log 與 `ai/contexts/changelog.md` 的 session 紀錄，不要塞進這份快照，避免它跟 changelog 一樣越長越難讀

---

## 故障排除

| 現象 | 原因 | 處理 |
| --- | --- | --- |
| `ping: cannot resolve danny-ops: Unknown host` | `/etc/hosts` 第一欄不是合法 IP（例如誤填 `user@domain`） | 改成純 IP，見上方「前置設定」 |
| `ssh ... Permission denied (publickey,...)` 且沒有指定帳號 | SSH 預設用本機使用者名稱登入，但該帳號在 EC2 上不存在 | 補上正確帳號，如 `ssh -i ~/.ssh/danny_ops.pem ec2-user@danny-ops`，或在 `~/.ssh/config` 設定 `User` |
| `Permission denied` 且帳號正確 | 私鑰檔權限過寬 | `chmod 400 ~/.ssh/danny_ops.pem` |
| bastion 上 `aws cli` 指令回傳 `AccessDenied` | Control Tower guardrail 擋下該操作，或 bastion 的 IAM Role 權限不足 | 依 spec §3.1 決策，權限問題採**邊執行邊調整**：確認錯誤訊息缺哪個 action，回報負責 IAM 的人補權限，不預先設計完整權限模型 |
| 想直接用 `aws s3 mb` / `aws s3api put-bucket-*` 等指令建立或修改資源 | 違反 RULE-001（禁止用 AWS CLI 部署） | 改用上方「透過 Terraform 部署 AWS 資源」流程；aws cli 僅能用於查詢/驗證 |
| `rsync --delete` 把 bastion 上的 `.terraform/`、`terraform.tfstate` 也刪掉 | 本機 repo 沒有這些檔案（它們只在 bastion 執行 `terraform init/apply` 後才產生），`--delete` 會把 bastion 上「本機沒有」的檔案一併清掉 | 一定要帶 `--exclude='.terraform/' --exclude='terraform.tfstate*'`（見上方指令）；若已經刪除且用的是 S3 backend，AWS 上的資源不受影響，用 `terraform import <resource_address> <id>` 把資源重新關聯回新的 state 即可，不需要重建資源 |

---

## 相關文件

- [docs/specs/slice0-batch-market-data.md](../specs/slice0-batch-market-data.md) §3.1 — 執行環境決策（真實 AWS，IAM 權限邊做邊調整）
- [CLAUDE.md](../../CLAUDE.md) 「環境限制」章節
- [ai/contexts/rules.md](../../ai/contexts/rules.md) RULE-001 — AWS 部署一律 Terraform
- [ai/contexts/infra_dev.md](../../ai/contexts/infra_dev.md) — dev 環境目前實際部署的資源現況快照
