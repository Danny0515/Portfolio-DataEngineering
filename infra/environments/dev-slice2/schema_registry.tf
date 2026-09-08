# Slice 2 Schema Registry：依 §3.4 建立 Glue Schema Registry + trade_events schema。
# 見 docs/specs/slice2a-cdc-ingestion.md §3.4、§4 項目 5、§6。
#
# 這裡註冊的是「初版」schema，採用攤平的 trade 資料列形狀（對應
# src/ingestion/sql/create_trade_table.sql 的欄位），而不是 Debezium CDC envelope
# （before/after/source/op/ts_ms 那層包裝）。理由：
#   1. Debezium 實際輸出的 envelope 形狀要等 §4 項目 6（plugin 打包 spike）與項目 7
#      （connector 部署）才會定案，現在猜測 envelope schema 猜錯的機率遠高於直接照抄
#      table schema。
#   2. §4 項目 9（破壞性變更驗證）驗的是「Glue Registry 的 BACKWARD 相容性檢查機制
#      本身有沒有正常擋下違規」，不必透過 Debezium 真的送一筆訊息才能測——直接對這個
#      schema 註冊一版新增必填無 default 欄位，就能完整驗證這條驗收標準，且不必等
#      項目 6/7 完成。
#   3. §6 完整性規則（trade_id/account_id/symbol/side/status/event_time 不得為
#      null）直接對應到下面各欄位是否為必填（無 null union），這個對應在 flat
#      schema 上最直接、最好驗證。
#
# ⚠️ 風險（留給項目 7/8/9 處理，非本項目要解決）：Debezium 的 AWS Glue Schema
# Registry Avro converter 真正送出第一筆訊息時，若採用預設的 topic-based 命名策略
# （schema 名稱對應到 topic 名如 transaction.trade.v1），就不會跟這裡的
# schema_name="trade_events" 撞名；只有在 connector 被明確設定成用固定 schema 名稱
# trade_events 時才可能撞名，進而在第一筆訊息就被 BACKWARD 規則擋下——項目 7 實作時
# 留意這一點即可，不是現在要解決的問題。
resource "aws_glue_registry" "trade_events" {
  registry_name = "slice2-trade-events"
  description   = "Slice 2 交易事件 Schema Registry（§3.4：Avro + Glue Schema Registry）"
}

resource "aws_glue_schema" "trade_events" {
  schema_name   = "trade_events"
  registry_arn  = aws_glue_registry.trade_events.arn
  data_format   = "AVRO"
  compatibility = "BACKWARD" # §3.4：允許刪欄位/新增有 default 的欄位，禁止新增無 default 的必填欄位

  # 欄位對應 §6 完整性規則：trade_id/account_id/symbol/side/status/event_time 必填
  # （無 null union）；price/quantity/updated_at 非完整性規則列管，設為可為 null。
  schema_definition = jsonencode({
    type      = "record"
    name      = "TradeEvent"
    namespace = "com.portfolio.trade"
    fields = [
      { name = "trade_id", type = "string" },
      { name = "account_id", type = "string" },
      { name = "symbol", type = "string" },
      {
        name    = "price"
        type    = ["null", { type = "bytes", logicalType = "decimal", precision = 12, scale = 2 }]
        default = null
      },
      {
        name    = "quantity"
        type    = ["null", "int"]
        default = null
      },
      {
        name = "side"
        type = { type = "enum", name = "Side", symbols = ["BUY", "SELL"] }
      },
      {
        name = "status"
        type = { type = "enum", name = "TradeStatus", symbols = ["NEW", "PARTIALLY_FILLED", "FILLED", "CANCELLED"] }
      },
      {
        name = "event_time"
        type = { type = "long", logicalType = "timestamp-millis" }
      },
      {
        name    = "updated_at"
        type    = ["null", { type = "long", logicalType = "timestamp-millis" }]
        default = null
      },
    ]
  })
}
