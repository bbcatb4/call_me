# LINE 出勤通知系統

Windows 11 本機工具：監測 LINE 電腦版的通知預覽，依規則與可選 AI 語意判讀出勤訊息，並可用 Pushover 發送 iPhone 緊急重複提醒。

可選擇兩種模式：

- [LINE 官方 Bot（建議）](LineDutyBot/README.md)：使用 Messaging API webhook，適合院內／自有伺服器長期運行。
- [Windows 通知監測器](LineDutyNotifier/README.md)：監測本機 LINE 電腦版的通知預覽，不需將 Bot 加入群組。

此 repository 不包含 API 金鑰或本機設定。請從各模式的 `*.example.json` 複製建立本機設定檔。

## 0.2.0 原始碼

- Windows 桌面啟動器、首次設定及加密搬遷：[快速開始](PORTABLE-QUICKSTART.md)。
- 人員管理、逐人推播與確認、可選班表分派：[多人通知說明](LineDutyNotifier/TEAM-GUIDE.md)。
- 五項背景工作可使用兩個程序運作：[低記憶體模式](LineDutyNotifier/RUNTIME-GUIDE.md)。
- 本機儀表板顯示工作狀態、實際程序記憶體及 AI token 用量。

此更新提供原始碼與測試；不包含個人設定、聊天匯出、教學輸出、執行狀態或預先建置的 EXE。建置方式見 `Build-Portable.ps1`；環境限制見 [驗證紀錄](PORTABLE-VALIDATION.md)。24 小時耐久測試尚無完整通過紀錄，不宣稱已完成長時間穩定性驗證。

## 未來擴充方向

- **PingMe 多通路通知**：保留目前的 Pushover 緊急重複提醒，未來可選擇透過 [PingMe](https://github.com/kha7iq/pingme) 路由至 Telegram、Email、Discord、LINE 等額外通知管道。
