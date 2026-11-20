# Encrypted team model, persistent dispatch and scheduling. Windows PowerShell 5.1.
. (Join-Path $PSScriptRoot 'Team.Roster.ps1')
function Invoke-TeamLock([scriptblock]$Action) {
    $lock=New-Object Threading.Mutex($false,('Local\LineDutyTeam-'+(Get-EventHash $script:StateRoot).Substring(0,20)))
    $owned=$false
    try {
        try {$owned=$lock.WaitOne(30000)} catch [Threading.AbandonedMutexException] {$owned=$true}
        if(-not $owned){throw 'TeamBusy'}
        & $Action
    } finally {if($owned){$lock.ReleaseMutex()};$lock.Dispose()}
}
function Get-TeamModel {return Read-State (Get-StatePath 'team' 'model')}
function Test-TeamEnabled {return Test-Path -LiteralPath (Get-StatePath 'team' 'model')}
function Get-NotificationRoutingMode {return Get-Option $script:Settings.NotificationRouting 'Mode' 'OwnerOnly'}
function Test-RosterEnabled {return (Get-NotificationRoutingMode) -eq 'Roster'}
function Assert-RosterEnabled {if(-not (Test-RosterEnabled)){throw '班表功能已停用，目前不使用班表分派。'}}
function Enable-Team {
    Invoke-TeamLock {
        if(Test-TeamEnabled){return}
        $person=[pscustomobject]@{Id='owner';Name='我（管理者）';Aliases=@();Enabled=$true;IsAdmin=$true;AlwaysOnDuty=$true;LeadMinutes=60;UserKey='';KeyEnvironment=[string]$script:Settings.Pushover.UserKeyEnvironmentVariable}
        $model=[pscustomobject]@{Version=1;RosterVersion=0;ActivatedUtc=(Get-UtcStamp);People=@($person);Shifts=@();LegacyRecipientKey=(Get-UserSecret $script:Settings.Pushover.UserKeyEnvironmentVariable);LegacyIds=@(Get-ChildItem (Join-Path $script:StateRoot 'inbox') -Filter '*.dat'|ForEach-Object BaseName)}
        Write-State (Get-StatePath 'team' 'model') $model
    }
}
function Test-TeamEvent($Event) {
    if(-not (Test-TeamEnabled)){return $false}
    $model=Get-TeamModel
    return $Event.Id -notin @($model.LegacyIds)
}
function Save-TeamModel($Model,[int]$ExpectedVersion) {
    Assert-NotifierEditable
    Invoke-TeamLock {
        $old=Get-TeamModel
        if($old.Version -ne $ExpectedVersion){throw '資料已更新，請重新整理後再儲存。'}
        $Model.Version=$old.Version+1
        Write-State (Get-StatePath 'team' ('history-'+$old.Version)) $old
        Write-State (Get-StatePath 'team' 'model') $Model
    }
}
function Save-TeamPerson($Person,[int]$ExpectedVersion) {
    Invoke-TeamLock {
        $model=Get-TeamModel
        if(-not $Person.Id){$Person.Id=[guid]::NewGuid().ToString('N')}
        if((Get-NotificationRoutingMode) -eq 'OwnerOnly' -and $Person.Id -eq 'owner' -and -not $Person.Enabled){throw '直接通知模式不能停用原收件人。'}
        if($Person.Id -notmatch '^[a-zA-Z0-9_-]+$' -or -not $Person.Name.Trim()){throw '請填寫姓名。'}
        if([int]$Person.LeadMinutes -lt 0 -or [int]$Person.LeadMinutes -gt 1440){throw '提前量必須為 0 至 1440 分鐘。'}
        $prior=@($model.People|Where-Object Id -eq $Person.Id)
        if(-not $Person.UserKey -and $prior.Count){$Person.UserKey=$prior[0].UserKey;$Person.KeyEnvironment=$prior[0].KeyEnvironment}
        if($Person.UserKey -and $Person.UserKey -notmatch '^[a-zA-Z0-9]{30}$'){throw 'Pushover 收件資料格式錯誤。'}
        if($Person.Enabled -and -not ($Person.UserKey -or $Person.KeyEnvironment)){throw '請先設定 Pushover 收件資料。'}
        $others=@($model.People|Where-Object Id -ne $Person.Id)
        foreach($other in $others){
            if($Person.UserKey -and $Person.UserKey -eq (Get-TeamRecipientKey $other.Id)){throw '此 Pushover 收件人已登錄，請修改原有人員。'}
            foreach($alias in @($Person.Name)+@($Person.Aliases)){
                if($alias -and $alias -in (@($other.Name)+@($other.Aliases))){throw '姓名或別名已被其他人使用。'}
            }
        }
        $model.People=@($others)+@($Person)
        if(-not @($model.People|Where-Object {$_.Enabled -and $_.IsAdmin}).Count){throw '至少需要一位啟用的管理者。'}
        Save-TeamModel $model $ExpectedVersion
    }
}
function Get-TeamRecipientKey([string]$Id) {
    $p=@((Get-TeamModel).People|Where-Object Id -eq $Id)
    if($p.Count -ne 1){throw 'RecipientMissing'}
    if($p[0].UserKey){return [string]$p[0].UserKey}
    return Get-UserSecret ([string]$p[0].KeyEnvironment)
}
function Convert-TaipeiUtc([string]$Value) {
    $d=[datetime]::ParseExact($Value,'yyyy-MM-dd HH:mm',[Globalization.CultureInfo]::InvariantCulture)
    return [TimeZoneInfo]::ConvertTimeToUtc([datetime]::SpecifyKind($d,[DateTimeKind]::Unspecified),[TimeZoneInfo]::FindSystemTimeZoneById('Taipei Standard Time'))
}
function Format-Taipei($Utc) {
    if(-not $Utc){return ''}
    return [TimeZoneInfo]::ConvertTimeFromUtc(([datetime]$Utc).ToUniversalTime(),[TimeZoneInfo]::FindSystemTimeZoneById('Taipei Standard Time')).ToString('yyyy-MM-dd HH:mm')
}
function Get-TeamRecipients($Model,[datetime]$At,[switch]$Fallback) {
    $ids=@($Model.Shifts|Where-Object {$At.ToUniversalTime() -ge ([datetime]$_.StartUtc).ToUniversalTime() -and $At.ToUniversalTime() -lt ([datetime]$_.EndUtc).ToUniversalTime()}|ForEach-Object PersonId)
    return @($Model.People|Where-Object {$_.Enabled -and ($_.AlwaysOnDuty -or $_.Id -in $ids -or ($Fallback -and $_.IsAdmin))}|Sort-Object Id -Unique)
}
function Get-ChineseHour([string]$Word) {
    if($Word -match '^\d+$'){return [int]$Word}
    $digits=@{'零'=0;'一'=1;'二'=2;'兩'=2;'三'=3;'四'=4;'五'=5;'六'=6;'七'=7;'八'=8;'九'=9}
    if($digits.ContainsKey($Word)){return $digits[$Word]}
    if($Word -match '^([一二]?)十([一二三四五六七八九]?)$'){
        $ten=if($Matches[1]){$digits[$Matches[1]]}else{1};$unit=if($Matches[2]){$digits[$Matches[2]]}else{0};return $ten*10+$unit
    }
    return -1
}
function Resolve-DutyMoment([string]$Text,[string]$ArrivalUtc,$Assessment=$null) {
    $t=$Text.Normalize([Text.NormalizationForm]::FormKC).Trim()
    $result=[pscustomobject]@{WhenUtc='';Immediate=$false;Reason='time_unclear'}
    if($t -match '^(出勤|出門)[！!。]*$|(?:請|立刻|馬上|現在).*(?:出勤|出門)' -and $t -notmatch '\d|明天|後天|明早|[一二三四五六七八九十]點'){$result.Immediate=$true;$result.Reason='direct';return $result}
    $day=[datetime]::ParseExact((Format-Taipei $ArrivalUtc),'yyyy-MM-dd HH:mm',[Globalization.CultureInfo]::InvariantCulture).Date
    try {
        if($t -match '(?:(\d{4})[/-])?(\d{1,2})[/-](\d{1,2})'){
            $year=if($Matches[1]){[int]$Matches[1]}else{$day.Year}
            $newDay=[datetime]::new($year,[int]$Matches[2],[int]$Matches[3]);if(-not $Matches[1] -and ($day-$newDay).TotalDays -gt 180){$newDay=$newDay.AddYears(1)};$day=$newDay
        }elseif($t -match '後天'){$day=$day.AddDays(2)}elseif($t -match '明天|明早|明晚'){$day=$day.AddDays(1)}
        elseif($t -match '(下)?(?:週|星期|禮拜)([一二三四五六日天])'){
            $week=@{'日'=0;'天'=0;'一'=1;'二'=2;'三'=3;'四'=4;'五'=5;'六'=6};$offset=($week[$Matches[2]]-[int]$day.DayOfWeek+7)%7
            if($Matches[1]){$offset+=7};$day=$day.AddDays($offset)
        }
        $hour=-1;$minute=0
        if($t -match '(?<!\d)([01]?\d|2[0-3]):([0-5]\d)(?!\d)'){$hour=[int]$Matches[1];$minute=[int]$Matches[2]}
        elseif($t -match '(?<![\d/])([01]\d|2[0-3])([0-5]\d)(?=接|入鍋|到院|開刀)'){$hour=[int]$Matches[1];$minute=[int]$Matches[2]}
        elseif($t -match '([\d一二三四五六七八九十兩]+)[點時](半|\d{1,2}分?)?'){
            $hour=Get-ChineseHour $Matches[1];$minute=if($Matches[2] -eq '半'){30}elseif($Matches[2]){[int]($Matches[2] -replace '分','')}else{0}
        }
        if($hour -ge 0){
            if($t -match '下午|晚上|明晚' -and $hour -lt 12){$hour+=12}
            if($t -match '凌晨|上午|早上|明早' -and $hour -eq 12){$hour=0}
            if($hour -gt 23 -or $minute -gt 59){return $result}
            # Bare 1-11 o'clock has two plausible halves of a day.
            if($hour -in 1..11 -and $t -notmatch '早|上午|凌晨|下午|晚上|明晚|\d:\d|(?<!\d)0\d[0-5]\d'){return $result}
            $result.WhenUtc=(Convert-TaipeiUtc ($day.ToString('yyyy-MM-dd')+(' {0:00}:{1:00}' -f $hour,$minute))).ToString('o');$result.Reason='exact';return $result
        }
        # Structured AI date/time may resolve a short contextual answer, never a vague period.
        if($Assessment -and $t -notmatch '中午|早上|下午|晚上|凌晨' -and $Assessment.date -match '^\d{4}-\d{2}-\d{2}$' -and $Assessment.time -match '^([01]\d|2[0-3]):[0-5]\d$'){
            $result.WhenUtc=(Convert-TaipeiUtc ($Assessment.date+' '+$Assessment.time)).ToString('o');$result.Reason='ai_exact'
        }
    }catch {$result.WhenUtc='';$result.Reason='time_invalid'}
    return $result
}
function Add-TeamRequest($Event,[string]$Kind,[string]$Reason,$Assessment) {
    if($Event.Body -match '取消|停刀|改期|改到|改成|改為'){$Kind='Change';$Assessment=$null}
    $id=Get-EventHash ($Event.Id+'|'+$Kind+'|'+($Assessment|ConvertTo-Json -Compress))
    $request=[pscustomobject]@{Id=$id;Event=$Event;Kind=$Kind;Reason=$Reason;Assessment=$Assessment;CreatedUtc=(Get-UtcStamp);Handled=$false}
    [void](Write-State (Get-StatePath 'dispatch' $id) $request -CreateOnly)
}
function New-TeamDelivery($Schedule,$Person,[string]$Stage,[string]$Kind,[string]$Message,[datetime]$Due,[int]$Revision=0,[string]$DeliveryReason='') {
    if(-not $Revision){$Revision=[int]$Schedule.Version}
    $route=@($Schedule.Routing|Where-Object PersonId -eq $Person.Id);$epoch=if($route.Count -and $Stage -in @('notice','urgent','review')){$route[0].Epoch}else{0}
    $id=Get-EventHash ($Schedule.Id+'|'+$Revision+'|'+$Person.Id+'|'+$Stage+'|'+$epoch)
    $alert=[pscustomobject]@{Id=$id;EventId=$Schedule.EventId;ScheduleId=$Schedule.Id;ScheduleVersion=$Revision;RouteEpoch=$epoch;RecipientId=$Person.Id;Stage=$Stage;Kind=$Kind;Message=$Message;Title='接刀排程提醒';ArrivalUtc='';Status='pending';Attempts=0;NextAttemptUtc=$Due.ToString('o');DueUtc=$Due.ToString('o');Receipt='';NextReceiptUtc='';LastError='';CreatedUtc=(Get-UtcStamp);AcceptedUtc='';AcknowledgedUtc='';CancelRequested=$false}
    $alert|Add-Member NoteProperty DeliveryReason $DeliveryReason
    $alert.Title=(Get-NotificationPresentation $alert).Title
    $path=Get-StatePath 'outbox' $id
    if(Test-Path $path){
        $old=Read-State $path
        # Refresh only unsent work, preserving identity, receipts and accepted history.
        if($old.Status -eq 'pending' -and $old.Attempts -eq 0){
            $changed=$false
            if($old.Message -ne $Message){$old.Message=$Message;$changed=$true}
            if($old.Title -ne $alert.Title){$old.Title=$alert.Title;$changed=$true}
            if($old.DeliveryReason -ne $DeliveryReason){$old|Add-Member NoteProperty DeliveryReason $DeliveryReason -Force;$changed=$true}
            if($Stage -eq 'urgent' -and $Schedule.WhenUtc -and ([datetime]$old.DueUtc).ToUniversalTime() -ne $Due.ToUniversalTime()){$old.DueUtc=$Due.ToString('o');$old.NextAttemptUtc=$Due.ToString('o');$changed=$true}
            if($changed){Write-State $path $old}
        }
        return
    }
    [void](Write-State $path $alert -CreateOnly)
}
function Request-TeamCancellation($Alert) {
    if($Alert.Status -eq 'accepted' -and $Alert.Receipt){$Alert.CancelRequested=$true}
    else{$Alert.Status='cancelled'}
    Write-State (Get-StatePath 'outbox' $Alert.Id) $Alert
}
function Set-TeamSchedule([string]$Id,[string]$WhenUtc,[switch]$Cancel,[int]$ExpectedVersion,[string]$RequestId='') {
    Assert-NotifierEditable
    Invoke-TeamLock {
        $path=Get-StatePath 'schedules' $Id;$s=Read-State $path
        if($s.Version -ne $ExpectedVersion){throw '排程已更新，請重新整理。'}
        if($WhenUtc){[void](Format-Taipei $WhenUtc)}elseif(-not $Cancel){throw '請填寫精確接刀時間。'}
        $s.Version++;$s.WhenUtc=$WhenUtc;$s.Status=if($Cancel){'cancelled'}else{'active'};$s.Kind='Confirmed';$s.Reason=if($Cancel){'cancelled'}else{'manual_exact'}
        if($RequestId){$s.HandledRequestIds=@($s.HandledRequestIds)+@($RequestId)}
        Write-State $path $s
    }
}
function Update-TeamRequest($Request) {
    $e=$Request.Event;$path=Get-StatePath 'schedules' $e.Id
    if(Test-Path $path){if($Request.Id -in @((Read-State $path).HandledRequestIds)){return}}
    $moment=Resolve-DutyMoment $e.Body $e.ArrivalUtc $Request.Assessment
    $change=$Request.Kind -eq 'Change' -or $e.Body -match '取消|停刀|改期|改到|改成|改為'
    if($change){
        $allPlans=@(Get-ChildItem (Join-Path $script:StateRoot 'schedules') -Filter '*.dat'|ForEach-Object {Read-State $_.FullName})
        if(@($allPlans|Where-Object {$Request.Id -in @($_.HandledRequestIds)}).Count){return}
        $pieces=[regex]::Split($e.Body,'改到|改成|改為|改期至',2)
        $oldMoment=Resolve-DutyMoment $pieces[0] $e.ArrivalUtc
        $candidates=@($allPlans|Where-Object {$_.Id -ne $e.Id -and $_.Group -eq $e.Group -and $_.Status -eq 'active' -and $oldMoment.WhenUtc -and $_.WhenUtc -eq $oldMoment.WhenUtc})
        if($e.Body -match '可能|是否|要不要|不用取消|不要取消|不取消|[?？]|取消嗎'){$candidates=@()}
        if($candidates.Count -eq 1){
            $target=$candidates[0]
            if($e.Body -match '取消|停刀'){Set-TeamSchedule $target.Id '' -Cancel -ExpectedVersion $target.Version -RequestId $Request.Id;return}
            if($pieces.Count -eq 2){
                $newMoment=Resolve-DutyMoment $pieces[1] $target.WhenUtc
                if($newMoment.WhenUtc){Set-TeamSchedule $target.Id $newMoment.WhenUtc -ExpectedVersion $target.Version -RequestId $Request.Id;return}
            }
        }
    }
    if(Test-Path $path){
        $s=Read-State $path
        if($s.Kind -eq 'Confirmed' -and $Request.Kind -ne 'Confirmed'){return}
        if($s.Kind -eq 'Confirmed' -and ($s.WhenUtc -or -not $moment.WhenUtc)){return}
        $s.Version++;$s.Kind=$Request.Kind;$s.WhenUtc=$moment.WhenUtc;$s.Reason=$moment.Reason;$s.Status='active'
    }else{
        $s=[pscustomobject]@{Id=$e.Id;EventId=$e.Id;Version=1;Group=$e.Group;Kind=$Request.Kind;WhenUtc=$moment.WhenUtc;Immediate=$moment.Immediate;Status='active';Reason=$moment.Reason;ArrivalUtc=$e.ArrivalUtc;CreatedUtc=$Request.CreatedUtc;Body=$e.Body;HandledRequestIds=@()}
    }
    if($change){$s.Status='change_review';$s.Reason='change_ambiguous';$s.Kind='Review';$s.WhenUtc=''}
    $s.HandledRequestIds=@($s.HandledRequestIds)+@($Request.Id)
    Write-State $path $s
}
function Resolve-TeamChange([string]$ChangeId,[string]$TargetId,[string]$WhenUtc,[switch]$Cancel,[int]$ExpectedVersion) {
    Invoke-TeamLock {
        if(-not $TargetId -or $ChangeId -eq $TargetId){throw '請選擇要異動的原排程。'}
        $change=Read-State (Get-StatePath 'schedules' $ChangeId)
        if($change.Status -ne 'change_review'){throw '此異動已處理，請重新整理。'}
        $target=Read-State (Get-StatePath 'schedules' $TargetId)
        if(('manual-'+$ChangeId) -notin @($target.HandledRequestIds)){Set-TeamSchedule $TargetId $WhenUtc -Cancel:$Cancel -ExpectedVersion $ExpectedVersion -RequestId ('manual-'+$ChangeId)}
        $change.Status='completed';Write-State (Get-StatePath 'schedules' $ChangeId) $change
    }
}
function Get-TeamScheduleRoutes($Schedule,$Model,[datetime]$Now) {
    $s=$Schedule;$fallback=-not $s.WhenUtc;$routingNow=([datetime]$s.CreatedUtc).ToUniversalTime();$at=$routingNow
    if($s.WhenUtc){$at=([datetime]$s.WhenUtc).ToUniversalTime()}
    $mode=Get-NotificationRoutingMode;$rosterEnabled=$mode -eq 'Roster'
    if($rosterEnabled){
    $people=@(Get-TeamRecipients $Model $at)
    # Always-on owner is not evidence that the roster covers the requested date.
    $covered=@($Model.Shifts|Where-Object {$at -ge ([datetime]$_.StartUtc).ToUniversalTime() -and $at -lt ([datetime]$_.EndUtc).ToUniversalTime()}).Count -gt 0
    if(-not $covered){$fallback=$true}
    if($fallback){$people=@($people)+@(Get-TeamRecipients $Model $routingNow -Fallback)}
    }elseif($mode -eq 'AllEnabled'){
        $people=@($Model.People|Where-Object Enabled)
    }else{
        # Keep the stable original recipient, regardless of shifts or always-on toggles.
        $people=@($Model.People|Where-Object {$_.Id -eq 'owner' -and $_.Enabled})
        if($people.Count -ne 1){throw 'OwnerRecipientMissing'}
    }
    $overdue=($s.WhenUtc -and $at -lt $Now -and (([datetime]$s.CreatedUtc).ToUniversalTime() -gt $at -or $s.RecoveryOnly)) -or (-not $s.WhenUtc -and (([datetime]$s.CreatedUtc).ToUniversalTime()-([datetime]$s.ArrivalUtc).ToUniversalTime()).TotalMinutes -gt 10)
    if($overdue -and $mode -ne 'OwnerOnly'){$people=@($Model.People|Where-Object {$_.Enabled -and $_.IsAdmin})}
    $people=@($people|Sort-Object Id -Unique)
    foreach($p in $people){
        $due=$Now;$stage='urgent';$kind='Confirmed'
        if($s.Kind -ne 'Confirmed'){$stage='review';$kind='Review'}
        elseif($s.WhenUtc -and -not $overdue){$due=$at.AddMinutes(-[int]$p.LeadMinutes)}
        $reason=if($overdue){'overdue_admin'}elseif($mode -eq 'AllEnabled'){'all_enabled'}elseif(-not $rosterEnabled){'direct_owner'}elseif($fallback){'fallback'}elseif($p.AlwaysOnDuty){'always_on'}else{'roster'}
        [pscustomobject]@{Person=$p;Due=$due;Stage=$stage;Kind=$kind;Reason=$reason;Overdue=$overdue}
    }
}
function Get-TeamDeliveryMessage($Schedule,$Route) {
    $s=$Schedule
    $when=if($s.WhenUtc){Format-Taipei $s.WhenUtc}elseif($s.Immediate){'立即出勤'}else{'時間待補'}
    $msg="接刀排程：$when`n請查看 LINE 群組確認詳情。`n排程：$($s.Id.Substring(0,8))"
    if($s.Kind -eq 'Confirmed' -and -not $s.WhenUtc -and -not $s.Immediate){$msg="【已確認接刀需求，時間待補】`n"+$msg}
    # Missing roster coverage must never imply the surgery time is unknown.
    if($Route.Reason -eq 'fallback'){$msg="【備援收件通知】`n"+$msg}
    if($Route.Overdue){$msg="【已過接刀時間，請人工核對】`n"+$msg}
    if($s.Status -eq 'change_review'){$msg="【改期／取消無法對應，請在接刀排程管理核對】`n"+$msg}
    return $msg
}
function Invoke-TeamSchedulerPass {
    if(Test-NotifierPaused){return}
    if(-not (Test-TeamEnabled)){return}
    Invoke-TeamLock {
        $hadError=$false
        foreach($f in @(Get-ReadyWorkFiles 'dispatch' 'Dispatch'|Sort-Object LastWriteTimeUtc)){
            if(Test-NotifierPaused){break}
            try {if(Test-WorkDeferred $f.FullName 'Dispatch'){continue};$r=Read-State $f.FullName;if($r.Handled){continue};Update-TeamRequest $r;$r.Handled=$true;Write-State $f.FullName $r}
            catch {Write-Audit 'SCHEDULE_RETRY' $r.Id 'will_retry=true';$hadError=$true}
        }
        $model=Get-TeamModel;$now=[datetime]::UtcNow
        foreach($f in @(Get-ReadyWorkFiles 'schedules' 'Schedule')){
            if(Test-NotifierPaused){break}
            try {
            if(Test-WorkDeferred $f.FullName 'Schedule'){continue}
            $s=Read-State $f.FullName
            if($s.Status -eq 'completed'){continue}
            $oldAlerts=@(Get-ChildItem (Join-Path $script:StateRoot 'outbox') -Filter '*.dat'|ForEach-Object {Read-State $_.FullName}|Where-Object {$_.ScheduleId -eq $s.Id})
            if($s.WhenUtc -and ([datetime]$s.WhenUtc).ToUniversalTime() -lt $now.AddMinutes(-10) -and -not @($oldAlerts|Where-Object {$_.ScheduleVersion -eq $s.Version -and $_.Stage -eq 'urgent' -and $_.AcceptedUtc}).Count){
                $s|Add-Member NoteProperty RecoveryOnly $true -Force;Write-State $f.FullName $s
            }
            $routes=if($s.Status -eq 'cancelled'){@()}else{@(Get-TeamScheduleRoutes $s $model $now)}
            $ids=@($routes|ForEach-Object {$_.Person.Id})
            if(-not $s.PSObject.Properties['Routing']){$s|Add-Member NoteProperty Routing @()}
            $routingChanged=$false
            foreach($r in @($s.Routing)){
                $active=$r.PersonId -in $ids
                if($active -ne $r.Active){if($active){$r.Epoch++};$r.Active=$active;$routingChanged=$true}
            }
            foreach($id in $ids){if(-not @($s.Routing|Where-Object PersonId -eq $id).Count){$s.Routing+=@([pscustomobject]@{PersonId=$id;Epoch=1;Active=$true});$routingChanged=$true}}
            if($routingChanged){Write-State $f.FullName $s}
            foreach($old in $oldAlerts){
                if($old.Stage -eq 'changed' -or $old.Stage -like 'escalation-*'){
                    if($s.Status -eq 'cancelled' -and $old.Stage -like 'escalation-*'){Request-TeamCancellation $old}
                    continue
                }
                $epoch=@($s.Routing|Where-Object PersonId -eq $old.RecipientId)
                if($s.Status -eq 'cancelled' -or $old.ScheduleVersion -ne $s.Version -or $old.RecipientId -notin $ids -or ($epoch.Count -and $old.RouteEpoch -ne $epoch[0].Epoch)){
                    if($old.Status -eq 'cancelled' -or $old.CancelRequested){continue}
                    Request-TeamCancellation $old
                    $p=@($model.People|Where-Object {$_.Id -eq $old.RecipientId -and $_.Enabled})
                    if($p.Count -and ($old.AcceptedUtc -or $old.Attempts -gt 0)){
                        New-TeamDelivery $s $p[0] 'changed' 'Review' ('接刀排程或當班人員已變更，請核對群組。排程 '+$s.Id.Substring(0,8)) $now -Revision ($s.Version*100000+$model.Version)
                    }
                }
            }
            foreach($route in $routes){
                $p=$route.Person;$msg=Get-TeamDeliveryMessage $s $route
                if($route.Kind -eq 'Confirmed' -and $route.Due -gt $now){New-TeamDelivery $s $p 'notice' 'Review' $msg $now -DeliveryReason $route.Reason}
                New-TeamDelivery $s $p $route.Stage $route.Kind $msg $route.Due -DeliveryReason $route.Reason
            }
            foreach($old in $oldAlerts){
                if($old.Kind -eq 'Confirmed' -and $old.Status -in @('accepted','expired') -and -not $old.CancelRequested -and $old.ScheduleVersion -eq $s.Version -and $s.Status -ne 'cancelled' -and $old.AcceptedUtc -and ([datetime]$old.AcceptedUtc).ToUniversalTime() -le $now.AddMinutes(-5)){
                    $who=@($model.People|Where-Object Id -eq $old.RecipientId|ForEach-Object Name) -join ','
                    foreach($admin in @($model.People|Where-Object {$_.Enabled -and $(if((Get-NotificationRoutingMode) -eq 'OwnerOnly'){$_.Id -eq 'owner'}else{$_.IsAdmin})})){
                        New-TeamDelivery $s $admin ('escalation-'+$old.Id) 'Review' ("緊急通知超過 5 分鐘未確認：$who。請聯絡核對；排程 "+$s.Id.Substring(0,8)) $now
                    }
                }
            }
            $terminal=@($oldAlerts|Where-Object {$_.ScheduleVersion -eq $s.Version -and $_.Stage -in @('urgent','review') -and $_.Status -ne 'cancelled'})
            $unfinished=@($terminal|Where-Object {$_.Status -eq 'pending' -or ($_.Kind -eq 'Confirmed' -and $_.Status -eq 'accepted')})
            if($s.Status -eq 'active' -and $terminal.Count -and -not $unfinished.Count -and (-not $s.WhenUtc -or ([datetime]$s.WhenUtc).ToUniversalTime() -le $now)){$s.Status='completed';Write-State $f.FullName $s}
            }catch {Write-Audit 'SCHEDULE_RETRY' $f.BaseName 'will_retry=true';$hadError=$true}
        }
        if($hadError){throw 'SchedulePassIncomplete'}
    }
}
function Invoke-SenderPass {Invoke-TeamLock {Invoke-LegacySenderPass}}
function Invoke-CancelReceiptHttp([string]$Receipt) {
    return Invoke-RestMethod -Method Post -Uri ('https://api.pushover.net/1/receipts/'+[uri]::EscapeDataString($Receipt)+'/cancel.json') -Body @{token=(Get-UserSecret $script:Settings.Pushover.AppTokenEnvironmentVariable)} -TimeoutSec 10 -ErrorAction Stop
}
function Invoke-ReceiptPass {
    Invoke-TeamLock {
        if($script:Settings.Pushover.Enabled){
            $cancelDeadline=[datetime]::UtcNow.AddSeconds(5)
            foreach($f in @(Get-ReadyWorkFiles 'outbox' 'Cancellation')){
                if(Test-NotifierPaused){break}
                if([datetime]::UtcNow -gt $cancelDeadline){break}
                if(Test-WorkDeferred $f.FullName 'Cancellation'){continue}
                $a=Read-State $f.FullName
                if($a.CancelRequested -and $a.Receipt -and $a.Status -ne 'cancelled'){
                    if($a.NextCancelUtc -and ([datetime]$a.NextCancelUtc).ToUniversalTime() -gt [datetime]::UtcNow){continue}
                    $a|Add-Member NoteProperty NextCancelUtc ([datetime]::UtcNow.AddSeconds(30).ToString('o')) -Force;Write-State $f.FullName $a
                    try {if((Invoke-CancelReceiptHttp $a.Receipt).status -ne 1){throw 'CancelFailed'};$a.Status='cancelled';Write-State $f.FullName $a}
                    catch {Write-Audit 'CANCEL_RETRY' $a.EventId 'will_retry=true'}
                }
            }
        }
        Invoke-LegacyReceiptPass
    }
}
