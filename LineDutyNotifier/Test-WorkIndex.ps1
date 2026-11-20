# Bounded candidate indexes, forced refresh and disk authority. No network.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Notifier.Core.ps1')
$root=Join-Path (Split-Path $PSScriptRoot) ('artifacts/index-test-'+[guid]::NewGuid().ToString('N'))
Initialize-Notifier (Join-Path $PSScriptRoot 'appsettings.example.json') $root
$script:LogDirectory=$root;$script:UseWorkIndex=$true;$script:Passed=0;$script:TestTick=10000L
function Get-PerformanceTick {return $script:TestTick}
function Assert($Value,[string]$Name){if(-not $Value){throw "FAIL: $Name"};$script:Passed++;"PASS: $Name"}
for($i=0;$i -lt 2500;$i++){
    Write-State (Get-StatePath processed ('old'+$i)) @{Status='done';AiStatus='not_needed'}
    Write-State (Get-StatePath inbox ('old'+$i)) @{Body='PRIVATE_TEST_CONTENT';Images=@('PRIVATE_IMAGE')}
}
Assert (@(Get-ReadyWorkFiles inbox Classifier).Count -eq 0) 'large completed inbox never enters active candidate list'
$scans=$script:WorkIndexScans;$reads=$script:WorkHintReads
1..5|ForEach-Object {[void](Get-ReadyWorkFiles inbox Classifier)}
Assert ($script:WorkIndexScans -eq $scans -and $script:WorkHintReads -eq $reads) 'idle passes avoid repeated history enumeration and decryption'
Write-State (Get-StatePath inbox fresh) @{Body='PRIVATE_TEST_CONTENT'}
Assert (@(Get-ReadyWorkFiles inbox Classifier).Count -eq 0) 'new work waits at most until next bounded scan'
$script:TestTick+=2001
$fresh=@(Get-ReadyWorkFiles inbox Classifier)
Assert ($fresh.Count -eq 1 -and $fresh[0].BaseName -eq 'fresh') 'new event discovered on two-second scan'
Write-State (Get-StatePath processed fresh) @{Status='done'}
Assert (Test-WorkDeferred (Get-StatePath processed fresh) Classifier) 'candidate is rechecked against disk before processing'
$script:TestTick+=2001
Assert (@(Get-ReadyWorkFiles inbox Classifier).Count -eq 0) 'completed work removed on next scan'
Write-State (Get-StatePath outbox pending) @{Status='pending';Kind='Confirmed';NextAttemptUtc=[datetime]::UtcNow.AddMinutes(-1).ToString('o');Message='PRIVATE_TEST_CONTENT';Receipt='PRIVATE_RECEIPT'}
Assert (@(Get-ReadyWorkFiles outbox Sender).Count -eq 1) 'due send eligible'
Write-State (Get-StatePath outbox pending) @{Status='accepted';Kind='Confirmed';Receipt='PRIVATE_RECEIPT';NextReceiptUtc=[datetime]::UtcNow.AddMinutes(-1).ToString('o');CancelRequested=$true}
Assert (@(Get-ReadyWorkFiles outbox Receipts).Count -eq 1 -and @(Get-ReadyWorkFiles outbox Cancellation).Count -eq 1) 'receipt and cancellation work retained independently'
$script:TestTick+=2001
Assert (@(Get-ReadyWorkFiles outbox Sender).Count -eq 0) 'accepted send cannot reenter sender queue'
Write-State (Get-StatePath outbox later) @{Status='pending';NextAttemptUtc=[datetime]::UtcNow.AddHours(1).ToString('o')}
$script:TestTick+=2001
Assert (@(Get-ReadyWorkFiles outbox Sender).Count -eq 0) 'future work not in current due list'
Write-State (Get-StatePath outbox later) @{Status='pending';NextAttemptUtc=[datetime]::UtcNow.AddMinutes(-1).ToString('o')}
$script:TestTick+=2001
Assert (@(Get-ReadyWorkFiles outbox Sender).Count -eq 1) 'changed due date picked up without restarting'
$before=$script:WorkHintReads;$script:TestTick+=31000
[void](Get-ReadyWorkFiles outbox Sender)
Assert ($script:WorkHintReads -gt $before) 'forced thirty-second refresh still reads durable records'
Assert ($script:WorkHints.Count -le 2048) 'metadata cache stays bounded after thousands of records'
$json=($script:WorkHints|ConvertTo-Json -Depth 8)+($script:ReadyWorkIndex|ConvertTo-Json -Depth 6)
Assert ($json -notmatch 'PRIVATE_TEST_CONTENT|PRIVATE_IMAGE|PRIVATE_RECEIPT') 'cache excludes decrypted content and receipts'
[IO.File]::WriteAllText((Get-StatePath outbox broken),'not encrypted')
$script:TestTick+=2001
Assert (@(Get-ReadyWorkFiles outbox Sender|Where-Object BaseName -eq 'broken').Count -eq 1) 'corrupt state is handed to worker for visible failure, not hidden'
for($i=0;$i -lt 4100;$i++){Write-State (Get-StatePath dispatch ('active'+$i)) @{Handled=$false}}
Assert (@(Get-ReadyWorkFiles dispatch Dispatch).Count -eq 4100 -and -not $script:ReadyWorkIndex.ContainsKey('Dispatch')) 'overflow falls back to complete enumeration without retaining unbounded candidates'
"RESULT: $script:Passed checks passed. Fixture: $root"
