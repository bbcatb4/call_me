param([ValidateSet('status','start','quiesce','initialize','check')][string]$Action,[Parameter(Mandatory=$true)][string]$ConfigPath)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
. (Join-Path $PSScriptRoot 'Notifier.Core.ps1')
function Get-PortableProcesses {
    $expected=[IO.Path]::GetFullPath($ConfigPath)
    foreach($p in @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'")){
        if($p.ProcessId -eq $PID){continue}
        $m=[regex]::Match([string]$p.CommandLine,'(?i)(?:^|\s)-File\s+(?:"([^"]+)"|(\S+))')
        $entry=if($m.Groups[1].Success){$m.Groups[1].Value}else{$m.Groups[2].Value}
        if(-not $entry -or [IO.Path]::GetFileName($entry) -notin @('Start-LineDutyNotifier.ps1','Show-TeamManagement.ps1','Show-NotifierDashboard.ps1')){continue}
        $m=[regex]::Match([string]$p.CommandLine,'(?i)(?:^|\s)-ConfigPath\s+(?:"([^"]+)"|(\S+))')
        $config=if($m.Groups[1].Success){$m.Groups[1].Value}elseif($m.Groups[2].Success){$m.Groups[2].Value}else{Join-Path (Split-Path $entry) 'appsettings.json'}
        if([IO.Path]::GetFullPath($config) -eq $expected){$p}
    }
}
try {
    switch($Action){
        'status'{
            if(-not (Test-Path -LiteralPath $ConfigPath)){[pscustomobject]@{Configured=$false}|ConvertTo-Json -Compress;break}
            . (Join-Path $PSScriptRoot 'Dashboard.Status.ps1')
            $s=Get-DashboardSnapshot $ConfigPath
            [pscustomobject]@{Configured=$true;Overall=$s.Overall;Workers=@($s.Workers|Select-Object Role,Running,Status,Reason);Runtime=$s.Runtime;RecentErrors=$s.RecentErrorCount}|ConvertTo-Json -Depth 6 -Compress
        }
        'start'{
            Initialize-Notifier $ConfigPath
            if(Test-NotifierPaused){throw 'Paused'}
            $existing=@(Get-PortableProcesses|Where-Object {$_.CommandLine -match 'Start-LineDutyNotifier.ps1' -and ($_.CommandLine -notmatch '(?i)\s-Role\s' -or $_.CommandLine -match '(?i)\s-Role\s+"?Collector')})
            if(-not $existing.Count){
                $entry=Join-Path $PSScriptRoot 'Start-LineDutyNotifier.ps1'
                [void](Start-Process powershell.exe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "'+$entry+'" -ConfigPath "'+$ConfigPath+'"') -WindowStyle Hidden)
            }
            '{"Ok":true}'
        }
        'quiesce'{
            # Never kill workers in the middle of a network operation or durable commit.
            $deadline=[datetime]::UtcNow.AddSeconds(150)
            do {
                $processes=@(Get-PortableProcesses)
                foreach($p in @($processes|Where-Object {$_.CommandLine -notmatch 'Start-LineDutyNotifier.ps1'})){
                    $proc=Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
                    if($proc){[void]$proc.CloseMainWindow()}
                }
                if(-not $processes.Count){'{"Ok":true}';break}
                if([datetime]::UtcNow -ge $deadline){throw 'QuiesceTimeout'}
                Start-Sleep -Milliseconds 500
            }while($true)
        }
        'initialize'{Initialize-Notifier $ConfigPath;Enable-Team;'{"Ok":true}'}
        'check'{
            $psOk=$PSVersionTable.PSVersion.Major -eq 5
            Add-Type -AssemblyName PresentationFramework,System.Runtime.WindowsRuntime
            [void][Windows.Data.Pdf.PdfDocument,Windows.Data.Pdf,ContentType=WindowsRuntime]
            $db=Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Notifications\wpndatabase.db'
            $sqlite=Join-Path (Split-Path $PSScriptRoot) 'tools\sqlite3.exe'
            $dbOk=Test-Path -LiteralPath $db;$sqliteOk=Test-Path -LiteralPath $sqlite
            $line=@(Get-Process -Name LINE -ErrorAction SilentlyContinue).Count -gt 0
            $probeOk=$false;$lineSource=$false
            if($dbOk -and $sqliteOk){
                $probe=Join-Path ([IO.Path]::GetTempPath()) ('ldn-probe-'+[guid]::NewGuid().ToString('N')+'.db')
                try {
                    Copy-Item -LiteralPath $db -Destination $probe
                    if(Test-Path -LiteralPath ($db+'-wal')){Copy-Item -LiteralPath ($db+'-wal') -Destination ($probe+'-wal')}
                    $info=New-Object Diagnostics.ProcessStartInfo;$info.FileName=$sqlite;$info.Arguments='-readonly "'+$probe+'" "SELECT count(*) FROM NotificationHandler WHERE PrimaryId LIKE ''%LINE%'';"';$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
                    $proc=New-Object Diagnostics.Process;$proc.StartInfo=$info
                    try {[void]$proc.Start();$out=$proc.StandardOutput.ReadToEndAsync();$err=$proc.StandardError.ReadToEndAsync();if(-not $proc.WaitForExit(10000)){$proc.Kill();throw 'ProbeTimeout'};$probeOk=$proc.ExitCode -eq 0;$count=0;$lineSource=[int]::TryParse($out.Result.Trim(),[ref]$count) -and $count -gt 0}
                    finally{$proc.Dispose()}
                }catch{$probeOk=$false}
                finally{foreach($suffix in @('','-wal','-shm')){$file=$probe+$suffix;if([IO.File]::Exists($file)){[IO.File]::Delete($file)}}}
            }
            [pscustomobject]@{PowerShell51=$psOk;Pdf=$true;Sqlite=$sqliteOk;Database=$dbOk;DatabaseReadable=$probeOk;LineRunning=$line;LineSource=$lineSource}|ConvertTo-Json -Compress
        }
    }
}catch{
    # Emit only fixed codes, never the raw exception or a child process response.
    $code=if($_.Exception.Message -eq 'QuiesceTimeout'){'quiesce_timeout'}elseif($_.Exception.Message -eq 'Paused'){'paused'}else{'operation_failed'}
    [pscustomobject]@{Ok=$false;Error=$code}|ConvertTo-Json -Compress
    exit 1
}
