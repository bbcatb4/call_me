# Synthetic examples of scheduling language. Default tests never call external services.
param([switch]$LiveAi)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Notifier.Core.ps1')
$testRoot=Join-Path (Join-Path $PSScriptRoot 'state') ('language-test-'+[guid]::NewGuid().ToString('N'))
$config=Join-Path $PSScriptRoot 'appsettings.json'
if(-not (Test-Path $config)){$config=Join-Path $PSScriptRoot 'appsettings.example.json'}
Initialize-Notifier $config $testRoot
$script:LogDirectory=$testRoot
$script:Passed=0;$script:Sequence=0;$script:Calls=@{};$script:Scenario=''
$script:NetworkCalls=0
function Assert($Condition,[string]$Name){if(-not $Condition){throw "FAIL: $Name"};$script:Passed++;Write-Output "PASS: $Name"}
function Invoke-PushHttp { $script:NetworkCalls++;throw 'TestMustNeverPush' }
function Invoke-ReceiptHttp { $script:NetworkCalls++;throw 'TestMustNeverPush' }
function Invoke-EventAi($Event,$Context){
    $script:Calls[$Event.Id]=@($Context)
    if($script:Scenario -eq 'ai_failure'){throw 'SimulatedTimeout'}
    # Only exercises routing and upgrade plumbing, not model accuracy.
    $reply=(Get-NormalizedMessage $Event.Body) -in @('可以謝謝大家','好,謝謝','8點','8:00','好的','好','可以','Yes','是','對')
    if($script:Scenario -eq 'ambiguous_reply'){$reply=$false}
    return [pscustomobject]@{status=$(if($reply){'confirmed'}else{'uncertain'});date='2026-08-03';time='08:00';image_readable=$false}
}
function Start-Scenario([string]$Name){$script:Scenario=$Name;$script:Settings.TargetGroupNames=@('test-'+$Name)}
function New-Message([string]$Body,[int]$AdvanceSeconds=1){
    $script:Sequence+=$AdvanceSeconds
    $xml='<toast launch="TextToast;ChatId='+$script:Scenario+';MessageId='+$script:Sequence+'"><visual><binding><text>test-'+$script:Scenario+'</text><text>'+[Security.SecurityElement]::Escape($Body)+'</text></binding></visual></toast>'
    $hex=([BitConverter]::ToString([Text.Encoding]::UTF8.GetBytes($xml))).Replace('-','')
    $stamp=[datetime]::Parse('2026-08-02T02:00:00Z').ToUniversalTime().AddSeconds($script:Sequence)
    return Convert-NotificationRow ([pscustomobject]@{payload_hex=$hex;sort_order=$script:Sequence;arrival_time=$stamp.ToFileTimeUtc();app_id='LINE_test'})
}
function Receive([string]$Body,[int]$AdvanceSeconds=1){
    $event=New-Message $Body $AdvanceSeconds
    [void](Save-IncomingEvent $event);Invoke-ClassifierPass
    return $event
}
function Has-Alert($Event,[string]$Kind){return Test-Path (Get-StatePath 'outbox' (Get-EventHash ($Event.Id+'|'+$Kind)))}
function Assert-Upgrade($Event,[string]$Name){
    Assert ($script:Calls.ContainsKey($Event.Id)) ($Name+': routed to AI')
    Assert (Has-Alert $Event 'Review') ($Name+': durable fallback')
    Assert (Has-Alert $Event 'Confirmed') ($Name+': mocked confirmation upgrades')
}
$localCases=@(
    @('算通勤時間1小時11:30接可嗎','Uncertain'),@('１１：３０ 接可嗎？','Uncertain'),
    @('明天早上加一台打AO plate','Uncertain'),@('加刀 ORIF','Uncertain'),
    @('請問 IVG. VP. 今天來得及嗎？','Uncertain'),@('打K-pin跟石膏','Uncertain'),
    @('打3支cannulated screw','Uncertain'),@('KPIN 石膏','Uncertain'),
    @('NPO時間到下午3點可接刀','Uncertain'),@('禁食滿六小時才可以接刀','Uncertain'),
    @('NPO時間夠了，請值班人員15:00到院接刀','Confirmed'),@('已確認下午3點接刀，NPO時間夠了','Confirmed'),
    @('明天 0800接','Confirmed'),@('明天中午接刀~~','Confirmed'),@('要開','Confirmed'),
    @('8點','None'),@('可以 謝謝大家','None'),@('好，謝謝','None'),
    @('手術室災害演練下午2點','None'),@('手術取消','Negative'),@('JAVA 開發會議','None'),
    @('急診刀','Uncertain'),@('A12d LA, 急診刀','Uncertain'),@('A12d LA','Uncertain'),
    @('A12d ＬＡ','Uncertain'),@('JAVA class','None'),@('SALAD','None'),
    @('是8點要接嗎','Uncertain'),@('0800接嗎','Uncertain'),@('八點接？','Uncertain'),
    @('８點要接刀嗎','Uncertain'),@('0800要接刀','Confirmed'),
    @('Yes','None'),@('是','None'),@('對','None'),@('還沒確定','None'))
foreach($case in $localCases){Assert ((Get-LocalDecision $case[0]).Level -eq $case[1]) ('local: '+$case[0])}

Start-Scenario 'split_0800'
$caseMessage=Receive 'A12d LA, 急診刀'
$question=Receive '是8點要接嗎'
foreach($candidate in @($caseMessage,$question)){
    Assert ($script:Calls.ContainsKey($candidate.Id) -and (Has-Alert $candidate 'Review') -and -not (Has-Alert $candidate 'Confirmed')) 'surgery description/question gets AI and fallback, not automatic confirmation'
}
$reply=Receive 'Yes'
Assert-Upgrade $reply 'split 0800 question plus Yes'
Assert ((@($script:Calls[$reply.Id].Body) -contains $caseMessage.Body) -and (@($script:Calls[$reply.Id].Body) -contains $question.Body)) 'AI receives surgery and time question together'
$later=Receive '好'
Assert (-not $script:Calls.ContainsKey($later.Id)) 'polite acknowledgement after Yes does not duplicate confirmation'

foreach($answer in @('是','對','yes')){
    Start-Scenario ('short_agreement_'+$answer)
    [void](Receive '0800接嗎')
    $reply=Receive $answer
    Assert-Upgrade $reply ('contextual agreement '+$answer)
}

Start-Scenario 'ambiguous_reply'
[void](Receive '急診刀，8點接嗎');[void](Receive '另一台手術9點接嗎')
$reply=Receive 'Yes'
Assert ($script:Calls.ContainsKey($reply.Id) -and (Has-Alert $reply 'Review') -and -not (Has-Alert $reply 'Confirmed')) 'ambiguous AI result remains review, never locally upgraded from Yes'

Start-Scenario 'no_replay_completed'
$old=New-Message '是8點要接嗎'
# Simulate the already-completed event produced by the old rules. Upgrading
# code must neither rewrite this decision nor reopen its durable job.
$old.Local=[pscustomobject]@{Level='None';Rule='unrelated';NeedsAi=$false}
[void](Write-State (Get-StatePath 'inbox' $old.Id) $old -CreateOnly)
Write-State (Get-StatePath 'processed' $old.Id) ([pscustomobject]@{Status='done';Attempts=0;NextAttemptUtc=(Get-UtcStamp);AiStatus='not_needed';ImageReadable=$false})
Assert (-not (Save-IncomingEvent $old)) 'rescanning old source does not replace stored decision'
Invoke-ClassifierPass
Assert (-not $script:Calls.ContainsKey($old.Id) -and -not (Has-Alert $old 'Review') -and -not (Has-Alert $old 'Confirmed')) 'completed old message is not replayed after rule update'

Start-Scenario 'proposal_with_interjection'
[void](Receive '有一個闌尾手術不知道方便幾點接？')
$proposal=Receive '算通勤時間1小時11:30接可嗎'
[void](Receive '是的。在急診，還沒有上排程。')
$reply=Receive '可以 謝謝大家'
Assert-Upgrade $reply 'time proposal plus spaced agreement'
Assert (@($script:Calls[$reply.Id].Body) -contains $proposal.Body) 'proposal survives intervening message'
$later=Receive '好'
Assert (-not $script:Calls.ContainsKey($later.Id)) 'polite reply after AI confirmation is not reopened'

Start-Scenario 'added_case_time_answer'
$addition=Receive '明天早上加一台打AO plate'
$question=Receive '請問幾點接刀？'
$reply=Receive '8點'
Assert-Upgrade $reply 'time-only answer'
Assert (@($script:Calls[$reply.Id].Body) -contains $addition.Body) 'added surgery retained in context'
Assert (@($script:Calls[$reply.Id].Body) -contains $question.Body) 'time question retained in context'

Start-Scenario 'eligibility_with_time_proposal'
[void](Receive '幾點可以接')
[void](Receive '禁食條件已符合，值班同仁需要準備時間，下午三點接可以嗎')
$reply=Receive '好，謝謝'
Assert-Upgrade $reply 'split surgery and time proposal'

Start-Scenario 'clock_format'
[void](Receive '請問幾點接刀？')
$reply=Receive '８：００'
Assert-Upgrade $reply 'fullwidth time-only answer'

Start-Scenario 'short_proposal'
[void](Receive '幾點可以接')
$short=Receive '三點可以嗎'
Assert ($script:Calls.ContainsKey($short.Id)) 'standalone time proposal inherits surgery context'
$reply=Receive '可以'
Assert-Upgrade $reply 'agreement after standalone proposal'

Start-Scenario 'ordinary'
[void](Receive '明天會議三點可以嗎')
foreach($body in @('好','收到','可以 謝謝大家','8點','Yes','是','對','還沒確定')){
    $reply=Receive $body
    Assert (-not $script:Calls.ContainsKey($reply.Id) -and -not (Has-Alert $reply 'Confirmed') -and -not (Has-Alert $reply 'Review')) ('ordinary reply stays quiet: '+$body)
}

Start-Scenario 'cancelled'
[void](Receive '下午3點接可以嗎？');[void](Receive '手術取消')
$reply=Receive '好的'
Assert (-not $script:Calls.ContainsKey($reply.Id)) 'cancelled discussion stays closed'
$reply=Receive 'Yes'
Assert (-not $script:Calls.ContainsKey($reply.Id) -and -not (Has-Alert $reply 'Review')) 'Yes after cancellation stays closed'

Start-Scenario 'confirmed'
[void](Receive '下午3點接可以嗎？');[void](Receive '請值班人員3點到院接刀')
$reply=Receive '好'
Assert (-not $script:Calls.ContainsKey($reply.Id)) 'explicitly confirmed discussion stays closed'
[void](Receive '下一台幾點接刀？')
$reply=Receive '8點'
Assert-Upgrade $reply 'new question after confirmed case opens new discussion'

Start-Scenario 'stale'
[void](Receive '下午3點接可以嗎？')
$reply=Receive '好' 1801
Assert (-not $script:Calls.ContainsKey($reply.Id)) 'reply beyond 30 minutes does not reuse proposal'

Start-Scenario 'other_group'
$reply=Receive '好'
Assert (-not $script:Calls.ContainsKey($reply.Id)) 'other group does not inherit pending proposal'

Start-Scenario 'eligibility'
$condition=Receive 'NPO時間到下午3點可接刀'
Assert ($script:Calls.ContainsKey($condition.Id) -and (Has-Alert $condition 'Review') -and -not (Has-Alert $condition 'Confirmed')) 'NPO eligibility is reviewed, not locally confirmed'
$reply=Receive '好'
Assert (-not $script:Calls.ContainsKey($reply.Id)) 'acknowledging NPO information alone does not confirm schedule'

Start-Scenario 'ai_failure'
[void](Receive '請問幾點接刀？')
$reply=Receive '8點'
$job=Read-State (Get-StatePath 'processed' $reply.Id)
Assert ((Has-Alert $reply 'Review') -and -not (Has-Alert $reply 'Confirmed') -and $job.Status -eq 'pending') 'AI failure on time answer retains fallback and retry'
[void](Receive '是8點要接嗎')
$reply=Receive 'Yes'
$job=Read-State (Get-StatePath 'processed' $reply.Id)
Assert ((Has-Alert $reply 'Review') -and -not (Has-Alert $reply 'Confirmed') -and $job.Status -eq 'pending') 'AI failure after Yes retains fallback and retry'

Start-Scenario 'context_order'
$past=New-Message '下午3點接可以嗎？';[void](Save-IncomingEvent $past)
$now=New-Message '好';[void](Save-IncomingEvent $now)
$future=New-Message '不用出勤';$future.ArrivalUtc=$now.ArrivalUtc;[void](Save-IncomingEvent $future)
$ctx=Get-EventContext $now
Assert (-not (@($ctx.Body) -contains $future.Body)) 'same timestamp higher source order excluded from context'
Assert (@($ctx.Body) -contains $past.Body) 'past proposal retained during batch recovery'

Start-Scenario 'stickers'
$past=Receive '下午3點接可以嗎？'
1..15|ForEach-Object {[void](Receive '貼圖')}
$reply=Receive '好'
Assert-Upgrade $reply 'sticker burst does not evict proposal'

Assert ($script:NetworkCalls -eq 0) 'no Pushover or receipt network calls'
Write-Output "MOCK RESULT: $script:Passed checks passed. State: $testRoot"
if($LiveAi){
    . (Join-Path $PSScriptRoot 'Notifier.Core.ps1')
    # Live tests use only these synthetic, de-identified cases. Never read or
    # transmit the private export or send Pushover. Preserve configured model.
    $script:Settings.Ai.Enabled=$true
    $scenarios=@(
        @{Name='proposal';Prior=@('有一台手術要接');Body='算通勤時間1小時11:30接可嗎';Expected='uncertain'},
        @{Name='agreement';Prior=@('有一台手術要接','算通勤時間1小時11:30接可嗎','是的。在急診，還沒有上排程。');Body='可以 謝謝大家';Expected='confirmed'},
        @{Name='time_answer';Prior=@('明天早上加一台打AO plate','請問幾點接刀？');Body='8點';Expected='confirmed'},
        @{Name='split_proposal';Prior=@('幾點可以接','禁食條件已符合，值班同仁需要準備時間，下午三點接可以嗎');Body='好，謝謝';Expected='confirmed'},
        @{Name='eligibility';Prior=@();Body='NPO時間到下午3點可接刀';Expected='uncertain'},
        @{Name='case_addition';Prior=@();Body='明天早上加一台打AO plate';Expected='confirmed'},
        @{Name='cancelled_reply';Prior=@('下午3點接可以嗎？','手術取消');Body='好的';ExpectedNot='confirmed'},
        @{Name='ordinary_reply';Prior=@('下午3點開會');Body='好';ExpectedNot='confirmed'}
    )
    foreach($liveCase in $scenarios){
        if(-not $liveCase.Name -or -not $liveCase.Body -or (-not $liveCase.Expected -and -not $liveCase.ExpectedNot)){throw 'InvalidLiveTestFixture'}
        Start-Scenario ('live_'+$liveCase.Name)
        $context=@($liveCase.Prior|ForEach-Object {
            $previous=New-Message $_
            [pscustomobject]@{Time=$previous.ArrivalUtc;Body=$_;Local=(Get-LocalDecision $_).Level;AiStatus='not_needed'}
        })
        $event=New-Message $liveCase.Body
        if($event.Body -cne $liveCase.Body){throw 'LiveTestPayloadMismatch'}
        try {
            $result=Invoke-EventAi $event $context
            $correct=if($liveCase.Expected){$result.status -eq $liveCase.Expected}else{$result.status -ne $liveCase.ExpectedNot}
            Assert $correct ('live AI: '+$liveCase.Name+' -> '+$result.status)
        }catch {throw ('Live AI check failed: '+$liveCase.Name+'; '+(Get-TransportError $_))}
    }
    Write-Output "TOTAL RESULT: $script:Passed checks passed (including 8 live AI checks)."
}
