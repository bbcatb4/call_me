# Performance hints never replace durable state. No message/key/receipt is cached here.
function Get-PerformanceTick {return [long]([Diagnostics.Stopwatch]::GetTimestamp()*1000.0/[Diagnostics.Stopwatch]::Frequency)}
function Initialize-Performance {
    $script:WorkHints=@{};$script:WorkHintHits=0L;$script:WorkHintReads=0L
    $script:DatabaseSignature='';$script:DatabaseScanTick=-1L
    $script:DatabaseScans=0L;$script:DatabaseSkips=0L
    $script:PerfTick=0L;$script:PerfCpu=0.0;$script:Performance=$null
    $script:PauseCheckAfter=0L;$script:PauseCached=$false
    $script:ReadyWorkIndex=@{};$script:WorkIndexScans=0L
}
function Get-ReadyWorkFiles([string]$Folder,[string]$Worker) {
    # Direct calls/tests remain eager. Only background workers enable the index.
    if(-not $script:UseWorkIndex){return Get-ChildItem (Join-Path $script:StateRoot $Folder) -Filter '*.dat' -File}
    $now=Get-PerformanceTick;$cached=$script:ReadyWorkIndex[$Worker]
    if($cached -and $now -lt $cached.NextScan){return $cached.Files}
    $script:WorkIndexScans++
    $ready=@(foreach($file in Get-ChildItem (Join-Path $script:StateRoot $Folder) -Filter '*.dat' -File){
        $hintPath=if($Worker -eq 'Classifier'){Get-StatePath 'processed' $file.BaseName}else{$file.FullName}
        try {if(-not [IO.File]::Exists($hintPath) -or -not (Test-WorkDeferred $hintPath $Worker)){$file}}
        catch {$file} # Let the worker report/retry a corrupt record; never hide it.
    })
    # Never retain unbounded pending queues; fall back to eager scans on overflow.
    if($ready.Count -le 4096){$script:ReadyWorkIndex[$Worker]=@{NextScan=$now+2000;Files=$ready}}
    else{$script:ReadyWorkIndex.Remove($Worker)}
    return $ready
}
function Get-WorkHint([string]$Path) {
    $file=[IO.FileInfo]::new($Path)
    if(-not $file.Exists){throw 'StateFileMissing'}
    $stamp=[string]$file.Length+':'+$file.LastWriteTimeUtc.Ticks+':'+$file.CreationTimeUtc.Ticks
    $now=Get-PerformanceTick;$old=$script:WorkHints[$Path]
    if($old -and $old.Stamp -eq $stamp -and ($now-$old.Tick) -lt 30000){$script:WorkHintHits++;return $old.Hint}
    $value=Read-State $Path;$script:WorkHintReads++
    $hint=[pscustomobject]@{Status=[string]$value.Status;Kind=[string]$value.Kind;Handled=[bool]$value.Handled;HasReceipt=[bool]$value.Receipt;CancelRequested=[bool]$value.CancelRequested;NextAttemptUtc=[string]$value.NextAttemptUtc;NextReceiptUtc=[string]$value.NextReceiptUtc;NextCancelUtc=[string]$value.NextCancelUtc}
    # Bounded metadata only. Re-read periodically even if timestamp/size were preserved.
    if($script:WorkHints.Count -ge 2048){$script:WorkHints.Clear()}
    $script:WorkHints[$Path]=[pscustomobject]@{Stamp=$stamp;Tick=$now;Hint=$hint}
    return $hint
}
function Test-WorkDeferred([string]$Path,[string]$Worker) {
    $h=Get-WorkHint $Path;$due=''
    switch($Worker){
        'Classifier'{if($h.Status -eq 'done'){return $true};$due=$h.NextAttemptUtc}
        'Sender'{if($h.Status -ne 'pending'){return $true};$due=$h.NextAttemptUtc}
        'Receipts'{if($h.Status -ne 'accepted' -or -not $h.HasReceipt){return $true};$due=$h.NextReceiptUtc}
        'Cancellation'{if(-not $h.CancelRequested -or -not $h.HasReceipt -or $h.Status -eq 'cancelled'){return $true};$due=$h.NextCancelUtc}
        'Dispatch'{return $h.Handled}
        'Schedule'{return $h.Status -eq 'completed'}
    }
    if($due){return ([datetime]$due).ToUniversalTime() -gt [datetime]::UtcNow}
    return $false
}
function Get-DatabaseProbeSignature([string]$Database,[string]$Sqlite) {
    if(-not [IO.File]::Exists($Database) -or -not [IO.File]::Exists($Sqlite)){throw 'DatabaseOrSqliteMissing'}
    $parts=foreach($path in @($Database,($Database+'-wal'))){
        if(-not [IO.File]::Exists($path)){'absent';continue}
        $file=[IO.FileInfo]::new($path)
        # Read only header/tail bytes. WAL timestamps can stay unchanged while LINE holds it open.
        $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try {
            $length=$stream.Length;$head=New-Object byte[] 64;$tail=New-Object byte[] 64
            $hc=$stream.Read($head,0,64);[void]$stream.Seek([Math]::Max(0,$length-64),[IO.SeekOrigin]::Begin);$tc=$stream.Read($tail,0,64)
            # Hash fragments so plaintext notification fragments are never retained in a signature.
            $hash=Get-EventHash (([Convert]::ToBase64String($head))+([Convert]::ToBase64String($tail)))
            "$length|$($file.LastWriteTimeUtc.Ticks)|$($file.CreationTimeUtc.Ticks)|$hc|$tc|$hash"
        } finally {$stream.Dispose()}
    }
    return $parts -join ';'
}
function Test-DatabaseScanRequired([string]$Signature) {
    return $script:DatabaseScanTick -lt 0 -or $script:DatabaseSignature -ne $Signature -or ((Get-PerformanceTick)-$script:DatabaseScanTick) -ge 30000
}
function Complete-DatabaseScan([string]$Signature) {
    $script:DatabaseSignature=$Signature;$script:DatabaseScanTick=Get-PerformanceTick;$script:DatabaseScans++
}
function Write-PerformanceSample([string]$Worker) {
    $now=Get-PerformanceTick;$p=[Diagnostics.Process]::GetCurrentProcess()
    try {
        $cpu=$p.TotalProcessorTime.TotalSeconds;$percent=$null
        if($script:PerfTick -gt 0 -and $now -gt $script:PerfTick){$percent=[Math]::Round(100*($cpu-$script:PerfCpu)/(($now-$script:PerfTick)/1000)/[Environment]::ProcessorCount,3)}
        $script:Performance=[pscustomobject]@{Utc=(Get-UtcStamp);Role=$Worker;Pid=$PID;CPUPercent=$percent;WorkingSetMB=[Math]::Round($p.WorkingSet64/1MB,2);PrivateMB=[Math]::Round($p.PrivateMemorySize64/1MB,2);Handles=$p.HandleCount;Threads=$p.Threads.Count;DatabaseScans=$script:DatabaseScans;DatabaseSkips=$script:DatabaseSkips;HintReads=$script:WorkHintReads;HintHits=$script:WorkHintHits;HintEntries=$script:WorkHints.Count}
        $script:PerfTick=$now;$script:PerfCpu=$cpu
        $path=Join-Path $script:LogDirectory ('performance-'+(Get-Date -Format 'yyyy-MM-dd')+'-'+$Worker+'.jsonl')
        Add-Content -LiteralPath $path -Value ($script:Performance|ConvertTo-Json -Compress) -Encoding UTF8 -ErrorAction Stop
        # Delete only this feature's own per-role samples older than seven calendar days.
        foreach($file in Get-ChildItem -LiteralPath $script:LogDirectory -Filter ('performance-*-'+$Worker+'.jsonl') -File){
            if($file.Name -match ('^performance-(\d{4}-\d{2}-\d{2})-'+[regex]::Escape($Worker)+'\.jsonl$') -and [datetime]::ParseExact($Matches[1],'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture) -lt (Get-Date).Date.AddDays(-6)){
                [IO.File]::Delete($file.FullName)
            }
        }
    }finally{$p.Dispose()}
}
