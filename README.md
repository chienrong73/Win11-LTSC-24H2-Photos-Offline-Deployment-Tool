# Win11 LTSC 24H2 Offline App Deployment Tool

**Version:** 2.0.0  
**Status:** Final / 實機驗證完成 ✅  
**封版日期:** 2026-08-21

這是一套以 **Windows PowerShell 5.1 + DISM** 為核心的 Windows 11 LTSC 24H2 離線 AppX / MSIX 部署工具。

目前已完成 **Microsoft Photos + Microsoft Sticky Notes（自黏便籤）** 的完整實機流程驗證：

`Packages 掃描 → Manifest 辨識 → Dependency 解析 → 多 App 選擇 → WIM 掛載 → Dependencies 注入 → Apps 注入 → 驗證 → Commit → ISO 重製 → VM 安裝 → App Provision / 使用者註冊 → 實際啟動`

---

## 1. 已驗證結果

| 項目 | 結果 |
|---|---|
| Windows 11 Enterprise LTSC 24H2 / Build 26100 | ✅ PASS |
| Windows PowerShell 5.1 | ✅ PASS |
| DISM WIM Mount / Commit / Unmount | ✅ PASS |
| 遞迴掃描 AppX / MSIX 套件 | ✅ PASS |
| Manifest-driven 主程式辨識 | ✅ PASS |
| Dependency 自動解析 | ✅ PASS |
| 多 App 選擇 | ✅ PASS |
| 共用 Dependency 去重複 | ✅ PASS |
| `-WhatIf` Dry Run | ✅ PASS |
| Microsoft Sticky Notes 離線注入 | ✅ PASS |
| Microsoft Photos 離線注入 | ✅ PASS |
| ISO 重製與 VM 安裝 | ✅ PASS |
| Provisioned Package 驗證 | ✅ PASS |
| 使用者 AppX Registration 驗證 | ✅ PASS |
| 首次連網啟用後離線使用 | ✅ PASS |

### 實機驗證版本

- `Microsoft.MicrosoftStickyNotes` — **6.1.4.0 / x64**
- `Microsoft.Windows.Photos` — **2026.11060.2004.0 / x64**

實機測試使用 23 個 AppX / MSIX 實體套件；Bundle 解析後共建立 283 筆有效 payload records。兩個主程式皆成功解析為 Ready 狀態。

---

## 2. 已驗證 Dependency Resolution

### Microsoft Sticky Notes

- `Microsoft.VCLibs.140.00` — 14.0.33519.0 x64
- `Microsoft.NET.Native.Runtime.2.2` — 2.2.28604.0 x64
- `Microsoft.NET.Native.Framework.2.2` — 2.2.29512.0 x64

### Microsoft Photos

- `Microsoft.VCLibs.140.00` — 14.0.33519.0 x64
- `Microsoft.WindowsAppRuntime.2` — 2.3.1.0 x64
- `Microsoft.VCLibs.140.00.UWPDesktop` — 14.0.33728.0 x64

共用 Dependency 會在多 App 部署時自動去重複後再注入。

---

## 3. 重要限制：首次啟用需要網路

WIM 離線注入、Provision 與 AppX Registration 均已驗證成功，但目前實測的 Photos 與 Sticky Notes 在 **全新 Windows 第一次完全離線啟動** 時會失敗。

實測事件包括：

- Sticky Notes：TWinUI Event ID **5961**，`PLM prepare for activation`
- Photos：AppModel-Runtime Event ID **203**，錯誤 **0x800704CF**，`LaunchProcess`

兩個 App 在 **第一次接上網路並成功啟動一次** 後，再次斷網均可正常啟動與使用。

> **結論：部署工具本身可完整離線注入 App；目前驗證的 Microsoft Store App 需要第一次連網完成啟用，之後可離線使用。**

此限制屬於 App 首次啟用行為，不是 WIM 注入或 Dependency Resolution 失敗。

---

## 4. 系統需求

- Windows 11 LTSC 24H2
- Minimum Build：**26100**
- Windows PowerShell **5.1**
- 系統管理員權限
- DISM
- x64 Windows
- `.wim` 或 `.esd` Windows Image

預設設定：

```text
ImagePath  = <專案目錄>\install.wim
MountPath  = <專案目錄>\Mount
ImageIndex = 1
PackageRoot = <專案目錄>\Packages
CommitOnSuccess = True
AutoUnmount = True
```

---

## 5. 支援的套件格式

工具會在 `Packages` 目錄下 **遞迴掃描**：

```text
.appx
.appxbundle
.msix
.msixbundle
```

### Packages 資料夾規則

只需要存在：

```text
Packages\
```

子資料夾名稱不參與判斷，也不需要固定結構。

以下都可以：

```text
Packages\Photos\...
Packages\StickyNotes\...
```

或：

```text
Packages\A\...
Packages\B\...
Packages\Dependencies\...
```

甚至全部放在同一層也可以。

主程式、Framework、Resource、Optional 與 Dependency 的分類由 **AppX / MSIX Manifest** 決定，不依賴資料夾名稱。

---

## 6. Dependency Resolution 規則

Dependency 解析依據 Manifest 中的資訊：

- Identity / Name
- Publisher
- MinimumVersion
- Architecture

解析時會：

- 尋找相容 Architecture
- 確認 MinimumVersion
- 選擇符合條件的最高版本
- 多 App 共用 Dependency 自動去重複
- 在掛載 WIM **之前**先檢查 Missing Dependencies

若選取的 App 有缺少 Dependency，正式 WIM 注入不會開始。

---

## 7. 使用方式

將 Windows Image 放在專案根目錄：

```text
install.wim
```

將需要部署的 AppX / MSIX 套件放入：

```text
Packages\
```

以系統管理員 PowerShell 執行：

```powershell
.\Add_Photos.ps1
```

程式會顯示可部署的 Application，例如：

```text
[1] Microsoft.MicrosoftStickyNotes
[2] Microsoft.Windows.Photos

[A] Install All Ready Applications
[Q] Quit
```

選擇方式：

```text
1
1,2
A
Q
```

---

## 8. Dry Run / WhatIf

正式修改 WIM 前，可先執行：

```powershell
.\Add_Photos.ps1 -WhatIf
```

Dry Run 會執行：

- 環境驗證
- Package 掃描
- Manifest 解析
- Dependency Resolution
- App Selection
- DISM 操作流程模擬

但不會真正 Mount、注入或 Commit WIM。

---

## 9. 可用參數

```powershell
.\Add_Photos.ps1 `
    -ImagePath <path> `
    -MountPath <path> `
    -Index <number> `
    -PackageRoot <path> `
    -NoCommit `
    -KeepMounted
```

其中：

- `-ImagePath`：指定 WIM / ESD
- `-MountPath`：指定掛載位置
- `-Index`：指定 Image Index
- `-PackageRoot`：指定 Package 根目錄
- `-NoCommit`：成功後不 Commit
- `-KeepMounted`：完成後保留掛載
- PowerShell Common Parameter `-WhatIf`：Dry Run

---

## 10. 部署順序

正式部署流程：

```text
Pre-deployment Validation
        ↓
Recursive Package Discovery
        ↓
Manifest Parsing
        ↓
Main Application Detection
        ↓
Dependency Resolution
        ↓
Application Selection
        ↓
Mount WIM once
        ↓
Install unique Dependencies first
        ↓
Install selected Applications
        ↓
Verify Provisioned AppX Packages
        ↓
Commit once
        ↓
Unmount
```

如果工具本身掛載的 WIM 在部署中發生失敗，流程會依設計執行失敗處理與清理，避免把未完成的部署當成成功結果。

---

## 11. 專案主要檔案

```text
Add_Photos.ps1
Add_Photos_Offline.bat
Config.ps1
Modules\
    Logger.psm1
    Common.psm1
    Validation.psm1
    Package.psm1
    Dism.psm1
Packages\
Logs\
Tests\
    static_validation.py
```

---

## 12. ISO 驗證流程

完成 WIM 注入後，本專案實測流程為：

1. 將修改後的 `install.wim` 覆蓋回 Windows ISO Source 的 `sources\install.wim`
2. 使用 Windows ADK `oscdimg.exe` 重製 BIOS + UEFI 可開機 ISO
3. 使用新 ISO 建立 / 安裝 VM
4. 驗證：

```powershell
Get-AppxProvisionedPackage -Online |
Where-Object { $_.DisplayName -in 'Microsoft.Windows.Photos','Microsoft.MicrosoftStickyNotes' } |
Select-Object DisplayName,Version,Architecture
```

目前登入使用者驗證：

```powershell
Get-AppxPackage |
Where-Object { $_.Name -in 'Microsoft.Windows.Photos','Microsoft.MicrosoftStickyNotes' } |
Select-Object Name,Version,Architecture,Status
```

實機結果兩者皆成功，且使用者註冊狀態為 `Status = Ok`。

---

## 13. 套件與授權來源

本工具 **不會**：

- 自動從 Microsoft Store 下載 App
- 自動使用 WinGet 取得 App
- 自動取得 Microsoft Store License

使用者需自行準備合法取得的 AppX / MSIX 套件與必要 Dependencies。

---

## 14. v2.0.0 封版結論

**Win11 LTSC 24H2 Offline App Deployment Tool v2.0.0 已完成核心功能與實機端到端驗證。**

已完成：

```text
Package Discovery       PASS
Manifest Parsing        PASS
Dependency Resolution   PASS
Multi-App Selection     PASS
Dry Run                 PASS
WIM Deployment          PASS
Verification            PASS
Commit / Unmount        PASS
ISO Build               PASS
VM Installation         PASS
Photos Provision        PASS
Sticky Notes Provision  PASS
User Registration       PASS
First Online Activation PASS
Offline Use Afterwards  PASS
```

### Final Status

**v2.0.0 — FINAL ✅**

後續新增其他 Microsoft Store App 時，應以既有 Manifest-driven 架構擴充與重新驗證，不應重新加入 Photos / Sticky Notes 專用的硬編碼判斷。
