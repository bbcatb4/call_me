# Isolated fixtures only; no real AI, Pushover, or production state.
param([switch]$Ui)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Notifier.Core.ps1')
$root=Join-Path $PSScriptRoot ('state/owner-test-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$config=Join-Path $root 'appsettings.json'
[IO.File]::WriteAllText($config,[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'appsettings.example.json')),[Text.Encoding]::UTF8)
Initialize-Notifier $config
$script:Passed=0
function Assert($Condition,[string]$Name){if(-not $Condition){throw "FAIL: $Name"};$script:Passed++;"PASS: $Name"}
function Get-UserSecret {return 'uuuuuuuuuuuuuuuuuuuuuuuuuuuuuu'}
function Invoke-PushHttp {throw 'UnexpectedNetworkCall'}
function Alerts([string]$Id){return @(Get-ChildItem (Join-Path $script:StateRoot 'outbox') -Filter '*.dat'|ForEach-Object {Read-State $_.FullName}|Where-Object EventId -eq $Id)}
function Event([string]$Text){return [pscustomobject]@{Id=(Get-EventHash ([guid]::NewGuid().ToString('N')));Body=$Text;Group='fixture';ArrivalUtc=(Get-UtcStamp);Images=@();ImageSources=@();ImageStatus='none';Local=(Get-LocalDecision $Text)}}
Enable-Team
Assert (-not (Test-RosterEnabled)) 'default mode disables roster'
$script:Settings.PSObject.Properties.Remove('NotificationRouting')
Assert (-not (Test-RosterEnabled)) 'missing option also defaults to owner only'
Initialize-Notifier $config
$future=Convert-TaipeiUtc (Format-Taipei ([datetime]::UtcNow.AddDays(2)))
$e=Event ((Format-Taipei $future)+'接刀');[void](Save-IncomingEvent $e);Invoke-TeamSchedulerPass
$a=Alerts $e.Id
Assert ($a.Count -eq 2 -and @($a|Where-Object RecipientId -ne 'owner').Count -eq 0) 'exact future creates two owner-only stages'
$urgent=@($a|Where-Object Stage -eq 'urgent')[0];$notice=@($a|Where-Object Stage -eq 'notice')[0]
Assert ($urgent.Kind -eq 'Confirmed' -and ([datetime]$urgent.DueUtc).ToUniversalTime() -eq $future.AddMinutes(-60)) 'priority stage and 60-minute lead retained'
Assert ($notice.Kind -eq 'Review' -and $notice.Message -notmatch '班表|時間需核對|時間待補') 'precise time has no false uncertainty warning'
$m=Get-TeamModel;$owner=@($m.People|Where-Object Id -eq 'owner')[0];$owner.AlwaysOnDuty=$false
$m.People+=@([pscustomobject]@{Id='colleague';Name='Fixture';Aliases=@();Enabled=$true;IsAdmin=$true;AlwaysOnDuty=$true;LeadMinutes=30;UserKey='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';KeyEnvironment=''})
$m.Shifts=@([pscustomobject]@{PersonId='colleague';StartUtc=$future.AddHours(-1).ToString('o');EndUtc=$future.AddHours(1).ToString('o')})
Save-TeamModel $m $m.Version;Invoke-TeamSchedulerPass
$plan=Read-State (Get-StatePath schedules $e.Id);$routes=@(Get-TeamScheduleRoutes $plan (Get-TeamModel) ([datetime]::UtcNow))
Assert ($routes.Count -eq 1 -and $routes[0].Person.Id -eq 'owner' -and $routes[0].Reason -eq 'direct_owner') 'ignores published shifts, other admins and always-on toggles'
Assert ((Alerts $e.Id).Count -eq 2) 'routing change does not duplicate existing work'
# Simulate the pre-upgrade misleading pending text and an already accepted notice.
$urgent.Message='【班表／時間需核對】';Write-State (Get-StatePath outbox $urgent.Id) $urgent
$notice.Status='accepted';$notice.Attempts=1;$notice.AcceptedUtc=Get-UtcStamp;$notice.Message='accepted historical text';Write-State (Get-StatePath outbox $notice.Id) $notice
Invoke-TeamSchedulerPass;Invoke-TeamSchedulerPass
$updated=Read-State (Get-StatePath outbox $urgent.Id);$history=Read-State (Get-StatePath outbox $notice.Id)
Assert ($updated.Message -notmatch '班表|時間需核對' -and $updated.Id -eq $urgent.Id -and $updated.DueUtc -eq $urgent.DueUtc -and $updated.Attempts -eq 0) 'unsent text refreshed without changing identity or due time'
Assert ($history.Message -eq 'accepted historical text' -and $history.Status -eq 'accepted' -and (Alerts $e.Id).Count -eq 2) 'accepted notice is neither rewritten nor replayed'
$vague=Event '明天中午接刀';[void](Save-IncomingEvent $vague);Invoke-TeamSchedulerPass
$a=@(Alerts $vague.Id)
Assert ($a.Count -eq 1 -and $a[0].Kind -eq 'Confirmed' -and $a[0].Message -match '已確認接刀需求，時間待補' -and ([datetime]$a[0].DueUtc).ToUniversalTime() -le [datetime]::UtcNow) 'vague confirmed time stays urgent immediately, not downgraded'
$direct=Event '出勤';[void](Save-IncomingEvent $direct);Invoke-TeamSchedulerPass
$a=@(Alerts $direct.Id)
Assert ($a.Count -eq 1 -and $a[0].Kind -eq 'Confirmed' -and $a[0].Message -match '立即出勤' -and $a[0].Message -notmatch '時間待|班表') 'direct call does not ask to confirm time'
$live=$a[0];$live.Status='accepted';$live.Receipt='fixture-receipt';$live.AcceptedUtc=[datetime]::UtcNow.AddMinutes(-6).ToString('o');Write-State (Get-StatePath outbox $live.Id) $live
Invoke-TeamSchedulerPass;Invoke-TeamSchedulerPass
$escalations=@(Alerts $direct.Id|Where-Object Stage -like 'escalation-*')
Assert ($escalations.Count -eq 1 -and $escalations[0].RecipientId -eq 'owner') 'unacknowledged escalation only goes to owner once'
Assert ((Read-State (Get-StatePath outbox $live.Id)).Receipt -eq 'fixture-receipt') 'existing receipt remains intact'
foreach($operation in @({New-RosterDraft 'does-not-exist.pdf'},{Invoke-RosterAi $null},{Publish-Roster $null})){
    $blocked=$false;try{& $operation}catch{$blocked=$_.Exception.Message -like '班表功能已停用*'}
    Assert $blocked 'disabled roster operation is rejected before IO or AI'
}
$m=Get-TeamModel;$owner=@($m.People|Where-Object Id -eq 'owner')[0];$owner.Enabled=$false;$blocked=$false
try{Save-TeamPerson $owner $m.Version}catch{$blocked=$true}
Assert $blocked 'owner cannot be disabled in owner-only mode'
Initialize-Notifier $config;Invoke-TeamSchedulerPass
Assert ((Alerts $e.Id).Count -eq 2 -and -not (Test-RosterEnabled)) 'restart preserves routing mode and deduplication'
$plan=Read-State (Get-StatePath schedules $e.Id)
Set-TeamSchedule $e.Id '' -Cancel -ExpectedVersion $plan.Version;Invoke-TeamSchedulerPass
Assert (@(Alerts $e.Id|Where-Object {$_.Stage -eq 'urgent' -and $_.Status -eq 'pending'}).Count -eq 0) 'cancellation still removes pending urgent work'
$past=Event ((Format-Taipei ([datetime]::UtcNow.AddHours(-2)))+'接刀');[void](Save-IncomingEvent $past);Invoke-TeamSchedulerPass
$a=@(Alerts $past.Id)
Assert ($a.Count -eq 1 -and $a[0].RecipientId -eq 'owner' -and $a[0].Message -match '已過接刀時間') 'overdue recovery remains owner-only with honest warning'
if($Ui){
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File (Join-Path $PSScriptRoot 'Show-TeamManagement.ps1') -ConfigPath $config -SmokeTest
    if($LASTEXITCODE){throw 'Owner UI failed'}
}
"RESULT: $script:Passed checks passed. Fixture: $root"
