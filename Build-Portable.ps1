param(
    [string]$DotnetPath=(Join-Path $PSScriptRoot '.tools\dotnet10\dotnet.exe'),
    [Parameter(Mandatory=$true)][string]$SqlitePath,
    [string]$OutputDirectory=(Join-Path $PSScriptRoot 'dist')
)
$ErrorActionPreference='Stop'
$version='0.2.0';$name="LineDutyNotifier-$version-win-x64"
$dist=[IO.Path]::GetFullPath($OutputDirectory);[void][IO.Directory]::CreateDirectory($dist)
$build=Join-Path $PSScriptRoot ('artifacts\package-'+[guid]::NewGuid().ToString('N'))
$package=Join-Path $build $name;[void][IO.Directory]::CreateDirectory($package)
if(-not (Test-Path -LiteralPath $DotnetPath) -or -not (Test-Path -LiteralPath $SqlitePath)){throw 'Build dependency missing'}
$sdk=(& $DotnetPath --version);if($LASTEXITCODE -ne 0 -or $sdk -notmatch '^10\.'){throw 'Require .NET 10 SDK'}
& $DotnetPath publish (Join-Path $PSScriptRoot 'LineDutyLauncher\LineDutyLauncher.csproj') -c Release -r win-x64 --self-contained true -p:DebugType=None -p:DebugSymbols=false -o $package
if($LASTEXITCODE -ne 0){throw 'Publish failed'}
$app=Join-Path $package 'app';$toolRoot=Join-Path $package 'tools';$licenses=Join-Path $package 'licenses'
foreach($dir in @($app,$toolRoot,$licenses)){[void][IO.Directory]::CreateDirectory($dir)}
# Explicit allowlist only: never copy a source tree or local user data recursively.
$files=@('appsettings.example.json','Notifier.Core.ps1','Performance.Core.ps1','Get-PerformanceReport.ps1','PERFORMANCE-GUIDE.md','Restart-NotifierSafely.ps1','Start-NotifierAtLogon.ps1','Start-LineDutyNotifier.ps1','Portable.Bridge.ps1','Dashboard.Status.ps1','Dashboard.xaml','Show-NotifierDashboard.ps1','Get-NotifierStatus.ps1','Team.Core.ps1','Team.Roster.ps1','Team.Preview.ps1','Team.Management.xaml','Show-TeamManagement.ps1','TEAM-GUIDE.md')
$files+=@('Runtime.Core.ps1','RUNTIME-GUIDE.md','Dashboard.View.ps1')
foreach($file in $files){Copy-Item -LiteralPath (Join-Path $PSScriptRoot ('LineDutyNotifier\'+$file)) -Destination (Join-Path $app $file)}
Copy-Item -LiteralPath $SqlitePath -Destination (Join-Path $toolRoot 'sqlite3.exe')
foreach($file in @('PORTABLE-QUICKSTART.md','PORTABLE-VALIDATION.md','THIRD-PARTY-NOTICES.md')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $package}
$sdkRoot=Split-Path $DotnetPath
Copy-Item -LiteralPath (Join-Path $sdkRoot 'LICENSE.txt') -Destination (Join-Path $licenses 'DOTNET-LICENSE.txt')
Copy-Item -LiteralPath (Join-Path $sdkRoot 'ThirdPartyNotices.txt') -Destination (Join-Path $licenses 'DOTNET-THIRD-PARTY-NOTICES.txt')
$sqliteVersion=(& $SqlitePath --version);if($LASTEXITCODE -ne 0){throw 'SQLite probe failed'}
$info=[ordered]@{Version=$version;Target='win-x64';Sdk=$sdk;Sqlite=$sqliteVersion;BuildUtc=[datetime]::UtcNow.ToString('o');SelfContained=$true;Signed=$false}
[IO.File]::WriteAllText((Join-Path $package 'BUILD-INFO.json'),($info|ConvertTo-Json),[Text.Encoding]::UTF8)
$all=@(Get-ChildItem -LiteralPath $package -File -Recurse)
$forbidden=@($all|Where-Object {$_.Name -eq 'appsettings.json' -or $_.Extension -in @('.dat','.db','.log','.ldntransfer','.pdb') -or $_.FullName -match '\\(?:state|logs|tests)\\'})
if($forbidden.Count){throw 'Private or unexpected artifacts in package'}
$hashes=@($all|Sort-Object FullName|ForEach-Object {((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant())+'  '+$_.FullName.Substring($package.Length+1).Replace('\','/')})
[IO.File]::WriteAllLines((Join-Path $package 'FILES-SHA256.txt'),$hashes,[Text.Encoding]::UTF8)
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip=Join-Path $dist ($name+'.zip');$temp=Join-Path $build ($name+'.zip')
[IO.Compression.ZipFile]::CreateFromDirectory($package,$temp,[IO.Compression.CompressionLevel]::Optimal,$true)
# Archive only the package directory; the temporary archive is a sibling, not input content.
Copy-Item -LiteralPath $temp -Destination $zip -Force
$hash=(Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText(($zip+'.sha256'),($hash+'  '+$name+'.zip'+[Environment]::NewLine),[Text.Encoding]::UTF8)
[pscustomobject]@{Zip=$zip;Sha256=$hash;Package=$package;SizeMB=[Math]::Round((Get-Item -LiteralPath $zip).Length/1MB,2)}|ConvertTo-Json -Compress
