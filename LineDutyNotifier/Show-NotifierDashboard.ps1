# Native read-only WPF dashboard. No HTTP server, listening port or remote assets.
param([string]$ConfigPath=(Join-Path $PSScriptRoot 'appsettings.json'),[string]$PreviewPath='',[ValidateSet('live','error','unknown')][string]$PreviewState='live',[switch]$SmokeTest)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Dashboard.View.ps1')
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$reader=[Xml.XmlReader]::Create((Join-Path $PSScriptRoot 'Dashboard.xaml'))
try {$script:Window=[Windows.Markup.XamlReader]::Load($reader)} finally {$reader.Dispose()}
$script:View=@{}
foreach($name in @('OpenBillingButton','RefreshButton','UpdatedText','OverviewBorder','OverviewTitle','OverviewDetail','WorkersGrid','MetricsGrid','QueueDetail','UsageGrid','UsageDetail','EventsList','NoEventsText','AiSetting','PushSetting','GroupSetting','IssuesText')){$script:View[$name]=$script:Window.FindName($name)}
$script:OfficialBillingUrl='https://platform.openai.com/settings/organization/billing/overview'
$script:View.ManageTeamButton=$script:Window.FindName('ManageTeamButton')
$script:View.RuntimeText=$script:Window.FindName('RuntimeText')
$script:Colors=@{ok='#14805E';warning='#AD650C';error='#C43B3B';unknown='#64748B'}
$script:Backgrounds=@{ok='#E3F4EC';warning='#FFF2D9';error='#FCE8E8';unknown='#E7EDF4'}
$script:Labels=@{ok='正常運作';warning='需要留意';error='需要處理';unknown='無法確認'}
$script:Reasons=@{healthy='心跳正常';health_missing='沒有心跳紀錄';health_unreadable='無法讀取心跳';process_access_failed='無法核對程序';process_not_found_or_reused='程序已停止或身分不符';invalid_heartbeat='心跳時間無效';heartbeat_stale='心跳超過 2 分鐘';worker_error='工作程序回報錯誤';read_not_fresh='尚無近期成功收訊紀錄'}
$script:WorkerControls=@{};$script:MetricControls=@{};$script:UsageControls=@{}
$script:RuntimeControls=@{}
function New-DashboardText([string]$Text,[int]$Size=14,[string]$Color='#263548'){
    $block=New-Object Windows.Controls.TextBlock
    $block.Text=$Text;$block.FontSize=$Size;$block.Foreground=$Color;$block.TextWrapping='Wrap'
    return $block
}
function New-DashboardCard {
    $border=New-Object Windows.Controls.Border
    $border.Style=$script:Window.FindResource('Card');$border.Margin='5,0,5,0'
    $panel=New-Object Windows.Controls.StackPanel;$border.Child=$panel
    return [pscustomobject]@{Border=$border;Panel=$panel}
}
$roleLabels=@{Collector='01  Windows 收訊';Classifier='02  AI 語意判讀';Sender='03  Pushover 推播';Receipts='04  手機確認追蹤';Scheduler='05  接刀排程'}
foreach($spec in @(@('Mode','執行模式','各項工作分開運作'),@('Count','實際背景程序','不是五項工作各開一個程序'),@('Memory','監測器記憶體總量','私有記憶體・共用程序只計一次'))){
    $card=New-DashboardCard;$card.Border.Padding='16,12'
    [void]$card.Panel.Children.Add((New-DashboardText $spec[1] 12 '#64748B'))
    $value=New-DashboardText '—' 25;$value.FontWeight='Bold';$value.Margin='0,5,0,4'
    $detail=New-DashboardText $spec[2] 11 '#64748B'
    [void]$card.Panel.Children.Add($value);[void]$card.Panel.Children.Add($detail)
    [void]$script:Window.FindName('RuntimeGrid').Children.Add($card.Border)
    $script:RuntimeControls[$spec[0]]=@{Value=$value;Detail=$detail}
}
$dashboardRoles=@('Collector','Classifier','Sender','Receipts')
if(Test-Path (Join-Path (Split-Path $ConfigPath) 'state/team/model.dat')){$dashboardRoles+=@('Scheduler');$script:View.WorkersGrid.Columns=5}
foreach($role in $dashboardRoles){
    $card=New-DashboardCard
    $title=New-DashboardText $roleLabels[$role] 13 '#64748B'
    $status=New-DashboardText '檢查中' 21;$status.Margin='0,12,0,8';$status.FontWeight='Bold'
    $detail=New-DashboardText '等待資料' 12 '#64748B';$detail.MinHeight=38
    $stamp=New-DashboardText '' 11 '#64748B';$stamp.Margin='0,8,0,0'
    foreach($item in @($title,$status,$detail,$stamp)){[void]$card.Panel.Children.Add($item)}
    [void]$script:View.WorkersGrid.Children.Add($card.Border)
    $script:WorkerControls[$role]=@{Status=$status;Detail=$detail;Stamp=$stamp}
}
$metrics=@(@('ConfirmedToday','今日緊急通知'),@('AiPending','等待判讀'),@('PushPending','等待送出'),@('AwaitingAcknowledgement','等待手機確認'))
foreach($metric in $metrics){
    $card=New-DashboardCard
    [void]$card.Panel.Children.Add((New-DashboardText $metric[1] 13 '#64748B'))
    $value=New-DashboardText '—' 32;$value.FontWeight='Bold';$value.Margin='0,8,0,0'
    [void]$card.Panel.Children.Add($value);[void]$script:View.MetricsGrid.Children.Add($card.Border)
    $script:MetricControls[$metric[0]]=$value
}
$usageMetrics=@(@('Today','今日使用'),@('Month','本月使用'),@('Last','最近一次'))
foreach($metric in $usageMetrics){
    $card=New-DashboardCard
    [void]$card.Panel.Children.Add((New-DashboardText $metric[1] 13 '#64748B'))
    $value=New-DashboardText '—' 30;$value.FontWeight='Bold';$value.Margin='0,8,0,5'
    $detail=New-DashboardText '等待資料' 11 '#64748B'
    [void]$card.Panel.Children.Add($value);[void]$card.Panel.Children.Add($detail);[void]$script:View.UsageGrid.Children.Add($card.Border)
    $script:UsageControls[$metric[0]]=@{Value=$value;Detail=$detail}
}
function Set-DashboardUnavailable([string]$Message) {
    $script:View.OverviewTitle.Text='無法確認最新狀態'
    $script:View.OverviewBorder.Background=$script:Backgrounds.unknown
    $script:View.OverviewDetail.Text=$Message
    $script:View.RuntimeText.Text='實際程序記憶體：無法確認'
    foreach($controls in $script:RuntimeControls.Values){$controls.Value.Text='—';$controls.Detail.Text='等待最新資料'}
    foreach($controls in $script:WorkerControls.Values){$controls.Status.Text='資料未更新';$controls.Status.Foreground=$script:Colors.unknown;$controls.Detail.Text='請勿將舊畫面視為目前正常';$controls.Stamp.Text=''}
    foreach($control in $script:MetricControls.Values){$control.Text='—'}
    foreach($control in $script:UsageControls.Values){$control.Value.Text='—';$control.Detail.Text='無法讀取'}
    $script:View.AiSetting.Text='AI：目前無法確認';$script:View.PushSetting.Text='Pushover：目前無法確認'
    $script:View.GroupSetting.Text='群組篩選：目前無法確認'
    $script:View.QueueDetail.Text='無最新資料；未執行任何啟動、停止或重送操作。'
    $script:View.UsageDetail.Text='Token 用量暫時無法讀取；不會以 0 代替缺失資料。'
    $script:View.EventsList.ItemsSource=@();$script:View.NoEventsText.Visibility='Visible';$script:View.NoEventsText.Text='最近紀錄暫時無法讀取'
}
function Update-DashboardView($Snapshot) {
    $age=([datetime]::UtcNow-([datetime]$Snapshot.GeneratedUtc).ToUniversalTime()).TotalSeconds
    if($age -gt 30 -or $age -lt -5){throw 'SnapshotTooOld'}
    $state=[string]$Snapshot.Overall
    if(-not $script:Labels.ContainsKey($state)){throw 'InvalidSnapshot'}
    $runtimeView=Get-DashboardRuntimeView $Snapshot
    $script:RuntimeControls.Mode.Value.Text=$runtimeView.Mode;$script:RuntimeControls.Mode.Detail.Text=$runtimeView.ModeDetail
    $script:RuntimeControls.Count.Value.Text=$runtimeView.Count;$script:RuntimeControls.Count.Detail.Text='只計算此監測器的背景程序'
    $script:RuntimeControls.Memory.Value.Text=$runtimeView.Memory;$script:RuntimeControls.Memory.Detail.Text='私有記憶體・共用程序只計一次'
    $script:View.RuntimeText.Text=$runtimeView.Detail
    $script:View.OverviewTitle.Text=$script:Labels[$state]
    $script:View.OverviewBorder.Background=$script:Backgrounds[$state]
    $script:View.OverviewDetail.Text=switch($state){
        'ok' {'收訊、判讀、推播與收據程序的心跳正常，且最近有成功讀取 Windows 通知資料庫。'}
        'warning' {'請留意待重試、未確認通知或功能設定；下方可查看是哪個環節需要注意。'}
        'error' {'有程序停止／心跳過期，或推播設定未就緒。請先處理下方標示的異常。'}
        default {'部分資料無法讀取，不能確認監測正常。請以啟動監測器的同一個 Windows 帳號開啟。'}
    }
    if(Test-DashboardHistoryOnlyWarning $Snapshot){
        $script:View.OverviewTitle.Text='監測正常・有既有紀錄需留意'
        $script:View.OverviewDetail.Text="所有工作心跳正常。保留 $($Snapshot.Queue.AiFailedCompleted) 筆先前 AI 判讀失敗紀錄，目前已結束重試；不代表監測器停止，也不會自動補發。"
    }
    foreach($worker in $Snapshot.Workers){
        $controls=$script:WorkerControls[$worker.Role];if(-not $controls){continue}
        $controls.Status.Text=$script:Labels[$worker.Status];$controls.Status.Foreground=$script:Colors[$worker.Status]
        $controls.Detail.Text=$script:Reasons[$worker.Reason]
        if($null -ne $worker.HeartbeatAgeSeconds){$controls.Detail.Text+="`n心跳距今 $($worker.HeartbeatAgeSeconds) 秒"}
        $controls.Detail.Text+=if($worker.SharedHost){"`n共用工作宿主"}else{"`n獨立背景程序"}
        $controls.Stamp.Text=if($worker.Role -eq 'Collector' -and $worker.LastSuccessfulReadUtc){'讀取成功 '+([datetime]$worker.LastSuccessfulReadUtc).ToLocalTime().ToString('HH:mm:ss')}elseif($worker.HeartbeatUtc){'心跳 '+([datetime]$worker.HeartbeatUtc).ToLocalTime().ToString('HH:mm:ss')}else{''}
    }
    foreach($key in $script:MetricControls.Keys){$script:MetricControls[$key].Text=if($Snapshot.QueueReadable){[string]$Snapshot.Queue.$key}else{'—'}}
    $q=$Snapshot.Queue
    $script:View.QueueDetail.Text=if($Snapshot.QueueReadable){"已保存 $($q.Inbox) 則  ·  推播重試 $($q.PushRetry) 筆  ·  AI 失敗重試中 $($q.AiFailedPending) 筆／已結束重試 $($q.AiFailedCompleted) 筆  ·  24 小時內到期未確認 $($q.ExpiredLast24Hours) 筆  ·  近期 30 分鐘錯誤 $($Snapshot.RecentErrorCount) 筆"}else{'部分佇列無法讀取，計數暫不顯示，避免誤判為零。'}
    $usage=$Snapshot.Usage
    if($usage -and $usage.Available){
        $script:UsageControls.Today.Value.Text=('{0:N0}' -f [long]$usage.TodayTotal)
        $script:UsageControls.Today.Detail.Text=("$($usage.TodayRequests) 次 · 輸入 $('{0:N0}' -f [long]$usage.TodayInput) · 輸出 $('{0:N0}' -f [long]$usage.TodayOutput)")
        $script:UsageControls.Month.Value.Text=('{0:N0}' -f [long]$usage.MonthTotal)
        $script:UsageControls.Month.Detail.Text=("$($usage.MonthRequests) 次 · 輸入 $('{0:N0}' -f [long]$usage.MonthInput) · 輸出 $('{0:N0}' -f [long]$usage.MonthOutput)")
        if($usage.LastRequestUtc){
            $script:UsageControls.Last.Value.Text=('{0:N0}' -f [long]$usage.LastTotal)
            $script:UsageControls.Last.Detail.Text=("輸入 $('{0:N0}' -f [long]$usage.LastInput) · 輸出 $('{0:N0}' -f [long]$usage.LastOutput) · "+([datetime]$usage.LastRequestUtc).ToLocalTime().ToString('MM/dd HH:mm'))
        }else{$script:UsageControls.Last.Value.Text='0';$script:UsageControls.Last.Detail.Text='尚無更新後的 AI 回應'}
        $script:View.UsageDetail.Text=if($usage.TrackingSinceUtc){'本機加密紀錄自 '+([datetime]$usage.TrackingSinceUtc).ToLocalTime().ToString('yyyy/MM/dd HH:mm')+' 起；不代表 OpenAI 帳戶全部用量或美元餘額。'}else{'尚無本機用量紀錄；只會統計此功能更新後成功取得 usage 的 AI 回應。'}
    }else{
        foreach($control in $script:UsageControls.Values){$control.Value.Text='—';$control.Detail.Text='資料不完整'}
        $script:View.UsageDetail.Text='Token 用量紀錄無法完整讀取，因此不顯示可能錯誤的合計。'
    }
    $s=$Snapshot.Services
    $script:View.AiSetting.Text=if(-not $s.ConfigurationReadable){'AI：設定無法讀取'}elseif(-not $s.AiEnabled){'AI：未啟用'}elseif(-not $s.AiKeyPresent){'AI：已啟用，但缺少金鑰'}else{'AI：已啟用・金鑰已設定'}
    $script:View.PushSetting.Text=if(-not $s.ConfigurationReadable){'Pushover：設定無法讀取'}elseif(-not $s.PushoverEnabled){'Pushover：未啟用'}elseif(-not $s.PushoverKeysPresent){'Pushover：缺少必要金鑰'}else{'Pushover：已啟用・金鑰已設定'}
    $script:View.GroupSetting.Text=if($s.ConfigurationReadable){'群組篩選：'+$s.GroupCount+' 個目標群組'}else{'群組篩選：無法讀取'}
    $events=@($Snapshot.RecentEvents|ForEach-Object {[pscustomobject]@{DisplayTime=([datetime]$_.Time).ToString('MM/dd HH:mm:ss');Label=$_.Label}})
    $script:View.EventsList.ItemsSource=$events
    $script:View.NoEventsText.Text='尚無可顯示的事件';$script:View.NoEventsText.Visibility=if($events.Count){'Collapsed'}else{'Visible'}
    $script:View.IssuesText.Text=if(@($Snapshot.Issues).Count){'部分狀態無法取得，請核對 Windows 帳號與檔案讀取權限。'}else{'綠燈代表運作檢查通過，不保證 LINE 未漏產生通知或手機已收到。'}
    $script:View.UpdatedText.Text='資料時間 '+([datetime]$Snapshot.GeneratedUtc).ToLocalTime().ToString('HH:mm:ss')
}
if($PreviewPath){
    # Render this same WPF view offscreen for visual QA, without taking a desktop
    # screenshot. Only the redacted snapshot reaches the view or preview image.
    . (Join-Path $PSScriptRoot 'Dashboard.Status.ps1')
    $snapshot=Get-DashboardSnapshot $ConfigPath
    if($PreviewState -eq 'error'){$snapshot.Overall='error';$snapshot.Workers[0].Status='error';$snapshot.Workers[0].Reason='heartbeat_stale';$snapshot.Workers[0].HeartbeatAgeSeconds=180}
    Update-DashboardView $snapshot
    if($PreviewState -eq 'unknown'){Set-DashboardUnavailable '狀態讀取逾時，會自動重試。監測器本身不受這個視窗影響。'}
    $content=$script:Window.Content
    $content.Measure([Windows.Size]::new(1064,760));$content.Arrange([Windows.Rect]::new(0,0,1064,760));$content.UpdateLayout()
    $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new(1120,816,96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $visual=New-Object Windows.Media.DrawingVisual;$drawing=$visual.RenderOpen()
    $drawing.DrawRectangle([Windows.Media.BrushConverter]::new().ConvertFromString('#F3F6FA'),$null,[Windows.Rect]::new(0,0,1120,816))
    $drawing.DrawRectangle([Windows.Media.VisualBrush]::new($content),$null,[Windows.Rect]::new(28,28,1064,760));$drawing.Close();$bitmap.Render($visual)
    $encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder;$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream=[IO.File]::Create([IO.Path]::GetFullPath($PreviewPath));try{$encoder.Save($stream)}finally{$stream.Dispose()}
    Write-Output 'Preview rendered';exit
}
$script:Poller=$null;$script:Pending=$null;$script:StartedAt=[datetime]::MinValue;$script:LastGood=[datetime]::MinValue;$script:NextPoll=[datetime]::MinValue
$script:Provider=Join-Path $PSScriptRoot 'Dashboard.Status.ps1'
$script:DashboardConfig=[IO.Path]::GetFullPath($ConfigPath)
$script:UiUpdates=0;$script:UiStarted=[datetime]::UtcNow;$script:UiError='none'
function Start-DashboardRead {
    if($script:Pending){return}
    $script:Poller=[PowerShell]::Create()
    [void]$script:Poller.AddScript('param($provider,$config); $ErrorActionPreference="Stop"; . $provider; Get-DashboardSnapshot $config').AddArgument($script:Provider).AddArgument($script:DashboardConfig)
    $script:Pending=$script:Poller.BeginInvoke();$script:StartedAt=[datetime]::UtcNow
}
$timer=New-Object Windows.Threading.DispatcherTimer;$timer.Interval=[TimeSpan]::FromMilliseconds(300)
$timer.Add_Tick({
    try {
        $now=[datetime]::UtcNow
        if($script:Pending -and $script:Pending.IsCompleted){
            try {
                $result=@($script:Poller.EndInvoke($script:Pending))
                if($script:Poller.HadErrors -or $result.Count -ne 1){throw 'SnapshotFailed'}
                Update-DashboardView $result[0];$script:LastGood=$now;$script:UiUpdates++
            }catch{$script:UiError=$_.Exception.GetType().Name;Set-DashboardUnavailable '讀取失敗；請使用同一個 Windows 帳號開啟。稍後會自動重試。'}
            finally {$script:Poller.Dispose();$script:Poller=$null;$script:Pending=$null;$script:NextPoll=$now.AddSeconds(5)}
        }
        if($script:Pending -and ($now-$script:StartedAt).TotalSeconds -gt 20){
            Set-DashboardUnavailable '讀取超過 20 秒；不再顯示舊的綠燈。等待讀取結束後會自動重試。'
        }
        if($SmokeTest -and ($script:UiUpdates -ge 2 -or ($now-$script:UiStarted).TotalSeconds -gt 45)){$script:Window.Close();return}
        if(-not $script:Pending -and $now -ge $script:NextPoll){Start-DashboardRead}
    }catch{$script:UiError=$_.Exception.GetType().Name;Set-DashboardUnavailable '儀表板暫時無法更新，請關閉後重新開啟。'}
})
$script:View.RefreshButton.Add_Click({$script:NextPoll=[datetime]::MinValue})
$script:View.ManageTeamButton.Add_Click({
    $entry=Join-Path $PSScriptRoot 'Show-TeamManagement.ps1'
    Start-Process powershell.exe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -STA -File "'+$entry+'" -ConfigPath "'+$ConfigPath+'"') -WindowStyle Hidden
})
$script:View.OpenBillingButton.Add_Click({
    try {
        $startInfo=New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName=$script:OfficialBillingUrl
        $startInfo.UseShellExecute=$true
        [void][Diagnostics.Process]::Start($startInfo)
    }catch{
        [void][Windows.MessageBox]::Show('無法開啟瀏覽器。請手動登入 OpenAI Platform，前往組織的 Billing 頁面。','無法開啟官方頁面','OK','Warning')
    }
})
$script:Window.Add_ContentRendered({$timer.Start();Start-DashboardRead})
$script:Window.Add_Closing({$timer.Stop()})
if($SmokeTest){$script:Window.WindowStartupLocation='Manual';$script:Window.Left=-20000;$script:Window.ShowInTaskbar=$false}
try {[void]$script:Window.ShowDialog()}
finally {
    $timer.Stop()
    if($script:Poller){
        if($script:Pending -and -not $script:Pending.IsCompleted){[void]$script:Poller.BeginStop($null,$null)}
        else{$script:Poller.Dispose()}
    }
}
if($SmokeTest){if($script:UiUpdates -lt 2){throw ('DashboardAsyncRefreshFailed: '+$script:UiError)};Write-Output ('UI_REFRESHES='+$script:UiUpdates)}
