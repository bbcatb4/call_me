# LINE 出勤通知監測器（Windows 11）

這是完全本機執行的工具。它使用 Windows UI Automation 讀取「當下出現」的 LINE 通知視窗，不會登入 LINE、讀取聊天紀錄或把訊息上傳。

## 使用方式

1. 先複製 `appsettings.example.json` 為 `appsettings.json`：

```powershell
Copy-Item .\LineDutyNotifier\appsettings.example.json .\LineDutyNotifier\appsettings.json
```

2. 開啟本機的 `appsettings.json`，填入目標群組名稱；可同時設定多個群組。
3. 依群組慣用語，增刪 `HighConfidenceTerms`、`UncertainTerms`、`NegativeTerms`。
4. 在此資料夾開啟 **Windows PowerShell**，執行：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\LineDutyNotifier\Start-LineDutyNotifier.ps1
```

程式會在偵測到目標群組的新 LINE 通知後顯示 Windows 提醒。記錄檔位於 `LineDutyNotifier\logs`。保持 PowerShell 視窗開啟就是持續監測；按 `Ctrl+C` 可結束。

`appsettings.json`、`logs` 與 LINE 聊天匯出檔都已列入 `.gitignore`，請不要將它們加入公開 repository。

## 啟用混合式語意判讀（選用）

預設完全本機執行。若要讓工具辨識日期、夜班、職務、缺額需求，並結合最近幾則通知理解「我可以」對應的問題，可在 `appsettings.json` 將 `Ai.Enabled` 改為 `true`。

最快的設定方式是在此資料夾執行：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\LineDutyNotifier\Set-OpenAIKey.ps1
```

接著將 API 金鑰存為使用者環境變數（不要寫進設定檔或傳給任何人）：

```powershell
[Environment]::SetEnvironmentVariable('OPENAI_API_KEY', '你的 API 金鑰', 'User')
```

重新開啟 PowerShell 後再啟動監測器。啟用時，只有通過本機群組與出勤詞篩選的通知，以及同群組最近最多六則候選通知，會傳送給 `Ai.Endpoint` 做判讀；API 要求含 `store: false`。若 API 未設定、無法連線或回應格式不符，工具會自動退回本機規則，不會中斷監測。

## 必要條件與限制

- LINE 電腦版必須開啟通知及訊息預覽，Windows 也不可處於專注模式／勿擾。
- 這只會看到程式執行期間彈出的新通知，不會讀取 LINE 歷史訊息。
- 第一次請保留 `LogAllCandidateNotifications: true`，確認通知中的群組名稱實際長相；若群組名稱沒有出現在通知預覽，這種方法就無法可靠地限制到單一群組。
- 請勿把記錄檔傳給他人，因為其中可能包含通知的文字。

## 啟用 iPhone 持續響鈴（Pushover，選用）

1. 在 iPhone 安裝 Pushover，建立帳號並記下 **User Key**。
2. 登入 Pushover 網站的 [應用程式頁面](https://pushover.net/apps/build)，建立一個名為 `LINE 出勤通知` 的應用程式，取得 **API Token/Key**。
3. 在 PowerShell 安全輸入兩個值（輸入時不會顯示）：

```powershell
$value = Read-Host '貼上 Pushover App Token' -AsSecureString
$pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($value)
[Environment]::SetEnvironmentVariable('PUSHOVER_APP_TOKEN', [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer), 'User')
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
```

```powershell
$value = Read-Host '貼上 Pushover User Key' -AsSecureString
$pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($value)
[Environment]::SetEnvironmentVariable('PUSHOVER_USER_KEY', [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer), 'User')
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
```

4. 將 `Pushover.Enabled` 改為 `true`，關閉並重新開啟 PowerShell，再啟動監測器。

預設只在 `Confirmed` 時傳送 Emergency Priority 通知：每 30 秒重複、最長 30 分鐘，須在 Pushover app 內確認才停止。可在設定檔調整 `RetrySeconds`、`ExpireSeconds` 與 `Sound`。
