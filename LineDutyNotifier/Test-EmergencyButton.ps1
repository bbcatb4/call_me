# Isolated synthetic tests; no real Pushover/AI requests or live state changes.
param([switch]$Ui)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Notifier.Core.ps1')
$root=Join-Path $PSScriptRoot ('state/emergency-button-test-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$config=Join-Path $root 'appsettings.json'
$settings=Get-Content (Join-Path $PSScriptRoot appsettings.example.json) -Raw -Encoding UTF8|ConvertFrom-Json
$settings.Pushover.Enabled=$true;$settings.Pushover.ExpireSeconds=3600;$settings.NotificationRouting.Mode='AllEnabled'
[IO.File]::WriteAllText($config,($settings|ConvertTo-Json -Depth 10),[Text.Encoding]::UTF8)
Initialize-Notifier $config;$script:Passed=0;$script:Requests=@();$script:FailPush=$false;$script:FailCancel=$false;$script:Ack=''
function Assert($Condition,[string]$Name){if(-not $Condition){throw "FAIL: $Name"};$script:Passed++;"PASS: $Name"}
function Get-UserSecret {return ('u'*30)}
function Invoke-RestMethod {
    param($Method,$Uri,$Body,$TimeoutSec,$ErrorAction)
    if($Uri -ne 'https://api.pushover.net/1/messages.json'){throw 'Unexpected request'}
    $script:Requests+=@($Body)
    if($script:FailPush){throw 'SyntheticOffline'}
    return [pscustomobject]@{status=1;receipt=('fixture-'+[guid]::NewGuid().ToString('N'))}
}
function Invoke-ReceiptHttp($Receipt){return [pscustomobject]@{status=1;acknowledged=($Receipt -eq $script:Ack);expired=0}}
function Invoke-CancelReceiptHttp {if($script:FailCancel){throw 'SyntheticOffline'};return [pscustomobject]@{status=1}}
Enable-Team
$p=[pscustomobject]@{Id='alice';Name='Alice';Aliases=@();Enabled=$false;IsAdmin=$false;AlwaysOnDuty=$false;LeadMinutes=30;UserKey=('a'*30);KeyEnvironment=''}
Save-TeamPerson $p (Get-TeamModel).Version
$blocked=$false;try{Start-TeamEmergencyTest owner}catch{$blocked=$true};Assert $blocked 'explicit confirmation required'
$blocked=$false;try{Start-TeamEmergencyTest nonexistent -Confirmed}catch{$blocked=$true};Assert $blocked 'unknown recipient rejected'
$script:Settings.Pushover.Enabled=$false;$blocked=$false;try{Start-TeamEmergencyTest owner -Confirmed}catch{$blocked=$true};Assert $blocked 'disabled transport rejected';$script:Settings.Pushover.Enabled=$true
$id=Start-TeamEmergencyTest alice -Confirmed;$a=Read-State (Get-StatePath outbox $id)
Assert ($a.IsTest -and $a.Stage -eq 'emergency_test' -and $a.RecipientId -eq 'alice' -and $a.Status -eq 'pending') 'saved disabled person can receive an explicitly requested test'
Assert (@(Get-ChildItem (Join-Path $script:StateRoot schedules) -Filter '*.dat').Count -eq 0 -and @(Get-ChildItem (Join-Path $script:StateRoot inbox) -Filter '*.dat').Count -eq 0) 'test never creates incoming duty event or schedule'
$blocked=$false;try{Start-TeamEmergencyTest alice -Confirmed}catch{$blocked=$true};Assert $blocked 'double click cannot enqueue duplicate active test'
[void](Stop-TeamEmergencyTests alice);Invoke-SenderPass
Assert ((Read-State (Get-StatePath outbox $id)).Status -eq 'cancelled' -and $script:Requests.Count -eq 0) 'stop before send prevents any HTTP request'
$ownerId=Start-TeamEmergencyTest owner -Confirmed;$aliceId=Start-TeamEmergencyTest alice -Confirmed
Invoke-SenderPass
$owner=Read-State (Get-StatePath outbox $ownerId);$alice=Read-State (Get-StatePath outbox $aliceId)
Assert ($script:Requests.Count -eq 2 -and $owner.Status -eq 'accepted' -and $alice.Status -eq 'accepted' -and $owner.Receipt -ne $alice.Receipt) 'each selected person receives independent receipt'
Assert (@($script:Requests|Where-Object {$_.priority -ne 2 -or $_.retry -ne 30 -or $_.expire -ne 120 -or $_.title -notmatch '測試.*非出勤'}).Count -eq 0) 'test HTTP payload uses priority 2 retry 30 expire 120 and unmistakable title'
Assert (@($script:Requests|Where-Object user -eq ('a'*30)).Count -eq 1 -and @($script:Requests|Where-Object user -eq ('u'*30)).Count -eq 1) 'transport uses selected individual keys'
$script:Ack=$owner.Receipt
foreach($a in @($owner,$alice)){$a.NextReceiptUtc=Get-UtcStamp;Write-State (Get-StatePath outbox $a.Id) $a}
Invoke-ReceiptPass
Assert ((Read-State (Get-StatePath outbox $ownerId)).Status -eq 'acknowledged' -and (Read-State (Get-StatePath outbox $aliceId)).Status -eq 'accepted') 'one acknowledgement leaves other test ringing'
$alice=Read-State (Get-StatePath outbox $aliceId);$alice.AcceptedUtc=[datetime]::UtcNow.AddMinutes(-6).ToString('o');Write-State (Get-StatePath outbox $aliceId) $alice
Invoke-TeamSchedulerPass
Assert (@(Get-ChildItem (Join-Path $script:StateRoot outbox) -Filter '*.dat'|ForEach-Object {Read-State $_.FullName}|Where-Object Stage -like 'escalation-*').Count -eq 0) 'manual tests never escalate as surgery alerts'
# A real schedule coexists, with its original transport parameters.
$event=[pscustomobject]@{Id=(Get-EventHash 'synthetic-formal-duty');Body='出勤';Group='fixture';ArrivalUtc=(Get-UtcStamp);Images=@();ImageSources=@();ImageStatus='none';Local=(Get-LocalDecision '出勤')}
[void](Save-IncomingEvent $event);Invoke-TeamSchedulerPass;Invoke-SenderPass
$formal=@(Get-ChildItem (Join-Path $script:StateRoot outbox) -Filter '*.dat'|ForEach-Object {Read-State $_.FullName}|Where-Object EventId -eq $event.Id)[0]
Assert ($script:Requests[-1].expire -eq 3600 -and $script:Requests[-1].title -eq '【出勤通知】緊急接刀提醒') 'formal emergency remains one hour and duty title'
[void](Stop-TeamEmergencyTests alice);$script:FailCancel=$true;Invoke-ReceiptPass
$alice=Read-State (Get-StatePath outbox $aliceId)
Assert ($alice.Status -eq 'accepted' -and $alice.CancelRequested) 'offline stop remains durable and is not claimed cancelled'
Assert ((Read-State (Get-StatePath outbox $formal.Id)).Status -eq 'accepted' -and -not (Read-State (Get-StatePath outbox $formal.Id)).CancelRequested) 'stopping test leaves formal alert untouched'
$snapshot=Get-TeamManagementSnapshot
Assert (@($snapshot.Deliveries|Where-Object {$_.Stage -eq 'emergency_test' -and $_.StatusLabel -like '停止中*'}).Count -eq 1) 'UI distinguishes cancellation pending'
$safe=$snapshot|ConvertTo-Json -Depth 10
Assert ($safe -notmatch 'fixture-|aaaaaa|UserKey|Receipt') 'test view never exposes keys or receipts'
Initialize-Notifier $config;$script:FailCancel=$false;$alice=Read-State (Get-StatePath outbox $aliceId);$alice.NextCancelUtc=Get-UtcStamp;Write-State (Get-StatePath outbox $aliceId) $alice
Invoke-ReceiptPass
Assert ((Read-State (Get-StatePath outbox $aliceId)).Status -eq 'cancelled') 'remote stop survives restart and succeeds on retry'
$id=Start-TeamEmergencyTest alice -Confirmed;$script:FailPush=$true;Invoke-SenderPass
$a=Read-State (Get-StatePath outbox $id)
Assert ($a.Status -eq 'pending' -and $a.Attempts -eq 1) 'failed test delivery retries durably'
$a.NotAfterUtc=[datetime]::UtcNow.AddSeconds(-1).ToString('o');$a.NextAttemptUtc=Get-UtcStamp;Write-State (Get-StatePath outbox $id) $a
$before=$script:Requests.Count;Initialize-Notifier $config;Invoke-SenderPass
Assert ((Read-State (Get-StatePath outbox $id)).Status -eq 'expired' -and $script:Requests.Count -eq $before) 'stale queued test cannot ring after recovery'
$script:FailPush=$false;$id=Start-TeamEmergencyTest alice -Confirmed;Invoke-SenderPass
function Invoke-ReceiptHttp {return [pscustomobject]@{status=1;acknowledged=0;expired=1}}
$a=Read-State (Get-StatePath outbox $id);$a.NextReceiptUtc=Get-UtcStamp;Write-State (Get-StatePath outbox $id) $a;Invoke-ReceiptPass
Assert ((Read-State (Get-StatePath outbox $id)).Status -eq 'expired') 'service test expiry is tracked'
if($Ui){& powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File (Join-Path $PSScriptRoot 'Show-TeamManagement.ps1') -ConfigPath $config -SmokeTest;if($LASTEXITCODE){throw 'UI failed'}}
"RESULT: $script:Passed checks passed. Fixture: $root"
