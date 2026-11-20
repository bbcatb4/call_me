# Requires Windows PowerShell 5.1. Expose this listener through your approved HTTPS reverse proxy.
param([string]$ConfigPath = (Join-Path $PSScriptRoot 'dutybot.settings.json'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-Hashtable($Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) { $result=@{}; foreach ($key in $Value.Keys) { $result[$key]=ConvertTo-Hashtable $Value[$key] }; return $result }
    if ($Value -is [System.Management.Automation.PSCustomObject]) { $result=@{}; foreach ($property in $Value.PSObject.Properties) { $result[$property.Name]=ConvertTo-Hashtable $property.Value }; return $result }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) { return @($Value | ForEach-Object { ConvertTo-Hashtable $_ }) }
    return $Value
}
$script:Settings = ConvertTo-Hashtable (Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json)
$script:ChannelSecret = [Environment]::GetEnvironmentVariable('LINE_CHANNEL_SECRET', 'Process')
if (-not $script:ChannelSecret) { $script:ChannelSecret = [Environment]::GetEnvironmentVariable('LINE_CHANNEL_SECRET', 'User') }
$script:ChannelToken = [Environment]::GetEnvironmentVariable('LINE_CHANNEL_ACCESS_TOKEN', 'Process')
if (-not $script:ChannelToken) { $script:ChannelToken = [Environment]::GetEnvironmentVariable('LINE_CHANNEL_ACCESS_TOKEN', 'User') }
if (-not $script:ChannelSecret -or -not $script:ChannelToken) { throw '請先設定 LINE_CHANNEL_SECRET 與 LINE_CHANNEL_ACCESS_TOKEN 使用者或程序環境變數。' }
$script:OpenAiKey = [Environment]::GetEnvironmentVariable('OPENAI_API_KEY', 'Process')
if (-not $script:OpenAiKey) { $script:OpenAiKey = [Environment]::GetEnvironmentVariable('OPENAI_API_KEY', 'User') }
$script:StatePath = Join-Path $PSScriptRoot $script:Settings.StatePath
New-Item -ItemType Directory -Path (Split-Path $script:StatePath -Parent) -Force | Out-Null

function New-State { return @{ version=1; processedEventIds=@(); groups=@{}; users=@{}; duties=@{}; audit=@() } }
function Read-State {
    if (-not (Test-Path -LiteralPath $script:StatePath)) { return (New-State) }
    try { return (ConvertTo-Hashtable (Get-Content -LiteralPath $script:StatePath -Raw -Encoding UTF8 | ConvertFrom-Json)) }
    catch { throw "無法讀取狀態檔：$($_.Exception.Message)" }
}
function Save-State($State) {
    $State.audit = @($State.audit | Where-Object { ([datetime]$_.at) -ge (Get-Date).AddDays(-[int]$script:Settings.RetentionDays) })
    $State.processedEventIds = @($State.processedEventIds | Select-Object -Last 500)
    $tmp = "$script:StatePath.tmp"
    $State | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $script:StatePath -Force
}
function Add-Audit($State, [string]$Kind, [string]$Detail) { $State.audit += @{ at=(Get-Date).ToString('o'); kind=$Kind; detail=$Detail } }
function Get-Text($Object, [string]$Name) { if ($null -eq $Object) { return $null }; $value = $Object[$Name]; if ($null -eq $value) { return $null }; return [string]$value }
function Test-Signature([byte[]]$Bytes, [string]$Signature) {
    $hmac = [System.Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes($script:ChannelSecret))
    try { return [Convert]::ToBase64String($hmac.ComputeHash($Bytes)) -eq $Signature } finally { $hmac.Dispose() }
}
function Send-Line([string]$Path, $Body) {
    Invoke-RestMethod -Method Post -Uri "https://api.line.me/v2/bot$Path" -Headers @{ Authorization="Bearer $script:ChannelToken" } -ContentType 'application/json' -Body ($Body | ConvertTo-Json -Depth 12) -TimeoutSec 20 | Out-Null
}
function Send-Push([string]$To, [string]$Text, $QuickReply) {
    $message = @{ type='text'; text=$Text }
    if ($QuickReply) { $message.quickReply = @{ items=$QuickReply } }
    Send-Line '/message/push' @{ to=$To; messages=@($message) }
}
function Send-Reply([string]$ReplyToken, [string]$Text) { if ($ReplyToken) { Send-Line '/message/reply' @{ replyToken=$ReplyToken; messages=@(@{ type='text'; text=$Text }) } } }
function Get-EnvironmentSecret([string]$Name) {
    $value = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if (-not $value) { $value = [Environment]::GetEnvironmentVariable($Name, 'User') }
    return $value
}
function Invoke-PushoverAlert([string]$DutyId, [string]$GroupId, [string]$Reason) {
    if (-not $script:Settings.Pushover.Enabled) { return @() }
    $appToken = Get-EnvironmentSecret ([string]$script:Settings.Pushover.AppTokenEnvironmentVariable)
    if (-not $appToken) { return @('Pushover 未送出：缺少 App Token') }
    $results = @()
    foreach ($keyVariable in @($script:Settings.Pushover.UserKeyEnvironmentVariables)) {
        $userKey = Get-EnvironmentSecret ([string]$keyVariable)
        if (-not $userKey) { $results += "Pushover 未送出：缺少 $keyVariable"; continue }
        $body = @{ token=$appToken; user=$userKey; title='出勤確認提醒'; message="案件：$DutyId`n$Reason`n請在 Pushover app 確認，或回到 LINE 點選確認到院。"; priority=2; retry=[int]$script:Settings.Pushover.RetrySeconds; expire=[int]$script:Settings.Pushover.ExpireSeconds; sound=[string]$script:Settings.Pushover.Sound }
        try { $response = Invoke-RestMethod -Method Post -Uri 'https://api.pushover.net/1/messages.json' -Body $body -TimeoutSec 20; $results += "Pushover 已送出：$($response.receipt)" }
        catch { $results += "Pushover 送出失敗：$($_.Exception.Message)" }
    }
    return $results
}
function Find-Term($Terms, [string]$Text) { foreach ($term in @($Terms)) { if ($term -and $Text.IndexOf([string]$term, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return [string]$term } }; return $null }
function Get-RuleAssessment([string]$Text) {
    if ($term = Find-Term $script:Settings.Rules.NegativeTerms $Text) { return @{ status='cancelled'; confidence='high'; reason="否定詞：$term" } }
    if ($term = Find-Term $script:Settings.Rules.HighConfidenceTerms $Text) { return @{ status='confirmed'; confidence='high'; reason="確認語句：$term" } }
    if ($term = Find-Term $script:Settings.Rules.UncertainTerms $Text) { return @{ status='candidate'; confidence='medium'; reason="待確認語句：$term" } }
    if ($term = Find-Term $script:Settings.Rules.RequiredContextTerms $Text) { return @{ status='candidate'; confidence='low'; reason="出勤相關詞：$term" } }
    return @{ status='ignored'; confidence='low'; reason='不含出勤語境' }
}
function Redact-Text([string]$Text) {
    $redacted = $Text -replace '(?<!\d)\d{8,}(?!\d)', '[已遮蔽編號]'
    $redacted = $redacted -replace '(?<!\d)\d{3,4}-?\d{3,4}(?!\d)', '[已遮蔽電話]'
    return $redacted -replace '(病人|患者)\s*[：:]?\s*[\p{IsCJKUnifiedIdeographs}A-Za-z]{2,4}', '$1 [已遮蔽姓名]'
}
function Invoke-AiAssessment([string]$Text, [string[]]$Context, $Local) {
    if (-not $script:Settings.Ai.Enabled -or -not $script:OpenAiKey) { return $Local }
    $schema = @{ type='object'; additionalProperties=$false; properties=@{ status=@{type='string';enum=@('confirmed','candidate','cancelled','ignored')}; confidence=@{type='string';enum=@('high','medium','low')}; reason=@{type='string'}; time=@{type=@('string','null')}; shift=@{type=@('string','null')}; role=@{type=@('string','null')}; staffing_need=@{type=@('string','null')} }; required=@('status','confidence','reason','time','shift','role','staffing_need') }
    $input = "只依下列去識別化的台灣醫療出勤訊息判讀。明確出勤才 confirmed，取消為 cancelled，其他不確定情況為 candidate。不要猜測。`n上下文：$((@($Context | ForEach-Object { Redact-Text $_ }) -join "`n"))`n本訊息：$(Redact-Text $Text)"
    $payload = @{ model=$script:Settings.Ai.Model; store=$false; instructions='你是出勤通知的審核器，只輸出符合 schema 的資料。'; input=$input; text=@{format=@{type='json_schema';name='duty_assessment';strict=$true;schema=$schema}} } | ConvertTo-Json -Depth 20
    try {
        $response = Invoke-RestMethod -Method Post -Uri 'https://api.openai.com/v1/responses' -Headers @{Authorization="Bearer $script:OpenAiKey"} -ContentType 'application/json' -Body $payload -TimeoutSec ([int]$script:Settings.Ai.TimeoutSeconds)
        $json = @($response.output | ForEach-Object { $_.content } | Where-Object { $_.type -eq 'output_text' } | Select-Object -First 1).text
        if ($json) { return (ConvertTo-Hashtable ($json | ConvertFrom-Json)) }
    } catch { }
    return $Local
}
function Get-Group($State, [string]$GroupId) { if (-not $State.groups.ContainsKey($GroupId)) { $State.groups[$GroupId] = @{ context=@(); roster=@{ date=''; staff=@(); administrators=@() } } }; return $State.groups[$GroupId] }
function Get-QuickReplies([string]$DutyId) { return @(
    @{type='action';action=@{type='postback';label='確認到院';data="duty:ack:$DutyId";displayText="確認到院 $DutyId"}},
    @{type='action';action=@{type='postback';label='無法出勤';data="duty:decline:$DutyId";displayText="無法出勤 $DutyId"}},
    @{type='action';action=@{type='postback';label='轉交管理者';data="duty:handoff:$DutyId";displayText="轉交管理者 $DutyId"}}
) }
function Create-Duty($State, [string]$GroupId, [string]$Text, $Assessment) {
    $group = Get-Group $State $GroupId
    $id = ('D' + (Get-Date -Format 'yyyyMMddHHmmss') + '-' + (Get-Random -Maximum 9999).ToString('0000'))
    $duty = @{ id=$id; groupId=$GroupId; source=(Redact-Text $Text); status='已派送待回覆'; createdAt=(Get-Date).ToString('o'); escalateAfter=(Get-Date).AddMinutes([int]$script:Settings.EscalationMinutes).ToString('o'); responders=@(); assessment=$Assessment }
    $State.duties[$id] = $duty
    $summary = "【出勤提醒 $id】`n$($Assessment.reason)`n請值班人員確認是否到院。"
    Send-Push $GroupId $summary $null
    foreach ($userId in @($group.roster.staff)) { if ($State.users.ContainsKey($userId)) { Send-Push $userId $summary (Get-QuickReplies $id) } }
    $duty.pushover = @{ attemptedAt=(Get-Date).ToString('o'); results=@(Invoke-PushoverAlert $id $GroupId ([string]$Assessment.reason)) }
    Add-Audit $State 'duty-created' $id
}
function Process-Text($State, $Event) {
    $source = $Event.source; $groupId = Get-Text $source 'groupId'; $userId = Get-Text $source 'userId'; $text = Get-Text $Event.message 'text'
    if (-not $text) { return }
    if ($source.type -eq 'user') { $State.users[$userId] = @{ linkedAt=(Get-Date).ToString('o') }; if ($text -eq '綁定值班') { Send-Reply $Event.replyToken '已完成值班通知綁定。'; return } }
    if ($source.type -ne 'group' -or -not ($script:Settings.AllowedGroupIds -contains $groupId)) { return }
    $group = Get-Group $State $groupId
    if ($text -match '^/值班\s+(.+)$' -and ($script:Settings.AdministratorUserIds -contains $userId)) { $group.roster = @{date=(Get-Date -Format 'yyyy-MM-dd');staff=@($Matches[1].Split(',') | ForEach-Object { $_.Trim() });administrators=@($script:Settings.AdministratorUserIds)}; Send-Reply $Event.replyToken '今日值班人員已更新（請填入已綁定 Bot 的 LINE user ID）。'; return }
    if ($text -eq '/值班表' -and ($script:Settings.AdministratorUserIds -contains $userId)) { Send-Reply $Event.replyToken ("今日值班：" + (@($group.roster.staff) -join ', ')); return }
    if ($text -match '^/取消\s+(D\S+)$' -and ($script:Settings.AdministratorUserIds -contains $userId)) { if ($State.duties.ContainsKey($Matches[1])) { $State.duties[$Matches[1]].status='已取消'; Send-Reply $Event.replyToken "已取消 $($Matches[1])" }; return }
    if ($text -match '^/提醒\s+(.+)$' -and ($script:Settings.AdministratorUserIds -contains $userId)) { Create-Duty $State $groupId $Matches[1] @{status='confirmed';confidence='high';reason='管理者手動派送'}; Send-Reply $Event.replyToken '已派送出勤提醒。'; return }
    $group.context += $text; $group.context = @($group.context | Select-Object -Last ([int]$script:Settings.ContextMessageLimit))
    $local = Get-RuleAssessment $text; if ($local.status -eq 'ignored') { return }
    $assessment = Invoke-AiAssessment $text $group.context $local
    if ($assessment.status -eq 'cancelled') { Add-Audit $State 'cancel-detected' (Redact-Text $text); return }
    if ($assessment.status -eq 'confirmed' -and $assessment.confidence -eq [string]$script:Settings.Ai.MinimumConfidence) { Create-Duty $State $groupId $text $assessment; return }
    Add-Audit $State 'candidate' (Redact-Text $text)
}
function Process-Postback($State, $Event) {
    $data = Get-Text $Event.postback 'data'; if ($data -notmatch '^duty:(ack|decline|handoff):(D\S+)$') { return }
    $action=$Matches[1]; $id=$Matches[2]; if (-not $State.duties.ContainsKey($id)) { Send-Reply $Event.replyToken '此提醒已不存在。'; return }
    $duty=$State.duties[$id]; $userId=Get-Text $Event.source 'userId'; $duty.responders += $userId
    if ($action -eq 'ack') { $duty.status = '已回覆'; $replyText = '已記錄到院確認。' }
    elseif ($action -eq 'decline') { $duty.status = '待人工確認'; $replyText = '已記錄無法出勤，管理者將接手。' }
    else { $duty.status = '待人工確認'; $replyText = '已通知管理者協助轉交。' }
    Send-Reply $Event.replyToken $replyText
    if ($action -ne 'ack') { foreach ($admin in @($script:Settings.AdministratorUserIds)) { if ($State.users.ContainsKey($admin)) { Send-Push $admin "【$id】值班者無法出勤／要求轉交，請處理。" $null } } }
    Add-Audit $State "duty-$action" $id
}
function Process-Event($State, $Event) {
    $eventId=Get-Text $Event 'webhookEventId'; if ($eventId -and $State.processedEventIds -contains $eventId) { return }; if ($eventId) { $State.processedEventIds += $eventId }
    if ($Event.type -eq 'join' -and (Get-Text $Event.source 'type') -eq 'group') { $groupId = Get-Text $Event.source 'groupId'; Get-Group $State $groupId | Out-Null; Add-Audit $State 'group-joined' $groupId; return }
    if ($Event.type -eq 'message' -and (Get-Text $Event.message 'type') -eq 'text') { Process-Text $State $Event }
    elseif ($Event.type -eq 'postback') { Process-Postback $State $Event }
}
function Escalate-Duties($State) { foreach ($duty in @($State.duties.Values)) { if ($duty.status -eq '已派送待回覆' -and (Get-Date) -ge [datetime]$duty.escalateAfter) { $duty.status='已升級'; Send-Push $duty.groupId "【$($duty.id)】值班者 10 分鐘未確認，請管理者協助。" $null; foreach($admin in @($script:Settings.AdministratorUserIds)) { if ($State.users.ContainsKey($admin)) { Send-Push $admin "【$($duty.id)】10 分鐘未確認，請立即協助。" $null } }; Add-Audit $State 'duty-escalated' $duty.id } } }

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add([string]$script:Settings.ListenPrefix); $listener.Start()
Write-Host "LINE Duty Bot 已啟動：$($script:Settings.ListenPrefix)$($script:Settings.WebhookPath)" -ForegroundColor Green
try {
    while ($listener.IsListening) {
        $task=$listener.GetContextAsync(); while(-not $task.Wait([int]$script:Settings.PollSeconds * 1000)) { $state=Read-State; Escalate-Duties $state; Save-State $state }
        $ctx=$task.Result; $ctx.Response.ContentType='application/json'; $path=$ctx.Request.Url.AbsolutePath.Trim('/')
        if ($ctx.Request.HttpMethod -ne 'POST' -or $path -ne ([string]$script:Settings.WebhookPath).Trim('/')) { $ctx.Response.StatusCode=404; $ctx.Response.Close(); continue }
        $stream=New-Object IO.MemoryStream; $ctx.Request.InputStream.CopyTo($stream); $bytes=$stream.ToArray(); $signature=$ctx.Request.Headers['X-Line-Signature']
        if (-not (Test-Signature $bytes $signature)) { $ctx.Response.StatusCode=401; $ctx.Response.Close(); continue }
        $ctx.Response.StatusCode=200; $ctx.Response.Close(); $payload=ConvertTo-Hashtable ([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json); $state=Read-State; foreach($event in @($payload.events)) { Process-Event $state $event }; Escalate-Duties $state; Save-State $state
    }
} finally { $listener.Stop(); $listener.Close() }
