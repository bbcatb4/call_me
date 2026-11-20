# Pure presentation of redacted status. No state reads or background actions.
function Get-DashboardRuntimeView($Snapshot) {
    $r=$Snapshot.Runtime;$workers=@($Snapshot.Workers)
    $mode=switch([string]$r.ExecutionMode){'SharedHost'{'低記憶體模式'};'MultiProcess'{'獨立程序模式'};default{'模式未確認'}}
    $count=if($r){[string]$r.ProcessCount}else{'—'}
    $complete=$r -and $r.MemoryAvailable -and $workers.Count -gt 0 -and @($workers|Where-Object {$_.Status -ne 'ok'}).Count -eq 0
    $memory=if($complete){('{0:N0} MB' -f $r.PrivateMB)}else{'—'}
    $names=@{Collector='Windows 收訊';Classifier='AI 判讀';Sender='推播';Receipts='確認追蹤';Scheduler='排程'}
    $parts=@(if($complete){foreach($p in @($r.Processes)){
        $name=if(@($p.Roles).Count -gt 1){'共用工作宿主'}else{$names[[string]$p.Roles[0]]}
        '{0}：{1:N0} MB' -f $name,$p.PrivateMB
    }})
    $detail=if($complete){($parts -join '　｜　')+'。不含儀表板與隔離測試程序；約每 30 秒取樣。'}else{'尚無完整、新鮮的工作狀態與記憶體資料，不以 0 取代缺失值。'}
    $expected=if($r.ExecutionMode -eq 'SharedHost'){2}else{$workers.Count}
    if($r -and $workers.Count -gt 0 -and $r.ProcessCount -ne $expected){$detail='設定與目前已核對的程序數不同，請查看下方工作狀態。 '+$detail}
    return [pscustomobject]@{Mode=$mode;ModeDetail=($workers.Count.ToString()+' 項工作，各自檢查心跳');Count=$count;Memory=$memory;Detail=$detail}
}
function Test-DashboardHistoryOnlyWarning($Snapshot) {
    $q=$Snapshot.Queue;$s=$Snapshot.Services
    return $Snapshot.Overall -eq 'warning' -and $Snapshot.QueueReadable -and $q.AiFailedCompleted -gt 0 -and $q.AiFailedPending -eq 0 -and $q.PushRetry -eq 0 -and $q.ExpiredLast24Hours -eq 0 -and $Snapshot.RecentErrorCount -eq 0 -and @($Snapshot.Issues).Count -eq 0 -and $Snapshot.Usage.Available -and $s.AiEnabled -and $s.AiKeyPresent -and $s.PushoverEnabled -and $s.PushoverKeysPresent -and @($Snapshot.Workers).Count -gt 0 -and @($Snapshot.Workers|Where-Object {$_.Status -ne 'ok'}).Count -eq 0
}
