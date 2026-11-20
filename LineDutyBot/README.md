# LINE 出勤通知 Bot

此服務用 LINE Messaging API 的 webhook 接收 Bot 所在群組的新訊息，判讀出勤需求後通知群組與已綁定的當日值班者。它不讀取 LINE 帳號歷史紀錄。

## 安裝與啟動

1. 複製 `dutybot.settings.example.json` 為 `dutybot.settings.json`；首次收到群組的 join event 後，將該 `groupId` 填入 `AllowedGroupIds`。
2. 在 LINE Developers Console 建立 Messaging API Channel，開啟 **Allow bot to join group chats**，設定 webhook 為 `https://你的網域/line/webhook`，並讓 HTTPS 反向代理轉送到本機 `http://127.0.0.1:8080/`。
3. 以使用者環境變數設定 `LINE_CHANNEL_SECRET` 和 `LINE_CHANNEL_ACCESS_TOKEN`。若啟用 AI，另設定 `OPENAI_API_KEY`。
4. 以系統管理員開啟 PowerShell（HttpListener 的 URL ACL 需依院內規範設定），執行：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\LineDutyBot\Start-LineDutyBot.ps1
```

## 日常操作

- 值班人員先在一對一聊天室傳送 `綁定值班`。
- 管理者在群組傳送 `/值班 <LINE user ID>,<LINE user ID>` 設定當日人員；`/值班表` 查看，`/提醒 <說明>` 手動派送，`/取消 D...` 取消未完成案件。
- 值班者點選「確認到院／無法出勤／轉交管理者」按鈕。未確認案件在設定的分鐘數後自動升級。

## Pushover 持續提醒（選用）

在 iPhone 安裝 Pushover、建立帳號，並在 Pushover 網站建立一個應用程式後，將其 App Token 設為 `PUSHOVER_APP_TOKEN`。每位要接收提醒的人，將自己的 User Key 設為設定檔 `UserKeyEnvironmentVariables` 所列的環境變數，例如 `PUSHOVER_USER_KEY`。

將 `Pushover.Enabled` 改為 `true` 後，Bot 在建立確認出勤案件時，會送出 Emergency Priority 提醒：預設每 30 秒重複、最長 30 分鐘，須在 Pushover app 內確認才停止。Pushover 內容只包含案件編號與判讀原因，不含原始群組訊息。

## 資料與資安

- `state/dutybot-state.json` 存放最低必要的去識別化案件摘要、值班名單與稽核記錄；檔案夾須僅授權服務帳號與管理者。
- 保留期限由 `RetentionDays` 控制。請將 `state/` 納入備份與存取權限政策，勿提交至版本控制。
- AI 預設關閉。開啟後僅會送出規則篩選後、經遮蔽電話與長編號等資料的短暫上下文；仍應由院方核准資料處理流程。
- 服務本身只監聽 HTTP 供受控反向代理使用；請勿直接以 HTTP 對外公開。
