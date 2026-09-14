# Pattern Card: MSK Connect Custom Plugin 一次只能掛一個

| 屬性 | 值 |
| --- | --- |
| **狀態** | ✅ Accepted |
| **相關模組** | `infra/environments/dev-slice2/msk_connector.tf` |
| **對應決策** | - |
| **決策者** | Danny |

## 適用情境 (When to Use)

任何要幫同一個 MSK Connect connector 準備「不只一個來源」的 plugin 時（例如 connector 本體 + 額外的 converter/SMT/interceptor jar）：一開始就規劃成單一 build 流程、輸出一個合併的 zip，不要先各自打包成多個獨立 custom plugin。

Kafka Connect 的 connector 與 converter 在架構上是互相獨立的兩個軸——同一個 connector（例如 Debezium）之後可能搭配不同的 converter，同一個 converter（例如 `AWSKafkaAvroConverter`）之後也可能被不同 connector 重用（S3 Sink、JDBC Sink 等）。這代表隨著 connector 數量增加，「需要合併哪些元件」的排列組合會越來越多，不會永遠只有這一種固定配對。

## 核心限制

MSK Connect 的 `CreateConnector` API，`plugins` 參數只接受**恰好一個元素**的清單（官方文件明載，不是文件沒寫清楚）。要用多個外部函式庫，必須先合併成同一個 zip 建立單一 custom plugin，不能像自架 Kafka Connect 的 `plugin.path` 機制那樣放多個獨立 plugin 讓 connector 設定自由引用——那個彈性是 Kafka Connect 框架本身提供的，MSK Connect 這個代管服務為了部署/隔離保證把它簡化掉了。

## 怎麼踩到這個坑的

§4 項目 6 誤以為「`CreateConnector` API 本來就接受 plugin 清單」，建了兩個獨立的 `aws_mskconnect_custom_plugin`（Debezium 本體、Glue Schema Registry converter）。項目 7 實際要建 connector 時才發現這個限制，回頭另建第三個合併版 plugin（`msk_connector.tf`），項目 6 那兩個舊 plugin 保留作歷史紀錄，沒有被使用。

## 如何在未來重用此樣式

現在只有一個 connector，`msk_connector.tf` 手寫死一段「下載＋合併＋打包＋註冊」的邏輯是合理的最小實作。**等真的要新增第二個 MSK Connect connector**（不管是另一個來源 DB、S3 Sink，或任何需要多個元件組合的情境），才是把這段邏輯抽成可重用 Terraform module 的時機——輸入是一份元件下載來源清單，輸出是一個 `aws_mskconnect_custom_plugin`；屆時可以把 S3 正式定位成「原子元件庫」（每個 connector 本體、每個 converter 各自存成獨立物件），由 module 依需求動態組裝，而不是像現在這樣每個 connector 各自重複整段打包邏輯。在只有一個 connector 的階段提前做這個抽象是過度工程，不建議現在就做。

## 相關文件

- [infra/environments/dev-slice2/msk_connect_plugin.tf](../../infra/environments/dev-slice2/msk_connect_plugin.tf) 的修正註解
- [infra/environments/dev-slice2/msk_connector.tf](../../infra/environments/dev-slice2/msk_connector.tf)
- [docs/runbooks/slice2-msk-connect-plugin-packaging-verification.md](../runbooks/slice2-msk-connect-plugin-packaging-verification.md) 的修正段落
