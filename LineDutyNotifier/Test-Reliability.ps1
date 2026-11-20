# Integration tests call production code with fake AI and Pushover transports.
param([switch]$LiveAi)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Notifier.Core.ps1')
$config=Join-Path $PSScriptRoot 'appsettings.json'
$testRoot=Join-Path (Join-Path $PSScriptRoot 'state') ('test-'+[guid]::NewGuid().ToString('N'))
Initialize-Notifier $config $testRoot
$script:LogDirectory=$testRoot
$script:Settings.TargetGroupNames=@('測試手術群組')
$script:Settings.Pushover.Enabled=$true
$script:Passed=0
function Assert($Condition,[string]$Name){if(-not $Condition){throw "FAIL: $Name"};$script:Passed++;Write-Output "PASS: $Name"}
function New-TestEvent([string]$Id,[string]$Body,[string]$Title='測試手術群組'){
    $xml='<toast launch="TextToast;ChatId=test;MessageId='+$Id+'"><visual><binding><text>'+[Security.SecurityElement]::Escape($Title)+'</text><text>'+[Security.SecurityElement]::Escape($Body)+'</text></binding></visual></toast>'
    $hex=([BitConverter]::ToString([Text.Encoding]::UTF8.GetBytes($xml))).Replace('-','')
    return Convert-NotificationRow ([pscustomobject]@{payload_hex=$hex;sort_order=1;arrival_time=[datetime]::UtcNow.ToFileTimeUtc();app_id='LINE_test'})
}
$cases=@(
    @('9/5中午接刀','Confirmed'),@('明天10點接','Confirmed'),@('明天0800接','Confirmed'),
    @('禮拜日早上08：00先接醫師的ORIF','Confirmed'),@('請值班人員11點到院接刀','Confirmed'),
    @('值班人員請出勤','Confirmed'),@('Oncall人員請出勤','Confirmed'),@('出勤','Confirmed'),@('出門','Confirmed'),
    @('請明早八點入鍋','Confirmed'),@('明天中午接刀可以嗎？','Uncertain'),@('可能明天中午接刀','Uncertain'),
    @('人員出勤大約需要一個小時','Uncertain'),@('幾點可以接','Uncertain'),@('等等，家屬猶豫再討論','Uncertain'),
    @('不用出來，是我們現在要接','Negative'),@('手術取消','Negative'),@('不用出勤','Negative'),
    @('好','None'),@('手術室災害演練下午2點','None'),@('圖片','Uncertain'),@('','Uncertain'))
foreach($case in $cases){Assert ((Get-LocalDecision $case[0]).Level -eq $case[1]) ('rule: '+$case[0])}
$reply=New-TestEvent 'reply' '好'
Assert ($reply.Body -eq '好' -and (Get-LocalDecision $reply.Body).Level -eq 'None') 'title never enters duty classification'
Assert ($null -eq (New-TestEvent 'other' '測試手術群組 請出勤' '其他群組')) 'group match uses title, not body mentions'
$usageEvent=New-TestEvent 'usage' '可能有刀'
$usageResponse=[pscustomobject]@{id='resp_private';created_at=[datetimeoffset]::UtcNow.ToUnixTimeSeconds();usage=[pscustomobject]@{
    input_tokens=120;output_tokens=30;total_tokens=150;
    input_tokens_details=[pscustomobject]@{cached_tokens=20};output_tokens_details=[pscustomobject]@{reasoning_tokens=5}
}}
Assert (Save-AiUsage $usageEvent $usageResponse) 'first API usage record persists'
Assert (-not (Save-AiUsage $usageEvent $usageResponse)) 'same API response usage is deduplicated'
$usageRecord=Read-State (@(Get-ChildItem (Join-Path $testRoot 'usage') -Filter '*.dat')[0].FullName)
Assert ($usageRecord.TotalTokens -eq 150 -and $usageRecord.CachedInputTokens -eq 20 -and $usageRecord.ReasoningTokens -eq 5) 'token categories persist accurately'
Assert (($usageRecord|ConvertTo-Json -Compress) -notmatch 'resp_private|可能有刀') 'usage record excludes response ID and message body'
$script:AiCalls=0
function Invoke-EventAi { $script:AiCalls++; throw 'SimulatedTimeout' }
function Invoke-PushHttp { throw 'NetworkMustNotRunDuringCollection' }
$e1=New-TestEvent '1' '明天10點接';$e2=New-TestEvent '2' '明天10點接'
Assert (Save-IncomingEvent $e1) 'first event persists'
Assert (Save-IncomingEvent $e2) 'same text different message ID persists'
Assert (-not (Save-IncomingEvent $e1)) 'same source message is deduplicated'
Assert (@(Get-ChildItem (Join-Path $testRoot 'outbox') -Filter '*.dat').Count -eq 2) 'two new calls inside 60 seconds both queued'
Assert ($script:AiCalls -eq 0) 'collection and confirmed alert do not wait for AI'
$review=New-TestEvent '3' '可能明天中午接刀'
[void](Save-IncomingEvent $review)
$photo=New-TestEvent '4' '圖片';[void](Save-IncomingEvent $photo)
Assert ($photo.ImageStatus -eq 'missing') 'photo-only notification records missing attachment'
$photoAlert=Read-State (Get-StatePath 'outbox' (Get-EventHash ($photo.Id+'|Review')))
Assert ($photoAlert.Message -match '照片缺失') 'missing photo produces visible review alert'
Invoke-ClassifierPass
$reviewJob=Read-State (Get-StatePath 'processed' $review.Id)
Assert ($reviewJob.AiStatus -eq 'failed' -and $reviewJob.Status -eq 'pending') 'AI timeout schedules retry'
Assert (Test-Path (Get-StatePath 'outbox' (Get-EventHash ($review.Id+'|Review')))) 'AI timeout does not discard review alert'
# Recover a crash after durable inbox commit, before initial alert creation.
$crashed=New-TestEvent '5' '請出勤';$crashed.Local=Get-LocalDecision $crashed.Body
[void](Write-State (Get-StatePath 'inbox' $crashed.Id) $crashed -CreateOnly)
Initialize-Notifier $config $testRoot
$script:LogDirectory=$testRoot;$script:Settings.Pushover.Enabled=$true
Invoke-ClassifierPass
Assert (Test-Path (Get-StatePath 'outbox' (Get-EventHash ($crashed.Id+'|Confirmed')))) 'restart recovers unfinished inbox event'
function Invoke-PushHttp { throw 'SimulatedNetworkFailure' }
Invoke-SenderPass
$pending=@(Get-ChildItem (Join-Path $testRoot 'outbox') -Filter '*.dat' | ForEach-Object {Read-State $_.FullName})
Assert (@($pending|Where-Object {$_.Status -eq 'pending' -and $_.Attempts -eq 1}).Count -eq $pending.Count) 'network failure retains all messages for retry'
foreach($alert in $pending){$alert.NextAttemptUtc=[datetime]::UtcNow.AddSeconds(-1).ToString('o');Write-State (Get-StatePath 'outbox' $alert.Id) $alert}
Initialize-Notifier $config $testRoot
$script:LogDirectory=$testRoot;$script:Settings.Pushover.Enabled=$true
$script:PushCalls=0
function Invoke-PushHttp($Alert){$script:PushCalls++;return [pscustomobject]@{status=1;receipt=('test-'+$Alert.Id)}}
function Invoke-ReceiptHttp {return [pscustomobject]@{status=1;acknowledged=1;expired=0}}
Invoke-SenderPass
$accepted=@(Get-ChildItem (Join-Path $testRoot 'outbox') -Filter '*.dat' | ForEach-Object {Read-State $_.FullName})
Assert (@($accepted|Where-Object {$_.Status -eq 'accepted' -and $_.Attempts -eq 2}).Count -eq $accepted.Count) 'restart retries pending sends successfully'
$before=$script:PushCalls;Invoke-SenderPass
Assert ($script:PushCalls -eq $before) 'accepted messages are not resent'
foreach($alert in $accepted){if($alert.Receipt){$alert.NextReceiptUtc=[datetime]::UtcNow.AddSeconds(-1).ToString('o');Write-State (Get-StatePath 'outbox' $alert.Id) $alert}}
Invoke-ReceiptPass
$tracked=@(Get-ChildItem (Join-Path $testRoot 'outbox') -Filter '*.dat'|ForEach-Object {Read-State $_.FullName}|Where-Object {$_.Kind -eq 'Confirmed'})
Assert (@($tracked|Where-Object {$_.Status -eq 'acknowledged'}).Count -eq $tracked.Count) 'receipt acknowledgement is persisted'
# Use production request builder with a synthetic image, no external API call.
$script:Settings.TargetGroupNames=@('測試手術群組')
$picture=New-TestEvent 'image' '圖片'
$picture.ImageStatus='available';$picture.Images=@([pscustomobject]@{Mime='image/png';Data='synthetic-test-bytes'})
$request=New-AiRequest $picture @()
Assert (@($request.input[0].content|Where-Object {$_.type -eq 'input_image'}).Count -eq 1) 'image-only event builds multimodal request'
Assert ($request.instructions -match '不需要有人承諾出勤') 'AI uses confirmed schedule policy'
Assert ($request.input[0].content[1].detail -eq 'high') 'schedule image uses high detail'
# Retry AI with a positive response and confirm a separate emergency upgrade.
$reviewJob.NextAttemptUtc=[datetime]::UtcNow.AddSeconds(-1).ToString('o');Write-State (Get-StatePath 'processed' $review.Id) $reviewJob
function Invoke-EventAi {return [pscustomobject]@{status='confirmed';date='2026-09-10';time='12:00';image_readable=$true}}
Invoke-ClassifierPass
Assert (Test-Path (Get-StatePath 'outbox' (Get-EventHash ($review.Id+'|Confirmed')))) 'AI confirmation upgrades review to emergency'
$proposal=New-TestEvent 'proposal' '下午3點接可以嗎？';[void](Save-IncomingEvent $proposal)
$agreement=New-TestEvent 'agreement' '好';[void](Save-IncomingEvent $agreement)
# A proposal is not itself a confirmation. Keep this mock faithful to the
# two-turn workflow so it does not close the discussion before the reply.
function Invoke-EventAi($Event){return [pscustomobject]@{status=$(if($Event.Body -match '可以嗎'){ 'uncertain' }else{'confirmed'});date='2026-09-10';time='15:00';image_readable=$false}}
Invoke-ClassifierPass
Assert (Test-Path (Get-StatePath 'outbox' (Get-EventHash ($agreement.Id+'|Confirmed')))) 'contextual reply confirms recent proposed surgery time'
$expired=$tracked[0];$expired.Status='accepted';$expired.NextReceiptUtc=[datetime]::UtcNow.AddSeconds(-1).ToString('o');Write-State (Get-StatePath 'outbox' $expired.Id) $expired
function Invoke-ReceiptHttp {return [pscustomobject]@{status=1;acknowledged=0;expired=1}}
Invoke-ReceiptPass
Assert ((Read-State (Get-StatePath 'outbox' $expired.Id)).Status -eq 'expired') 'expired unacknowledged emergency is tracked'
if($LiveAi){
    . (Join-Path $PSScriptRoot 'Notifier.Core.ps1') # Restore actual AI HTTP implementation, never invoke sender.
    $result=Invoke-EventAi (New-TestEvent 'live' '明天10點接') @()
    Assert ($result.status -eq 'confirmed') 'live AI classifies synthetic confirmed schedule'
    Add-Type -AssemblyName System.Drawing
    $bitmap=New-Object Drawing.Bitmap(800,240)
    $graphics=[Drawing.Graphics]::FromImage($bitmap)
    $font=New-Object Drawing.Font('Microsoft JhengHei',32)
    $stream=New-Object IO.MemoryStream
    try {
        $graphics.Clear([Drawing.Color]::White)
        $graphics.DrawString('9/10 中午 12:00 接刀',$font,[Drawing.Brushes]::Black,30,80)
        $bitmap.Save($stream,[Drawing.Imaging.ImageFormat]::Png)
        $picture.Images=@([pscustomobject]@{Mime='image/png';Data=[Convert]::ToBase64String($stream.ToArray())})
        $result=Invoke-EventAi $picture @()
        Assert ($result.status -eq 'confirmed' -and $result.image_readable) 'live AI reads synthetic schedule photograph'
    } finally {$graphics.Dispose();$font.Dispose();$bitmap.Dispose();$stream.Dispose()}
}
Write-Output "RESULT: $script:Passed checks passed. State: $testRoot"
