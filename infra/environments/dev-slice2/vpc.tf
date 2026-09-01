# Slice 2 網路層：§4 項目 1 spike 驗證 Control Tower SCP 未限制後，項目 2 正式化
# 見 docs/specs/slice2a-cdc-ingestion.md §4 項目 1/2、§8
resource "aws_vpc" "slice2" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
}

resource "aws_subnet" "private" {
  for_each          = var.private_subnet_cidrs
  vpc_id            = aws_vpc.slice2.id
  cidr_block        = each.value
  availability_zone = "${var.aws_region}${each.key}"
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.slice2.id
}

resource "aws_route_table_association" "private" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

# Gateway 型 endpoint 免費，必須掛在 route table 上才能生效
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.slice2.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
}

# RDS/MSK/MSK Connect 未來共用的內部 SG；入站規則隨各自建立資源的項目（§4 項目 4/5/7）逐步補齊，
# 這裡先只開讓 Interface VPC Endpoint 能被存取的最低限度規則
# 註：GroupDescription 跟規則層級的 description 一樣只接受 ASCII，不能用中文
resource "aws_security_group" "slice2_internal" {
  name        = "slice2-internal"
  description = "Slice 2 CDC pipeline shared internal SG (RDS/MSK/MSK Connect/Interface Endpoint)"
  vpc_id      = aws_vpc.slice2.id

  # AWS SecurityGroupRuleDescription 只接受 ASCII 字元，這兩條規則的 description 不能用中文
  ingress {
    description = "Allow HTTPS between SG members for Interface VPC Endpoint access"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    self        = true
  }

  egress {
    description = "Allow all egress; no IGW/NAT in this VPC, so this only reaches VPC Endpoints or in-VPC peers"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Interface 型 endpoint：跟 S3 的 Gateway 型不同機制，需佔用子網 IP、掛 SG、且持續計費
resource "aws_vpc_endpoint" "glue" {
  vpc_id              = aws_vpc.slice2.id
  service_name        = "com.amazonaws.${var.aws_region}.glue"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [for s in aws_subnet.private : s.id]
  security_group_ids  = [aws_security_group.slice2_internal.id]
  private_dns_enabled = true
}
