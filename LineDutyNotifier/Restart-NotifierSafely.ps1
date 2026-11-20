param([string]$ConfigPath=(Join-Path $PSScriptRoot 'appsettings.json'))
$ErrorActionPreference='Stop';$ConfigPath=[IO.Path]::GetFullPath($ConfigPath)
. (Join-Path $PSScriptRoot 'Notifier.Core.ps1');Initialize-Notifier $ConfigPath
$entry=Join-Path $PSScriptRoot 'Start-LineDutyNotifier.ps1'
function Get-MatchingWorkers {
    @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'"|Where-Object {$_.CommandLine -match ('(?i)-File\s+"'+[regex]::Escape($entry)+'"') -and $_.CommandLine -match ('(?i)-ConfigPath\s+"'+[regex]::Escape($ConfigPath)+'"')})
}
$controlPath=Join-Path (Split-Path $ConfigPath) 'control.json'
$control=if(Test-Path -LiteralPath $controlPath){Get-Content -LiteralPath $controlPath -Raw -Encoding UTF8|ConvertFrom-Json}else{[pscustomobject]@{Version=1;DatasetId=[guid]::NewGuid().ToString('N');State='ready'}}
if($control.State -ne 'ready'){throw 'Not ready: use launcher to resolve paused/transfer state first'}
foreach($role in @('Collector','Classifier','Sender','Receipts','Scheduler','Host')){
    $path=Get-StatePath 'health' $role
    if(Test-Path $path){$health=Read-State $path;if(@(Get-MatchingWorkers|Where-Object ProcessId -eq $health.Pid).Count -and $health.ControlProtocol -ne 1){throw 'Running legacy worker cannot be stopped safely'}}
}
function Save-Control {
    $temp=$controlPath+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        $bytes=[Text.Encoding]::UTF8.GetBytes(($control|ConvertTo-Json -Depth 10));$f=[IO.File]::Open($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$f.Write($bytes,0,$bytes.Length);$f.Flush($true)}finally{$f.Dispose()}
        if([IO.File]::Exists($controlPath)){[IO.File]::Replace($temp,$controlPath,[NullString]::Value)}else{[IO.File]::Move($temp,$controlPath)}
    }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}
$control.State='stopped';Save-Control
$deadline=[datetime]::UtcNow.AddSeconds(90)
do{Start-Sleep -Milliseconds 500;$remaining=@(Get-MatchingWorkers)}while($remaining.Count -and [datetime]::UtcNow -lt $deadline)
if($remaining.Count){throw 'Safe stop timed out; source remains stopped; no processes killed'}
$control.State='ready';Save-Control
[void](Start-Process powershell.exe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "'+$entry+'" -ConfigPath "'+$ConfigPath+'"') -WindowStyle Hidden)
'RESTART_REQUESTED: existing data and pending notifications preserved'
