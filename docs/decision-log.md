# Decision Log

> 跨 Slice 累積的技術選型決策索引。每筆條目是輕量索引——完整背景/理由留在原始 spec 章節，這裡只記「選了什麼、為什麼、隸屬哪個 ADR」，避免與 spec/ADR 內容重複。定位見 [execution-roadmap.md](../execution-roadmap.md) §3「每個 Slice 的完成 Gate」步驟 4：ADR 記大架構決策，Decision Log 記支撐該決策的技術選型細節。

| 日期 | 決策 | 隸屬 ADR | 詳細理由 |
| --- | --- | --- | --- |
| 2026-08-07 | Slice1 品質檢核工具選 **Great Expectations**，不選 Soda Core | [ADR-0004](architecture/adr/0004-wap-quality-gate.md) | [slice1-quality-contract.md §3.1](specs/slice1-quality-contract.md#31-品質檢核工具great-expectations-vs-soda-core) |
| 2026-08-07 | Slice1 WAP 暫存機制選 **Iceberg 原生 branch**，不降級為手動 staging table（AWS 環境已驗證支援） | [ADR-0004](architecture/adr/0004-wap-quality-gate.md) | [slice1-quality-contract.md §3.2](specs/slice1-quality-contract.md#32-wap-暫存分支機制iceberg-原生-branch-vs-手動-staging-table) |
| 2026-08-07 | Slice1 Data Contract 涵蓋範圍選**限縮版**：Silver 完整品質規則 + Gold schema-only，不含聚合一致性檢查 | [ADR-0004](architecture/adr/0004-wap-quality-gate.md) | [slice1-quality-contract.md §3.4](specs/slice1-quality-contract.md#34-data-contract-範圍) |
