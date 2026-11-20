# Real processes, synthetic encrypted data, all remote transports replaced.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Notifier.Core.ps1')
. (Join-Path $PSScriptRoot 'Test.RuntimeHelpers.ps1')
$script:Passed=0
function Assert($Value,[string]$Name){if(-not $Value){throw "FAIL: $Name"};$script:Passed++;"PASS: $Name"}
function Wait-For([scriptblock]$Condition,[int]$Seconds=40){
    $until=[datetime]::UtcNow.AddSeconds($Seconds)
    do {try{if(& $Condition){return $true}}catch{};Start-Sleep -Milliseconds 250}while([datetime]::UtcNow -lt $until)
    return $false
}
$sqlite=(Get-Content (Join-Path $PSScriptRoot 'appsettings.json') -Raw -Encoding UTF8|ConvertFrom-Json).NotificationDatabase.SqlitePath
$root=Join-Path (Split-Path $PSScriptRoot) ('artifacts/shared-integration-'+[guid]::NewGuid().ToString('N'))
$f=New-RuntimeFixture $root SharedHost $sqlite
$entry=Join-Path $root 'Start-LineDutyNotifier.ps1'
# Failure injection is in the isolated copy only, not a production configuration.
$source=[IO.File]::ReadAllText($entry)
$source=$source.Replace('        Write-WorkerHealth',('        if($Role -eq ''Classifier'' -and (Test-Path (Join-Path (Split-Path $ConfigPath) ''exit-classifier.flag''))){break}'+[Environment]::NewLine+'        Write-WorkerHealth'))
[IO.File]::WriteAllText($entry,$source,[Text.UTF8Encoding]::new($true))
$handles=@()
try {
    $handles+=@(Start-RuntimeFixture $f)
    Assert (Wait-For {Test-Path (Get-StatePath health Host)}) 'shared host creates membership heartbeat'
    Assert (Wait-For {@(Get-ChildItem (Join-Path $script:StateRoot health) -Filter '*.dat').Count -eq 6}) 'all five roles publish health'
    $roles=@('Classifier','Sender','Receipts','Scheduler')
    $h=Read-State (Get-StatePath health Host)
    $workerHealth=@($roles|ForEach-Object {Read-State (Get-StatePath health $_)})
    Assert (@($workerHealth.Pid|Select-Object -Unique).Count -eq 1 -and $workerHealth[0].Pid -eq $h.Pid) 'four roles share exactly one process'
    Assert (@(Get-FixtureProcesses $f).Count -eq 2) 'only two background processes'
    $handles+=@(Start-RuntimeFixture $f);Start-Sleep -Seconds 2
    Assert (@(Get-FixtureProcesses $f).Count -eq 2) 'duplicate collector exits without creating workers'
    # Exercise the cloned dashboard so entrypoint identity matches this fixture.
    . (Join-Path $root 'Dashboard.Status.ps1')
    function Test-DashboardSecret {return $true}
    Assert (Wait-For { $s=Get-DashboardSnapshot $f.Config; @($s.Workers|Where-Object Status -eq 'ok').Count -eq 5 } 50) 'shared PID dashboard verifies all five independent heartbeats'
    $s=Get-DashboardSnapshot $f.Config
    Assert ($s.Runtime.ProcessCount -eq 2 -and $s.Runtime.PrivateMB -lt 400) 'dashboard sums two actual memory samples, not five roles'
    $oldInstance=(Read-State (Get-StatePath health Classifier)).WorkerInstanceId
    [IO.File]::WriteAllText((Join-Path $root 'exit-classifier.flag'),'fixture')
    Assert (Wait-For {((Read-State (Get-StatePath health Host)).Roles|Where-Object Role -eq 'Classifier').WorkerInstanceId -ne $oldInstance} 15) 'completed role can be replaced without restarting other roles'
    [IO.File]::Delete((Join-Path $root 'exit-classifier.flag'))
    Assert (Wait-For {(Read-State (Get-StatePath health Classifier)).WorkerInstanceId -ne $oldInstance} 20) 'replacement publishes new role identity'
    # A slow AI request must not hold the collector or sender thread.
    [IO.File]::WriteAllText((Join-Path $root 'slow-ai.flag'),'fixture')
    [void](Add-FixtureNotification $f 1 '是8點要接嗎')
    Assert (Wait-For { @(Get-ChildItem (Join-Path $root logs) -Filter 'monitor-*.log'|ForEach-Object {Select-String -LiteralPath $_.FullName -Pattern '\[AI_REQUEST\]'}).Count -gt 0 } 12) 'slow AI scenario starts'
    [void](Add-FixtureNotification $f 2 '出勤')
    Assert (Wait-For { @(Get-ChildItem (Join-Path $script:StateRoot outbox) -Filter '*.dat'|ForEach-Object {Read-State $_.FullName}|Where-Object {$_.Kind -eq 'Confirmed' -and $_.Status -eq 'accepted'}).Count -eq 2 } 12) 'direct duty is collected and delivered while AI is waiting'
    [IO.File]::Delete((Join-Path $root 'slow-ai.flag'))
    $events=@(Get-ChildItem (Join-Path $script:StateRoot inbox) -Filter '*.dat'|ForEach-Object {Read-State $_.FullName}|Where-Object CollectedUtc)
    Assert (@($events|Where-Object {(([datetime]$_.CollectedUtc)-([datetime]$_.ArrivalUtc)).TotalSeconds -gt 3}).Count -eq 0) 'collection latency below three seconds despite slow AI'
    # Crash only this known synthetic host, with no active push in flight.
    $h=Read-State (Get-StatePath health Host);$oldHost=$h.HostInstanceId
    $target=@(Get-FixtureProcesses $f|Where-Object ProcessId -eq $h.Pid)
    Assert ($target.Count -eq 1 -and $target[0].CommandLine -match '-Role Host') 'crash target is verified isolated host'
    Stop-Process -Id $h.Pid -ErrorAction Stop
    Assert (Wait-For {(Read-State (Get-StatePath health Host)).HostInstanceId -ne $oldHost} 20) 'collector recreates crashed shared host'
    $accepted=@(Get-ChildItem (Join-Path $script:StateRoot outbox) -Filter '*.dat'|ForEach-Object {Read-State $_.FullName}|Where-Object {$_.Kind -eq 'Confirmed' -and $_.Status -eq 'accepted'})
    foreach($a in $accepted){$a.NextReceiptUtc=Get-UtcStamp;Write-State (Get-StatePath outbox $a.Id) $a}
    Assert (Wait-For { @(Get-ChildItem (Join-Path $script:StateRoot outbox) -Filter '*.dat'|ForEach-Object {Read-State $_.FullName}|Where-Object {$_.EventId -in @($events.Id) -and $_.Kind -eq 'Confirmed' -and $_.Status -eq 'acknowledged'}).Count -eq 2 } 15) 'accepted receipts survive host crash and resume tracking'
    [IO.File]::WriteAllText((Join-Path $root 'offline.flag'),'fixture')
    [void](Add-FixtureNotification $f 3 '出勤')
    Assert (Wait-For {@(Get-ChildItem (Join-Path $script:StateRoot outbox) -Filter '*.dat'|ForEach-Object {Read-State $_.FullName}|Where-Object {$_.Status -eq 'pending' -and $_.Attempts -gt 0}).Count -eq 2} 15) 'network failure preserves each recipient pending delivery'
    [IO.File]::Delete((Join-Path $root 'offline.flag'))
    foreach($file in Get-ChildItem (Join-Path $script:StateRoot outbox) -Filter '*.dat'){$a=Read-State $file.FullName;if($a.Status -eq 'pending'){$a.NextAttemptUtc=Get-UtcStamp;Write-State $file.FullName $a}}
    Assert (Wait-For {@(Get-ChildItem (Join-Path $script:StateRoot outbox) -Filter '*.dat'|ForEach-Object {Read-State $_.FullName}|Where-Object {$_.Status -eq 'accepted' -and $_.Attempts -eq 2}).Count -eq 2} 15) 'individual retries resume after connection recovery'
    Stop-RuntimeFixture $f
    Assert (@(Get-FixtureProcesses $f).Count -eq 0) 'safe stop drains and exits both processes'
    'RESULT: '+$script:Passed+' checks passed; synthetic fixture: '+$root
} finally {
    Stop-RuntimeFixture $f
    foreach($p in $handles){$p.Dispose()}
}
