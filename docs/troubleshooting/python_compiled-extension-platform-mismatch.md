# Python 編譯依賴的平台不符（本機 macOS vs Lambda Amazon Linux）

> 故障排除筆記，**不是**規格或決策紀錄（那些見 [docs/specs/](../specs/)、[docs/architecture/adr/](../architecture/adr/)）。記錄一個未來換其他套件也可能重複踩到的錯誤模式，目的是讓遇到類似症狀時能快速聯想到「這個之前踩過」。

## 症狀

Lambda 執行期間拋出：

```
ImportModuleError: No module named 'orjson.orjson'
```

`orjson` 是 `aws-glue-schema-registry` 這個 Python 套件的間接依賴，本機（macOS）用一般 `pip install` 打包 Lambda 部署包時會踩到。

## 根因

`orjson` 是用 Rust 編譯的原生擴充套件（native extension），不是純 Python 檔案——PyPI 上為每個作業系統/CPU 架構各自發布對應的 wheel（例如 `*-macosx_*.whl`、`*-manylinux_*.whl`）。一般 `pip install` 預設依照**本機環境**判斷該抓哪個 wheel；本機是 macOS，抓到的自然是 macOS 版本的編譯產物。但 Lambda 執行環境是 Amazon Linux（x86_64），兩者的二進位介面（ABI）不相容，macOS 版本編譯出的擴充模組在 Lambda 上載入不了，才會出現 `No module named 'orjson.orjson'`——模組檔案雖然在部署包裡，但因為是不相容的二進位格式，Python 判定成「找不到」。

## 解法

用 `pip install` 明確指定目標平台，強制抓 Linux 版本的預編譯 wheel，不讓 pip 依本機環境自動判斷：

```bash
python3 -m pip install --quiet \
  --platform manylinux2014_x86_64 --implementation cp --python-version 3.12 \
  --only-binary=:all: --target <build_dir> \
  kafka-python-ng aws-glue-schema-registry
```

- `--platform manylinux2014_x86_64`：強制抓 Linux x86_64 的 wheel
- `--implementation cp --python-version 3.12`：對齊 Lambda runtime 的 CPython 版本
- `--only-binary=:all:`：禁止 pip 退回原始碼在本機編譯（本機編譯出來的一樣是 macOS 二進位，這個 flag 確保一定是抓現成的 Linux 預編譯版本，而不是找不到對應 wheel 時嘗試在本機生一份）

已實測確認能抓到正確版本並在 Lambda 上正常載入。

## 辨識線索

- 任何 Python 依賴鏈裡只要有**編譯過的原生擴充套件**（C extension 或 Rust extension），本機打包 Lambda 部署包時都可能踩到這個問題——不限於 `orjson`，常見的還有 `pydantic-core`、`cryptography`、`numpy`、`grpcio` 等
- 判斷方法：套件在 PyPI 上有沒有平台專屬的 wheel 檔名（`macosx`/`manylinux`/`win`），有就代表是編譯依賴
- 這個問題**經常藏在間接依賴裡**（像這次的 orjson 是透過 `aws-glue-schema-registry` 帶進來的），檢查直接依賴清單看不出來，要往下追依賴樹
- 本機開發機是 macOS、部署目標是 Lambda（Linux）的專案，凡是新增 Python 依賴都該養成習慣先用同一組 `--platform`/`--only-binary` flag 打包測試，而不是等 Lambda 噴錯才回頭查

## 相關

- [docs/specs/slice2a-cdc-ingestion.md](../specs/slice2a-cdc-ingestion.md) §4 項目 8 — 本次踩坑對應的實作項目（CDC 事件驗證）
- [infra/environments/dev-slice2/msk_event_verifier.tf](../../infra/environments/dev-slice2/msk_event_verifier.tf) — 修正後的打包指令與完整註解
