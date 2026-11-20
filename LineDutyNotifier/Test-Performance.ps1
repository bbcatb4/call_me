$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Notifier.Core.ps1')
$root=Join-Path (Split-Path $PSScriptRoot) ('artifacts\performance-test-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$config=Join-Path $root 'appsettings.json';Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'appsettings.example.json') -Destination $config
Initialize-Notifier $config
$script:Passed=0
function Assert($value,[string]$name){if(-not $value){throw "FAIL: $name"};$script:Passed++;"PASS: $name"}
Assert ((Get-PerformanceTick) -gt 0) 'monotonic clock works on Windows PowerShell 5.1'
$path=Get-StatePath 'outbox' 'fixture';Write-State $path ([pscustomobject]@{Status='pending';Kind='Confirmed';NextAttemptUtc=[datetime]::UtcNow.AddSeconds(-1).ToString('o')})
Assert (-not (Test-WorkDeferred $path 'Sender')) 'due alert remains eligible'
$reads=$script:WorkHintReads;[void](Get-WorkHint $path)
Assert ($script:WorkHintReads -eq $reads -and $script:WorkHintHits -gt 0) 'unchanged metadata avoids repeated decryption'
Write-State $path ([pscustomobject]@{Status='accepted';Kind='Confirmed';Receipt='synthetic';NextReceiptUtc=[datetime]::UtcNow.AddSeconds(-1).ToString('o')})
Assert (Test-WorkDeferred $path 'Sender') 'accepted alert is not resent'
Assert (-not (Test-WorkDeferred $path 'Receipts')) 'accepted receipt still tracked'
Write-State $path ([pscustomobject]@{Status='acknowledged';Receipt='synthetic'})
Assert (Test-WorkDeferred $path 'Receipts') 'acknowledged receipt skips work'
Write-State $path ([pscustomobject]@{Status='accepted';Receipt='synthetic';CancelRequested=$true})
Assert (-not (Test-WorkDeferred $path 'Cancellation')) 'cancel request remains eligible'
Write-State $path ([pscustomobject]@{Status='pending';NextAttemptUtc=[datetime]::UtcNow.AddHours(1).ToString('o')})
Assert (Test-WorkDeferred $path 'Sender') 'future retry waits without HTTP'
Write-State $path ([pscustomobject]@{Status='done'})
Assert (Test-WorkDeferred $path 'Classifier') 'completed classification skips decryption'
$script:WorkHints[$path].Tick-=31000;$reads=$script:WorkHintReads;[void](Get-WorkHint $path)
Assert ($script:WorkHintReads -eq $reads+1) 'forced hint refresh prevents permanent stale state'
Initialize-Performance
Assert (Test-DatabaseScanRequired 'a') 'startup always scans'
Complete-DatabaseScan 'a'
Assert (-not (Test-DatabaseScanRequired 'a')) 'unchanged database skips copy'
Assert (Test-DatabaseScanRequired 'b') 'changed database scans immediately'
$script:DatabaseScanTick-=31000
Assert (Test-DatabaseScanRequired 'a') 'unchanged database still rescanned within 30 seconds'
$script:DatabaseScanTick=-1
Assert (Test-DatabaseScanRequired 'a') 'failed scan is eligible for immediate retry'
$db=Join-Path $root 'synthetic.db';$sqlite=Join-Path $root 'sqlite-placeholder.exe'
[IO.File]::WriteAllBytes($db,(New-Object byte[] 256));[IO.File]::WriteAllBytes($sqlite,@(1))
$sig=Get-DatabaseProbeSignature $db $sqlite
$wal=$db+'-wal';[IO.File]::WriteAllBytes($wal,(New-Object byte[] 256));$s2=Get-DatabaseProbeSignature $db $sqlite
Assert ($sig -ne $s2) 'WAL appearance triggers scan'
$stamp=[IO.File]::GetLastWriteTimeUtc($wal);$bytes=[IO.File]::ReadAllBytes($wal);$bytes[250]=42;[IO.File]::WriteAllBytes($wal,$bytes);[IO.File]::SetLastWriteTimeUtc($wal,$stamp)
Assert ((Get-DatabaseProbeSignature $db $sqlite) -ne $s2) 'WAL commit change detected even with same size and timestamp'
$missing=$false;try{[void](Get-DatabaseProbeSignature ($db+'.missing') $sqlite)}catch{$missing=$true}
Assert $missing 'missing database is an error, not idle success'
for($i=0;$i -lt 2050;$i++){$script:WorkHints['synthetic'+$i]=@{}}
[void](Get-WorkHint $path)
Assert ($script:WorkHints.Count -le 2048) 'hint memory is bounded'
Write-PerformanceSample 'Collector'
Assert ($script:Performance.PrivateMB -gt 0) 'performance memory sample available'
$log=@(Get-ChildItem -LiteralPath $script:LogDirectory -Filter 'performance-*.jsonl')[0]
Assert ((Get-Content -LiteralPath $log.FullName -Raw) -notmatch 'synthetic|Receipt|Message|token|key') 'performance sample contains no notification or secret data'
$control=Join-Path $root 'control.json';[IO.File]::WriteAllText($control,'{"State":"ready"}')
$script:PauseCheckAfter=0
Assert (-not (Test-NotifierPaused)) 'ready state allows work'
[IO.File]::WriteAllText($control,'{"State":"stopped"}');Start-Sleep -Milliseconds 300
Assert (Test-NotifierPaused) 'pause observed within bounded 250 ms cache'
[IO.File]::WriteAllText($control,'broken');Start-Sleep -Milliseconds 300
Assert (Test-NotifierPaused) 'unreadable control fails closed'
[IO.File]::WriteAllText($control,'{"State":"ready"}');Initialize-Notifier $config
Assert (-not (Test-NotifierPaused)) 'initialization clears previous pause cache'
"RESULT: $script:Passed checks passed. Fixture: $root"
