# Runbook: 網路層最小驗證（VPC/私有子網/S3 VPC Endpoint spike）

## 背景 (Why)

對應 [docs/specs/slice2a-cdc-ingestion.md](../specs/slice2a-cdc-ingestion.md) §8「網路層」風險項與 §4 項目 1。`infra/environments/dev/` 原本完全沒有 VPC 資源，而 RDS / MSK / MSK Connect 全部需要 VPC、子網與 Security Group。組織 AWS 帳號受 Control Tower 治理，VPC/IGW/NAT 這類網路資源是否受 SCP（Service Control Policy）限制，在動工前**尚未驗證**——這份 spike 就是為了在投入 RDS/MSK 之前，先用最小資源組合把這個治理層級的未知數解除。

**範圍限制**：只驗證 §4 項目 1 清單列出的三項——VPC、私有子網、S3 VPC Endpoint（Gateway 型，免費資源）。不含 IGW / NAT Gateway：這兩者留到之後真的需要對外連線（例如 2b 若要對外存取）時再測，一來 §4 項目 1 的建置清單本來就沒列這兩項，二來 NAT Gateway 是按小時計費的資源，不需要在最小驗證階段就承擔這筆成本。

## 前置條件

- 本機已有可重用的 AWS MFA session（`dt-lab-long-term-mfa`，用 `aws-cli-mfa-session` skill 的 `check_mfa_session.sh dt-lab-long-term` 確認 `REUSABLE`）
- 依 §3.3(b) 已拍板的「用完即拆」策略，Slice 2 的網路層資源使用**獨立於 Slice 0/1 的 Terraform state**，避免這裡的 `destroy` 誤傷既有 Lakehouse 資源

## 部署

新增 `infra/environments/dev-slice2/` 作為 Slice 2 專屬的 Terraform 工作目錄，backend key 為 `terraform-state/dev/slice2.tfstate`（沿用既有 `terraform-state/dev/slice0.tfstate` 的命名脈絡），與 `infra/environments/dev/`（Slice 0/1）完全分離。

檔案：`versions.tf` / `provider.tf` / `variables.tf` / `vpc.tf` / `outputs.tf`。核心資源定義於 `vpc.tf`：

```hcl
resource "aws_vpc" "slice2" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.slice2.id
  cidr_block        = "10.20.1.0/24"
  availability_zone = "${var.aws_region}a"
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.slice2.id
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.slice2.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
}
```

（Route table + association 是 Gateway 型 VPC Endpoint 能運作的必要依附資源，不算擴大驗證範圍。）

```bash
cd infra/environments/dev-slice2
AWS_PROFILE=dt-lab-long-term-mfa terraform init
AWS_PROFILE=dt-lab-long-term-mfa terraform plan
AWS_PROFILE=dt-lab-long-term-mfa terraform apply
```

## 驗證步驟與參考結果（2026-08-21 執行）

### `terraform apply`

```
Plan: 5 to add, 0 to change, 0 to destroy.

aws_vpc.slice2: Creating...
aws_vpc.slice2: Creation complete after 12s [id=vpc-0361729fbc5d983ca]
aws_subnet.private: Creating...
aws_route_table.private: Creating...
aws_route_table.private: Creation complete after 1s [id=rtb-003b27538d3b846d3]
aws_vpc_endpoint.s3: Creating...
aws_subnet.private: Creation complete after 1s [id=subnet-0aaee49a9601f944e]
aws_route_table_association.private: Creating...
aws_route_table_association.private: Creation complete after 1s [id=rtbassoc-0249586c72f97c0d4]
aws_vpc_endpoint.s3: Creation complete after 7s [id=vpce-0b3aa196b1bcd82bf]

Apply complete! Resources: 5 added, 0 changed, 0 destroyed.
```

**5 個資源全數建立成功，過程中沒有出現任何 `AccessDenied`/`UnauthorizedOperation` 之類的 SCP 拒絕訊息**——這直接回答了 §8 的未知項：Control Tower 沒有限制 VPC / 私有子網 / Gateway 型 VPC Endpoint 的建立。

### 交叉驗證

```bash
AWS_PROFILE=dt-lab-long-term-mfa terraform state list
```
```
aws_route_table.private
aws_route_table_association.private
aws_subnet.private
aws_vpc.slice2
aws_vpc_endpoint.s3
```

```bash
AWS_PROFILE=dt-lab-long-term-mfa AWS_REGION=ap-northeast-1 aws ec2 describe-vpc-endpoints \
  --vpc-endpoint-ids vpce-0b3aa196b1bcd82bf \
  --query 'VpcEndpoints[0].{State:State,ServiceName:ServiceName,VpcId:VpcId,RouteTableIds:RouteTableIds}'
```
```json
{
    "State": "available",
    "ServiceName": "com.amazonaws.ap-northeast-1.s3",
    "VpcId": "vpc-0361729fbc5d983ca",
    "RouteTableIds": ["rtb-003b27538d3b846d3"]
}
```

唯讀 AWS CLI 查詢（RULE-001 允許的驗證用途）確認 S3 VPC Endpoint 狀態為 `available`，正確掛在剛建立的 VPC 與 route table 上，與 Terraform state 一致。

### 銷毀（依 §3.3(b) 用完即拆）

```bash
AWS_PROFILE=dt-lab-long-term-mfa terraform destroy
```

destroy 成功，5 個資源全數移除，`terraform state list` 之後為空。

## 結論

Control Tower SCP **未限制**本次驗證範圍內的網路資源（VPC、私有子網、route table、Gateway 型 S3 VPC Endpoint）建立與銷毀。§8 標記的網路層治理風險至此解除，可以繼續往下推進 §4 項目 2（`vpc.tf` 正式化，補上 Security Group 與 Glue VPC Endpoint）。

**未驗證項**：IGW、NAT Gateway、Interface 型 VPC Endpoint（Glue 用的是 Interface 型，非本次測的 Gateway 型）——這些留到 §4 項目 2 或實際需要時再驗證，不在本次 spike 範圍內，不能直接推論這些資源也不受 SCP 限制。

`infra/environments/dev-slice2/` 的 `.tf` 檔案 destroy 後保留在 git 中，作為 §4 項目 2 正式化 `vpc.tf` 的起點。

## 相關文件

- [docs/specs/slice2a-cdc-ingestion.md](../specs/slice2a-cdc-ingestion.md) §4 項目 1 / §8 — 這份 runbook 對應的實作項目與風險項
- `infra/environments/dev-slice2/` — 本次驗證使用的 Terraform 工作目錄（獨立 state：`terraform-state/dev/slice2.tfstate`）
