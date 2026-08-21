# Slice 2 網路層 spike：最小驗證 Control Tower SCP 是否限制 VPC 相關資源建立
# 見 docs/specs/slice2a-cdc-ingestion.md §4 項目 1 / §8
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

# Gateway 型 endpoint 免費，必須掛在 route table 上才能生效
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.slice2.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
}
