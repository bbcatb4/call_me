param([switch]$Ui)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Notifier.Core.ps1')
$root=Join-Path $PSScriptRoot ('state/team-test-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$config=Join-Path $root 'appsettings.json'
[IO.File]::WriteAllText($config,[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'appsettings.example.json')),[Text.Encoding]::UTF8)
Initialize-Notifier $config
$script:Settings.NotificationRouting.Mode='Roster'
$script:Settings.Pushover.Enabled=$true;$script:Passed=0
function Get-UserSecret {return 'uuuuuuuuuuuuuuuuuuuuuuuuuuuuuu'}
function Assert($Condition,[string]$Name){if(-not $Condition){throw "FAIL: $Name"};$script:Passed++;"PASS: $Name"}
function Event([string]$Text,[string]$Id=''){
    if(-not $Id){$Id=[guid]::NewGuid().ToString('N')}
    return [pscustomobject]@{Id=(Get-EventHash $Id);Body=$Text;Group='fixture';ArrivalUtc=(Get-UtcStamp);Images=@();ImageSources=@();ImageStatus='none';Local=(Get-LocalDecision $Text)}
}
function Alerts([string]$Id){return @(Get-ChildItem (Join-Path $script:StateRoot 'outbox') -Filter '*.dat'|ForEach-Object {Read-State $_.FullName}|Where-Object EventId -eq $Id)}
$legacy=Event '出勤';[void](Save-IncomingEvent $legacy)
Enable-Team;Enable-Team
$m=Get-TeamModel
Assert ($m.People.Count -eq 1 -and $m.People[0].AlwaysOnDuty -and $m.People[0].IsAdmin -and $m.People[0].LeadMinutes -eq 60) 'owner migration is idempotent and always on duty'
Assert (-not (Test-TeamEvent $legacy)) 'pre-migration inbox keeps original path'
$arrival=(Convert-TaipeiUtc '2026-09-11 20:00').ToString('o')
Assert ((Resolve-DutyMoment '明天中午接刀' $arrival).WhenUtc -eq '') 'vague period is never invented as a clock time'
Assert ((Format-Taipei (Resolve-DutyMoment '明天上午八點接刀' $arrival).WhenUtc) -eq '2026-09-12 08:00') 'relative Chinese time uses Taipei original arrival'
Assert ((Format-Taipei (Resolve-DutyMoment '明天15:30接刀' $arrival).WhenUtc) -eq '2026-09-12 15:30') '24-hour precise time parses'
Assert ((Resolve-DutyMoment '出勤' $arrival).Immediate) 'direct instruction is immediate'
Assert ((Resolve-DutyMoment '9/12三點接刀' $arrival).WhenUtc -eq '') 'ambiguous AM/PM stays unresolved'
$future=[datetime]::UtcNow.AddDays(1);$futureText=(Format-Taipei $future);$future=Convert-TaipeiUtc $futureText
$e=Event ($futureText+'接刀');[void](Save-IncomingEvent $e);Invoke-TeamSchedulerPass
$a=Alerts $e.Id
Assert ($a.Count -eq 2 -and @($a|Where-Object Stage -eq 'notice').Count -eq 1 -and @($a|Where-Object Stage -eq 'urgent').Count -eq 1) 'precise future schedule has notice plus distinct urgent stage'
$urgent=@($a|Where-Object Stage -eq 'urgent')[0]
Assert (([datetime]$urgent.DueUtc).ToUniversalTime() -eq $future.AddMinutes(-60)) 'owner defaults to 60-minute lead'
Invoke-TeamSchedulerPass;[void](Save-IncomingEvent $e);Invoke-TeamSchedulerPass
Assert ((Alerts $e.Id).Count -eq 2) 'scheduler rerun and inbox duplicate do not duplicate deliveries'
$person=[pscustomobject]@{Id='colleague';Name='同事甲';Aliases=@('甲');Enabled=$true;IsAdmin=$false;AlwaysOnDuty=$false;LeadMinutes=30;UserKey='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';KeyEnvironment=''}
Save-TeamPerson $person (Get-TeamModel).Version
$person2=[pscustomobject]@{Id='backup';Name='同事乙';Aliases=@('乙');Enabled=$true;IsAdmin=$false;AlwaysOnDuty=$false;LeadMinutes=90;UserKey='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';KeyEnvironment=''}
Save-TeamPerson $person2 (Get-TeamModel).Version
$m=Get-TeamModel;$m.Shifts=@([pscustomobject]@{PersonId='colleague';StartUtc=$future.AddHours(-4).ToString('o');EndUtc=$future.AddHours(4).ToString('o');RosterId='fixture'})
Save-TeamModel $m $m.Version
Invoke-TeamSchedulerPass;$a=Alerts $e.Id
Assert (@($a|Where-Object RecipientId -eq 'colleague').Count -eq 2) 'published shift colleague is independently routed'
Assert (([datetime]@($a|Where-Object {$_.RecipientId -eq 'colleague' -and $_.Stage -eq 'urgent'})[0].DueUtc).ToUniversalTime() -eq $future.AddMinutes(-30)) 'colleague has individual lead time'
Assert (@(Get-TeamRecipients (Get-TeamModel) $future.AddHours(4)|Where-Object Id -eq 'colleague').Count -eq 0) 'shift end is excluded'
Assert (@(Get-TeamRecipients (Get-TeamModel) $future.AddHours(-4)|Where-Object Id -eq 'colleague').Count -eq 1) 'shift start is included'
Assert (@(Get-TeamRecipients (Get-TeamModel) $future.AddMonths(6)|Where-Object Id -eq 'owner').Count -eq 1) 'owner is on duty beyond any published roster'
$vague=Event '明天中午接刀';[void](Save-IncomingEvent $vague);Invoke-TeamSchedulerPass
Assert (@(Alerts $vague.Id|Where-Object {$_.RecipientId -eq 'owner' -and $_.Kind -eq 'Confirmed'}).Count -eq 1) 'vague confirmed schedule falls back to owner once'
$script:sent=@();function Invoke-PushHttp($Alert){$script:sent+=@($Alert.RecipientId);return [pscustomobject]@{status=1;receipt=('receipt-'+$Alert.Id)}}
Invoke-SenderPass
Assert ((Read-State (Get-StatePath 'outbox' $urgent.Id)).Status -eq 'pending') 'future urgent is not sent early'
$immediate=Event '出勤';[void](Save-IncomingEvent $immediate);Invoke-TeamSchedulerPass;Invoke-SenderPass
$ia=@(Alerts $immediate.Id|Where-Object {$_.RecipientId -eq 'owner' -and $_.Stage -eq 'urgent'})[0]
Assert ($ia.Status -eq 'accepted' -and $ia.Receipt) 'immediate confirmed request receives independent receipt'
$ia.AcceptedUtc=[datetime]::UtcNow.AddMinutes(-6).ToString('o');Write-State (Get-StatePath 'outbox' $ia.Id) $ia
Invoke-TeamSchedulerPass;Invoke-TeamSchedulerPass
Assert (@(Alerts $immediate.Id|Where-Object Stage -like 'escalation-*').Count -eq 1) 'five-minute escalation persists and deduplicates'
function Invoke-ReceiptHttp {return [pscustomobject]@{status=1;acknowledged=1;expired=0}}
$ia.NextReceiptUtc=Get-UtcStamp;Write-State (Get-StatePath 'outbox' $ia.Id) $ia
Invoke-ReceiptPass
Assert ((Read-State (Get-StatePath 'outbox' $ia.Id)).Status -eq 'acknowledged') 'individual receipt acknowledgement is tracked'
$m=Get-TeamModel;$m.Shifts=@([pscustomobject]@{PersonId='backup';StartUtc=$future.AddHours(-4).ToString('o');EndUtc=$future.AddHours(4).ToString('o');RosterId='swap'})
Save-TeamModel $m $m.Version;Invoke-TeamSchedulerPass
Assert (@(Alerts $e.Id|Where-Object {$_.RecipientId -eq 'colleague' -and $_.Stage -eq 'urgent' -and $_.Status -eq 'cancelled'}).Count -eq 1) 'swap cancels pending old recipient urgent'
Assert (@(Alerts $e.Id|Where-Object {$_.RecipientId -eq 'backup' -and $_.Stage -eq 'urgent' -and $_.Status -eq 'pending'}).Count -eq 1) 'swap adds replacement recipient'
$plan=Read-State (Get-StatePath 'schedules' $e.Id)
Set-TeamSchedule $e.Id $future.AddHours(1).ToString('o') -ExpectedVersion $plan.Version;Invoke-TeamSchedulerPass
Assert ((Read-State (Get-StatePath 'schedules' $e.Id)).Version -eq 2) 'manual reschedule creates new version'
$plan=Read-State (Get-StatePath 'schedules' $e.Id);Set-TeamSchedule $e.Id '' -Cancel -ExpectedVersion $plan.Version;Invoke-TeamSchedulerPass
Assert (@(Alerts $e.Id|Where-Object {$_.Stage -eq 'urgent' -and $_.Status -eq 'pending'}).Count -eq 0) 'cancellation removes pending urgent deliveries'
$past=Event (((Format-Taipei ([datetime]::UtcNow.AddHours(-2))))+'接刀');[void](Save-IncomingEvent $past);Invoke-TeamSchedulerPass
Assert (@(Alerts $past.Id|Where-Object RecipientId -ne 'owner').Count -eq 0) 'overdue recovery routes only to admin'
$draft=[pscustomobject]@{Id=[guid]::NewGuid().ToString('N');BaseVersion=(Get-TeamModel).Version;Status='draft';PeriodStart='2027-01-01';PeriodEnd='2027-01-31';Rows=@([pscustomobject]@{Name='甲';Date='2027-01-10';Shift='夜';Start='2027-01-10 20:00';End='2027-01-11 08:00';Note=''})}
Publish-Roster $draft
$m=Get-TeamModel
Assert (@(Get-TeamRecipients $m (Convert-TaipeiUtc '2027-01-11 02:00')|Where-Object Id -eq 'colleague').Count -eq 1) 'published overnight roster uses stable person identity'
$draft.BaseVersion=$m.Version;$draft.Rows[0].Name='不存在';$rejected=$false;try{Publish-Roster $draft}catch{$rejected=$true}
Assert $rejected 'unknown roster person cannot be published'
$draft.Rows[0].Name='甲';$draft.Rows[0].End='';$rejected=$false;try{Publish-Roster $draft}catch{$rejected=$true}
Assert $rejected 'undefined shift times cannot be published'
$rejected=$false;try{Save-TeamPerson $person 1}catch{$rejected=$true}
Assert $rejected 'stale model edit is rejected'
$safe=Get-TeamManagementSnapshot|ConvertTo-Json -Depth 10
Assert ($safe -notmatch 'aaaaaaaaaa|bbbbbbbbbb|receipt-|UserKey|Body') 'management projection excludes keys receipts and chat body'
# Isolate routing lifecycle, automatic change correlation and cancellation transport.
$m=Get-TeamModel;$p=@($m.People|Where-Object Id -eq 'colleague')[0];$p.AlwaysOnDuty=$true;Save-TeamPerson $p $m.Version
$live=Event '出勤';[void](Save-IncomingEvent $live);Invoke-TeamSchedulerPass;Invoke-SenderPass
$livePlan=Read-State (Get-StatePath schedules $live.Id)
$ownerAlert=@(Alerts $live.Id|Where-Object RecipientId -eq 'owner')[0]
$otherAlert=@(Alerts $live.Id|Where-Object RecipientId -eq 'colleague')[0]
foreach($a in @($ownerAlert,$otherAlert)){$a.NextReceiptUtc=Get-UtcStamp;Write-State (Get-StatePath outbox $a.Id) $a}
$script:ackReceipt=$ownerAlert.Receipt
function Invoke-ReceiptHttp($Receipt){return [pscustomobject]@{status=1;acknowledged=($Receipt -eq $script:ackReceipt);expired=0}}
Invoke-ReceiptPass
Assert ((Read-State (Get-StatePath outbox $ownerAlert.Id)).Status -eq 'acknowledged' -and (Read-State (Get-StatePath outbox $otherAlert.Id)).Status -eq 'accepted') 'one person acknowledgement does not silence another'
Set-TeamSchedule $live.Id '' -Cancel -ExpectedVersion $livePlan.Version;Invoke-TeamSchedulerPass
Assert ((Read-State (Get-StatePath outbox $otherAlert.Id)).CancelRequested) 'cancel requests stop for the specific outstanding receipt'
function Invoke-CancelReceiptHttp {throw 'SyntheticOffline'}
Invoke-ReceiptPass
Assert ((Read-State (Get-StatePath outbox $otherAlert.Id)).CancelRequested) 'failed remote cancellation remains durable'
function Invoke-CancelReceiptHttp {return [pscustomobject]@{status=1}}
$otherAlert=Read-State (Get-StatePath outbox $otherAlert.Id);$otherAlert.NextCancelUtc=Get-UtcStamp;Write-State (Get-StatePath outbox $otherAlert.Id) $otherAlert
Invoke-ReceiptPass
Assert ((Read-State (Get-StatePath outbox $otherAlert.Id)).Status -eq 'cancelled') 'remote cancellation succeeds after retry'
$swapEvent=Event ((Format-Taipei ([datetime]::UtcNow.AddDays(5)))+'接刀');[void](Save-IncomingEvent $swapEvent);Invoke-TeamSchedulerPass
$m=Get-TeamModel;$p=@($m.People|Where-Object Id -eq 'colleague')[0];$p.AlwaysOnDuty=$false;Save-TeamPerson $p $m.Version;Invoke-TeamSchedulerPass
$m=Get-TeamModel;$p=@($m.People|Where-Object Id -eq 'colleague')[0];$p.AlwaysOnDuty=$true;Save-TeamPerson $p $m.Version;Invoke-TeamSchedulerPass;Invoke-TeamSchedulerPass
Assert (@(Alerts $swapEvent.Id|Where-Object {$_.RecipientId -eq 'colleague' -and $_.Stage -eq 'urgent' -and $_.Status -eq 'pending'}).Count -eq 1) 'returning to a shift reactivates delivery exactly once with history retained'
$uniqueTime=Format-Taipei ([datetime]::UtcNow.AddDays(8))
$u=Event ($uniqueTime+'接刀');[void](Save-IncomingEvent $u);Invoke-TeamSchedulerPass
$change=Event ($uniqueTime+'接刀取消');[void](Save-IncomingEvent $change);Invoke-TeamSchedulerPass
Assert ((Read-State (Get-StatePath schedules $u.Id)).Status -eq 'cancelled') 'explicit unique date/time cancellation resolves automatically'
$requestFile=@(Get-ChildItem (Join-Path $script:StateRoot dispatch) -Filter '*.dat'|Where-Object {(Read-State $_.FullName).Event.Id -eq $change.Id})[0]
$r=Read-State $requestFile.FullName;$r.Handled=$false;Write-State $requestFile.FullName $r;Invoke-TeamSchedulerPass
Assert (-not (Test-Path (Get-StatePath schedules $change.Id))) 'recovery after applying a change does not recreate an ambiguous change'
$time=Format-Taipei ([datetime]::UtcNow.AddDays(9))
$u1=Event ($time+'接刀');$u2=Event ($time+'接刀');[void](Save-IncomingEvent $u1);[void](Save-IncomingEvent $u2);Invoke-TeamSchedulerPass
$amb=Event ($time+'接刀取消');[void](Save-IncomingEvent $amb);Invoke-TeamSchedulerPass
Assert ((Read-State (Get-StatePath schedules $amb.Id)).Status -eq 'change_review' -and (Read-State (Get-StatePath schedules $u1.Id)).Status -eq 'active') 'two simultaneous surgeries require manual change selection'
$target=Read-State (Get-StatePath schedules $u1.Id);Resolve-TeamChange $amb.Id $u1.Id '' -Cancel -ExpectedVersion $target.Version;Invoke-TeamSchedulerPass
Assert ((Read-State (Get-StatePath schedules $u1.Id)).Status -eq 'cancelled' -and (Read-State (Get-StatePath schedules $u2.Id)).Status -eq 'active') 'manual selection cancels only chosen surgery'
$rescheduleTime=Format-Taipei ([datetime]::UtcNow.AddDays(10));$u3=Event ($rescheduleTime+'接刀');[void](Save-IncomingEvent $u3);Invoke-TeamSchedulerPass
$newTime=Format-Taipei ((Convert-TaipeiUtc $rescheduleTime).AddHours(2))
$reschedule=Event ($rescheduleTime+'接刀改到'+$newTime);[void](Save-IncomingEvent $reschedule);Invoke-TeamSchedulerPass
Assert ((Format-Taipei (Read-State (Get-StatePath schedules $u3.Id)).WhenUtc) -eq $newTime) 'unique explicit old and new times reschedule automatically'
Invoke-TeamSchedulerPass
Assert ((Read-State (Get-StatePath schedules $immediate.Id)).Status -eq 'completed') 'acknowledged immediate call becomes completed and does not follow future shifts'
Initialize-Notifier $config;Invoke-TeamSchedulerPass
Assert ((Get-TeamModel).People[0].Id -eq 'owner') 'encrypted team model survives restart'
if($Ui){& powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File (Join-Path $PSScriptRoot 'Show-TeamManagement.ps1') -ConfigPath $config -SmokeTest;if($LASTEXITCODE){throw 'UI failed'}}
"RESULT: $script:Passed checks passed. Fixture: $root"
