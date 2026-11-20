# Synthetic multi-recipient tests; never call real Pushover or AI.
param([switch]$Ui)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Notifier.Core.ps1')
$root=Join-Path $PSScriptRoot ('state/multi-test-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$config=Join-Path $root 'appsettings.json'
$fixture=Get-Content (Join-Path $PSScriptRoot 'appsettings.example.json') -Raw -Encoding UTF8|ConvertFrom-Json
$fixture.NotificationRouting.Mode='AllEnabled';$fixture.Pushover.Enabled=$true
[IO.File]::WriteAllText($config,($fixture|ConvertTo-Json -Depth 15),[Text.Encoding]::UTF8)
Initialize-Notifier $config
$script:Passed=0
function Assert($Condition,[string]$Name){if(-not $Condition){throw "FAIL: $Name"};$script:Passed++;"PASS: $Name"}
function Get-UserSecret {return 'uuuuuuuuuuuuuuuuuuuuuuuuuuuuuu'}
function Event([string]$Text){return [pscustomobject]@{Id=(Get-EventHash ([guid]::NewGuid().ToString('N')));Body=$Text;Group='fixture';ArrivalUtc=(Get-UtcStamp);Images=@();ImageSources=@();ImageStatus='none';Local=(Get-LocalDecision $Text)}}
function Alerts([string]$Id){return @(Get-ChildItem (Join-Path $script:StateRoot outbox) -Filter '*.dat'|ForEach-Object {Read-State $_.FullName}|Where-Object EventId -eq $Id)}
function Invoke-PushHttp($Alert){
    if($Alert.RecipientId -eq $script:FailRecipient){throw 'SyntheticOffline'}
    return [pscustomobject]@{status=1;receipt=('receipt-'+$Alert.Id)}
}
function Invoke-ReceiptHttp($Receipt){return [pscustomobject]@{status=1;acknowledged=($Receipt -eq $script:AckReceipt);expired=0}}
function Invoke-CancelReceiptHttp {return [pscustomobject]@{status=1}}
Enable-Team
Assert ((Get-NotificationRoutingMode) -eq 'AllEnabled' -and -not (Test-RosterEnabled)) 'multi mode does not enable roster'
foreach($p in @(
    [pscustomobject]@{Id='alice';Name='Alice';Aliases=@();Enabled=$true;IsAdmin=$false;AlwaysOnDuty=$false;LeadMinutes=30;UserKey=('a'*30);KeyEnvironment=''},
    [pscustomobject]@{Id='bob';Name='Bob';Aliases=@();Enabled=$false;IsAdmin=$false;AlwaysOnDuty=$true;LeadMinutes=90;UserKey=('b'*30);KeyEnvironment=''}
)){Save-TeamPerson $p (Get-TeamModel).Version}
$future=Convert-TaipeiUtc (Format-Taipei ([datetime]::UtcNow.AddDays(1)))
$e=Event ((Format-Taipei $future)+'接刀');[void](Save-IncomingEvent $e);Invoke-TeamSchedulerPass
$a=@(Alerts $e.Id)
Assert ($a.Count -eq 4 -and @($a|Where-Object RecipientId -eq 'bob').Count -eq 0) 'only enabled recipients get independent notice and urgent stages'
Assert (@($a|Where-Object {$_.RecipientId -eq 'alice' -and $_.Stage -eq 'urgent' -and ([datetime]$_.DueUtc).ToUniversalTime() -eq $future.AddMinutes(-30)}).Count -eq 1) 'individual 30-minute lead is honored'
Assert (@($a|Where-Object {$_.RecipientId -eq 'owner' -and $_.Stage -eq 'urgent' -and ([datetime]$_.DueUtc).ToUniversalTime() -eq $future.AddMinutes(-60)}).Count -eq 1) 'owner 60-minute lead retained'
Assert (@($a|Where-Object {$_.Message -match '班表|時間需核對'}).Count -eq 0) 'no misleading missing-roster warning'
$m=Get-TeamModel;$m.Shifts=@([pscustomobject]@{PersonId='bob';StartUtc=$future.AddHours(-1).ToString('o');EndUtc=$future.AddHours(1).ToString('o')});Save-TeamModel $m $m.Version
Invoke-TeamSchedulerPass
Assert ((@(Alerts $e.Id)).Count -eq 4) 'published shifts cannot add a disabled recipient or duplicate work'
$direct=Event '出勤';[void](Save-IncomingEvent $direct);Invoke-TeamSchedulerPass
$script:FailRecipient='alice';Invoke-SenderPass
$a=@(Alerts $direct.Id)
Assert (@($a|Where-Object {$_.RecipientId -eq 'owner' -and $_.Status -eq 'accepted'}).Count -eq 1 -and @($a|Where-Object {$_.RecipientId -eq 'alice' -and $_.Status -eq 'pending' -and $_.Attempts -eq 1}).Count -eq 1) 'one recipient failure does not block another'
$script:FailRecipient='';$alice=@($a|Where-Object RecipientId -eq 'alice')[0];$alice.NextAttemptUtc=Get-UtcStamp;Write-State (Get-StatePath outbox $alice.Id) $alice;Invoke-SenderPass
$a=@(Alerts $direct.Id);$owner=@($a|Where-Object RecipientId -eq 'owner')[0];$alice=@($a|Where-Object RecipientId -eq 'alice')[0]
Assert ($alice.Status -eq 'accepted' -and $alice.Attempts -eq 2 -and $owner.Attempts -eq 1 -and $owner.Receipt -ne $alice.Receipt) 'retry is individual and receipt IDs are distinct'
$script:AckReceipt=$owner.Receipt
foreach($alert in $a){$alert.NextReceiptUtc=Get-UtcStamp;Write-State (Get-StatePath outbox $alert.Id) $alert}
Invoke-ReceiptPass
Assert ((Read-State (Get-StatePath outbox $owner.Id)).Status -eq 'acknowledged' -and (Read-State (Get-StatePath outbox $alice.Id)).Status -eq 'accepted') 'owner acknowledgement does not stop Alice'
$alice=Read-State (Get-StatePath outbox $alice.Id);$alice.AcceptedUtc=[datetime]::UtcNow.AddMinutes(-6).ToString('o');Write-State (Get-StatePath outbox $alice.Id) $alice
Invoke-TeamSchedulerPass;Invoke-TeamSchedulerPass
$esc=@(Alerts $direct.Id|Where-Object Stage -like 'escalation-*')
Assert ($esc.Count -eq 1 -and $esc[0].RecipientId -eq 'owner' -and $esc[0].Message -match 'Alice') 'five-minute escalation is admin-only and deduplicated'
$script:AckReceipt=$alice.Receipt;$alice.NextReceiptUtc=Get-UtcStamp;Write-State (Get-StatePath outbox $alice.Id) $alice;Invoke-ReceiptPass;Invoke-TeamSchedulerPass
Assert ((Read-State (Get-StatePath schedules $direct.Id)).Status -eq 'completed') 'all individual acknowledgements complete the immediate schedule'
$before=@(Alerts $direct.Id).Count
$m=Get-TeamModel;$bob=@($m.People|Where-Object Id -eq 'bob')[0];$bob.Enabled=$true;Save-TeamPerson $bob $m.Version;Invoke-TeamSchedulerPass
Assert (@(Alerts $direct.Id).Count -eq $before) 'adding a recipient never replays completed schedules'
Assert (@(Alerts $e.Id|Where-Object RecipientId -eq 'bob').Count -eq 2) 'new enabled recipient joins still-active future schedules'
$vague=Event '明天中午接刀';[void](Save-IncomingEvent $vague);Invoke-TeamSchedulerPass
$a=@(Alerts $vague.Id)
Assert ($a.Count -eq 3 -and @($a|Where-Object {$_.Kind -ne 'Confirmed' -or $_.Stage -ne 'urgent'}).Count -eq 0) 'vague confirmed demand urgently notifies every enabled person'
$m=Get-TeamModel;$bob=@($m.People|Where-Object Id -eq 'bob')[0];$bob.Enabled=$false;Save-TeamPerson $bob $m.Version;Invoke-TeamSchedulerPass
Assert (@(Alerts $e.Id|Where-Object {$_.RecipientId -eq 'bob' -and $_.Stage -eq 'urgent' -and $_.Status -eq 'pending'}).Count -eq 0) 'disabling recipient removes their pending urgent work'
$past=Event ((Format-Taipei ([datetime]::UtcNow.AddHours(-2)))+'接刀');[void](Save-IncomingEvent $past);Invoke-TeamSchedulerPass
$a=@(Alerts $past.Id)
Assert ($a.Count -eq 1 -and $a[0].RecipientId -eq 'owner') 'overdue recovery stays admin-only'
foreach($op in @({New-RosterDraft 'missing.pdf'},{Invoke-RosterAi $null},{Publish-Roster $null})){
    $blocked=$false;try{& $op}catch{$blocked=$_.Exception.Message -like '班表功能已停用*'}
    Assert $blocked 'roster operation remains disabled'
}
$count=@(Alerts $e.Id).Count;Initialize-Notifier $config;Invoke-TeamSchedulerPass
Assert ((Get-NotificationRoutingMode) -eq 'AllEnabled' -and @(Alerts $e.Id).Count -eq $count) 'restart retains mode and does not duplicate deliveries'
if($Ui){& powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File (Join-Path $PSScriptRoot 'Show-TeamManagement.ps1') -ConfigPath $config -SmokeTest;if($LASTEXITCODE){throw 'Multi UI failed'}}
"RESULT: $script:Passed checks passed. Fixture: $root"
