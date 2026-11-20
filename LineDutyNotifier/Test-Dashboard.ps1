# Isolated diagnostic fixtures: never modifies live state or worker processes.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Dashboard.Status.ps1')
$testRoot=Join-Path $PSScriptRoot ('state/dashboard-test-'+[guid]::NewGuid().ToString('N'))
foreach($dir in @('','logs','state/inbox','state/processed','state/outbox','state/health','state/usage')){[void][IO.Directory]::CreateDirectory((Join-Path $testRoot $dir))}
$config=Join-Path $testRoot 'appsettings.json'
$fixture=@{TargetGroupNames=@('SENTINEL_PRIVATE_GROUP');Ai=@{Enabled=$true;ApiKeyEnvironmentVariable='TEST_AI'};Pushover=@{Enabled=$true;AppTokenEnvironmentVariable='TEST_PUSH';UserKeyEnvironmentVariable='TEST_USER'}}
[IO.File]::WriteAllText($config,($fixture|ConvertTo-Json -Depth 5),[Text.Encoding]::UTF8)
$script:FakeProcesses=@();$script:SimulateProcessFailure=$false;$script:SecretPresent=$true;$script:Passed=0
function Assert($Condition,[string]$Name){if(-not $Condition){throw ('FAIL: '+$Name)};$script:Passed++;Write-Output ('PASS: '+$Name)}
function Get-DashboardProcesses {if($script:SimulateProcessFailure){throw 'SENTINEL_ERROR'};return $script:FakeProcesses}
function Test-DashboardSecret {return $script:SecretPresent}
$xamlText=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Dashboard.xaml'))
$dashboardScript=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Show-NotifierDashboard.ps1'))
$billingMatch=[regex]::Match($dashboardScript,'\$script:OfficialBillingUrl=''([^'']+)''')
$billingUri=if($billingMatch.Success){[uri]$billingMatch.Groups[1].Value}else{$null}
Assert ($xamlText -match 'Name="OpenBillingButton"' -and $billingUri -and $billingUri.Scheme -eq 'https' -and $billingUri.Host -eq 'platform.openai.com' -and $billingUri.AbsolutePath -eq '/settings/organization/billing/overview' -and -not $billingUri.Query) 'billing button uses fixed official HTTPS URL without query data'
$health=@{};$index=45000
foreach($role in @('Collector','Classifier','Sender','Receipts')){
    $index++
    $health[$role]=[pscustomobject]@{Role=$role;Pid=$index;HeartbeatUtc=[datetime]::UtcNow.AddSeconds(-10).ToString('o');LastSuccessfulReadUtc=[datetime]::UtcNow.AddSeconds(-11).ToString('o');LastReadError='';Polls=5;Saved=2}
    Write-State (Join-Path $testRoot ('state/health/'+$role+'.dat')) $health[$role]
    $script:FakeProcesses+=@([pscustomobject]@{ProcessId=$index;CommandLine=('powershell.exe -File "'+(Join-Path $PSScriptRoot 'Start-LineDutyNotifier.ps1')+'" -Role '+$role);CreationDate=[datetime]::UtcNow.AddMinutes(-20)})
}
$snapshot=Get-DashboardSnapshot $config
Assert ($snapshot.Overall -eq 'ok' -and @($snapshot.Workers|Where-Object Status -eq 'ok').Count -eq 4) 'fresh identities, heartbeats and read produce green'
Assert ($snapshot.QueueReadable -and $snapshot.Queue.PushPending -eq 0) 'valid empty queue displays zero'
$health.Collector.HeartbeatUtc=[datetime]::UtcNow.AddMinutes(-4).ToString('o')
Write-State (Join-Path $testRoot 'state/health/Collector.dat') $health.Collector
$snapshot=Get-DashboardSnapshot $config
Assert ($snapshot.Overall -ne 'ok' -and $snapshot.Workers[0].Reason -eq 'heartbeat_stale') 'running but stale heartbeat is not healthy'
$health.Collector.HeartbeatUtc=[datetime]::UtcNow.ToString('o');$health.Collector.LastSuccessfulReadUtc=[datetime]::UtcNow.AddMinutes(-4).ToString('o')
Write-State (Join-Path $testRoot 'state/health/Collector.dat') $health.Collector
$snapshot=Get-DashboardSnapshot $config
Assert ($snapshot.Workers[0].Status -eq 'warning') 'fresh heartbeat with stale successful read warns'
$health.Collector.LastSuccessfulReadUtc=[datetime]::UtcNow.ToString('o')
Write-State (Join-Path $testRoot 'state/health/Collector.dat') $health.Collector
$savedCommand=$script:FakeProcesses[0].CommandLine;$script:FakeProcesses[0].CommandLine='powershell.exe -File "C:\other.ps1"'
$snapshot=Get-DashboardSnapshot $config
Assert ($snapshot.Workers[0].Status -eq 'error' -and -not $snapshot.Workers[0].Running) 'reused PID with wrong entry point is rejected'
$script:FakeProcesses[0].CommandLine=$savedCommand
$script:SimulateProcessFailure=$true;$snapshot=Get-DashboardSnapshot $config
Assert ($snapshot.Overall -eq 'unknown') 'process access failure does not claim green'
$script:SimulateProcessFailure=$false
$script:SecretPresent=$false;$snapshot=Get-DashboardSnapshot $config
Assert ($snapshot.Overall -eq 'error' -and -not $snapshot.Services.PushoverKeysPresent) 'missing credentials are visible without reading values'
$script:SecretPresent=$true
foreach($id in @('one','two')){Write-State (Join-Path $testRoot ('state/inbox/'+$id+'.dat')) @{Body='SENTINEL_CHAT';Images=@('SENTINEL_IMAGE')}}
Write-State (Join-Path $testRoot 'state/processed/one.dat') @{Status='pending';AiStatus='failed'}
Write-State (Join-Path $testRoot 'state/outbox/one.dat') @{Kind='Confirmed';Status='pending';Message='SENTINEL_CHAT';LastError='SENTINEL_ERROR';CreatedUtc=[datetime]::UtcNow.ToString('o')}
Write-State (Join-Path $testRoot 'state/outbox/two.dat') @{Kind='Confirmed';Status='accepted';Message='SENTINEL_CHAT';Receipt='SENTINEL_RECEIPT';CreatedUtc=[datetime]::UtcNow.ToString('o')}
Write-State (Join-Path $testRoot 'state/outbox/three.dat') @{Kind='Confirmed';Status='expired';Message='SENTINEL_CHAT';CreatedUtc=[datetime]::UtcNow.AddDays(-2).ToString('o')}
$today=[datetime]::Now.Date.AddHours(1).ToUniversalTime()
Write-State (Join-Path $testRoot 'state/usage/today.dat') @{Id='today';CreatedUtc=$today.ToString('o');InputTokens=100;OutputTokens=20;TotalTokens=120;CachedInputTokens=10;ReasoningTokens=5}
Write-State (Join-Path $testRoot 'state/usage/previous-month.dat') @{Id='previous';CreatedUtc=$today.AddMonths(-1).ToString('o');InputTokens=50;OutputTokens=10;TotalTokens=60;CachedInputTokens=0;ReasoningTokens=0}
$log=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')+' [AI_FAILED] event=SENTINEL_ID SENTINEL_PRIVATE_LOG'
[IO.File]::WriteAllText((Join-Path $testRoot ('logs/monitor-'+(Get-Date -Format yyyy-MM-dd)+'.log')),$log,[Text.Encoding]::UTF8)
$snapshot=Get-DashboardSnapshot $config
Assert ($snapshot.Queue.AiPending -eq 2) 'pending includes received events without a job yet'
Assert ($snapshot.Queue.AiFailedPending -eq 1 -and $snapshot.Queue.AiFailedCompleted -eq 0) 'AI failure counters distinguish active retry from completed history'
Assert ($snapshot.Queue.PushPending -eq 1 -and $snapshot.Queue.PushRetry -eq 1) 'failed pending pushes count as retries'
Assert ($snapshot.Queue.AwaitingAcknowledgement -eq 1 -and $snapshot.Queue.ExpiredLast24Hours -eq 1) 'accepted is distinct from acknowledged and expired'
Assert ($snapshot.Queue.ConfirmedToday -eq 2) 'today means alert creation date, not total history'
Assert ($snapshot.RecentErrorCount -eq 1) 'recent known error code is surfaced'
Assert ($snapshot.Usage.Available -and $snapshot.Usage.TodayTotal -eq 120 -and $snapshot.Usage.MonthTotal -eq 120) 'today and month totals use local calendar boundaries'
Assert ($snapshot.Usage.TodayInput -eq 100 -and $snapshot.Usage.TodayOutput -eq 20 -and $snapshot.Usage.LastTotal -eq 120) 'input, output and latest usage are separate'
$json=$snapshot|ConvertTo-Json -Depth 8
Assert ($json -notmatch 'SENTINEL|CommandLine|Receipt"|Message"|Body"') 'snapshot and log projection do not leak private values'
$before=@(Get-ChildItem -LiteralPath (Join-Path $testRoot 'state') -Recurse -File|ForEach-Object {(Get-FileHash -LiteralPath $_.FullName).Hash}) -join ','
[void](Get-DashboardSnapshot $config)
$after=@(Get-ChildItem -LiteralPath (Join-Path $testRoot 'state') -Recurse -File|ForEach-Object {(Get-FileHash -LiteralPath $_.FullName).Hash}) -join ','
Assert ($before -eq $after) 'status polling does not modify encrypted state'
[IO.File]::WriteAllText((Join-Path $testRoot 'state/outbox/broken.dat'),'SENTINEL_BROKEN')
$snapshot=Get-DashboardSnapshot $config
Assert ($snapshot.Overall -eq 'unknown' -and -not $snapshot.QueueReadable) 'unreadable queue becomes unavailable, not zero'
[IO.File]::WriteAllText((Join-Path $testRoot 'state/health/Collector.dat'),'SENTINEL_BROKEN')
$snapshot=Get-DashboardSnapshot $config
Assert ($snapshot.Workers[0].Reason -eq 'health_unreadable') 'unreadable heartbeat is explicit'
[IO.File]::WriteAllText((Join-Path $testRoot 'state/usage/broken.dat'),'SENTINEL_BROKEN')
$snapshot=Get-DashboardSnapshot $config
Assert (-not $snapshot.Usage.Available -and $snapshot.Usage.Unreadable -eq 1) 'incomplete usage is unavailable, not a misleading partial total'
[void][IO.Directory]::CreateDirectory((Join-Path $testRoot 'state/team'))
Write-State (Join-Path $testRoot 'state/team/model.dat') @{Version=1}
$snapshot=Get-DashboardSnapshot $config
Assert (@($snapshot.Workers|Where-Object {$_.Role -eq 'Scheduler' -and $_.Reason -eq 'health_missing'}).Count -eq 1) 'enabled team requires scheduler heartbeat'
$schedulerPid=46000
Write-State (Join-Path $testRoot 'state/health/Scheduler.dat') @{Role='Scheduler';Pid=$schedulerPid;HeartbeatUtc=[datetime]::UtcNow.ToString('o');LastSuccessfulReadUtc=[datetime]::UtcNow.ToString('o');LastReadError=''}
$script:FakeProcesses+=@([pscustomobject]@{ProcessId=$schedulerPid;CommandLine=('powershell.exe -File "'+(Join-Path $PSScriptRoot 'Start-LineDutyNotifier.ps1')+'" -Role Scheduler');CreationDate=[datetime]::UtcNow.AddMinutes(-20)})
$snapshot=Get-DashboardSnapshot $config
Assert (@($snapshot.Workers|Where-Object {$_.Role -eq 'Scheduler' -and $_.Status -eq 'ok'}).Count -eq 1) 'scheduler process role and heartbeat are verified'
$sharedPid=47000;$hostId='host-current';$membership=@()
foreach($role in @('Collector','Classifier','Sender','Receipts','Scheduler')){
    $pidValue=if($role -eq 'Collector'){45001}else{$sharedPid}
    $memberId='member-'+$role
    $row=@{Role=$role;Pid=$pidValue;HeartbeatUtc=[datetime]::UtcNow.ToString('o');LastSuccessfulReadUtc=[datetime]::UtcNow.ToString('o');LastReadError='';RuntimeProtocol=2;HostInstanceId=$(if($role -eq 'Collector'){''}else{$hostId});WorkerInstanceId=$memberId;Performance=@{PrivateMB=$(if($role -eq 'Collector'){80}else{130});WorkingSetMB=100;CPUPercent=0.1}}
    Write-State (Join-Path $testRoot ('state/health/'+$role+'.dat')) $row
    if($role -ne 'Collector'){$membership+=@(@{Role=$role;WorkerInstanceId=$memberId;State='running'})}
}
$hostRow=@{Pid=$sharedPid;HostInstanceId=$hostId;HeartbeatUtc=[datetime]::UtcNow.ToString('o');Roles=$membership}
Write-State (Join-Path $testRoot 'state/health/Host.dat') $hostRow
$script:FakeProcesses=@($script:FakeProcesses|Where-Object ProcessId -eq 45001)
$hostProcess=[pscustomobject]@{ProcessId=$sharedPid;CommandLine=('powershell.exe -File "'+(Join-Path $PSScriptRoot 'Start-LineDutyNotifier.ps1')+'" -Role Host -ConfigPath "'+$config+'"');CreationDate=[datetime]::UtcNow.AddMinutes(-5)}
$script:FakeProcesses+=@($hostProcess)
$snapshot=Get-DashboardSnapshot $config
Assert (@($snapshot.Workers|Where-Object Running).Count -eq 5 -and $snapshot.Runtime.ProcessCount -eq 2) 'five logical roles verified in two processes'
Assert ($snapshot.Runtime.PrivateMB -eq 210) 'shared memory counted once, not four times'
$hostRow.Roles[0].WorkerInstanceId='old-member';Write-State (Join-Path $testRoot 'state/health/Host.dat') $hostRow
$snapshot=Get-DashboardSnapshot $config
Assert (-not ($snapshot.Workers|Where-Object Role -eq 'Classifier').Running) 'old runspace heartbeat rejected even under same PID'
$hostRow.Roles[0].WorkerInstanceId='member-Classifier';$hostRow.Roles[0].State='blocked';Write-State (Join-Path $testRoot 'state/health/Host.dat') $hostRow
$snapshot=Get-DashboardSnapshot $config
Assert (-not ($snapshot.Workers|Where-Object Role -eq 'Classifier').Running) 'stopping or blocked role cannot appear healthy'
$hostRow.Roles[0].State='running';$hostRow.HeartbeatUtc=[datetime]::UtcNow.AddMinutes(-3).ToString('o');Write-State (Join-Path $testRoot 'state/health/Host.dat') $hostRow
$snapshot=Get-DashboardSnapshot $config
Assert (@($snapshot.Workers|Where-Object {$_.SharedHost -and $_.Running}).Count -eq 0) 'stale host membership rejects shared roles'
$hostRow.HeartbeatUtc=[datetime]::UtcNow.ToString('o');Write-State (Join-Path $testRoot 'state/health/Host.dat') $hostRow
$hostProcess.CommandLine=$hostProcess.CommandLine.Replace($config,($config+'.other'))
$snapshot=Get-DashboardSnapshot $config
Assert (@($snapshot.Workers|Where-Object {$_.SharedHost -and $_.Running}).Count -eq 0) 'another dataset cannot impersonate shared host'
Write-Output ('RESULT: '+$script:Passed+' checks passed. State: '+$testRoot)
