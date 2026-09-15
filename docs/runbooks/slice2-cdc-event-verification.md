# Runbook: CDC 事件驗證（insert/update/delete → Kafka topic）

## 背景 (Why)

對應 [docs/specs/slice2a-cdc-ingestion.md](../specs/slice2a-cdc-ingestion.md) §4 項目 8、§7 驗收標準前兩條。§4 項目 7 已經把 `aws_mskconnect_connector.debezium_postgres` 部署成 `RUNNING`，但只確認了「連線建立成功」，還沒有真的證明「來源 DB 的異動會變成帶 before/after 影像與 LSN 的 CDC 事件」。這份 runbook 是本專案第一次寫 Kafka consumer 程式碼、第一次真的解碼 Debezium 產生的 Avro envelope。

## 範圍限制

只驗證 spec §7 前兩條：(1) insert/update/delete 三種操作都出現在 `transaction.trade.v1` topic 上，且帶 before/after 影像與來源變更序（LSN）；(2) 一筆交易走完 NEW→PARTIALLY_FILLED→FILLED 完整狀態機時，topic 上能看到對應的完整事件軌跡。**不涵蓋** DLQ／schema 破壞性變更驗證（§4 項目 9）、端到端延遲 SLA（Slice 2b 的非目標）。依 §2 非目標段落「用 consumer 印出訊息即為驗收」的定位，這是一次性檢查工具，不是常駐服務。

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

## 結論

spec §7 前兩條驗收標準皆已用真實資料驗證通過：insert/update/delete 三種操作都在 `transaction.trade.v1` 上產生對應 CDC 事件，帶完整 before/after 影像與遞增的 LSN；完整交易生命週期（NEW→PARTIALLY_FILLED→FILLED）與取消路徑（NEW→CANCELLED→DELETE）皆有多筆真實案例佐證。

過程中額外確認：(1) Debezium 的 initial snapshot 會產生 `op=r` 的訊息，這是設計上的正常行為，不是異常；(2) delete 會多產生一筆 null-value 的 tombstone 訊息；(3) `aws-glue-schema-registry` 這個「純 Python」套件其實透過間接依賴帶進一個編譯過的 Rust extension（`orjson`），純 Python 的判斷不能只看套件本身宣告的內容，也要往下追依賴樹。

留給項目 9：Schema 破壞性變更驗證（註冊違反 `BACKWARD` 規則的新 schema）與 DLQ 行為——`verify_cdc_events.py` 已刻意設計成可以直接傳 `topic="transaction.trade.v1.dlq"` 重用，不需要改程式碼。

## 相關文件

- [docs/specs/slice2a-cdc-ingestion.md](../specs/slice2a-cdc-ingestion.md) §4 項目 8、§7 — 對應的實作項目與驗收標準
- `infra/environments/dev-slice2/msk_event_verifier.tf` — 本次新增的驗證用 Lambda
- `src/ingestion/verify_cdc_events.py` — consumer／解碼邏輯
- [slice2-msk-connect-plugin-packaging-verification.md](slice2-msk-connect-plugin-packaging-verification.md) — 項目 6/7 的前置驗證（plugin 打包、connector 部署）
