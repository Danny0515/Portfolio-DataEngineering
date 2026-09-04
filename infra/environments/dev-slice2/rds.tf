# Slice 2 來源 OLTP DB
# 見 docs/specs/slice2a-cdc-ingestion.md §3.1、§4 項目 4
#
# 主密碼直接由 Terraform 產生、同時寫進 RDS 與 lambda.tf 的環境變數，不透過 Secrets
# Manager——這是刻意簡化：Lambda 要讀 Secrets Manager 一樣需要對應的 VPC Endpoint，
# 對這個 lab/demo 環境不值得多開一個常駐計費資源。
resource "random_password" "trade_db" {
  length  = 20
  special = false
}

resource "aws_db_subnet_group" "trade" {
  name       = "slice2-trade"
  subnet_ids = [for s in aws_subnet.private : s.id]
}

# rds.logical_replication 是 Debezium CDC 擷取的前提，這個 instance 一開始建立就掛上
# 這個 parameter group，不會有「改參數要重開機」的問題（apply_method 只在既有 instance
# 上修改參數時才有意義）。
resource "aws_db_parameter_group" "trade" {
  name   = "slice2-trade-pg16"
  family = "postgres16"

  parameter {
    name         = "rds.logical_replication"
    value        = "1"
    apply_method = "pending-reboot"
  }
}

resource "aws_db_instance" "trade" {
  identifier     = "slice2-trade"
  engine         = "postgres"
  engine_version = "16"
  instance_class = "db.t4g.micro"

  allocated_storage = 20
  storage_type      = "gp3"

  db_name  = "trade"
  username = "trade_admin"
  password = random_password.trade_db.result

  db_subnet_group_name   = aws_db_subnet_group.trade.name
  vpc_security_group_ids = [aws_security_group.slice2_internal.id]
  parameter_group_name   = aws_db_parameter_group.trade.name

  publicly_accessible = false
  multi_az            = false # cost-conscious lab env；依 §3.3(b) 用完即拆，不做 HA

  skip_final_snapshot = true # 用完即拆，不需要保留最終快照
  deletion_protection = false
}
