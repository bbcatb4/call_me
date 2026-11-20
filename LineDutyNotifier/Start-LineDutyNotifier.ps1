# 在 Windows PowerShell 5.1 執行：powershell.exe -ExecutionPolicy Bypass -File .\Start-LineDutyNotifier.ps1
param([string]$ConfigPath=(Join-Path $PSScriptRoot 'appsettings.json'),
    [ValidateSet('Collector','Classifier','Sender','Receipts','Scheduler','Host')][string]$Role='Collector', [switch]$Once,
    [string]$HostInstanceId='',[string]$WorkerInstanceId='',[object]$WorkerControl=$null)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Notifier.Core.ps1')
Initialize-Notifier $ConfigPath
$script:WorkerControl=$WorkerControl
$script:UseWorkIndex=$true
if(-not $WorkerInstanceId){$WorkerInstanceId=[guid]::NewGuid().ToString('N')}
if($Role -eq 'Host' -and -not $HostInstanceId){$HostInstanceId=[guid]::NewGuid().ToString('N')}
if(Test-NotifierPaused){exit 0}
$identity=(Get-EventHash $script:StateRoot).Substring(0,20)
$mutex=New-Object Threading.Mutex($false, ("Local\LineDutyNotifier-$identity-$Role"))
$owned=$false
try{$owned=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
if(-not $owned){$mutex.Dispose();exit 0}
$children=@{}
$script:LastReadUtc=''
$script:LastReadError=''
$script:LastHealth=[datetime]::MinValue
$script:Polls=0
$script:Saved=0
function Get-DatabaseRows {
    $db=[string]$script:Settings.NotificationDatabase.DatabasePath
    $sqlite=[string]$script:Settings.NotificationDatabase.SqlitePath
    if(-not (Test-Path -LiteralPath $db) -or -not (Test-Path -LiteralPath $sqlite)){throw 'DatabaseOrSqliteMissing'}
    $hours=[int](Get-Option $script:Settings.Reliability 'RecoveryLookbackHours' 24)
    $cutoff=[datetime]::UtcNow.AddHours(-$hours).ToFileTimeUtc()
    $controlPath=Join-Path (Split-Path $ConfigPath) 'control.json'
    if(Test-Path -LiteralPath $controlPath){
        $control=Get-Content -LiteralPath $controlPath -Raw -Encoding UTF8|ConvertFrom-Json
        if($control.ResumeAfterUtc){$cutoff=[Math]::Max($cutoff,([datetime]$control.ResumeAfterUtc).ToUniversalTime().ToFileTimeUtc())}
    }
    $query="SELECT n.[Order] AS sort_order,n.ArrivalTime AS arrival_time,h.PrimaryId AS app_id,hex(n.Payload) AS payload_hex FROM Notification n JOIN NotificationHandler h ON h.RecordId=n.HandlerId WHERE h.PrimaryId LIKE '%LINE%' COLLATE NOCASE AND n.Payload IS NOT NULL AND n.ArrivalTime >= $cutoff ORDER BY n.[Order];"
    $attempts=[Math]::Max(1,[int](Get-Option $script:Settings.NotificationDatabase 'RetryCount' 4))
    for($attempt=1;$attempt -le $attempts;$attempt++){
        $path=Join-Path (Join-Path $script:StateRoot 'snapshot') ([guid]::NewGuid().ToString('N')+'.db')
        try {
            Copy-Item -LiteralPath $db -Destination $path -ErrorAction Stop
            if(Test-Path -LiteralPath ($db+'-wal')){Copy-Item -LiteralPath ($db+'-wal') -Destination ($path+'-wal') -ErrorAction Stop}
            $info=New-Object Diagnostics.ProcessStartInfo
            $info.FileName=$sqlite
            $info.Arguments='-json "'+$path+'" "'+$query+'"'
            $info.UseShellExecute=$false;$info.CreateNoWindow=$true
            $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
            $process=New-Object Diagnostics.Process;$process.StartInfo=$info
            try {
                [void]$process.Start()
                $outputTask=$process.StandardOutput.ReadToEndAsync()
                $errorTask=$process.StandardError.ReadToEndAsync()
                if(-not $process.WaitForExit(10000)){$process.Kill();$process.WaitForExit();throw 'SqliteTimeout'}
                $output=$outputTask.GetAwaiter().GetResult()
                [void]$errorTask.GetAwaiter().GetResult()
                if($process.ExitCode -ne 0){throw 'SqliteReadFailed'}
            }finally{$process.Dispose()}
            if(-not $output){return @()}
            return @($output | ConvertFrom-Json)
        }catch{
            if($attempt -eq $attempts){throw}
            Start-Sleep -Milliseconds ([int](Get-Option $script:Settings.NotificationDatabase 'RetryDelayMilliseconds' 250))
        }finally{
            foreach($suffix in @('','-wal','-shm','-journal')){
                $temporaryFile=$path+$suffix
                if([IO.File]::Exists($temporaryFile)){[IO.File]::Delete($temporaryFile)}
            }
        }
    }
}
function Write-WorkerHealth {
    if(([datetime]::UtcNow-$script:LastHealth).TotalSeconds -lt 30){return}
    $script:LastHealth=[datetime]::UtcNow
    try{Write-PerformanceSample $Role}catch{Write-Audit 'PERFORMANCE_LOG_FAILED' '' 'metrics_unavailable=true'}
    Write-State (Get-StatePath 'health' $Role) ([pscustomobject]@{
        Role=$Role;Pid=$PID;HeartbeatUtc=(Get-UtcStamp);Polls=$script:Polls;ControlProtocol=1;RuntimeProtocol=2;HostInstanceId=$HostInstanceId;WorkerInstanceId=$WorkerInstanceId;
        Saved=$script:Saved;LastSuccessfulReadUtc=$script:LastReadUtc;LastReadError=$script:LastReadError;Performance=$script:Performance;PerformanceProtocol=1
    })
}
function Ensure-Worker([string]$WorkerRole) {
    if($children.ContainsKey($WorkerRole) -and -not $children[$WorkerRole].HasExited){return}
    if($children.ContainsKey($WorkerRole)){$children[$WorkerRole].Dispose();$children.Remove($WorkerRole)}
    $healthPath=Get-StatePath 'health' $WorkerRole
    if(Test-Path $healthPath){
        $state=Read-State $healthPath
        if(([datetime]::UtcNow-([datetime]$state.HeartbeatUtc).ToUniversalTime()).TotalSeconds -lt 120){
            $candidate=Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$state.Pid) -ErrorAction SilentlyContinue
            $expected=Join-Path $PSScriptRoot 'Start-LineDutyNotifier.ps1'
            if($candidate -and $candidate.CommandLine -match ('(?i)-File\s+"'+[regex]::Escape($expected)+'"') -and $candidate.CommandLine -match ('(?i)-ConfigPath\s+"'+[regex]::Escape($ConfigPath)+'"') -and $candidate.CommandLine -match ('(?i)-Role\s+'+$WorkerRole+'(?:\s|$)') -and ([datetime]$candidate.CreationDate).ToUniversalTime() -le ([datetime]$state.HeartbeatUtc).ToUniversalTime().AddSeconds(2)){return}
        }
    }
    $entry=Join-Path $PSScriptRoot 'Start-LineDutyNotifier.ps1'
    $arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$entry+'" -ConfigPath "'+$ConfigPath+'" -Role '+$WorkerRole
    $children[$WorkerRole]=Start-Process powershell.exe -ArgumentList $arguments -WindowStyle Hidden -PassThru
    Write-Audit 'WORKER_STARTED' '' ("role=$WorkerRole; pid=$($children[$WorkerRole].Id)")
}
try{
    Write-Audit 'STARTED' '' ("role=$Role; pid=$PID")
    if($Role -eq 'Host'){Invoke-SharedWorkerHost $ConfigPath $HostInstanceId;return}
    do{
        if(Test-NotifierPaused){break}
        if($script:WorkerControl){$script:WorkerControl.LastProgress=Get-PerformanceTick}
        Write-WorkerHealth
        try{
            switch($Role){
                'Collector'{
                    if(-not $Once){
                        if((Get-ExecutionMode) -eq 'SharedHost'){Ensure-Worker 'Host'}
                        else{Ensure-Worker 'Classifier';Ensure-Worker 'Sender';Ensure-Worker 'Receipts';if(Test-TeamEnabled){Ensure-Worker 'Scheduler'}}
                    }
                    $script:Polls++
                    $signature=Get-DatabaseProbeSignature ([string]$script:Settings.NotificationDatabase.DatabasePath) ([string]$script:Settings.NotificationDatabase.SqlitePath)
                    if(-not (Test-DatabaseScanRequired $signature)){$script:DatabaseSkips++;break}
                    $rows=Get-DatabaseRows
                    $complete=$true
                    foreach($row in $rows){
                        if(Test-NotifierPaused){$complete=$false;break}
                        try{
                            $event=Convert-NotificationRow $row
                            if($null -ne $event -and (Save-IncomingEvent $event)){$script:Saved++}
                        }catch{$complete=$false;Write-Audit 'COLLECT_EVENT_FAILED' ([string]$row.sort_order) 'will_rescan=true'}
                    }
                    if(-not $complete){$script:DatabaseScanTick=-1;throw 'CollectionIncomplete'}
                    Complete-DatabaseScan $signature
                    $script:LastReadUtc=Get-UtcStamp;$script:LastReadError=''
                }
                'Classifier'{Invoke-ClassifierPass}
                'Sender'{Invoke-SenderPass}
                'Receipts'{Invoke-ReceiptPass}
                'Scheduler'{Invoke-TeamSchedulerPass;$script:LastReadUtc=Get-UtcStamp;$script:LastReadError=''}
            }
        }catch{
            if($Role -eq 'Collector'){$script:DatabaseScanTick=-1}
            $script:LastReadError=$_.Exception.GetType().Name
            Write-Audit 'WORKER_ERROR' '' ("role=$Role; error_type=$($script:LastReadError)")
        }
        if(-not $Once){
            $delay=if($Role -eq 'Collector'){[Math]::Max(250,[int]$script:Settings.NotificationDatabase.PollMilliseconds)}elseif($Role -eq 'Scheduler'){5000}else{500}
            Start-Sleep -Milliseconds $delay
        }
    }while(-not $Once)
}finally{
    if($Role -ne 'Host'){$script:LastHealth=[datetime]::MinValue;Write-WorkerHealth}
    if($owned){$mutex.ReleaseMutex()};$mutex.Dispose()
}
