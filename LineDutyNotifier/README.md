# LINE 出勤通知監測器（Windows 11）

目前版本使用 Windows 通知資料庫收訊，將收到的目標群組通知保存至本機加密佇列，再由獨立程序判讀及推播。啟用 AI 時，候選訊息及可讀附圖會傳至設定的 OpenAI API；不是完全離線的工具。

## 啟動及查看狀態

多人班表版：儀表板右上角新增「班表與人員」，支援全時段當班、人員提前量、圖片／PDF 班表核對、逐人分派與確認。啟用後的新事件優先使用 [多人班表通知規則與操作說明](TEAM-GUIDE.md)；以下舊版立即通知政策保留供尚未啟用及升級前工作使用。

### 本機狀態儀表板

雙擊 `Open-Dashboard.cmd`，或執行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\LineDutyNotifier\Show-NotifierDashboard.ps1
```

這是 Windows WPF 視窗，不需要網站、額外套件或開放網路連接埠。不傳送聊天資料、呼叫 AI 或測試推播；關閉視窗不影響監測器。

- 每次讀取完成後約 5 秒自動更新，也可按「立即更新」。背景讀取不阻塞視窗；超過 20 秒會撤下舊的綠燈。超過 30 秒的狀態快照不會當成最新資料顯示。
- 五項工作會核對執行檔路徑、角色、執行個體及建立時間，避免 PID 被其他程序重用造成假正常。心跳超過 120 秒即警示；收訊器還會檢查最近成功讀取資料庫的時間。儀表板另外顯示實際程序數與依唯一 PID 加總的私有記憶體，並區分已結束的 AI 失敗紀錄與目前重試。
- 顯示今日建立的緊急通知數、待判讀（含剛收進但尚未建立判讀工作的訊息）、待送出、等待手機確認，以及 AI 失敗、推播重試和 24 小時內到期未確認數。
- 顯示今日、本月及最近一次 AI 的 input、output、total token。數字直接取自 Responses API 每次成功回應的 `usage`，以台灣本機日期彙總並存入 DPAPI 加密的 `state/usage`。依 [OpenAI 官方文件](https://help.openai.com/en/articles/10478918-api-usage-dashboard)，Responses 欄位為 `usage.input_tokens`、`usage.output_tokens`、`usage.total_tokens`。
- Token 區只統計此功能更新後、監測器成功收到 `usage` 的請求；舊請求、失敗而未取得回應的請求、其他應用及其他 API 金鑰不在內。它不是帳戶餘額或完整帳單，完整組織用量仍以 [OpenAI Usage Dashboard](https://platform.openai.com/usage) 為準。
- 右上角「官方餘額」會用預設瀏覽器開啟 [OpenAI API 組織 Billing Overview](https://platform.openai.com/settings/organization/billing/overview)。網址固定且不含 API 金鑰或聊天資料；頁面仍需登入具有帳務權限的 OpenAI Platform 帳號。API 帳務與 ChatGPT 訂閱分開。
- 「正常運作」為綠色；「需要留意」為黃色；「需要處理」為紅色；讀取／權限問題顯示「無法確認」，不把失敗當成零筆或正常。
- 近期事件只取最近兩個 monitor 日誌各末 2,000 行，顯示固定中文摘要，不顯示聊天、群組名稱、原始錯誤、通知 receipt 或任何金鑰。最近 30 分鐘錯誤數亦以此讀取範圍計算；AI 失敗數是仍保留失敗狀態的工作累計。
- 設定狀態只表示功能開關及金鑰是否存在，不測試 API 有效性或連線。Pushover 接受通知不代表手機已響鈴；綠燈也不能證明 LINE 沒有漏產生 Windows 通知。
- 請使用與監測器相同的 Windows 帳號；DPAPI 加密狀態不能由其他使用者讀取。`Get-NotifierStatus.ps1` 同步使用相同的唯讀摘要，保留原本 `Workers` 與 `Alerts` 欄位。

儀表板驗證（隔離資料，不影響正式監測）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\LineDutyNotifier\Test-Dashboard.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\LineDutyNotifier\Show-NotifierDashboard.ps1 -SmokeTest
```

### 啟動監測器

使用 Windows PowerShell 5.1：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\LineDutyNotifier\Start-LineDutyNotifier.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\LineDutyNotifier\Get-NotifierStatus.ps1
```

Collector 會自動啟動 Classifier、Sender、Receipts、Scheduler 四項工作。`MultiProcess` 使用五個程序；`SharedHost` 使用獨立收訊器及共用工作宿主，共兩個程序。每個角色有單一實例鎖，避免重複啟動。復原方式及切換步驟見 [低記憶體執行模式](RUNTIME-GUIDE.md)。這不是 Windows 開機自啟服務；Collector 停止後仍需重新啟動。

## 提醒政策

- 已確認的接刀時間或直接出勤指令：立即排入 Confirmed 緊急提醒，不等待 AI。
- 疑似有刀、詢問時間、等待確認：先排入 Review 一般提醒，再交給 AI；AI 確認後追加緊急提醒。
- 圖片通知無法取得照片：Review 提醒「照片缺失，請查看群組」。照片不是從 LINE 相簿或歷史聊天下載，僅支援 Toast 中可讀取且位於本機 LINE 目錄內的附圖。
- AI 逾時／錯誤：一般提醒仍保留，AI 最多嘗試三次。
- 明確取消／不需出勤不產生新的緊急提醒。取消訊息不會自動取消先前已送出的 receipt，避免誤取消其他手術。
- 群組標題與正文分開，只有正文參與語意分類。已知的「好／收到／貼圖」不會僅因群名含「手術」而触發。

### 多句排程與防漏判（2026-09-09）

- 冒號／全形時間後的「接」（例如 `11:30接可嗎`）、加刀／加一台及 ORIF、IVG、VP、K-pin、AO plate 等術式提示，至少進入一般提醒與 AI 審查，不因缺少「手術」兩字而跳過。
- 同群組最近 30 分鐘有未解決的時間提議或詢問時，`8點`、`可以 謝謝大家`、`好，謝謝` 等短答覆會交給 AI，並先建立該答覆的一般提醒；AI 失敗時此提醒及重試仍保留。沒有活動排程的普通回覆不觸發。
- 比對前統一空白與全半形。時間與「接刀」可分散在多句，AI 可連結提議、插話與同意；本機不把每個「好」直接升為緊急。
- 上下文保留同群組最近兩小時的文字，包含短答覆與原先判為無關的文字；不包含未來訊息。同時間戳記以來源順序排除後來訊息，貼圖不佔名額。`Ai.ContextMessageLimit` 有效範圍為 12–30，低於 12 的舊設定以 12 計，避免必要提議被過早擠掉。
- 已明確取消或確認的討論，不因之後的普通「好」重開；新的時間詢問仍可啟動下一段討論。這是有限視窗的保守路由，並非完整的逐病例配對系統；多台手術交錯或太久後才答覆仍可能需要人工核對。
- `NPO時間到下午3點可接刀` 是條件資訊，先交 AI 審查，不直接當成已排定；明確到院指令仍可立即緊急提醒。
- 使用 [OpenAI 官方提示設計指引](https://developers.openai.com/api/docs/guides/prompt-engineering) 的明確規則及正反例方式，保留既有模型、API 介面與結構化回應格式。更完整的候選訊息／上下文會增加部分 AI 用量；不將完整聊天匯出檔送往 API。

判讀統一於 Notifier.Core.ps1 的 Get-LocalDecision 及 New-AiRequest。舊設定檔的 HighConfidenceTerms、ConfirmedSchedulePatterns、UncertainTerms、NegativeTerms、RequiredContextTerms 為舊版欄位，新版不再使用；調整規則後請執行回歸測試。

## 佇列與恢復

state/inbox 保存收到的訊息、圖片、原通知時間及本機判讀；state/processed 保存判讀進度；state/outbox 保存待發通知及 receipt 狀態；state/usage 只保存 AI token 數字與時間。內容用目前 Windows 使用者的 DPAPI 加密，不能直接搬到其他帳號解密。日誌僅記錄事件雜湊、狀態、原因代碼及錯誤類型。

收訊使用 LINE message ID（含內容版本）或通知 ID／到達時間去重，不能用相同文字當成同一事件。收到後先原子寫入 inbox，再建立提醒；中斷後可恢復。每次啟動重新掃描 Windows 資料庫內最近 24 小時仍存在的通知，不再直接跳至最新一筆。已保存的未完成工作不受此 24 小時限制。超過 10 分鐘的補送會標示原通知時間與「延遲補送」。

若 Windows 已清除通知、LINE 沒有產生 Toast 或電腦離線，單靠此來源不能補回不存在的訊息。資料庫複製仍不是正式的通知 API；目前使用新快照、複製失敗重試、失敗後再次掃描來降低遺漏。

## Pushover 傳送

- Confirmed 使用 priority=2、設定的 retry／expire；Review 使用 priority=0，一般單次提醒。
- 新事件不會因同群組 60 秒冷卻被丟掉；緊急待發項目優先處理。
- HTTP 失敗保留 pending，30 秒開始遞增重試，最多間隔 15 分鐘，重啟後繼續。
- accepted 表示 Pushover 服務接受，不代表 iPhone 已響鈴。緊急通知另由 Receipts 工作程序追蹤 acknowledged 或 expired。
- 到期仍未確認會留下 PUSH_EXPIRED_UNACKNOWLEDGED。一般通知不提供同樣的 receipt 確認追蹤。
- 遇到伺服器已接受但本機未收到回應／未保存成功的情況，補送可能重複。此版優先避免漏送，不能宣稱恰好送達一次。
- 舊 AlertLevels／CooldownSeconds 已由此政策取代。

API 金鑰仍從使用者環境變數 OPENAI_API_KEY、PUSHOVER_APP_TOKEN、PUSHOVER_USER_KEY 取得，不寫入設定檔。state、logs 與聊天匯出檔不可公開；已列入 .gitignore。

## 驗證

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\LineDutyNotifier\Test-Reliability.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\LineDutyNotifier\Test-Reliability.ps1 -LiveAi
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\LineDutyNotifier\Test-LanguageRegression.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\LineDutyNotifier\Test-LanguageRegression.ps1 -LiveAi
```

預設以正式函式搭配假的網路回應驗證去重、兩級提醒、失敗補送、重啟恢復、receipt 及圖片缺失，不實際傳送推播。LiveAi 另外使用合成文字和合成圖片呼叫真實 AI，會使用 API 額度，不會發送測試 Pushover。

Test-LanguageRegression 使用不含人名或群組資料的範例句型驗證多句同意、時間答覆、英文術式、禁食條件及防誤報；預設使用模擬 AI，`-LiveAi` 才額外將 8 組範例文字送往真實 AI。模擬測試通過不代表模型準確率，真實 API 測試通過也不能保證所有訊息或照片都不漏報。既有已完成的正式事件不因更新規則而自動重播，以免大量補發舊通知。

狀態檔每 30 秒更新，與過去的一週自動檢查排程獨立。OperationalLog.Until 不再控制新版工作程序的狀態檔。日誌中不得將「程序存在」當成「最後讀取成功」；請使用狀態工具查看 LastSuccessfulReadUtc 和 LastError。
