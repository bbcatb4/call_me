# Runs isolated, network-blocked workers; never changes the live monitor.
param([ValidateRange(1,1440)][int]$Minutes=30,[ValidateRange(0,30)][int]$WarmupMinutes=2,[string]$ResultRoot='',[switch]$SharedOnly)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Notifier.Core.ps1')
. (Join-Path $PSScriptRoot 'Test.RuntimeHelpers.ps1')
if(-not $ResultRoot){$ResultRoot=Join-Path (Split-Path $PSScriptRoot) ('artifacts/runtime-benchmark-'+[guid]::NewGuid().ToString('N'))}
if(Test-Path $ResultRoot){throw 'ResultRootAlreadyExists'}
[void][IO.Directory]::CreateDirectory($ResultRoot)
$localConfig=Get-Content (Join-Path $PSScriptRoot 'appsettings.json') -Raw -Encoding UTF8|ConvertFrom-Json
$sqlite=[string]$localConfig.NotificationDatabase.SqlitePath;$localConfig=$null
$fixtures=@();$processHandles=@();$rows=[Collections.Generic.List[object]]::new();$sequence=0;$faults=0
try {
    $modes=if($SharedOnly){@('SharedHost')}else{@('MultiProcess','SharedHost')}
    foreach($mode in $modes){$f=New-RuntimeFixture (Join-Path $ResultRoot $mode) $mode $sqlite;$fixtures+=@($f);$processHandles+=@(Start-RuntimeFixture $f)}
    $start=[datetime]::UtcNow;$measureAt=$start.AddMinutes($WarmupMinutes);$end=$measureAt.AddMinutes($Minutes);$nextEvent=$start
    [IO.File]::WriteAllText((Join-Path $ResultRoot 'progress.json'),(@{Status='running';MeasureFrom=$measureAt.ToString('o');FinishAfter=$end.ToString('o')}|ConvertTo-Json),[Text.Encoding]::UTF8)
    while([datetime]::UtcNow -lt $end){
        $now=[datetime]::UtcNow
        if($now -ge $nextEvent){$sequence++;foreach($f in $fixtures){[void](Add-FixtureNotification $f $sequence $(if($sequence%3 -eq 0){'是8點要接嗎'}else{'出勤'}))};$nextEvent=$now.AddMinutes(1)}
        foreach($f in $fixtures){
            $procs=@(Get-FixtureProcesses $f);$private=0L;$working=0L;$cpu=0.0
            foreach($procInfo in $procs){$p=Get-Process -Id $procInfo.ProcessId -ErrorAction Stop;$private+=$p.PrivateMemorySize64;$working+=$p.WorkingSet64;$cpu+=$p.TotalProcessorTime.TotalSeconds;$p.Dispose()}
            if($now -ge $measureAt){
                $expected=if($f.Mode -eq 'SharedHost'){2}else{5};if($procs.Count -ne $expected){$faults++}
                $row=[pscustomobject]@{Utc=$now.ToString('o');Mode=$f.Mode;Processes=$procs.Count;PrivateMB=[math]::Round($private/1MB,2);WorkingSetMB=[math]::Round($working/1MB,2);CpuSeconds=$cpu}
                $rows.Add($row);Add-Content -LiteralPath (Join-Path $ResultRoot 'samples.jsonl') -Value ($row|ConvertTo-Json -Compress) -Encoding UTF8
            }
        }
        Start-Sleep -Seconds 5
    }
    # Freeze a consistent terminal snapshot before decrypting the report data.
    foreach($f in $fixtures){Stop-RuntimeFixture $f}
    $summary=@(foreach($f in $fixtures){
        $data=@($rows|Where-Object Mode -eq $f.Mode);$sorted=@($data.PrivateMB|Sort-Object)
        $script:StateRoot=Join-Path $f.Root 'state'
        $events=@(Get-ChildItem (Join-Path $script:StateRoot inbox) -Filter '*.dat'|ForEach-Object {Read-State $_.FullName}|Where-Object CollectedUtc)
        $lag=@($events|ForEach-Object {(([datetime]$_.CollectedUtc)-([datetime]$_.ArrivalUtc)).TotalSeconds})
        $pending=@(Get-ChildItem (Join-Path $script:StateRoot outbox) -Filter '*.dat'|ForEach-Object {Read-State $_.FullName}|Where-Object Status -eq 'pending')
        $allAlerts=@(Get-ChildItem (Join-Path $script:StateRoot outbox) -Filter '*.dat'|ForEach-Object {Read-State $_.FullName}|Where-Object {$_.EventId -in @($events.Id)})
        $delivered=@($allAlerts|Where-Object {$_.Status -in @('accepted','acknowledged')})
        $jobs=@(Get-ChildItem (Join-Path $script:StateRoot processed) -Filter '*.dat'|ForEach-Object {Read-State $_.FullName})
        $deliveryLag=@(foreach($a in $delivered){$e=$events|Where-Object Id -eq $a.EventId|Select-Object -First 1;if($e -and $a.AcceptedUtc){(([datetime]$a.AcceptedUtc)-([datetime]$e.ArrivalUtc)).TotalSeconds}})
        [pscustomobject]@{Mode=$f.Mode;Samples=$data.Count;MedianPrivateMB=$sorted[[int][math]::Floor($sorted.Count/2)];PeakPrivateMB=($data|Measure-Object PrivateMB -Maximum).Maximum;CpuSeconds=($data[-1].CpuSeconds-$data[0].CpuSeconds);Collected=$events.Count;ExpectedCollected=$sequence;MaxCollectionSeconds=($lag|Measure-Object -Maximum).Maximum;MaxDeliverySeconds=($deliveryLag|Measure-Object -Maximum).Maximum;PendingPushes=$pending.Count;Delivered=$delivered.Count;ExpectedDelivered=2*$sequence;AiPending=@($jobs|Where-Object Status -ne 'done').Count}
    })
    $reduction=$null;if($summary.Count -eq 2){$reduction=[math]::Round(100*(1-$summary[1].MedianPrivateMB/$summary[0].MedianPrivateMB),2)}
    $result=[pscustomobject]@{Status='completed';Minutes=$Minutes;WarmupMinutes=$WarmupMinutes;TopologyFaults=$faults;ReductionPercent=$reduction;MeetsMemoryTarget=($null -ne $reduction -and $reduction -ge 25 -and $Minutes -ge 30);Workers=$summary;NoRealNetwork=$true}
    [IO.File]::WriteAllText((Join-Path $ResultRoot 'result.json'),($result|ConvertTo-Json -Depth 8),[Text.Encoding]::UTF8)
    [IO.File]::WriteAllText((Join-Path $ResultRoot 'progress.json'),(@{Status='completed';FinishedUtc=[datetime]::UtcNow.ToString('o')}|ConvertTo-Json),[Text.Encoding]::UTF8)
    $result|ConvertTo-Json -Depth 8
} catch {
    [IO.File]::WriteAllText((Join-Path $ResultRoot 'failure.json'),(@{Status='failed';ErrorType=$_.Exception.GetType().Name;Utc=[datetime]::UtcNow.ToString('o')}|ConvertTo-Json),[Text.Encoding]::UTF8)
    throw
} finally {
    foreach($f in $fixtures){Stop-RuntimeFixture $f}
    foreach($p in $processHandles){$p.Dispose()}
}
