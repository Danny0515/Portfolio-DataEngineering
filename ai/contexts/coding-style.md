# Coding Style — 程式碼與測試撰寫風格

> 本文件記錄本專案的程式碼/測試撰寫風格規範，供人與 AI Agent 共同遵守。內容隨專案發展持續擴充，目前只記錄已經實際使用到的規範，不預先定義還沒用到的規則。

## Pytest Marker（測試分類 tag）

`pytest.ini` 目前定義的 marker：

- **`compat`**：驗證特定套件/工具/版本在目前技術棧下是否真的能用（例如新依賴、新執行環境），檢驗的是外部工具的能力，不是專案自己的邏輯。只有在依賴版本升級或技術選型調整時才需要重跑，不屬於一般開發流程的例行測試。
  - **預設排除**：`pytest.ini` 的 `addopts = -m "not compat"` 讓 `uv run pytest` 預設不會執行這類測試
  - **手動執行**：`uv run pytest -m compat`（只跑這類測試）或 `uv run pytest -m ""`（跑全部，含 compat）
  - **標記方式**：整個檔案都是這類測試時，在檔案頂層加 `pytestmark = pytest.mark.compat`；單一測試則用 `@pytest.mark.compat` 裝飾。範例見 [tests/quality/test_gx_spark_validation.py](../../tests/quality/test_gx_spark_validation.py)
