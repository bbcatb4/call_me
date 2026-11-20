param([string]$ConfigPath=(Join-Path $PSScriptRoot 'appsettings.json'))
$ErrorActionPreference='Stop'
$ConfigPath=[IO.Path]::GetFullPath($ConfigPath)
$root=Split-Path $ConfigPath
$log=Join-Path $root 'logs\autostart.log'
try {
    if(-not [IO.File]::Exists($ConfigPath)){throw 'ConfigMissing'}
    $controlPath=Join-Path $root 'control.json'
    if([IO.File]::Exists($controlPath)){
        $control=[IO.File]::ReadAllText($controlPath,[Text.Encoding]::UTF8)|ConvertFrom-Json
        # A login must never reactivate a source that was frozen for migration.
        if($control.State -in @('exporting','transferred')){exit 0}
        $control.State='ready'
        $temp=$controlPath+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
        try {
            $bytes=[Text.Encoding]::UTF8.GetBytes(($control|ConvertTo-Json -Depth 10))
            $stream=[IO.File]::Open($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
            [IO.File]::Replace($temp,$controlPath,[NullString]::Value)
        }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
    }
    $response=& (Join-Path $PSScriptRoot 'Portable.Bridge.ps1') -Action start -ConfigPath $ConfigPath
    $result=$response|ConvertFrom-Json
    if(-not $result.Ok){throw 'BridgeStartFailed'}
    exit 0
}catch{
    # Fixed diagnostic only: never write paths, notification text, or credentials.
    [void][IO.Directory]::CreateDirectory((Split-Path $log))
    Add-Content -LiteralPath $log -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss')+' [AUTOSTART_FAILED] error_type='+$_.Exception.GetType().Name) -Encoding UTF8
    exit 1
}
