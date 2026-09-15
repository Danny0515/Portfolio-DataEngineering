# Pattern Card 總覽 (Patterns Overview)

> 這份文件是「總覽層」：收錄本專案已拍板、可重用的設計樣式（Pattern Card）。**進入實作前一律先讀這份索引**，確認有沒有既有樣式可以直接套用，避免同一類設計問題在不同 Slice 重新想一遍、甚至做出不一致的實作。單篇 Pattern Card 的詳細機制、適用情境、重用步驟見各檔案本身；本文件只列摘要與定位。

---

## WAP (Write-Audit-Publish) Quality Gate

- **檔案**：[wap-quality-gate.md](wap-quality-gate.md)
- **適用情境**：上游資料不可信、但下游不能容忍壞資料流入的批次寫入場景——資料先寫進暫存分支（Iceberg branch）、跑品質規則，通過才 fast-forward 到正式表
- **對應**：[docs/architecture/adr/0004-wap-quality-gate.md](../architecture/adr/0004-wap-quality-gate.md)；[src/transform/silver_stock.py](../../src/transform/silver_stock.py)

## Lambda 作為私有 VPC 資源存取閘道

- **檔案**：[lambda-vpc-access-gateway.md](lambda-vpc-access-gateway.md)
- **適用情境**：運算資源需要存取部署在私有子網路內的 AWS 資源（RDS、MSK 等），但呼叫方在 VPC 外部、且不想為單一存取需求額外維運常駐 bastion
- **對應**：[docs/architecture/adr/0008-lambda-vpc-access-gateway.md](../architecture/adr/0008-lambda-vpc-access-gateway.md)；[infra/environments/dev-slice2/lambda.tf](../../infra/environments/dev-slice2/lambda.tf)

## MSK Connect Custom Plugin 一次只能掛一個

- **檔案**：[msk-connect-single-plugin-per-connector.md](msk-connect-single-plugin-per-connector.md)
- **適用情境**：要幫同一個 MSK Connect connector 準備不只一個外部元件（connector 本體 + converter/SMT 等）時，一開始就規劃成單一 build 流程輸出一個合併 zip，不要先各自打包成多個獨立 custom plugin
- **對應**：[infra/environments/dev-slice2/msk_connector.tf](../../infra/environments/dev-slice2/msk_connector.tf)
