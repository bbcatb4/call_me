# Shortened deadlines apply ONLY to the cloned synthetic fixture.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Notifier.Core.ps1')
. (Join-Path $PSScriptRoot 'Test.RuntimeHelpers.ps1')
$script:Passed=0
function Assert($Value,[string]$Name){if(-not $Value){throw "FAIL: $Name"};$script:Passed++;"PASS: $Name"}
function Wait-For([scriptblock]$Condition,[int]$Seconds=20){$end=[datetime]::UtcNow.AddSeconds($Seconds);do{try{if(& $Condition){return $true}}catch{};Start-Sleep -Milliseconds 100}while([datetime]::UtcNow -lt $end);return $false}
$sqlite=(Get-Content (Join-Path $PSScriptRoot 'appsettings.json') -Raw -Encoding UTF8|ConvertFrom-Json).NotificationDatabase.SqlitePath
$root=Join-Path (Split-Path $PSScriptRoot) ('artifacts/shared-timeout-'+[guid]::NewGuid().ToString('N'))
$f=New-RuntimeFixture $root SharedHost $sqlite 0
$runtime=Join-Path $root 'Runtime.Core.ps1'
$source=[IO.File]::ReadAllText($runtime).Replace('-gt 120000 -and','-gt $(if($role -eq ''Classifier''){1000}else{120000}) -and').Replace('-gt 90000','-gt 1000')
[IO.File]::WriteAllText($runtime,$source,[Text.UTF8Encoding]::new($true))
$handles=@()
try{
    [IO.File]::WriteAllText((Join-Path $root 'slow-ai.flag'),'fixture')
    $handles+=@(Start-RuntimeFixture $f)
    Assert (Wait-For {Test-Path (Get-StatePath health Classifier)}) 'test classifier starts'
    $instance=(Read-State (Get-StatePath health Classifier)).WorkerInstanceId
    [void](Add-FixtureNotification $f 1 '是8點要接嗎')
    Assert (Wait-For {((Read-State (Get-StatePath health Host)).Roles|Where-Object Role -eq 'Classifier').State -eq 'blocked'} 8) 'unresponsive role marked blocked after cooperative-stop deadline'
    $h=Read-State (Get-StatePath health Host);$role=@($h.Roles|Where-Object Role -eq 'Classifier')
    Assert ($role.Count -eq 1 -and $role[0].WorkerInstanceId -eq $instance) 'no duplicate classifier while old request is still in flight'
    Assert (@(Get-FixtureProcesses $f).Count -eq 2) 'blocked role never creates extra process'
    # Stopping the whole fixture must wait for the pending AI operation to unwind.
    Stop-RuntimeFixture $f
    Assert (@(Get-FixtureProcesses $f).Count -eq 0) 'safe stop waits for blocked role rather than killing it'
    $jobs=@(Get-ChildItem (Join-Path $script:StateRoot processed) -Filter '*.dat'|ForEach-Object {Read-State $_.FullName})
    Assert ($jobs.Count -eq 1 -and $jobs[0].Status -eq 'pending') 'in-flight failed AI job remains durable for recovery'
    [IO.File]::Delete((Join-Path $root 'slow-ai.flag'))
    $cfg=Get-Content $f.Config -Raw -Encoding UTF8|ConvertFrom-Json;$cfg.Runtime.ExecutionMode='MultiProcess'
    [IO.File]::WriteAllText($f.Config,($cfg|ConvertTo-Json -Depth 15),[Text.UTF8Encoding]::new($true))
    [IO.File]::WriteAllText((Join-Path $root 'control.json'),'{"State":"ready"}',[Text.Encoding]::UTF8)
    $handles+=@(Start-RuntimeFixture $f)
    Assert (Wait-For {@(Get-FixtureProcesses $f).Count -eq 5}) 'same fixture safely rolls back to five-process mode'
    Assert (@(Get-FixtureProcesses $f|Where-Object {$_.CommandLine -match '-Role Host'}).Count -eq 0) 'rollback leaves no orphan shared host'
    $jobFile=@(Get-ChildItem (Join-Path $script:StateRoot processed) -Filter '*.dat')[0]
    $job=Read-State $jobFile.FullName;$job.NextAttemptUtc=Get-UtcStamp;Write-State $jobFile.FullName $job
    Assert (Wait-For {(Read-State $jobFile.FullName).Status -eq 'done'}) 'pending job completes after rollback without data migration'
    'RESULT: '+$script:Passed+' checks passed. Fixture: '+$root
}finally{Stop-RuntimeFixture $f;foreach($p in $handles){$p.Dispose()}}
