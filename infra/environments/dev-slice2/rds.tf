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

  # replication slot 保留 WAL 的上限（保險絲）：萬一 heartbeat 失效或 connector 長期離線，
  # 超過上限時 slot 會被作廢（wal_status=lost）而不是把磁碟寫滿、讓整個資料庫當機。
  # 10GB 對應 30GB 儲存；閒置 WAL 約 0.75GB/小時，正常有 heartbeat 時不會碰到。
  # 代價：slot 被作廢後 Debezium 需重建 slot 並重新 snapshot，期間事件會遺失。動態參數，
  # 不需重開機。
  parameter {
    name         = "max_slot_wal_keep_size"
    value        = "10240"
    apply_method = "immediate"
  }
}

resource "aws_db_instance" "trade" {
  identifier     = "slice2-trade"
  engine         = "postgres"
  engine_version = "16"
  instance_class = "db.t4g.micro"

  # 20 → 30（Slice 2b spike 實測後調整）：Debezium 的 replication slot 在表沒有變更
  # 時不會前進，RDS 內部寫入產生的 WAL 會被 slot 持續保留（實測約 0.75GB/小時），
  # stack 閒置約 1 天就把 20GB 填滿（storage-full）。加大儲存只是延後、不是根治；
  # 根治靠 Debezium heartbeat（msk_connector.tf）加上本檔 parameter group 的
  # max_slot_wal_keep_size 保險絲。
  allocated_storage = 30
  storage_type      = "gp3"

  # 儲存已滿，需立即套用，不等維護時段。
  apply_immediately = true

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
