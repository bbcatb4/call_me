param([string]$ZipPath=(Join-Path $PSScriptRoot 'dist\LineDutyNotifier-0.2.0-win-x64.zip'))
$ErrorActionPreference='Stop'
$test=Join-Path $PSScriptRoot ('artifacts\解壓 搬動測試-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($test)
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::ExtractToDirectory($ZipPath,$test)
$package=Join-Path $test 'LineDutyNotifier-0.2.0-win-x64'
$exe=Join-Path $package 'LineDutyNotifier.exe'
$entries=@(Get-Content -LiteralPath (Join-Path $package 'FILES-SHA256.txt') -Encoding UTF8)
foreach($entry in $entries){
    if($entry -notmatch '^([a-f0-9]{64})  (.+)$'){throw 'Invalid manifest'}
    $expected=$Matches[1];$relative=$Matches[2]
    $full=[IO.Path]::GetFullPath((Join-Path $package $relative))
    if(-not $full.StartsWith($package+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Invalid manifest path'}
    if((Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected){throw 'Manifest hash mismatch'}
}
foreach($file in @('coreclr.dll','hostfxr.dll','System.Windows.Forms.dll','tools\sqlite3.exe')){if(-not (Test-Path -LiteralPath (Join-Path $package $file))){throw 'Self contained component missing'}}
$output=Join-Path $test 'results'
$p=Start-Process -FilePath $exe -ArgumentList ('--self-test "'+$output+'"') -WindowStyle Hidden -Wait -PassThru
if($p.ExitCode -ne 0){throw 'Portable integration failed; inspect isolated results'}
$result=Get-Content -LiteralPath (Join-Path $output 'self-test-result.json') -Raw -Encoding UTF8|ConvertFrom-Json
# Move only this freshly extracted code directory within this verified test root; user data stays outside it.
$moved=Join-Path $test '程式 已搬動';Move-Item -LiteralPath $package -Destination $moved
$preview=Join-Path $test 'launcher.png'
$p=Start-Process -FilePath (Join-Path $moved 'LineDutyNotifier.exe') -ArgumentList ('--preview "'+$preview+'"') -WindowStyle Hidden -Wait -PassThru
if($p.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $preview)){throw 'Moved application preview failed'}
$config=Join-Path $result.Fixture 'integration imported\appsettings.json'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File (Join-Path $moved 'app\Show-NotifierDashboard.ps1') -ConfigPath $config -SmokeTest
if($LASTEXITCODE -ne 0){throw 'Packaged dashboard failed'}
[pscustomobject]@{Passed=$result.Passed;ManifestFiles=$entries.Count;MovedAppLaunch=$true;Dashboard=$true;TestRoot=$test;CrossMachine='NOT_TESTED'}|ConvertTo-Json -Compress
