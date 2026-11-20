param([string]$ConfigPath=(Join-Path $PSScriptRoot 'appsettings.json'),[ValidateRange(1,168)][int]$Hours=24)
$ErrorActionPreference='Stop'
$logs=Join-Path (Split-Path ([IO.Path]::GetFullPath($ConfigPath))) 'logs'
$since=[datetime]::UtcNow.AddHours(-$Hours);$rows=[Collections.Generic.List[object]]::new();$unreadable=0
foreach($file in Get-ChildItem -LiteralPath $logs -Filter 'performance-*.jsonl' -File){
    if($file.Name -notmatch '^performance-(\d{4}-\d{2}-\d{2})-(Collector|Classifier|Sender|Receipts|Scheduler)\.jsonl$'){continue}
    if([datetime]::ParseExact($Matches[1],'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture) -lt $since.ToLocalTime().Date){continue}
    foreach($line in Get-Content -LiteralPath $file.FullName -Encoding UTF8){
        try{$r=$line|ConvertFrom-Json;if(([datetime]$r.Utc).ToUniversalTime() -ge $since){$rows.Add($r)}}catch{$unreadable++}
    }
}
$summary=@(foreach($group in $rows|Group-Object Role){
    $data=@($group.Group|Sort-Object Utc);$last=$data[-1];$cpu=@($data|Where-Object {$null -ne $_.CPUPercent})
    [pscustomobject]@{Role=$group.Name;Samples=$data.Count;LatestUtc=$last.Utc;CPUAverage=if($cpu.Count){[Math]::Round(($cpu|Measure-Object CPUPercent -Average).Average,3)}else{$null};CPUMax=($cpu|Measure-Object CPUPercent -Maximum).Maximum;PrivateMBLatest=$last.PrivateMB;PrivateMBMin=($data|Measure-Object PrivateMB -Minimum).Minimum;PrivateMBMax=($data|Measure-Object PrivateMB -Maximum).Maximum;LatestProcess=$last.Pid;DatabaseScans=$last.DatabaseScans;DatabaseSkips=$last.DatabaseSkips;HintHits=$last.HintHits;HintReads=$last.HintReads}
})
$physical=@(foreach($group in $summary|Group-Object LatestProcess){
    $latest=$group.Group|Sort-Object LatestUtc -Descending|Select-Object -First 1
    [pscustomobject]@{Pid=$latest.LatestProcess;Roles=@($group.Group.Role);PrivateMBLatest=$latest.PrivateMBLatest;LatestUtc=$latest.LatestUtc}
})
[pscustomobject]@{Hours=$Hours;UnreadableLines=$unreadable;Workers=$summary;PhysicalProcesses=$physical;LatestPrivateMBSum=($physical|Measure-Object PrivateMBLatest -Sum).Sum;Note='Memory/CPU samples are process-wide; never sum per-role values for a shared PID. Historical latest samples do not prove the process is still running.'}|ConvertTo-Json -Depth 5
