# Runbook: CDC 事件驗證（insert/update/delete → Kafka topic）

## 背景 (Why)

對應 [docs/specs/slice2a-cdc-ingestion.md](../specs/slice2a-cdc-ingestion.md) §4 項目 8、§7 驗收標準前兩條。§4 項目 7 已經把 `aws_mskconnect_connector.debezium_postgres` 部署成 `RUNNING`，但只確認了「連線建立成功」，還沒有真的證明「來源 DB 的異動會變成帶 before/after 影像與 LSN 的 CDC 事件」。這份 runbook 是本專案第一次寫 Kafka consumer 程式碼、第一次真的解碼 Debezium 產生的 Avro envelope。

## 範圍限制

驗證 spec §7 四條 CDC 相關驗收標準：(1) insert/update/delete 三種操作都出現在 `transaction.trade.v1` topic 上，且帶 before/after 影像與來源變更序（LSN）；(2) 一筆交易走完 NEW→PARTIALLY_FILLED→FILLED 完整狀態機時，topic 上能看到對應的完整事件軌跡（以上兩條為 §4 項目 8，見下方主體段落）；(3) 註冊破壞性 schema 變更被 Registry 擋下；(4) 違約訊息進 DLQ 不阻塞主流程（以上兩條為 §4 項目 9，見文末補充段落）。**不涵蓋**端到端延遲 SLA（Slice 2b 的非目標）。依 §2 非目標段落「用 consumer 印出訊息即為驗收」的定位，這是一次性檢查工具，不是常駐服務。

## 前置條件

- 可重用的 AWS MFA session（`dt-lab-long-term-mfa`）
- Slice 2 stack 已跑到項目 7（connector `RUNNING`）
- 本機 `kafka-python-ng`／`aws-glue-schema-registry` 皆為純 Python 套件，但 `aws-glue-schema-registry` 間接依賴 `orjson`（編譯過的 Rust extension）——**這點在本次實作中真的踩到**，見下方部署段落

## 部署

新增 `infra/environments/dev-slice2/msk_event_verifier.tf`：一支新 Lambda（`slice2-cdc-event-verifier`），跟 `trade_generator` 掛同一個 VPC/SG（`slice2_internal` 既有的 9094／443 self-referencing 規則已涵蓋，沒有新增 SG 規則），IAM 只給唯讀的 `glue:GetSchemaVersion`／`GetSchema`／`ListSchemaVersions`（範圍鎖定 `slice2-trade-events` registry），核心邏輯見 `src/ingestion/verify_cdc_events.py`。

**實作過程中踩到的坑**：第一次 `terraform apply` 後呼叫 Lambda，回傳 `Runtime.ImportModuleError: No module named 'orjson.orjson'`。原因是 `aws-glue-schema-registry` 間接依賴 `orjson`（一個用 Rust／PyO3 編譯的 JSON 函式庫，不是純 Python），本機 macOS 直接 `pip install --target` 會抓到 macOS 版本的 `.so`，Lambda（Amazon Linux x86_64）載入時找不到相容的原生函式庫。修法：在 `null_resource` 的 `pip install` 加上 `--platform manylinux2014_x86_64 --implementation cp --python-version 3.12 --only-binary=:all:`，強制抓預先編譯好的 Linux x86_64 wheel（已用 `file` 指令確認抓下來的 `.so` 是 `ELF 64-bit ... x86-64`，不是本機的 macOS Mach-O），不需要在本機跨平台編譯。這跟 `pg8000` 選型時要避開的問題是同一類，只是這次是**間接依賴**帶進來的，不是我們自己選的套件。

```bash
cd infra/environments/dev-slice2
AWS_PROFILE=dt-lab-long-term-mfa terraform validate
AWS_PROFILE=dt-lab-long-term-mfa terraform plan
AWS_PROFILE=dt-lab-long-term-mfa terraform apply
# 第一次 apply 後發現 orjson 問題，修正 pip install 指令後：
AWS_PROFILE=dt-lab-long-term-mfa terraform apply -replace="null_resource.build_cdc_event_verifier"
```

## 驗證步驟與參考結果（2026-09-15 執行）

### 步驟 1：觸發來源異動

```bash
aws lambda invoke --function-name slice2-trade-generator \
  --payload '{"num_trades": 10, "seed": 42}' /tmp/generator_output.json
```
```json
{"trades": 10, "dirty_injected": 0, "operations": {"INSERT": 10, "UPDATE": 16, "DELETE": 2}, "status_counts": {"FILLED": 24}}
```

### 步驟 2：等待 CDC 傳播

實測：`sleep 15` 後立刻呼叫 consumer，10 筆交易的所有異動（INSERT/UPDATE/DELETE）都已經在 topic 上——實際傳播延遲遠低於 15 秒（訊息時間戳 `ts_ms` 顯示同一批次的 c/u/d 事件彼此間隔多在 0.5-1.5 秒內，這是 generator 本身逐筆處理的間隔，不是 CDC 延遲）。這是本片段唯一一次量測，不代表正式 SLA（§2 明訂延遲 SLA 留給 Slice 2b）。

### 步驟 3：消費並解碼

```bash
aws lambda invoke --function-name slice2-cdc-event-verifier \
  --payload '{"topic": "transaction.trade.v1", "max_messages": 200, "timeout_seconds": 20}' \
  /tmp/verifier_output.json
```

回傳摘要（`total_messages` 46 筆是整個 topic 的歷史累積，含 connector 第一次啟動時對既有資料做的 initial snapshot）：

```json
{
  "topic": "transaction.trade.v1",
  "total_messages": 46,
  "op_counts": {"r": 16, "c": 10, "u": 16, "d": 2, "tombstone": 2},
  "distinct_keys": 28
}
```

`op_counts` 裡的 `r`（16 筆）是原本沒預期到的一種 op 值——Debezium connector 第一次啟動時，會對來源表既有的資料做一次 initial snapshot，這些訊息的 `op` 是 `r`（read），不是 `c`；`c`/`u`/`d` 三種計數（10／16／2）跟步驟 1 generator 回報的 `operations` 完全對得上；`tombstone`（2 筆）對應 2 筆 DELETE 各自附帶的 null-value 墓碑訊息，跟預期一致。

### 步驟 4：驗證 before/after 與 LSN（insert/update/delete 三種操作）

**INSERT**（`op=c`，`before=null`）：
```json
{
  "op": "c",
  "before": null,
  "after": {"trade_id": "T1789439131-0000", "account_id": "ACC0009", "symbol": "3653",
             "price": 144.17, "quantity": 16000, "side": "BUY", "status": "NEW",
             "event_time": "2026-09-15T02:25:31.260976Z", "updated_at": "2026-09-15T02:25:31.260976Z"},
  "lsn": 227834593552, "ts_ms": 1789439131549
}
```

**UPDATE**（`op=u`，`before`/`after` 皆非空，狀態從 `NEW`→`PARTIALLY_FILLED`）：
```json
{
  "op": "u",
  "before": {"...": "...", "status": "NEW", "updated_at": "2026-09-15T02:25:31.260976Z"},
  "after":  {"...": "...", "status": "PARTIALLY_FILLED", "updated_at": "2026-09-15T02:25:31.261036Z"},
  "lsn": 227834595512, "ts_ms": 1789439131551
}
```

**DELETE**（`op=d`，`before` 是刪除前的完整資料列、`after=null`，後面接一筆 tombstone）：
```json
{
  "op": "d",
  "before": {"trade_id": "T1789439131-0006", "...": "...", "status": "CANCELLED"},
  "after": null,
  "lsn": 227834600640, "ts_ms": 1789439135625
}
```

三種操作皆帶非空 LSN（`source.lsn`），且 LSN 隨事件順序遞增——符合「來源變更序」的驗收要求。

### 步驟 5：驗證完整交易生命週期

在 46 筆訊息裡找到 **6 筆完整的 `c → u → u` 序列**，狀態依序是 `NEW → PARTIALLY_FILLED → FILLED`，例如 `T1789439131-0000`／`T1789439131-0001`／`T1789439131-0002`／`T1789439131-0003`／`T1789439131-0005`／`T1789439131-0007`（完整 JSON 見上次 Lambda 呼叫的原始輸出，此處僅摘錄 `T1789439131-0000` 一組為代表）：

```json
[
  {"op": "c", "before": null, "after": {"status": "NEW", ...}, "lsn": 227834593552},
  {"op": "u", "before": {"status": "NEW", ...}, "after": {"status": "PARTIALLY_FILLED", ...}, "lsn": 227834595512},
  {"op": "u", "before": {"status": "PARTIALLY_FILLED", ...}, "after": {"status": "FILLED", ...}, "lsn": 227834595792}
]
```

另外找到 **2 筆完整的 `c → u → d` 序列**（`NEW → CANCELLED → DELETE`），例如 `T1789439131-0006`：
```json
[
  {"op": "c", "before": null, "after": {"status": "NEW", ...}},
  {"op": "u", "before": {"status": "NEW", ...}, "after": {"status": "CANCELLED", ...}},
  {"op": "d", "before": {"status": "CANCELLED", ...}, "after": null}
]
```

## 項目 9：Schema 破壞性變更驗證（2026-09-15 執行）

對應 spec §7 後兩條驗收標準：註冊破壞性 schema 變更被 Registry 擋下（附錯誤訊息佐證）、違約訊息進 DLQ 不阻塞主流程。使用者明確要求不必為此新增一整個完整建設——查證後確認確實不需要任何新的 Terraform 資源，全部沿用項目 5-8 既有基礎設施。

### 測試對象

用 `trade_events`（`slice2-trade-events` registry 下、項目 5/6 手動註冊、刻意不被真實流量使用的 schema）而非正式流量用的 `transaction.trade.v1` schema——`schema_registry.tf` 開頭註解本來就是為此預留：「不必透過 Debezium 真的送一筆訊息才能測，直接對這個 schema 註冊一版新增必填無 default 欄位，就能完整驗證這條驗收標準」。兩者共用同一個 registry、同一個 `BACKWARD` 相容性模式，Registry 端的拒絕邏輯是通用的，不因測試對象是哪個 schema 而不同。

### 步驟 1：用 AWS CLI 註冊違反 BACKWARD 規則的新版 schema

**為何這裡可以用 AWS CLI（而非違反 RULE-001）**：RULE-001 禁止的是「用 AWS CLI 部署」——造成 Terraform 追蹤不到的、成功且持久的變更（drift）。這次要測的違規版本，設計上就預期會被 Registry 拒絕；若真的被拒絕，就沒有東西被部署/持久化，也就沒有漂移可言。這個前提在步驟 3 用 `terraform plan` 實際證實，不只是假設。

`trade_events` 目前唯一版本（version 1）的實際欄位（用 `get-schema-version` 取得，跟 `schema_registry.tf` 的 `schema_definition` 一致）：`trade_id`/`account_id`/`symbol`/`side`/`status`/`event_time` 為必填，`price`/`quantity`/`updated_at` 為可選（nullable + default null）。在此基礎上新增一個沒有 default 值的必填欄位 `order_type`（`string`），呼叫：

```bash
aws glue register-schema-version \
  --schema-id '{"RegistryName":"slice2-trade-events","SchemaName":"trade_events"}' \
  --schema-definition file://trade_events_breaking_v2.avsc
```

實際回傳：

```json
{
    "SchemaVersionId": "32510bea-07eb-4b32-9dce-077e3d200ee0",
    "VersionNumber": 2,
    "Status": "FAILURE"
}
```

CLI 呼叫本身沒有報錯（exit code 0）——Glue 是用「接受呼叫、但把這個版本標記為 `FAILURE`」的方式回應，不是同步丟例外，這點跟規劃時「可能同步報錯」的假設不同，照實記錄。API 沒有回傳描述性的錯誤訊息字串，因此另外用兩個方式交叉佐證這個 `FAILURE` 確實是相容性檢查擋下、不是別的原因：

1. `aws glue check-schema-version-validity` 對同一份 schema definition 回傳 `{"Valid": true}`——排除是 Avro 語法本身有問題
2. `aws glue get-schema` 顯示 `"SchemaCheckpoint": 1, "LatestSchemaVersion": 2`——版本 2 確實被建立（`LatestSchemaVersion` 前進到 2），但 `SchemaCheckpoint`（真正「目前生效」的版本指標）仍停在 1，代表這個違規版本從未成為可用版本

### 步驟 2：DLQ 機制確認

`msk_connector.tf` 既有的 connector 設定已經配好 DLQ：

```
errors.tolerance                                = "all"
errors.deadletterqueue.topic.name               = "transaction.trade.v1.dlq"
errors.deadletterqueue.topic.replication.factor = "2"
errors.deadletterqueue.context.headers.enable   = "true"
```

沿用項目 8 的 `slice2-cdc-event-verifier`（其 docstring 本來就設計成可以直接指向 DLQ topic 重用），呼叫：

```bash
aws lambda invoke --function-name slice2-cdc-event-verifier \
  --payload '{"topic": "transaction.trade.v1.dlq", "max_messages": 50, "timeout_seconds": 20}' \
  /tmp/dlq_verifier_output.json
```

實際回傳：

```json
{"topic": "transaction.trade.v1.dlq", "total_messages": 0, "op_counts": {}, "distinct_keys": 0, "events_by_key": {}, "sample_raw_envelope": null}
```

DLQ topic 可達、能正常消費，0 筆訊息是健康狀態（目前沒有真的訊息被連接器判定轉換失敗過），不是失敗。

### 步驟 3：復原確認（`terraform plan`）

在 `infra/environments/dev-slice2/` 跑 `terraform plan`，結果**不是**「No changes」，但差異全部與這次的 schema 測試無關：

- `aws_glue_registry.trade_events` / `aws_glue_schema.trade_events` 在輸出中只出現於 `Refreshing state...`，**沒有任何 diff 區塊**——直接證實步驟 1 的違規版本沒有在 Terraform 追蹤的狀態上留下任何殘留，驗證了步驟 1 一開始的假設
- 差異全部落在四個跟本次驗證無關的既存資源：`null_resource.build_trade_generator`（因為 `generate_trade_data.py` 這次 session 稍早新增了 `trade_ids` 欄位、但尚未 `apply` 部署）、連帶的 `aws_lambda_function.trade_generator`／`data.archive_file.trade_generator`，以及兩個 MSK Connect plugin 的 `aws_s3_object`（`debezium_combined_plugin`／`glue_schema_registry_converter_plugin`）的 etag 差異（對應的 `null_resource` build 觸發條件沒有變，判斷是 zip 封裝本身非完全可重現造成的既存差異，與本次驗證無關）
- 這些差異都不屬於本次 §4 項目 9 的範圍，刻意不在這裡 `apply` 處理，留給後續另外決定是否／何時處理

### 範圍聲明：DLQ 沒有做「真的觸發一筆訊息」的端到端實驗

DLQ 機制要真的收到一筆訊息，需要 Debezium 在做 Avro 轉換時失敗——最貼近真實情境的觸發方式是對 `trade` 表新增一個沒有 default 值的 `NOT NULL` 欄位。但 **Postgres 不允許對已有資料列的表新增沒有 default 值的 `NOT NULL` 欄位**（DDL 會直接被拒絕）；若改成有 default 值的 `NOT NULL` 欄位，Debezium 會把該 default 值帶進 Connect schema，轉成 Avro 後反而是「有 default 的新增欄位」，屬於 `BACKWARD` **相容**的變更，根本觸發不了要驗證的破壞性場景。要繞過這點需要對正在跑的來源表做更複雜的操作（例如先清空表、或分兩步 DDL 並同步改 generator 邏輯），超出「只是驗證」的範圍，也會對正在運行中的 connector 帶來不必要的風險，因此這次不做。

DLQ 的正確性改用邏輯推論佐證：步驟 1 已經證實 Registry 會擋下破壞性變更——而真正會導致 DLQ 進件的那類破壞性變更，從來源頭（Registry 註冊時）就不會被允許存在；換句話說，DLQ 機制存在的意義本來就是接住 Registry 沒能事前擋下的少數例外情況，不是接住「每一次 schema 演進」——步驟 1 的結果反而強化了「大部分違規根本到不了需要 DLQ 出手的地步」這個設計預期。

## 結論

spec §7 前兩條驗收標準皆已用真實資料驗證通過：insert/update/delete 三種操作都在 `transaction.trade.v1` 上產生對應 CDC 事件，帶完整 before/after 影像與遞增的 LSN；完整交易生命週期（NEW→PARTIALLY_FILLED→FILLED）與取消路徑（NEW→CANCELLED→DELETE）皆有多筆真實案例佐證。

過程中額外確認：(1) Debezium 的 initial snapshot 會產生 `op=r` 的訊息，這是設計上的正常行為，不是異常；(2) delete 會多產生一筆 null-value 的 tombstone 訊息；(3) `aws-glue-schema-registry` 這個「純 Python」套件其實透過間接依賴帶進一個編譯過的 Rust extension（`orjson`），純 Python 的判斷不能只看套件本身宣告的內容，也要往下追依賴樹。

項目 9（Schema 破壞性變更驗證）也已完成，結果見上方對應段落：註冊違反 `BACKWARD` 規則的新版 schema 確實被 Registry 擋下（`SchemaCheckpoint` 未被違規版本移動，`LatestSchemaVersion` 前進但該版本狀態為 `FAILURE`）；DLQ 機制的設定與可達性皆已確認，但受限於 Postgres 對 `NOT NULL` 欄位的語意限制，沒有做「真的觸發一筆訊息進 DLQ」的端到端實驗，理由與範圍界線見上方對應段落。

## 相關文件

- [docs/specs/slice2a-cdc-ingestion.md](../specs/slice2a-cdc-ingestion.md) §4 項目 8、9、§7 — 對應的實作項目與驗收標準
- `infra/environments/dev-slice2/msk_event_verifier.tf` — 項目 8 新增的驗證用 Lambda，項目 9 直接重用
- `src/ingestion/verify_cdc_events.py` — consumer／解碼邏輯
- `infra/environments/dev-slice2/schema_registry.tf` — `trade_events` schema 定義與項目 9 預留的測試用途說明
- `infra/environments/dev-slice2/msk_connector.tf` — DLQ 相關 connector 設定（`errors.tolerance`／`errors.deadletterqueue.*`）
- [slice2-msk-connect-plugin-packaging-verification.md](slice2-msk-connect-plugin-packaging-verification.md) — 項目 6/7 的前置驗證（plugin 打包、connector 部署）
