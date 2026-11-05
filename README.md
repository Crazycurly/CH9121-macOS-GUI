# CH9121 Config for macOS

[![Build macOS app](https://github.com/Crazycurly/CH9121-macOS-GUI/actions/workflows/build.yml/badge.svg)](https://github.com/Crazycurly/CH9121-macOS-GUI/actions/workflows/build.yml)

原生 **SwiftUI / AppKit** 圖形設定程式，透過 Ethernet 搜尋與設定 CH9121。目標系統 **macOS 13+**，打包產物為 **Apple Silicon + Intel Universal App**。不需要 Windows、Wine、Python、Go、USB–TTL 或管理員權限。

> 這是獨立開發的工具，**不是 WCH 官方產品**。以使用者提供的《串口改网口模块设置说明》中的基本版 NetModuleConfig 介面為目標。實體 CH9121／M10P 的相容性仍需驗證；不宣稱所有型號、韌體與原廠檔案格式完全相容。

## 下載

開啟 [GitHub Actions](https://github.com/Crazycurly/CH9121-macOS-GUI/actions/workflows/build.yml)，選擇成功的 `Build macOS app` 執行紀錄，在 **Artifacts** 下載 `CH9121-Config-macOS-universal`。

解開 Artifact 後包含：

| 檔案 | 用途 |
|---|---|
| `CH9121-Config-macOS-universal.dmg` | 安裝映像，將 App 拖到 Applications |
| `CH9121-Config-macOS-universal.zip` | 直接解出 `CH9121 Config.app` |
| `SHA256SUMS.txt` | ZIP／DMG 的 SHA-256 校驗碼 |
| `CH9121-Config-preview.png` | CI 啟動真正 GUI 後產生的示範截圖 |

另有 `test-results` Artifact 提供測試紀錄。Actions Artifact 可能需要登入 GitHub；保留期限以執行紀錄為準。發行 tag 成功編譯後，產物也會出現在 [Releases](https://github.com/Crazycurly/CH9121-macOS-GUI/releases)。

**簽署狀態：ad-hoc 簽署，未做 Apple Developer ID 簽署／公證。** 第一次開啟若受到系統阻擋，確認來源後，使用「系統設定 → 隱私權與安全性」針對這個 App 的個別允許開啟流程；不要全域關閉 Gatekeeper。第一次搜尋時若出現區域網路權限提示，請允許。

## 功能

| 類別 | 內容 |
|---|---|
| 網卡與搜尋 | 列出 IPv4／MAC、刷新網卡、指定介面 UDP 廣播、設備名稱／IP／MAC／版本、雙擊讀取 |
| 基礎設定 | 名稱、DHCP、IPv4、遮罩、閘道、串口協商配置；MAC 唯讀 |
| 雙串口 | UART1、UART2；TCP Server／Client、UDP Server／Client；本地埠、隨機埠、目的 IP／域名與埠 |
| 串口參數 | 自訂 baud（包含 **512000**）、5–8 資料位、1／2 停止位、None／Odd／Even／Mark／Space |
| 打包與連線 | RX 長度、逾時原始值、斷線關閉、建立連線時清空緩衝區 |
| 寫入與還原 | 變更確認、自動備份、重新讀取排除外部修改、單次寫入、重啟後讀回核對、出廠還原 |
| 檔案 | 自有 JSON 備份儲存／載入；跨設備匯入不覆寫目標識別與保留欄位 |
| 輔助工具 | M10／M10P／N10／N10P 預設、無網路封包的示範模式、通訊紀錄與 HEX 封包匯出 |

功能實作不等於實體相容性認證。輔助 UART2 的可用行為仍取決於晶片與韌體。

## M10P 首次使用

先閱讀 [首次連線檢查](docs/FIRST-RUN.md)。使用已確認能正常運作的交換器或 Ethernet 連線，選擇真正接到模組的網卡，不要假設一定是 `en0`。

1. 搜尋設備、核對 MAC、讀取設定，先保存 JSON 備份。
2. 選擇 **M10P**，確認接收電腦 IP，按「填入預設」。此時只修改畫面，不會寫入裝置。
3. 核對參數後按「寫入設定」，確認變更並等候讀回核對。

手冊的 M10P 預設：**UDP CLIENT、本地埠 2369、目的埠 2368、512000 baud、8N1**。接收 IP 預設取自選取的網卡，可手動修改，不會寫死為手冊範例 `192.168.1.102`。設備 IP／遮罩／閘道與 UART2 不會因套用預設而擅自更改。

M10／N10／N10P 預設 baud 分別為 460800／230400／460800。這些值來自提供的模組手冊，不代表所有廠牌同名雷達通用。

## 建置與開發

本 repo 已接好 GitHub Actions，不需要另外建立 repo 或提供 token。Push 到 `main`、pull request 與手動 `Run workflow` 均可觸發建置。

macOS 安裝 Xcode Command Line Tools 或完整 Xcode 後：

```bash
git clone https://github.com/Crazycurly/CH9121-macOS-GUI.git
cd CH9121-macOS-GUI
swift test
bash scripts/build-macos.sh
open 'dist/CH9121 Config.app'
```

無硬體示範：

```bash
open 'dist/CH9121 Config.app' --args --demo
```

Linux 可執行 `swift test` 驗證協定及實際 loopback UDP socket；Linux executable 只提供平台提示，不是 Mac GUI。

### CI 與發行

Workflow 使用 `macos-15`：先跑測試，接著分別編譯 ARM64／x86_64、用 `lipo` 合併、ad-hoc 簽署與驗證、啟動真正 App bundle 的無網路 GUI smoke test、擷取截圖，再打包 ZIP／DMG。失敗步驟不會被當成編譯成功；測試紀錄仍會嘗試上傳。

正式建立版本 tag 時：

```bash
git tag v0.1.0
git push origin v0.1.0
```

成功後 Release job 會發布同一份產物。一般建置只有 `contents: read`；只有 tag Release job 使用 `contents: write` 與 GitHub 提供的 `GITHUB_TOKEN`，不需要額外 secrets。

## 寫入保護與已知限制

自動備份位於 `~/Library/Application Support/CH9121Config/Backups/`，不會自動上傳。寫入前重新 GET，若設定與原先讀取時不同會拒絕覆寫；編輯基於最新 payload，保留未編輯欄位、MAC、韌體識別、端口序號與保留區。

SET 與出廠還原每次只傳一次。ACK 遺失不會反覆寫 flash；成功提示需經過獨立 GET 讀回核對。「結果未確認」時請重新搜尋／讀取，勿反覆寫入。**恢復出廠不是一般重新啟動**，會清除雷達所需參數。

- 原廠 `.cfg` 匯入／匯出尚未支援，本版使用自有 JSON。
- CH9121A/T 額外擴展命令、DNS 與流控／協定轉換等進階功能尚未實作。
- RX timeout 顯示原始值；舊工具 10 ms 與新 A/T 文件 5 ms 的差異不自動猜測換算。
- 停止位只接受原始值 1／2；其他值會顯示未知並拒絕寫入。
- 名稱最多 20 bytes，新輸入使用 UTF-8；非 ASCII 名稱互通性尚未驗證，建議先使用 ASCII。
- 須位於同一二層網路；廣播不穿過一般路由、Tailscale 或 VLAN 隔離。本程式不會修改 Mac 的 IP。
- 不修復交換器／供電造成的模組重啟，也不提供光達點雲解碼。
- MAC 核對不是密碼學驗證；請在可信任的區域網路使用。紀錄可能含內網 IP／MAC，分享前請檢查。

## 原始資料與程式結構

[協定欄位與來源](docs/PROTOCOL.md) 記錄封包依據、來源間的差異與保留策略。本程式是獨立 Swift/C 實作，沒有嵌入原廠 Windows 執行檔、第三方依賴或使用者的 Word 手冊。

```text
Sources/CH9121Config/     SwiftUI / AppKit GUI
Sources/CH9121Core/       協定、驗證、JSON、UDP 交易及讀回
Sources/CNet/             Darwin / Linux 網卡與 socket bridge
Tests/CH9121CoreTests/    18 項封包測試 + 11 項 loopback UDP 測試
scripts/build-macos.sh   Universal App、簽署、截圖、ZIP／DMG
.github/workflows/       自動測試、編譯、Artifact 與 tag Release
```

MIT License。實體裝置驗證尚未完成；請以 Actions 執行結果確認特定 commit 的建置狀態。
