# Presentation-only fixtures; no network, private data, or state writes.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Dashboard.View.ps1')
$passed=0
function Assert($Value,[string]$Name){if(-not $Value){throw "FAIL: $Name"};$script:passed++;"PASS: $Name"}
$s=[pscustomobject]@{Overall='warning';QueueReadable=$true;Queue=[pscustomobject]@{AiFailedCompleted=1;AiFailedPending=0;PushRetry=0;ExpiredLast24Hours=0};RecentErrorCount=0;Issues=@();Usage=@{Available=$true};Services=@{AiEnabled=$true;AiKeyPresent=$true;PushoverEnabled=$true;PushoverKeysPresent=$true};Workers=@(1..5|ForEach-Object {[pscustomobject]@{Status='ok'}});Runtime=[pscustomobject]@{ExecutionMode='SharedHost';ProcessCount=2;MemoryAvailable=$true;PrivateMB=240.18;Processes=@(@{Roles=@('Collector');PrivateMB=90},@{Roles=@('Classifier','Sender','Receipts','Scheduler');PrivateMB=150.18})}}
$v=Get-DashboardRuntimeView $s
Assert ($v.Mode -eq '低記憶體模式' -and $v.Count -eq '2' -and $v.Memory -eq '240 MB') 'two real processes and total memory displayed separately from roles'
Assert ($v.ModeDetail -match '5 項工作' -and $v.Detail -match '共用工作宿主' -and $v.Detail -match '隔離測試') 'logical roles and excluded test processes explained'
Assert (Test-DashboardHistoryOnlyWarning $s) 'completed AI failure shown as historical warning, not stopped monitor'
$s.Queue.AiFailedPending=1
Assert (-not (Test-DashboardHistoryOnlyWarning $s)) 'active AI retry never hidden as history only'
$s.Queue.AiFailedPending=0;$s.RecentErrorCount=1
Assert (-not (Test-DashboardHistoryOnlyWarning $s)) 'recent error never hidden as history only'
$s.RecentErrorCount=0;$s.Workers[0].Status='error'
Assert (-not (Test-DashboardHistoryOnlyWarning $s) -and (Get-DashboardRuntimeView $s).Memory -eq '—') 'failed role prevents reassuring summary and stale memory total'
$s.Workers[0].Status='ok';$s.Runtime.ProcessCount=5
Assert ((Get-DashboardRuntimeView $s).Detail -match '設定與目前') 'configured shared mode with five running processes is flagged'
$s.Runtime.ExecutionMode='MultiProcess'
Assert ((Get-DashboardRuntimeView $s).Mode -eq '獨立程序模式') 'legacy mode remains readable'
$s.Runtime.MemoryAvailable=$false
Assert ((Get-DashboardRuntimeView $s).Memory -eq '—') 'missing memory not represented as zero'
$s.Runtime=$null
Assert ((Get-DashboardRuntimeView $s).Count -eq '—' -and (Get-DashboardRuntimeView $s).Mode -eq '模式未確認') 'missing runtime data is explicit'
"RESULT: $passed checks passed."
