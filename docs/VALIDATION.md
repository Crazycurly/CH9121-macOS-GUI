# 驗證紀錄 — 2026-11-05

## 已完成的 CI 建置

- 原始碼 commit：`a792256189cece6966a08e2380d8754b7b08ae12`
- 版本：**0.1.0，build 3**。
- [GitHub Actions run #3](https://github.com/Crazycurly/CH9121-macOS-GUI/actions/runs/41993886196)：`Test and package Universal macOS app` 工作及所有測試、建置、打包、上傳步驟成功。
- [下載完整 Artifact](https://github.com/Crazycurly/CH9121-macOS-GUI/actions/runs/41993886196/artifacts/13398814824)。另有 `test-results` Artifact。
- macOS runner 執行 **29 項 XCTest，0 failures**：18 項協定與設定測試、11 項真實 loopback UDP socket 測試。測試紀錄的完成時間為 2026-11-05 08:22:37 UTC。
- ARM64 與 x86_64 Release 分別編譯，`lipo` 合併與雙架構檢查通過。
- App bundle ad-hoc 簽署、`codesign --verify --deep --strict` 驗證步驟通過。
- 真正的 App bundle 執行 `--smoke-test`，建立示範視窗並輸出 PNG；此測試不開啟實體網路連線。
- ZIP、DMG、SHA-256 清單及 GUI 預覽成功產出並上傳。
- Release 工作在一般 main push 時略過是預期行為；正式發行工作只由版本 tag 觸發。

## 下載後的獨立檢查

已下載上述 Artifact 並核對 GitHub 回傳的 Artifact SHA-256：

```text
8635967d70340392e93aa39671046072c2794e06b3677ce03cdb9e40645f9bfc
```

解開後，重新計算兩份檔案的 SHA-256，與內附清單一致：

```text
32d53d35f108d5c24b4ebd05fbf987795b67de6d87a1bb016cc5d93ed7183a03  CH9121-Config-macOS-universal.zip
495351ad1b50ee7ada435c773834bd1ada094445ff9c1e4fd46f14eadf6551ae  CH9121-Config-macOS-universal.dmg
```

另以二進位解析確認 ZIP 中的執行檔是含 **x86_64 與 arm64** 的 Mach-O Universal 檔案；兩個 slice 都有 code-signature load command。這項檢查不是在 Linux 上重新驗證 Apple 簽章；實際簽章驗證由上述 macOS CI 的 codesign 執行。

Info.plist 與兩個 Mach-O slice 的最低部署目標均為 **macOS 13.0**，App 版本為 0.1.0 / 3。已檢視產出的示範 GUI 預覽；預覽是介面擷取，不是完整的互動 UI 自動化測試。

## 本次修正

第一輪 macOS 測試與雙架構編譯成功，但 `lipo -verify_arch` 參數順序錯誤造成打包失敗；已修正，未略過架構檢查。第二輪完整打包成功。第三輪進一步讓 CI 示範視窗先顯示、完成 run-loop 繪製，再擷取帶背景的預覽，沒有更改 CH9121 通訊或寫入協定。

## 仍未完成／不涵蓋的驗證

- **尚未連接使用者的實體 CH9121／M10P**；不把 loopback 模擬器測試等同實體相容性認證。
- 尚未在獨立 Intel Mac 或 macOS 13 實機執行；Universal slice 與最低部署目標檢查不取代這些執行測試。
- 未做 Apple Developer ID 簽署或公證；ad-hoc 簽署不代表 Gatekeeper 信任。
- 未驗證所有晶片版本、UART2 硬體差異、非 ASCII 名稱及不同韌體的 RX timeout 單位。
- 原廠 `.cfg` 相容性、CH9121A/T 擴展指令尚未實作。
- 交換器／供電造成的重啟與光達點雲資料解碼不在這次 GUI 驗證範圍。

首次實體測試請依 [FIRST-RUN.md](FIRST-RUN.md)，先搜尋、核對 MAC、讀取並保存設定，再進行小幅可回復的寫入。不要把恢復出廠當作第一個測試步驟。
