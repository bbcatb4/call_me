# Synthetic fixtures only; no HTTP requests leave this test.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Notifier.Core.ps1')
$root=Join-Path $PSScriptRoot ('state/labels-test-'+[guid]::NewGuid().ToString('N'))
Initialize-Notifier (Join-Path $PSScriptRoot 'appsettings.example.json') $root
$script:LogDirectory=$root
$script:Settings.Pushover.RetrySeconds=30;$script:Settings.Pushover.ExpireSeconds=3600
$script:Passed=0
function Assert($Condition,[string]$Name){if(-not $Condition){throw "FAIL: $Name"};$script:Passed++;"PASS: $Name"}
function Get-UserSecret {return 'synthetic-secret'}
function Get-TeamRecipientKey($Id){return ('synthetic-'+$Id)}
function Invoke-RestMethod {param($Method,$Uri,$Body,$TimeoutSec,$ErrorAction);$script:Payload=$Body;return [pscustomobject]@{status=1;receipt='fake'}}
function Alert([string]$Stage,[string]$Kind='Review'){
    return [pscustomobject]@{Stage=$Stage;Kind=$Kind;RecipientId='owner';Title='old title';Message='排程：synthetic';ArrivalUtc='';DeliveryReason='';IsTest=$false}
}
$cases=@(
    @('urgent','Confirmed','【出勤通知】緊急接刀提醒',2),
    @('notice','Review','【出勤通知】接刀排程預告',0),
    @('review','Review','【出勤通知】疑似需求待確認',0),
    @('changed','Review','【出勤通知】排程異動',0),
    @('escalation-fake','Review','【管理員通知】出勤人員尚未確認',0)
)
foreach($case in $cases){
    $a=Alert $case[0] $case[1];[void](Invoke-PushHttp $a)
    Assert ($script:Payload.title -eq $case[2]) ('actual HTTP title: '+$case[0])
    Assert ($script:Payload.priority -eq $case[3] -and $script:Payload.user -eq 'synthetic-owner') ('priority and recipient unchanged: '+$case[0])
    Assert ($script:Payload.message -match '用途：' -and $script:Payload.message -match 'synthetic') ('action and original content: '+$case[0])
}
$a=Alert urgent Confirmed;[void](Invoke-PushHttp $a)
Assert ($script:Payload.retry -eq 30 -and $script:Payload.expire -eq 3600) 'duty retry and expiry unchanged'
Assert ($script:Payload.message -match '只停止你自己') 'individual acknowledgement explained'
$a.DeliveryReason='overdue_admin';[void](Invoke-PushHttp $a)
Assert ($script:Payload.title -eq '【管理員通知】過時排程待核對' -and $script:Payload.priority -eq 2) 'admin purpose survives emergency priority'
$a.DeliveryReason='';$a.Message='【已過接刀時間，請人工核對】 historical';[void](Invoke-PushHttp $a)
Assert ($script:Payload.title -eq '【管理員通知】過時排程待核對') 'old queued overdue alert has compatible label'
$a=Alert urgent Confirmed;$a.ArrivalUtc=[datetime]::UtcNow.AddHours(-1).ToString('o');[void](Invoke-PushHttp $a)
Assert ($script:Payload.message -match '延遲補送' -and $script:Payload.message -match '用途：') 'late legacy alert retains purpose text'
$a=Alert emergency_test Confirmed;$a.IsTest=$true;$a.Title='【測試】緊急通知，非出勤';[void](Invoke-PushHttp $a)
Assert ($script:Payload.title -eq $a.Title -and $script:Payload.expire -eq 120) 'emergency test remains clearly a two-minute test'
$a=Alert '';$a.IsTest=$true;$a.Title='【測試】一般通知，非出勤';[void](Invoke-PushHttp $a)
Assert ($script:Payload.title -eq $a.Title -and $script:Payload.priority -eq 0) 'general test remains clearly a test'
$s=[pscustomobject]@{Id=('s'*64);EventId='synthetic-event';Version=1;Routing=@();WhenUtc=''}
$p=[pscustomobject]@{Id='owner';IsAdmin=$true}
New-TeamDelivery $s $p urgent Confirmed 'synthetic original' ([datetime]::UtcNow)
$file=@(Get-ChildItem (Join-Path $root outbox) -Filter '*.dat')[0]
$old=Read-State $file.FullName
Assert ($old.Title -eq '【出勤通知】緊急接刀提醒') 'admin own duty is stored as duty notification'
$old.Title='old title';Write-State $file.FullName $old
New-TeamDelivery $s $p urgent Confirmed 'synthetic original' ([datetime]::UtcNow)
$updated=Read-State $file.FullName
Assert ($updated.Id -eq $old.Id -and $updated.Title -eq '【出勤通知】緊急接刀提醒' -and @(Get-ChildItem (Join-Path $root outbox) -Filter '*.dat').Count -eq 1) 'unsent title refresh does not create another delivery'
$updated.Status='accepted';$updated.Attempts=1;$updated.Receipt='original-receipt';Write-State $file.FullName $updated
$before=(Get-FileHash $file.FullName).Hash
New-TeamDelivery $s $p urgent Confirmed 'changed text' ([datetime]::UtcNow)
Assert ((Get-FileHash $file.FullName).Hash -eq $before) 'accepted delivery remains byte-for-byte unchanged'
"RESULT: $script:Passed checks passed. All HTTP requests mocked."
