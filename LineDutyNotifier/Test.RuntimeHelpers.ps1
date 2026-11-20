# Isolated runtime fixtures. Never copy settings, keys, or production state.
function New-RuntimeFixture([string]$Destination,[string]$Mode,[string]$Sqlite,[int]$HistoryCount=127) {
    if(Test-Path -LiteralPath $Destination){throw 'FixtureAlreadyExists'}
    [void][IO.Directory]::CreateDirectory($Destination)
    foreach($name in @('Notifier.Core.ps1','Performance.Core.ps1','Runtime.Core.ps1','Team.Core.ps1','Team.Roster.ps1','Start-LineDutyNotifier.ps1','Dashboard.Status.ps1','Dashboard.View.ps1','Portable.Bridge.ps1')){
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $Destination $name)
    }
    $transport=@'
function Invoke-RestMethod {throw 'FixtureNetworkForbidden'}
function Get-UserSecret {return 'synthetic-only'}
function Invoke-EventAi($Event,$Context){
    if(Test-Path (Join-Path (Split-Path $script:StateRoot) 'slow-ai.flag')){Start-Sleep -Seconds 8;throw 'SyntheticTimeout'}
    return [pscustomobject]@{status='uncertain';date=$null;time=$null;image_readable=$false}
}
function Invoke-PushHttp($Alert){
    if(Test-Path (Join-Path (Split-Path $script:StateRoot) 'offline.flag')){throw 'SyntheticOffline'}
    return [pscustomobject]@{status=1;receipt=('mock-'+$Alert.Id)}
}
function Invoke-ReceiptHttp {return [pscustomobject]@{status=1;acknowledged=1;expired=0}}
function Invoke-CancelReceiptHttp {return [pscustomobject]@{status=1}}
'@
    [IO.File]::WriteAllText((Join-Path $Destination 'Fixture.Transport.ps1'),$transport,[Text.UTF8Encoding]::new($true))
    $entry=Join-Path $Destination 'Start-LineDutyNotifier.ps1'
    $source=[IO.File]::ReadAllText($entry)
    $source=$source.Replace('Initialize-Notifier $ConfigPath',('Initialize-Notifier $ConfigPath'+[Environment]::NewLine+'. (Join-Path $PSScriptRoot ''Fixture.Transport.ps1'')'))
    [IO.File]::WriteAllText($entry,$source,[Text.UTF8Encoding]::new($true))
    $db=Join-Path $Destination 'notifications.db'
    & $Sqlite $db 'PRAGMA journal_mode=WAL; CREATE TABLE NotificationHandler(RecordId INTEGER, PrimaryId TEXT); INSERT INTO NotificationHandler VALUES(1,''LINE_fixture''); CREATE TABLE Notification([Order] INTEGER PRIMARY KEY,ArrivalTime INTEGER,HandlerId INTEGER,Payload BLOB);' | Out-Null
    if($LASTEXITCODE){throw 'FixtureDatabaseFailed'}
    $cfg=Get-Content (Join-Path $PSScriptRoot 'appsettings.example.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $cfg.Runtime.ExecutionMode=$Mode;$cfg.TargetGroupNames=@('SyntheticRuntimeGroup');$cfg.NotificationRouting.Mode='AllEnabled'
    $cfg.NotificationDatabase.DatabasePath=$db;$cfg.NotificationDatabase.SqlitePath=$Sqlite
    $cfg.Ai.Enabled=$true;$cfg.Pushover.Enabled=$true
    $config=Join-Path $Destination 'appsettings.json'
    [IO.File]::WriteAllText($config,($cfg|ConvertTo-Json -Depth 15),[Text.UTF8Encoding]::new($true))
    Initialize-Notifier $config
    $people=@([pscustomobject]@{Id='owner';Name='SyntheticAdmin';IsAdmin=$true;Enabled=$true;AlwaysOnDuty=$true;LeadMinutes=60;UserKey=('a'*30)},[pscustomobject]@{Id='other';Name='SyntheticDuty';IsAdmin=$false;Enabled=$true;AlwaysOnDuty=$true;LeadMinutes=60;UserKey=('b'*30)})
    Write-State (Get-StatePath 'team' 'model') @{Version=1;RosterVersion=0;People=$people;Shifts=@();LegacyIds=@();LegacyRecipientKey='synthetic'}
    for($i=0;$i -lt $HistoryCount;$i++){
        $id=Get-EventHash ('history-'+$i)
        Write-State (Get-StatePath 'inbox' $id) @{Id=$id;Body='Synthetic completed message';Group='SyntheticRuntimeGroup';ArrivalUtc=[datetime]::UtcNow.AddDays(-2).ToString('o');Local=@{Level='None';NeedsAi=$false};Images=@()}
        Write-State (Get-StatePath 'processed' $id) @{Status='done';AiStatus='not_needed'}
        foreach($n in 1..2){Write-State (Get-StatePath 'outbox' ($id+$n)) @{Id=($id+$n);EventId=$id;Kind='Confirmed';Status='acknowledged';Receipt='mock';CreatedUtc=[datetime]::UtcNow.AddDays(-2).ToString('o')}}
        if($i -lt 96){Write-State (Get-StatePath 'dispatch' $id) @{Handled=$true}}
        if($i -lt 73){Write-State (Get-StatePath 'schedules' $id) @{Id=$id;Status='completed'}}
    }
    return [pscustomobject]@{Root=$Destination;Config=$config;Database=$db;Sqlite=$Sqlite;Mode=$Mode}
}
function Start-RuntimeFixture($Fixture) {
    $entry=Join-Path $Fixture.Root 'Start-LineDutyNotifier.ps1'
    return Start-Process powershell.exe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "'+$entry+'" -ConfigPath "'+$Fixture.Config+'"') -WindowStyle Hidden -PassThru
}
function Get-FixtureProcesses($Fixture) {
    return @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'"|Where-Object {$_.CommandLine -like ('*-File "'+$Fixture.Root+'\Start-LineDutyNotifier.ps1"*') -and $_.CommandLine -like ('*-ConfigPath "'+$Fixture.Config+'"*')})
}
function Stop-RuntimeFixture($Fixture) {
    $control=Join-Path $Fixture.Root 'control.json';$temp=$control+'.tmp'
    [IO.File]::WriteAllText($temp,'{"State":"stopped"}',[Text.Encoding]::UTF8)
    if([IO.File]::Exists($control)){[IO.File]::Replace($temp,$control,[NullString]::Value)}else{[IO.File]::Move($temp,$control)}
    $deadline=[datetime]::UtcNow.AddSeconds(90)
    do {if(-not @(Get-FixtureProcesses $Fixture).Count){return};Start-Sleep -Milliseconds 250}while([datetime]::UtcNow -lt $deadline)
    throw 'FixtureSafeStopTimeout'
}
function Add-FixtureNotification($Fixture,[int]$Sequence,[string]$Body='出勤') {
    $xml='<toast launch="TextToast;ChatId=fixture;MessageId='+$Sequence+'"><visual><binding><text>SyntheticRuntimeGroup</text><text>'+[Security.SecurityElement]::Escape($Body)+'</text></binding></visual></toast>'
    $hex=([BitConverter]::ToString([Text.Encoding]::UTF8.GetBytes($xml))).Replace('-','')
    $arrival=[datetime]::UtcNow.ToFileTimeUtc()
    & $Fixture.Sqlite $Fixture.Database ("INSERT INTO Notification VALUES($Sequence,$arrival,1,X'$hex');") | Out-Null
    if($LASTEXITCODE){throw 'FixtureInsertFailed'}
    return [pscustomobject]@{Sequence=$Sequence;ArrivalUtc=[datetime]::FromFileTimeUtc($arrival).ToString('o')}
}
