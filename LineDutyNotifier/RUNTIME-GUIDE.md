# 低記憶體執行模式

## 模式與相容性

`Runtime.ExecutionMode` 可選 `MultiProcess`（原本五程序）或 `SharedHost`（兩程序）。缺少設定時使用 `MultiProcess`；未知值拒絕啟動，避免默默使用錯誤架構。

`SharedHost` 保留獨立 Collector。另一個 Host 程序內各用一個固定執行緒的 PowerShell Runspace 執行 Classifier、Sender、Receipts、Scheduler。五項工作仍各自寫入加密心跳；共用程序不代表單一循序工作迴圈。班表是否啟用、通知對象和語言規則均不改變。

角色 mutex 與團隊資料 mutex 繼續使用；宿主不共用各角色的設定物件、PowerShell 腳本變數或解密聊天。宿主只持有角色識別、執行緒生命週期及合作停止訊號。

## 安全停止與恢復

- Collector 監督 Host。Host 崩潰或退出後，Collector 重新啟動它；角色使用原本的持久化資料恢復工作。
- 角色退出後，宿主先完成 EndInvoke 及 Dispose，再等五秒建立新的執行個體。
- 角色超過 120 秒沒有迴圈進度時，要求合作停止；再等 90 秒仍未結束則標示 blocked。不得強制中止 HTTP、強殺宿主或另外啟動同角色。
- 停止／搬遷沿用 control.json；Host 會等全部角色退出才離開。安全停止逾時會保持停止狀態並回報，不自動強殺。
- 每個角色仍有獨立 WorkerInstanceId；HostInstanceId、PID、啟動命令、設定路徑及宿主成員表共同用於健康驗證。
- 網路端已接受但本機尚未記錄 receipt 時仍有原本的至少一次重試限制，不能保證跨崩潰完全不重複通知。

切換模式需先確認沒有搬遷鎖定，再修改設定並執行 `Restart-NotifierSafely.ps1`。它會安全停止同設定的所有舊角色與宿主，再啟動新模式。若切換或停止失敗，先處理狀態，不得另開第二組監測器。回復時將模式設回 `MultiProcess`，採相同流程；不用遷移資料，也不重播已完成事件。

## 掃描及資源顯示

背景工作每兩秒重新列舉檔案並建立到期候選清單，不再每半秒排序所有歷史通知。執行前仍讀取最新持久化狀態；檔案變更會刷新提示，即使時間戳記未變，最遲每 30 秒重新解密核對。候選超過 4096 筆時改為完整列舉、不快取巨大清單；提示快取上限 2048 筆。不刪除聊天、歷史通知、去重或 receipt 紀錄。

儀表板上方顯示執行模式、實際程序數與私有記憶體總量，下方列出五項工作狀態。共用宿主的記憶體、CPU 是整個程序的數值，不能把四個角色的取樣加總。效能報告新增 `PhysicalProcesses` 與依 PID 去重的最新記憶體總計；歷史取樣本身不證明程序目前仍在執行。

## 驗證與限制

- `Test-SharedRuntime.ps1`：真實隔離程序、模擬網路，驗證兩程序、重複啟動、個別角色退出、慢 AI、宿主崩潰、receipt 恢復、逐人重試及安全停止。
- `Test-SharedRuntimeTimeout.ps1`：只在測試副本縮短逾時，驗證 blocked 角色不被強殺／重複啟動，並測試回復五程序。
- `Test-WorkIndex.ps1`：大量歷史紀錄、到期變更、強制刷新、損壞檔案與快取上限。
- `Test-RuntimeBenchmark.ps1 -Minutes 30 -WarmupMinutes 2`：相同合成資料與模擬流量，比較兩模式，記錄中位數、峰值、CPU、收訊／送出延遲；不連接真實 AI 或 Pushover。
- `Test-RuntimeBenchmark.ps1 -SharedOnly -Minutes 1440 -WarmupMinutes 2`：24 小時隔離耐久測試，完成後安全停止測試程序。測試期間會額外使用一組測試程序與測試控制程序的記憶體。

結果寫入新建的 `artifacts/runtime-benchmark-*`，不含正式群組、金鑰或聊天。必須看實際 result.json；沒有完成檔或有 failure.json，不可宣稱驗證成功。正式切換前要求至少 30 分鐘測量、同機私有記憶體中位數下降至少 25%、無角色／通知可靠性退步；24 小時測試未結束時應明確標示尚待驗證。
