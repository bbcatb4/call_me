# 在 Windows PowerShell 5.1 執行：powershell.exe -ExecutionPolicy Bypass -File .\Start-LineDutyNotifier.ps1
param([string]$ConfigPath = (Join-Path $PSScriptRoot 'appsettings.json'))

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$script:Settings = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$script:Seen = New-Object 'System.Collections.Generic.HashSet[string]'
$script:ContextByGroup = @{}
$script:LastPushoverAlertByGroup = @{}
$script:LogDirectory = Join-Path $PSScriptRoot 'logs'
New-Item -ItemType Directory -Path $script:LogDirectory -Force | Out-Null
$script:Tray = New-Object System.Windows.Forms.NotifyIcon
$script:Tray.Icon = [System.Drawing.SystemIcons]::Exclamation
$script:Tray.Visible = $true
$script:Tray.Text = 'LINE 出勤通知監測器'

function Write-MonitorLog([string]$Message) {
    $path = Join-Path $script:LogDirectory ("monitor-{0:yyyy-MM-dd}.log" -f (Get-Date))
    Add-Content -LiteralPath $path -Value ("{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $Message) -Encoding UTF8
}
function Find-Term($Terms, [string]$Text) {
    foreach ($term in $Terms) { if ($term -and $Text.IndexOf([string]$term, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return [string]$term } }
    return $null
}
function Show-Alert([string]$Title, [string]$Message, [System.Windows.Forms.ToolTipIcon]$Icon) {
    [System.Media.SystemSounds]::Exclamation.Play()
    $script:Tray.BalloonTipTitle = $Title
    $script:Tray.BalloonTipText = $Message.Substring(0, [Math]::Min(250, $Message.Length))
    $script:Tray.BalloonTipIcon = $Icon
    $script:Tray.ShowBalloonTip([Math]::Max(3000, [int]$script:Settings.AlertDurationSeconds * 1000))
}
function Add-Context([string]$Group, [string]$Text) {
    if (-not $script:ContextByGroup.ContainsKey($Group)) { $script:ContextByGroup[$Group] = New-Object 'System.Collections.Generic.Queue[string]' }
    $queue = $script:ContextByGroup[$Group]
    $queue.Enqueue(("{0:HH:mm} {1}" -f (Get-Date), $Text))
    $limit = [Math]::Max(1, [int]$script:Settings.Ai.ContextMessageLimit)
    while ($queue.Count -gt $limit) { [void]$queue.Dequeue() }
    return @($queue.ToArray())
}
function Invoke-AiAssessment([string]$Group, [string]$Text, [string]$LocalLevel, [string]$LocalReason, [string[]]$Context) {
    if (-not $script:Settings.Ai.Enabled) { return $null }
    $keyName = [string]$script:Settings.Ai.ApiKeyEnvironmentVariable
    $apiKey = [Environment]::GetEnvironmentVariable($keyName, 'User')
    if (-not $apiKey) { $apiKey = [Environment]::GetEnvironmentVariable($keyName, 'Process') }
    if (-not $apiKey) { Write-MonitorLog "AI 未執行：找不到環境變數 $keyName"; return $null }
    $schema = @{ type='object'; additionalProperties=$false; properties=@{
        status=@{ type='string'; enum=@('confirmed','uncertain','negative','none') }
        date=@{ type=@('string','null') }; shift=@{ type=@('string','null') }; time=@{ type=@('string','null') }
        role=@{ type=@('string','null') }; person=@{ type=@('string','null') }; staffing_need=@{ type=@('string','null') }
        confidence=@{ type='string'; enum=@('high','medium','low') }; reason=@{ type='string' }
    }; required=@('status','date','shift','time','role','person','staffing_need','confidence','reason') }
    $instructions = '你是台灣醫療排班通知的審核助手。僅根據提供的通知上下文判讀。找出出勤需求與回覆是否配對，擷取日期、班別、時間、職務、人員與缺額需求。若回覆文字中明確出現人名，例如「小美，我可以支援」，person 必須填入「小美」；未出現人名時才填 null。只有明確承諾且可對應需求時，status 才能是 confirmed；「應該可以」、「再看看」一律 uncertain。無法判斷時不可臆測，欄位填 null。'
    $input = "群組：$Group`n本機初判：$LocalLevel（$LocalReason）`n最近候選通知：`n" + ($Context -join "`n") + "`n本次通知：$Text"
    $payload = @{ model=[string]$script:Settings.Ai.Model; store=$false; instructions=$instructions; input=$input; text=@{ format=@{ type='json_schema'; name='duty_assessment'; strict=$true; schema=$schema } } } | ConvertTo-Json -Depth 20
    try {
        $response = Invoke-RestMethod -Method Post -Uri ([string]$script:Settings.Ai.Endpoint) -Headers @{ Authorization = "Bearer $apiKey" } -ContentType 'application/json' -Body $payload -TimeoutSec ([int]$script:Settings.Ai.TimeoutSeconds)
        $jsonText = $null
        foreach ($item in @($response.output)) { foreach ($content in @($item.content)) { if ($content.type -eq 'output_text') { $jsonText = $content.text; break } } }
        if (-not $jsonText) { throw 'AI 回應未包含結構化文字' }
        return ($jsonText | ConvertFrom-Json)
    } catch { Write-MonitorLog ('AI 判讀失敗，改用本機規則：' + $_.Exception.Message); return $null }
}
function Invoke-PushoverAlert([string]$Group, [string]$Level, [string]$Message) {
    if (-not $script:Settings.Pushover.Enabled) { return }
    if ($script:Settings.Pushover.AlertLevels -notcontains $Level) { return }
    $lastSent = $script:LastPushoverAlertByGroup[$Group]
    if ($lastSent -and ((Get-Date) - $lastSent).TotalSeconds -lt [int]$script:Settings.Pushover.CooldownSeconds) {
        Write-MonitorLog "Pushover 略過：$Group 仍在冷卻時間內"
        return
    }
    $appToken = [Environment]::GetEnvironmentVariable([string]$script:Settings.Pushover.AppTokenEnvironmentVariable, 'User')
    $userKey = [Environment]::GetEnvironmentVariable([string]$script:Settings.Pushover.UserKeyEnvironmentVariable, 'User')
    if (-not $appToken -or -not $userKey) {
        Write-MonitorLog 'Pushover 未執行：找不到 APP_TOKEN 或 USER_KEY 環境變數'
        return
    }
    $body = @{ token=$appToken; user=$userKey; title='出勤確認提醒'; message=("群組：$Group`n$Message"); priority=2; retry=[int]$script:Settings.Pushover.RetrySeconds; expire=[int]$script:Settings.Pushover.ExpireSeconds; sound=[string]$script:Settings.Pushover.Sound }
    try {
        $response = Invoke-RestMethod -Method Post -Uri 'https://api.pushover.net/1/messages.json' -Body $body -TimeoutSec 20
        $script:LastPushoverAlertByGroup[$Group] = Get-Date
        Write-MonitorLog "Pushover 已送出緊急通知；receipt：$($response.receipt)"
    } catch { Write-MonitorLog ('Pushover 傳送失敗：' + $_.Exception.Message) }
}
function Test-LineNotification([System.Windows.Automation.AutomationElement]$Root) {
    try {
        $process = [System.Diagnostics.Process]::GetProcessById($Root.Current.ProcessId).ProcessName
        if ($process -notmatch 'ShellExperienceHost|Line') { return }
        $names = New-Object 'System.Collections.Generic.List[string]'
        $addName = { param($item) try { $name = $item.Current.Name.Trim(); if ($name -and -not $names.Contains($name)) { $names.Add($name) } } catch { } }
        & $addName $Root
        foreach ($item in $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) { & $addName $item }
        $text = ($names -join ' ').Trim()
        if (-not $text) { return }
        $group = Find-Term $script:Settings.TargetGroupNames $text
        if (-not $group) { return }
        if ($process -notmatch 'Line' -and $text -notmatch 'LINE') { return }
        $key = "$process|$text"
        if (-not $script:Seen.Add($key)) { return }
        if ($script:Seen.Count -gt 200) { $script:Seen.Clear() }
        $context = Add-Context $group $text
        $level = 'None'; $reason = '未偵測到出勤語意'; $icon = [System.Windows.Forms.ToolTipIcon]::Info
        if ($term = Find-Term $script:Settings.NegativeTerms $text) { $level = 'Negative'; $reason = "偵測到否定詞：$term"; $icon = [System.Windows.Forms.ToolTipIcon]::Error }
        elseif ($term = Find-Term $script:Settings.HighConfidenceTerms $text) { $level = 'Confirmed'; $reason = "偵測到確認語句：$term" }
        elseif ($term = Find-Term $script:Settings.UncertainTerms $text) { $level = 'Uncertain'; $reason = "偵測到不確定語句：$term"; $icon = [System.Windows.Forms.ToolTipIcon]::Warning }
        elseif ($term = Find-Term $script:Settings.RequiredContextTerms $text) { $level = 'Uncertain'; $reason = "偵測到出勤相關內容：$term"; $icon = [System.Windows.Forms.ToolTipIcon]::Warning }
        if ($level -ne 'None') {
            $ai = Invoke-AiAssessment $group $text $level $reason $context
            if ($ai) {
                $level = switch ($ai.status) { 'confirmed' { 'Confirmed' } 'negative' { 'Negative' } 'uncertain' { 'Uncertain' } default { 'None' } }
                $reason = "AI：$($ai.reason)｜日期：$($ai.date)｜班別：$($ai.shift)｜時間：$($ai.time)｜職務：$($ai.role)｜人員：$($ai.person)｜需求：$($ai.staffing_need)｜信心：$($ai.confidence)"
                $icon = switch ($level) { 'Negative' { [System.Windows.Forms.ToolTipIcon]::Error } 'Uncertain' { [System.Windows.Forms.ToolTipIcon]::Warning } default { [System.Windows.Forms.ToolTipIcon]::Info } }
            }
        }
        if ($script:Settings.LogAllCandidateNotifications) { Write-MonitorLog "[$level] $group | $reason | $text" }
        Invoke-PushoverAlert $group $level $reason
        if ($level -ne 'None') { Show-Alert ("LINE 出勤：" + $level) ("群組：$group`n$reason`n$text") $icon }
    } catch { Write-MonitorLog ('讀取通知失敗：' + $_.Exception.Message) }
}
$handler = [System.Windows.Automation.AutomationEventHandler]{ param($sender, $eventArgs) Test-LineNotification $sender }
[System.Windows.Automation.Automation]::AddAutomationEventHandler([System.Windows.Automation.WindowPattern]::WindowOpenedEvent, [System.Windows.Automation.AutomationElement]::RootElement, [System.Windows.Automation.TreeScope]::Subtree, $handler)
Write-MonitorLog '監測已啟動。請保持此 PowerShell 視窗開啟。'
Write-Host 'LINE 出勤通知監測中…按 Ctrl+C 結束。' -ForegroundColor Green
try { while ($true) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 } }
finally { [System.Windows.Automation.Automation]::RemoveAutomationEventHandler([System.Windows.Automation.WindowPattern]::WindowOpenedEvent, [System.Windows.Automation.AutomationElement]::RootElement, $handler); $script:Tray.Dispose() }
