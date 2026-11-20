# Process/runspace lifecycle. No credentials or message data in host membership.
function Get-ExecutionMode {
    $mode=[string](Get-Option $script:Settings.Runtime 'ExecutionMode' 'MultiProcess')
    if($mode -notin @('MultiProcess','SharedHost')){throw 'InvalidExecutionMode'}
    return $mode
}
function Start-HostedRole([string]$Entry,[string]$Config,[string]$WorkerRole,[string]$HostId) {
    $id=[guid]::NewGuid().ToString('N')
    $control=[hashtable]::Synchronized(@{Stop=$false;LastProgress=(Get-PerformanceTick)})
    $runspace=[runspacefactory]::CreateRunspace()
    $runspace.ThreadOptions='ReuseThread';$runspace.ApartmentState='MTA';$runspace.Open()
    $pipeline=[powershell]::Create();$pipeline.Runspace=$runspace
    [void]$pipeline.AddCommand($Entry).AddParameter('ConfigPath',$Config).AddParameter('Role',$WorkerRole).AddParameter('HostInstanceId',$HostId).AddParameter('WorkerInstanceId',$id).AddParameter('WorkerControl',$control)
    try {$async=$pipeline.BeginInvoke()}
    catch {$pipeline.Dispose();$runspace.Dispose();throw}
    return [pscustomobject]@{Role=$WorkerRole;InstanceId=$id;Control=$control;Runspace=$runspace;Pipeline=$pipeline;Async=$async;StopRequestedTick=0L;State='running'}
}
function Close-HostedRole($Worker) {
    # EndInvoke/Dispose only AFTER completion. Never abort an HTTP/state commit.
    if(-not $Worker.Async.IsCompleted){throw 'WorkerStillRunning'}
    try {[void]$Worker.Pipeline.EndInvoke($Worker.Async)}catch{}
    $Worker.Pipeline.Dispose();$Worker.Runspace.Dispose()
}
function Invoke-SharedWorkerHost([string]$ConfigPath,[string]$HostId) {
    $entry=Join-Path $PSScriptRoot 'Start-LineDutyNotifier.ps1'
    $roles=@('Classifier','Sender','Receipts');if(Test-TeamEnabled){$roles+=@('Scheduler')}
    $workers=@{};$lastHealth=0L;$nextStart=@{}
    try {
        while(-not (Test-NotifierPaused)){
            $now=Get-PerformanceTick
            foreach($role in $roles){
                $w=$workers[$role]
                if($w -and $w.Async.IsCompleted){
                    Close-HostedRole $w;$workers.Remove($role);$w=$null
                    $nextStart[$role]=$now+5000
                    Write-Audit 'HOST_ROLE_EXITED' '' ('role='+$role)
                }
                if(-not $w -and $now -ge [long]$nextStart[$role]){
                    $workers[$role]=Start-HostedRole $entry $ConfigPath $role $HostId
                    Write-Audit 'HOST_ROLE_STARTED' '' ('role='+$role)
                    continue
                }
                if($w){
                    if(($now-[long]$w.Control.LastProgress) -gt 120000 -and -not $w.Control.Stop){
                        $w.Control.Stop=$true;$w.StopRequestedTick=$now;$w.State='stopping'
                        Write-Audit 'HOST_ROLE_STALE' '' ('role='+$role)
                    }
                    if($w.StopRequestedTick -and ($now-$w.StopRequestedTick) -gt 90000){$w.State='blocked'}
                    # Error streams are diagnostic only and must not grow for days.
                    $w.Pipeline.Streams.Error.Clear();$w.Pipeline.Streams.Warning.Clear();$w.Pipeline.Streams.Verbose.Clear();$w.Pipeline.Streams.Debug.Clear();$w.Pipeline.Streams.Progress.Clear();$w.Pipeline.Streams.Information.Clear()
                }
            }
            if(($now-$lastHealth) -ge 5000){
                Write-State (Get-StatePath 'health' 'Host') ([pscustomobject]@{Role='Host';Pid=$PID;HostInstanceId=$HostId;HeartbeatUtc=(Get-UtcStamp);ControlProtocol=1;Roles=@($workers.Values|ForEach-Object {[pscustomobject]@{Role=$_.Role;WorkerInstanceId=$_.InstanceId;State=$_.State}})})
                $lastHealth=$now
            }
            Start-Sleep -Milliseconds 250
        }
    } finally {
        foreach($w in @($workers.Values)){$w.Control.Stop=$true}
        # Stay visible to safe-stop/transfer until every in-flight worker exits.
        while($workers.Count){
            foreach($role in @($workers.Keys)){if($workers[$role].Async.IsCompleted){Close-HostedRole $workers[$role];$workers.Remove($role)}}
            if($workers.Count){Start-Sleep -Milliseconds 250}
        }
    }
}
