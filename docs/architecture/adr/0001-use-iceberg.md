# ADR-0001: 為何用 Iceberg 而非直接 Parquet on S3

| 屬性 | 值 |
| --- | --- |
| **狀態** | ✅ `Accepted` |
| **日期** | 2026-07-28 |
| **相關模組** | `src/transform`、`infra/environments/dev` |
| **決策者** | Danny |

## 背景 (Context)

Slice0 需要一個能長期演進的批次 Lakehouse 骨架，資料會經過 Bronze/Silver/Gold 三層轉換，且 Slice1 規劃導入 WAP（Write-Audit-Publish）品質關卡，需要在「已寫入但未驗證」與「已驗證可查詢」之間有明確邊界。若直接用 Parquet on S3（無 catalog-level 交易保證），schema 變更、多次 append 的一致性、以及「先寫暫存快照、驗證通過才讓下游看到」這種 pattern 都得自己刻意設計替代方案，複雜度不會比直接用支援這些特性的 table format 低。

## 決策 (Decision)

Bronze/Silver/Gold 三層都採用 Apache Iceberg 作為 table format，以 AWS Glue Data Catalog 當作 Iceberg catalog（`glue_catalog`），而非把資料以純 Parquet 檔案形式直接放在 S3、僅靠檔案路徑/命名慣例組織。

## 理由 (Rationale)

- Schema evolution：Silver 的型別校正（price → decimal、date → date type）、未來欄位增修，Iceberg 支援 `ALTER TABLE` 級別的 schema 演進，不需要重寫整個資料集
- Snapshot isolation / 原子寫入：每次 commit 是一個新 snapshot，讀者不會看到寫入中途的中間狀態；純 Parquet on S3 沒有這層保證，並行讀寫容易看到不一致資料
- 為 Slice1 WAP Gate 鋪路：WAP（Write-Audit-Publish）模式仰賴「先寫入、驗證通過後才讓下游可見」，Iceberg 的 snapshot/time-travel（`AS OF VERSION`）與 branch/tag 機制是實作這個 pattern 的天然基礎；用純 Parquet 得自己刻意設計 staging 區＋rename 這類替代方案
- 與 AWS Glue 原生整合：Glue 5.0 透過 `--datalake-formats=iceberg` 原生支援，不需自行管理 jar，串接 Glue Data Catalog 幾乎零額外設定成本（見 `infra/environments/dev/glue.tf` 的 `--conf` 設定）
- Partition 彈性：Iceberg 的 hidden partitioning 讓 partition 策略可以晚點決定、事後用 `ALTER TABLE ... ADD PARTITION FIELD` 補上，不用重寫既有資料（呼應 spec item 9 刻意延後的決策）

## 影響 (Consequences)

- ✅ **正面**：Bronze/Silver/Gold 可以各自獨立演進 schema 與 partition 策略，不需要協調一次性遷移；為 Slice1 WAP Gate 打好地基
- ⚠️ **注意**：Iceberg 的 metadata（manifest/snapshot）會隨著 commit 次數增加而累積，長期需要 compaction/expire snapshots 維護（Slice0 資料量小，暫不處理，留意後續 Slice 是否要排入）
- ⚠️ **注意**：IAM policy 需要額外授權 Glue Data Catalog 的 CRUD（見 `infra/environments/dev/iam.tf`），比純 S3 read/write 複雜一些
- ❌ **負面/限制**：目前執行環境（AWS Glue Jobs）綁定 Iceberg 版本跟著 Glue Version 走（Glue 5.0 = Iceberg 1.7.1），若未來需要更新版 Iceberg 特性，需搭配升級 Glue Version 或改用 `--extra-jars` 自帶 jar
