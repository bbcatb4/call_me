# Read-only projection; no bodies, images, names, receipts, keys or raw logs.
. (Join-Path $PSScriptRoot 'Notifier.Core.ps1')
. (Join-Path $PSScriptRoot 'Dashboard.View.ps1')
Add-Type -AssemblyName System.Security
function Get-DashboardProcesses { return @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction Stop) }
function Test-DashboardSecret([string]$Name) {
    if(-not $Name){return $false}
    if($script:DashboardSecretPath -and (Test-Path -LiteralPath $script:DashboardSecretPath)){
        if((Read-State $script:DashboardSecretPath).$Name){return $true}
    }
    return [bool]([Environment]::GetEnvironmentVariable($Name,'User') -or [Environment]::GetEnvironmentVariable($Name,'Process'))
}
function Get-DashboardAge($Value,[datetime]$Now) {
    if(-not $Value){return $null}
    try {return [Math]::Floor(($Now-([datetime]$Value).ToUniversalTime()).TotalSeconds)} catch {return $null}
}
function Get-DashboardSnapshot([string]$ConfigPath=(Join-Path $PSScriptRoot 'appsettings.json')) {
    $now=[datetime]::UtcNow
    $appRoot=Split-Path ([IO.Path]::GetFullPath($ConfigPath));$root=Join-Path $appRoot 'state'
    $script:DashboardSecretPath=Join-Path $appRoot 'secrets.dat'
    $entry=Join-Path $PSScriptRoot 'Start-LineDutyNotifier.ps1'
    $issues=[Collections.Generic.List[string]]::new();$settings=$null
    try {$settings=Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop}
    catch {$issues.Add('config_unreadable')}
    $processes=@();$processAccess=$true
    try {$processes=@(Get-DashboardProcesses)} catch {$processAccess=$false;$issues.Add('process_access_failed')}
    $roles=@('Collector','Classifier','Sender','Receipts')
    if(Test-Path (Join-Path $root 'team/model.dat')){$roles+=@('Scheduler')}
    $workers=@(foreach($role in $roles) {
        $row=[ordered]@{Role=$role;Pid=0;Running=$false;Status='unknown';Reason='health_missing';HeartbeatUtc='';HeartbeatAgeSeconds=$null;LastSuccessfulReadUtc='';ReadAgeSeconds=$null;LastError='';Polls=0;Saved=0;CPUPercent=$null;PrivateMB=$null;WorkingSetMB=$null;SharedHost=$false}
        $path=Join-Path $root ('health/'+$role+'.dat')
        try {
            if(-not (Test-Path -LiteralPath $path)){throw 'MissingHealth'}
            $health=Read-State $path;$row.Pid=[int]$health.Pid
            $perf=Get-Option $health 'Performance' $null
            if($perf){$row.CPUPercent=$perf.CPUPercent;$row.PrivateMB=$perf.PrivateMB;$row.WorkingSetMB=$perf.WorkingSetMB}
            $row.HeartbeatAgeSeconds=Get-DashboardAge $health.HeartbeatUtc $now
            $row.ReadAgeSeconds=Get-DashboardAge $health.LastSuccessfulReadUtc $now
            if($null -ne $row.HeartbeatAgeSeconds){$row.HeartbeatUtc=([datetime]$health.HeartbeatUtc).ToUniversalTime().ToString('o')}
            if($null -ne $row.ReadAgeSeconds){$row.LastSuccessfulReadUtc=([datetime]$health.LastSuccessfulReadUtc).ToUniversalTime().ToString('o')}
            $row.Polls=[long](Get-Option $health 'Polls' 0);$row.Saved=[long](Get-Option $health 'Saved' 0)
            $candidate=@($processes|Where-Object {[int]$_.ProcessId -eq $row.Pid}|Select-Object -First 1);$identity=$false
            if($candidate.Count){
                $process=$candidate[0];$command=[string]$process.CommandLine
                $fileMatch=[regex]::Match($command,'(?i)(?:^|\s)-File\s+(?:"([^"]+)"|(\S+))')
                $file=if($fileMatch.Groups[1].Success){$fileMatch.Groups[1].Value}else{$fileMatch.Groups[2].Value}
                $roleMatch=[regex]::Match($command,'(?i)(?:^|\s)-Role\s+"?(Collector|Classifier|Sender|Receipts|Scheduler|Host)(?:"|\s|$)')
                $processRole=if($roleMatch.Success){$roleMatch.Groups[1].Value}else{'Collector'}
                if($file -and $processRole -eq $role){
                    $identity=[IO.Path]::GetFullPath($file).Equals($entry,[StringComparison]::OrdinalIgnoreCase)
                    if($process.CreationDate -and $row.HeartbeatUtc -and ([datetime]$process.CreationDate).ToUniversalTime() -gt ([datetime]$row.HeartbeatUtc).ToUniversalTime().AddSeconds(2)){$identity=$false}
                }
                if($file -and $processRole -eq 'Host' -and $health.RuntimeProtocol -eq 2 -and $health.HostInstanceId -and $health.WorkerInstanceId){
                    $hostHealth=Read-State (Join-Path $root 'health/Host.dat')
                    $cm=[regex]::Match($command,'(?i)(?:^|\s)-ConfigPath\s+(?:"([^"]+)"|(\S+))')
                    $cp=if($cm.Groups[1].Success){$cm.Groups[1].Value}else{$cm.Groups[2].Value}
                    $membership=@($hostHealth.Roles|Where-Object {$_.Role -eq $role -and $_.WorkerInstanceId -eq $health.WorkerInstanceId -and $_.State -eq 'running'})
                    $hostAge=Get-DashboardAge $hostHealth.HeartbeatUtc $now
                    $identity=$cp -and [IO.Path]::GetFullPath($file).Equals($entry,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFullPath($cp).Equals([IO.Path]::GetFullPath($ConfigPath),[StringComparison]::OrdinalIgnoreCase) -and $hostHealth.Pid -eq $row.Pid -and $hostHealth.HostInstanceId -eq $health.HostInstanceId -and $membership.Count -eq 1 -and $null -ne $hostAge -and $hostAge -ge -5 -and $hostAge -le 120
                    if($process.CreationDate -and ([datetime]$process.CreationDate).ToUniversalTime() -gt ([datetime]$health.HeartbeatUtc).ToUniversalTime().AddSeconds(2)){$identity=$false}
                    $row.SharedHost=$true
                }
            }
            $row.Running=$identity
            if(-not $processAccess){$row.Status='unknown';$row.Reason='process_access_failed'}
            elseif(-not $identity){$row.Status='error';$row.Reason='process_not_found_or_reused'}
            elseif($null -eq $row.HeartbeatAgeSeconds -or $row.HeartbeatAgeSeconds -lt -5){$row.Status='unknown';$row.Reason='invalid_heartbeat'}
            elseif($row.HeartbeatAgeSeconds -gt 120){$row.Status='error';$row.Reason='heartbeat_stale'}
            elseif($health.LastReadError){$row.Status='error';$row.Reason='worker_error';$row.LastError='worker_error'}
            elseif($role -eq 'Collector' -and ($null -eq $row.ReadAgeSeconds -or $row.ReadAgeSeconds -lt -5 -or $row.ReadAgeSeconds -gt 120)){$row.Status='warning';$row.Reason='read_not_fresh'}
            else{$row.Status='ok';$row.Reason='healthy'}
        }catch {$row.Status='unknown';$row.Reason=if(Test-Path -LiteralPath $path){'health_unreadable'}else{'health_missing'};$issues.Add($role+'_'+$row.Reason)}
        [pscustomobject]$row
    })
    $queue=[ordered]@{Inbox=0;AiPending=0;AiFailed=0;AiFailedPending=0;AiFailedCompleted=0;PushPending=0;UrgentPending=0;PushRetry=0;AwaitingAcknowledgement=0;Acknowledged=0;ExpiredLast24Hours=0;ConfirmedToday=0;Unreadable=0}
    $alertGroups=@{};$inboxIds=@();$processedIds=@{}
    foreach($folder in @('inbox','processed','outbox')){
        $directory=Join-Path $root $folder
        try {
            if(-not (Test-Path -LiteralPath $directory)){throw 'MissingStateDirectory'}
            $files=@(Get-ChildItem -LiteralPath $directory -Filter '*.dat' -File -ErrorAction Stop)
            if($folder -eq 'inbox'){$queue.Inbox=$files.Count;$inboxIds=@($files|ForEach-Object {$_.BaseName});continue}
            foreach($file in $files){
                try {
                    $state=Read-State $file.FullName
                    if($folder -eq 'processed'){
                        if($state.Status -notin @('pending','done')){throw 'InvalidJobState'}
                        $processedIds[$file.BaseName]=$true
                        if($state.Status -eq 'pending'){$queue.AiPending++}
                        if($state.AiStatus -eq 'failed'){$queue.AiFailed++;if($state.Status -eq 'pending'){$queue.AiFailedPending++}else{$queue.AiFailedCompleted++}}
                    }else{
                        if($state.Kind -notin @('Confirmed','Review') -or $state.Status -notin @('pending','accepted','acknowledged','expired','cancelled')){throw 'InvalidAlertState'}
                        $group=$state.Kind+', '+$state.Status
                        if(-not $alertGroups.ContainsKey($group)){$alertGroups[$group]=0};$alertGroups[$group]++
                        if($state.Status -eq 'pending'){$queue.PushPending++;if($state.Kind -eq 'Confirmed'){$queue.UrgentPending++};if($state.LastError){$queue.PushRetry++}}
                        if($state.Kind -eq 'Confirmed' -and $state.Status -eq 'accepted'){$queue.AwaitingAcknowledgement++}
                        if($state.Status -eq 'acknowledged'){$queue.Acknowledged++}
                        if($state.Status -eq 'expired' -and $file.LastWriteTimeUtc -ge $now.AddHours(-24)){$queue.ExpiredLast24Hours++}
                        if($state.Kind -eq 'Confirmed' -and $state.CreatedUtc -and ([datetime]$state.CreatedUtc).ToLocalTime().Date -eq $now.ToLocalTime().Date){$queue.ConfirmedToday++}
                    }
                }catch {$queue.Unreadable++}
            }
        }catch {$issues.Add($folder+'_unreadable')}
    }
    # A received event without a job file is also waiting for classification.
    $queue.AiPending+=@($inboxIds|Where-Object {-not $processedIds.ContainsKey($_)}).Count
    if($queue.Unreadable){$issues.Add('state_unreadable')}
    $today=$now.ToLocalTime().Date;$monthStart=[datetime]::new($today.Year,$today.Month,1)
    $usage=[ordered]@{
        Available=$true;Records=0;Unreadable=0;TrackingSinceUtc='';
        TodayRequests=0;TodayInput=0L;TodayOutput=0L;TodayTotal=0L;TodayCachedInput=0L;TodayReasoning=0L;
        MonthRequests=0;MonthInput=0L;MonthOutput=0L;MonthTotal=0L;MonthCachedInput=0L;MonthReasoning=0L;
        LastRequestUtc='';LastInput=0L;LastOutput=0L;LastTotal=0L
    }
    $usageFolder=Join-Path $root 'usage';$usageRecords=[Collections.Generic.List[object]]::new()
    try {
        if(-not (Test-Path -LiteralPath $usageFolder)){throw 'MissingUsageDirectory'}
        foreach($file in @(Get-ChildItem -LiteralPath $usageFolder -Filter '*.dat' -File -ErrorAction Stop)){
            try {
                $record=Read-State $file.FullName
                $created=([datetime]$record.CreatedUtc).ToUniversalTime()
                $input=[long]$record.InputTokens;$output=[long]$record.OutputTokens;$total=[long]$record.TotalTokens
                $cached=[long](Get-Option $record 'CachedInputTokens' 0);$reasoning=[long](Get-Option $record 'ReasoningTokens' 0)
                if($input -lt 0 -or $output -lt 0 -or $total -lt ($input+$output) -or $cached -lt 0 -or $cached -gt $input -or $reasoning -lt 0 -or $reasoning -gt $output){throw 'InvalidUsageState'}
                $usageRecords.Add([pscustomobject]@{CreatedUtc=$created;Input=$input;Output=$output;Total=$total;Cached=$cached;Reasoning=$reasoning})
            }catch {$usage.Unreadable++}
        }
    }catch {$usage.Available=$false;$usage.Unreadable++}
    if($usage.Unreadable){$usage.Available=$false;$issues.Add('usage_unreadable')}
    if($usage.Available){
        $orderedUsage=@($usageRecords|Sort-Object CreatedUtc);$usage.Records=$orderedUsage.Count
        if($orderedUsage.Count){
            $usage.TrackingSinceUtc=$orderedUsage[0].CreatedUtc.ToString('o')
            $latest=$orderedUsage[-1];$usage.LastRequestUtc=$latest.CreatedUtc.ToString('o');$usage.LastInput=$latest.Input;$usage.LastOutput=$latest.Output;$usage.LastTotal=$latest.Total
        }
        foreach($record in $orderedUsage){
            $local=$record.CreatedUtc.ToLocalTime()
            if($local -ge $monthStart){$usage.MonthRequests++;$usage.MonthInput+=$record.Input;$usage.MonthOutput+=$record.Output;$usage.MonthTotal+=$record.Total;$usage.MonthCachedInput+=$record.Cached;$usage.MonthReasoning+=$record.Reasoning}
            if($local.Date -eq $today){$usage.TodayRequests++;$usage.TodayInput+=$record.Input;$usage.TodayOutput+=$record.Output;$usage.TodayTotal+=$record.Total;$usage.TodayCachedInput+=$record.Cached;$usage.TodayReasoning+=$record.Reasoning}
        }
    }
    $events=[Collections.Generic.List[object]]::new()
    $allowed=@{
        'HOST_ROLE_STARTED'='共用程序內的工作啟動';'HOST_ROLE_EXITED'='共用工作退出，等待恢復';'HOST_ROLE_STALE'='共用工作逾時，要求安全停止';
        'STARTED'='背景程序啟動';'WORKER_STARTED'='背景程序啟動';'WORKER_ERROR'='背景程序異常';
        'COLLECT_EVENT_FAILED'='收訊處理失敗';'CLASSIFIER_FAILED'='判讀工作失敗';'AI_FAILED'='AI 呼叫失敗';'AI_USAGE_FAILED'='AI 用量紀錄失敗';
        'PUSH_RETRY'='推播失敗，等待重試';'OUTBOX_FAILED'='推播佇列讀取失敗';'RECEIPT_RETRY'='收據查詢等待重試';'SCHEDULE_RETRY'='接刀排程處理失敗，等待重試';'CANCEL_RETRY'='停止舊提醒失敗，等待重試';
        'PUSH_EXPIRED_UNACKNOWLEDGED'='緊急提醒到期仍未確認';'PUSH_ACCEPTED'='Pushover 已接受';'PUSH_ACKNOWLEDGED'='使用者已確認'
    }
    $errorCodes=@('HOST_ROLE_EXITED','HOST_ROLE_STALE','WORKER_ERROR','COLLECT_EVENT_FAILED','CLASSIFIER_FAILED','AI_FAILED','AI_USAGE_FAILED','PUSH_RETRY','OUTBOX_FAILED','RECEIPT_RETRY','PUSH_EXPIRED_UNACKNOWLEDGED','SCHEDULE_RETRY','CANCEL_RETRY')
    try {
        $logFiles=@(Get-ChildItem -LiteralPath (Join-Path $appRoot 'logs') -Filter 'monitor-*.log' -File -ErrorAction Stop|Sort-Object Name -Descending|Select-Object -First 2)
        foreach($file in $logFiles){
            foreach($line in @(Get-Content -LiteralPath $file.FullName -Tail 2000 -Encoding UTF8 -ErrorAction Stop)){
                if($line -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) \[([A-Z_]+)\]'){
                    $code=$Matches[2];$when=[datetime]::ParseExact($Matches[1],'yyyy-MM-dd HH:mm:ss',[Globalization.CultureInfo]::InvariantCulture)
                    if($allowed.ContainsKey($code)){$events.Add([pscustomobject]@{Time=$when.ToString('yyyy-MM-dd HH:mm:ss');Code=$code;Label=$allowed[$code];IsError=($code -in $errorCodes)})}
                }
            }
        }
    }catch {$issues.Add('logs_unreadable')}
    $recentErrors=@($events|Where-Object {$_.IsError -and [datetime]$_.Time -ge $now.ToLocalTime().AddMinutes(-30)}).Count
    $services=[ordered]@{AiEnabled=$false;AiKeyPresent=$false;PushoverEnabled=$false;PushoverKeysPresent=$false;GroupCount=0;ConfigurationReadable=($null -ne $settings)}
    if($settings){
        $services.AiEnabled=[bool]$settings.Ai.Enabled;$services.PushoverEnabled=[bool]$settings.Pushover.Enabled
        $services.GroupCount=@($settings.TargetGroupNames|Where-Object {$_}).Count
        try {
            $services.AiKeyPresent=Test-DashboardSecret ([string]$settings.Ai.ApiKeyEnvironmentVariable)
            $services.PushoverKeysPresent=(Test-DashboardSecret ([string]$settings.Pushover.AppTokenEnvironmentVariable)) -and (Test-DashboardSecret ([string]$settings.Pushover.UserKeyEnvironmentVariable))
        }catch {$issues.Add('credential_check_failed')}
    }
    $overall='ok'
    if(@($workers|Where-Object Status -eq 'warning').Count -or $recentErrors -or $queue.PushRetry -or $queue.AiFailed -or $queue.ExpiredLast24Hours -or -not $services.AiEnabled -or -not $services.AiKeyPresent -or -not $usage.Available){$overall='warning'}
    if(@($workers|Where-Object Status -eq 'error').Count -or -not $services.PushoverEnabled -or -not $services.PushoverKeysPresent -or $services.GroupCount -eq 0){$overall='error'}
    $blockingIssues=@($issues|Where-Object {$_ -ne 'usage_unreadable'})
    if($blockingIssues.Count -or @($workers|Where-Object Status -eq 'unknown').Count){$overall='unknown'}
    $processMetrics=@(foreach($group in @($workers|Where-Object Running|Group-Object Pid)){
        $latest=$group.Group|Sort-Object HeartbeatUtc -Descending|Select-Object -First 1
        [pscustomobject]@{Pid=$latest.Pid;Roles=@($group.Group.Role);PrivateMB=$latest.PrivateMB;WorkingSetMB=$latest.WorkingSetMB;CPUPercent=$latest.CPUPercent}
    })
    $memoryAvailable=$processAccess -and $processMetrics.Count -gt 0 -and @($processMetrics|Where-Object {$null -eq $_.PrivateMB}).Count -eq 0
    return [pscustomobject]@{
        GeneratedUtc=$now.ToString('o');Overall=$overall;Workers=$workers;Queue=[pscustomobject]$queue;Usage=[pscustomobject]$usage;Services=[pscustomobject]$services;
        Runtime=[pscustomobject]@{ExecutionMode=(Get-Option $settings.Runtime 'ExecutionMode' 'MultiProcess');ProcessCount=$processMetrics.Count;MemoryAvailable=$memoryAvailable;PrivateMB=$(if($memoryAvailable){[math]::Round(($processMetrics|Measure-Object PrivateMB -Sum).Sum,2)}else{$null});Processes=$processMetrics};
        Alerts=@($alertGroups.Keys|Sort-Object|ForEach-Object {[pscustomobject]@{AlertState=$_;Count=$alertGroups[$_]}});
        RecentEvents=@($events|Sort-Object Time -Descending|Select-Object -First 8);RecentErrorCount=$recentErrors;
        Issues=@($issues.ToArray());QueueReadable=(-not ($issues -match '^(inbox|processed|outbox|state)_unreadable$'))
    }
}
