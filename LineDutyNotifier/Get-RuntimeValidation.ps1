# Read-only acceptance projection for synthetic benchmark/endurance reports.
param([Parameter(Mandatory=$true)][string]$ResultRoot)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Notifier.Core.ps1')
Add-Type -AssemblyName System.Security
$resultPath=Join-Path $ResultRoot 'result.json'
if(-not (Test-Path $resultPath)){
    [pscustomobject]@{Status=$(if(Test-Path (Join-Path $ResultRoot 'failure.json')){'failed'}else{'not_completed'});EligibleForRollout=$false}|ConvertTo-Json
    exit
}
$result=Get-Content $resultPath -Raw -Encoding UTF8|ConvertFrom-Json
$samples=@(Get-Content (Join-Path $ResultRoot 'samples.jsonl') -Encoding UTF8|ForEach-Object {$_|ConvertFrom-Json})
$modes=@(foreach($mode in @($result.Workers.Mode)){
    $data=@($samples|Where-Object Mode -eq $mode|Sort-Object Utc)
    $sorted=@($data.PrivateMB|Sort-Object);$n=$sorted.Count
    if(-not $n){throw 'NoSamples'}
    $mid=[int][math]::Floor($n/2)
    $median=if($n%2){$sorted[$mid]}else{($sorted[$mid-1]+$sorted[$mid])/2}
    $gap=0.0
    for($i=1;$i -lt $n;$i++){$gap=[math]::Max($gap,(([datetime]$data[$i].Utc)-([datetime]$data[$i-1].Utc)).TotalSeconds)}
    $script:StateRoot=Join-Path (Join-Path $ResultRoot $mode) 'state'
    $events=@(Get-ChildItem (Join-Path $script:StateRoot inbox) -Filter '*.dat'|ForEach-Object {Read-State $_.FullName}|Where-Object CollectedUtc)
    $ids=@($events.Id)
    $alerts=@(Get-ChildItem (Join-Path $script:StateRoot outbox) -Filter '*.dat'|ForEach-Object {Read-State $_.FullName}|Where-Object {$_.EventId -in $ids})
    $deliveryLag=@(foreach($a in $alerts){if($a.AcceptedUtc){$e=$events|Where-Object Id -eq $a.EventId|Select-Object -First 1;(([datetime]$a.AcceptedUtc)-([datetime]$e.ArrivalUtc)).TotalSeconds}})
    $errors=@(Get-ChildItem (Join-Path (Join-Path $ResultRoot $mode) logs) -Filter 'monitor-*.log'|Select-String -Pattern '\[(WORKER_ERROR|HOST_ROLE_EXITED|HOST_ROLE_STALE|CLASSIFIER_FAILED|OUTBOX_FAILED|SCHEDULE_RETRY|COLLECT_EVENT_FAILED|AI_FAILED|PUSH_RETRY)\]')
    $original=$result.Workers|Where-Object Mode -eq $mode
    $delivered=@($alerts|Where-Object {$_.Status -in @('accepted','acknowledged')}).Count
    [pscustomobject]@{Mode=$mode;Samples=$n;MedianPrivateMB=[math]::Round($median,2);PeakPrivateMB=($data|Measure-Object PrivateMB -Maximum).Maximum;MaxSampleGapSeconds=[math]::Round($gap,2);CpuSeconds=($data[-1].CpuSeconds-$data[0].CpuSeconds);Expected=$original.ExpectedCollected;Collected=$events.Count;Delivered=$delivered;ExpectedDeliveries=2*$original.ExpectedCollected;MaxCollectionSeconds=$original.MaxCollectionSeconds;MaxDeliverySeconds=($deliveryLag|Measure-Object -Maximum).Maximum;ErrorEvents=$errors.Count;Healthy=($events.Count -eq $original.ExpectedCollected -and $delivered -eq 2*$original.ExpectedCollected -and $errors.Count -eq 0 -and $gap -lt 120 -and $original.MaxCollectionSeconds -le 3)}
})
$legacy=@($modes|Where-Object Mode -eq 'MultiProcess');$shared=@($modes|Where-Object Mode -eq 'SharedHost')
$reduction=if($legacy.Count -eq 1 -and $shared.Count -eq 1){[math]::Round(100*(1-$shared[0].MedianPrivateMB/$legacy[0].MedianPrivateMB),2)}else{$null}
$eligible=$result.Status -eq 'completed' -and $result.Minutes -ge 30 -and $result.TopologyFaults -eq 0 -and $null -ne $reduction -and $reduction -ge 25 -and @($modes|Where-Object {-not $_.Healthy}).Count -eq 0
[pscustomobject]@{Status=$result.Status;MeasuredMinutes=$result.Minutes;ReductionPercent=$reduction;EligibleForRollout=$eligible;EnduranceCompleted=($result.Minutes -ge 1440 -and $result.TopologyFaults -eq 0 -and @($modes|Where-Object {-not $_.Healthy}).Count -eq 0);Modes=$modes}|ConvertTo-Json -Depth 6
