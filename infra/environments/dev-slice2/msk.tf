# Slice 2 MSK cluster：依 §3.3 建立 Provisioned MSK（2 個 kafka.t3.small broker，對應
# 2 個私有子網/AZ）。見 docs/specs/slice2a-cdc-ingestion.md §3.3、§4 項目 5。
#
# Topic（transaction.trade.v1 / transaction.trade.v1.dlq）不在這裡建立：依決策延後到
# §4 項目 7（Debezium/MSK Connect 第一次寫入時觸發），這裡只需開
# auto.create.topics.enable，讓 broker 具備自動建立 topic 的能力（見 docs/TODO.md
# 「Kafka topic 改為正式 Terraform 管理」）。
#
# 認證：Unauthenticated + TLS in-transit only（9094）。存取控制完全交給 Security
# Group，跟 rds.tf 保護 RDS 的哲學一致，不用 SASL/IAM，避免 §4 項目 7 設定 connector
# 時要多處理一層 IAM 簽章。

locals {
  # aws_msk_configuration.kafka_versions 與 aws_msk_cluster.kafka_version 必須一致，
  # 用同一個 local 避免兩處手動同步時漏改其中一處。
  # 3.9.x 是 AWS MSK 官方文件目前標示的 Recommended 版本，尚無 end-of-support 日期
  # （3.6.0/3.7.x 已過或即將過保護期，不選）。
  msk_kafka_version = "3.9.x"
}

resource "aws_msk_configuration" "trade" {
  name           = "slice2-trade-msk-config"
  kafka_versions = [local.msk_kafka_version]

  # auto.create.topics.enable：topic 由未來的 producer（Debezium connector）第一次
  # 寫入時自動建立，不用額外的 provider/Lambda 手動建立 topic。
  # default.replication.factor=2：對應 2-broker 佈署，讓自動建立的 topic 兩個 broker
  # 都有副本。min.insync.replicas=1：demo 用途刻意寬鬆，一顆 broker 掛掉仍可寫入。
  server_properties = <<-PROPERTIES
    auto.create.topics.enable=true
    default.replication.factor=2
    min.insync.replicas=1
  PROPERTIES
}

resource "aws_msk_cluster" "trade" {
  cluster_name           = "slice2-trade-msk"
  kafka_version          = local.msk_kafka_version
  number_of_broker_nodes = 2 # 對應 2 個私有子網/AZ（§3.3(a)、variables.tf 既有註解）

  broker_node_group_info {
    instance_type   = "kafka.t3.small"
    client_subnets  = [for s in aws_subnet.private : s.id]
    security_groups = [aws_security_group.slice2_internal.id]

    storage_info {
      ebs_storage_info {
        volume_size = 20 # demo 用途最小可用量級，比照 rds.tf allocated_storage=20
      }
    }
  }

  client_authentication {
    unauthenticated = true
  }

  # 只開 TLS（9094），不開 PLAINTEXT（9092）——client_broker="TLS" 讓 broker 不開放
  # 9092 這個 listener，逼所有連線走加密埠。
  encryption_info {
    encryption_in_transit {
      client_broker = "TLS"
      in_cluster    = true
    }
  }

  configuration_info {
    arn      = aws_msk_configuration.trade.arn
    revision = aws_msk_configuration.trade.latest_revision
  }
}
