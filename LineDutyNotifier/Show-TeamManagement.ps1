param([string]$ConfigPath=(Join-Path $PSScriptRoot 'appsettings.json'),[switch]$SmokeTest,[string]$PreviewPath='',[int]$PreviewTab=0,[string]$PreviewDraftId='')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Notifier.Core.ps1')
. (Join-Path $PSScriptRoot 'Team.Preview.ps1')
Initialize-Notifier $ConfigPath
if(-not (Test-TeamEnabled)){throw '請先執行 Enable-Team 初始化管理者。'}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$reader=[Xml.XmlReader]::Create((Join-Path $PSScriptRoot 'Team.Management.xaml'))
try {$window=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Dispose()}
$v=@{};foreach($name in @('TeamSummary','TeamStatus','PeopleTable','PersonName','PersonAliases','PersonLead','PersonKey','PersonEnabled','PersonAdmin','PersonAlways','NewPerson','SavePerson','TestPerson','RefreshTeam','ImportRoster','RecognizeRoster','DraftList','LoadDraft','SaveDraft','PublishRoster','PeriodStart','PeriodEnd','RosterNotes','PrevPage','NextPage','PageLabel','RosterImage','RosterRows','ShiftCode','ShiftStart','ShiftEnd','ApplyShift','AddRosterRow','DeleteRosterRow','ScheduleTime','SaveSchedule','CancelSchedule','PreviewRoutes','RoutePreview','ScheduleTable','DeliveryTable')){$v[$name]=$window.FindName($name)}
$script:personId='';$script:draft=$null;$script:page=0;$script:importJob=$null
$v.ScheduleContext=$window.FindName('ScheduleContext');$v.ChangeTarget=$window.FindName('ChangeTarget')
$v.EmergencyTestPerson=$window.FindName('EmergencyTestPerson');$v.StopEmergencyTest=$window.FindName('StopEmergencyTest')
if(-not (Test-RosterEnabled)){$window.FindName('RosterTab').Visibility='Collapsed';$window.FindName('RosterTab').IsEnabled=$false}
function Refresh-TeamView {
    $selectedPersonId=if($v.PeopleTable.SelectedItem){$v.PeopleTable.SelectedItem.Id}else{''}
    $script:snapshot=Get-TeamManagementSnapshot
    $v.PeopleTable.ItemsSource=@($snapshot.People);$v.ScheduleTable.ItemsSource=@($snapshot.Plans);$v.DeliveryTable.ItemsSource=@($snapshot.Deliveries)
    if($selectedPersonId){$v.PeopleTable.SelectedItem=@($snapshot.People|Where-Object Id -eq $selectedPersonId)[0]}
    $always=@($snapshot.People|Where-Object {$_.Enabled -and $_.AlwaysOnDuty}|ForEach-Object Name) -join '、'
    if(Test-RosterEnabled){
        $v.TeamSummary.Text="班表版本 $($snapshot.RosterVersion)　｜　全時段當班：$always　｜　個人提前量可在下方修改"
        $v.DraftList.ItemsSource=@(Get-ChildItem (Join-Path $script:StateRoot 'rosters') -Filter '*.dat'|Sort-Object LastWriteTimeUtc -Descending|ForEach-Object {$d=Read-State $_.FullName;[pscustomobject]@{Id=$d.Id;Label=((Format-Taipei $d.CreatedUtc)+' '+$d.Status)}})
    }elseif((Get-NotificationRoutingMode) -eq 'AllEnabled'){
        $recipients=@($snapshot.People|Where-Object Enabled|ForEach-Object Name) -join '、'
        $v.TeamSummary.Text="多人分派（班表停用）　｜　收件人：$recipients　｜　依各人提前量提醒、各自確認；全時段開關不影響分派"
        $v.DraftList.ItemsSource=@()
    }else{
        $owner=@($snapshot.People|Where-Object Id -eq 'owner')[0]
        $v.TeamSummary.Text="班表已停用　｜　直接通知：$($owner.Name)　｜　提前 $($owner.LeadMinutes) 分鐘　｜　其他人員與全時段開關不參與分派"
        $v.DraftList.ItemsSource=@()
    }
}
function Show-TeamError { $v.TeamStatus.Text='操作未完成：'+$_.Exception.Message }
function Set-RosterView {
    $rows=New-Object Collections.ObjectModel.ObservableCollection[object]
    foreach($row in @($script:draft.Rows)){$rows.Add($row)}
    $v.RosterRows.ItemsSource=$rows;$v.PeriodStart.Text=$draft.PeriodStart;$v.PeriodEnd.Text=$draft.PeriodEnd;$v.RosterNotes.Text=$draft.Notes
    Show-RosterPage
}
function Show-RosterPage {
    $preview=Get-RosterImage $script:draft $script:page;$script:page=$preview.Page
    $v.RosterImage.Source=$preview.Image;$v.PageLabel.Text=('{0} / {1}' -f ($preview.Page+1),$preview.Count)
}
function Save-CurrentDraft {
    Assert-NotifierEditable
    if(-not $script:draft){throw '請先選擇或載入班表。'}
    [void]$v.RosterRows.CommitEdit();[void]$v.RosterRows.CommitEdit()
    $script:draft.Rows=@($v.RosterRows.ItemsSource);$script:draft.PeriodStart=$v.PeriodStart.Text;$script:draft.PeriodEnd=$v.PeriodEnd.Text
    Write-State (Get-StatePath 'rosters' $draft.Id) $draft
}
$v.PeopleTable.Add_SelectionChanged({
    $p=$v.PeopleTable.SelectedItem;if(-not $p){return};$script:personId=$p.Id
    $v.PersonName.Text=$p.Name;$v.PersonAliases.Text=$p.Aliases;$v.PersonLead.Text=[string]$p.LeadMinutes;$v.PersonKey.Password=''
    $v.PersonEnabled.IsChecked=$p.Enabled;$v.PersonAdmin.IsChecked=$p.IsAdmin;$v.PersonAlways.IsChecked=$p.AlwaysOnDuty
})
$v.NewPerson.Add_Click({$script:personId='';$v.PeopleTable.SelectedItem=$null;$v.PersonName.Text='';$v.PersonAliases.Text='';$v.PersonKey.Password='';$v.PersonLead.Text='60';$v.PersonEnabled.IsChecked=$true;$v.PersonAdmin.IsChecked=$false;$v.PersonAlways.IsChecked=$false})
$v.SavePerson.Add_Click({try {
    $p=[pscustomobject]@{Id=$script:personId;Name=$v.PersonName.Text.Trim();Aliases=@($v.PersonAliases.Text -split '[,，]'|ForEach-Object {$_.Trim()}|Where-Object {$_});Enabled=[bool]$v.PersonEnabled.IsChecked;IsAdmin=[bool]$v.PersonAdmin.IsChecked;AlwaysOnDuty=[bool]$v.PersonAlways.IsChecked;LeadMinutes=[int]$v.PersonLead.Text;UserKey=$v.PersonKey.Password.Trim();KeyEnvironment=''}
    Save-TeamPerson $p $script:snapshot.Version;$v.PersonKey.Password='';Refresh-TeamView;$v.TeamStatus.Text='人員已儲存，排程會重新核對。'
}catch{Show-TeamError}})
$v.TestPerson.Add_Click({try{Test-TeamPersonNotification $script:personId;$v.TeamStatus.Text='測試已被 Pushover 接受，請核對手機。'}catch{$v.TeamStatus.Text='測試未成功，請核對人員收件資料及網路。'}})
$v.EmergencyTestPerson.Add_Click({try{
    $p=$v.PeopleTable.SelectedItem;if(-not $p){throw '請先從上方選取已儲存的人員。'}
    $prompt="只對「$($p.Name)」發送緊急測試，可能突破靜音／勿擾。`n每 30 秒重複，最長 2 分鐘；手機按 Acknowledge 可停止。`n請先取得對方同意。這不是正式出勤通知。`n確定發送？"
    if([Windows.MessageBox]::Show($prompt,'確認緊急測試收件人','YesNo','Warning','No') -ne 'Yes'){return}
    $id=Start-TeamEmergencyTest $p.Id -Confirmed
    Refresh-TeamView;$v.TeamStatus.Text="測試 $($id.Substring(0,8)) 已排入佇列（不代表手機已收到）。請保持監測器運作，按重新整理查看個別通知紀錄。"
}catch{Show-TeamError}})
$v.StopEmergencyTest.Add_Click({try{
    $p=$v.PeopleTable.SelectedItem;if(-not $p){throw '請先從上方選取人員。'}
    if([Windows.MessageBox]::Show("只停止「$($p.Name)」的緊急測試，不停止正式通知或其他人提醒。",'停止測試','YesNo','Question','No') -ne 'Yes'){return}
    $count=Stop-TeamEmergencyTests $p.Id
    Refresh-TeamView;$v.TeamStatus.Text=if($count){'已要求停止測試。已送出者須等服務確認；請保持監測器運作。亦可在手機按 Acknowledge，測試最長 2 分鐘。'}else{'此人沒有進行中的緊急測試。'}
}catch{Show-TeamError}})
$v.RefreshTeam.Add_Click({try{Refresh-TeamView;$v.TeamStatus.Text='已重新整理。'}catch{Show-TeamError}})
$v.ImportRoster.Add_Click({try{
    $dialog=New-Object Microsoft.Win32.OpenFileDialog;$dialog.Filter='班表圖片與 PDF|*.png;*.jpg;*.jpeg;*.pdf'
    if($dialog.ShowDialog()){$script:draft=New-RosterDraft $dialog.FileName;$script:page=0;Set-RosterView;Refresh-TeamView;$v.TeamStatus.Text='原檔已加密保存。按 AI 辨識會將這份班表送往既有 AI 服務並產生用量。'}
}catch{Show-TeamError}})
$v.LoadDraft.Add_Click({try{if(-not $v.DraftList.SelectedItem){return};$script:draft=Read-State (Get-StatePath 'rosters' $v.DraftList.SelectedItem.Id);if($draft.Status -eq 'published'){$draft.Id=[guid]::NewGuid().ToString('N');$draft.Status='draft'};$draft.BaseVersion=(Get-TeamModel).Version;$script:page=0;Set-RosterView;$v.TeamStatus.Text='已載入。請核對人員及班次後再發布。'}catch{Show-TeamError}})
$v.SaveDraft.Add_Click({try{Save-CurrentDraft;$v.TeamStatus.Text='草稿已保存，尚未套用通知。'}catch{Show-TeamError}})
$v.RecognizeRoster.Add_Click({try{
    if($script:importJob){return};Save-CurrentDraft
    $ps=[PowerShell]::Create();[void]$ps.AddScript('param($core,$config,$id);$ErrorActionPreference="Stop";. $core;Initialize-Notifier $config;Invoke-RosterAi (Read-State (Get-StatePath "rosters" $id))').AddArgument((Join-Path $PSScriptRoot 'Notifier.Core.ps1')).AddArgument($ConfigPath).AddArgument($draft.Id)
    $script:importJob=@{PowerShell=$ps;Pending=$ps.BeginInvoke()};$v.RecognizeRoster.IsEnabled=$false;$v.ImportRoster.IsEnabled=$false;$v.LoadDraft.IsEnabled=$false;$v.PublishRoster.IsEnabled=$false;$v.SaveDraft.IsEnabled=$false;$v.RosterRows.IsEnabled=$false
    $v.TeamStatus.Text='AI 正在辨識班表，可繼續查看其他分頁；結果必須核對後發布。'
}catch{Show-TeamError}})
$v.PublishRoster.Add_Click({try{
    Save-CurrentDraft
    if([Windows.MessageBox]::Show('已逐列核對姓名、日期及跨日時間？發布會取代所選日期範圍的班表並重新分派待發通知。','發布班表','YesNo','Question') -ne 'Yes'){return}
    Publish-Roster $script:draft;Refresh-TeamView;$v.TeamStatus.Text='班表已發布。'
}catch{Show-TeamError}})
$v.PrevPage.Add_Click({try{if($draft){$script:page--;Show-RosterPage}}catch{Show-TeamError}})
$v.NextPage.Add_Click({try{if($draft){$script:page++;Show-RosterPage}}catch{Show-TeamError}})
$v.AddRosterRow.Add_Click({if($draft){$v.RosterRows.ItemsSource.Add([pscustomobject]@{Name='';Date='';Shift='';Start='';End='';Note=''})}})
$v.DeleteRosterRow.Add_Click({if($v.RosterRows.SelectedItem){[void]$v.RosterRows.ItemsSource.Remove($v.RosterRows.SelectedItem)}})
$v.ApplyShift.Add_Click({try{
    [void]$v.RosterRows.CommitEdit();[void]$v.RosterRows.CommitEdit()
    if(-not $v.ShiftCode.Text.Trim()){throw '請輸入班別代碼。'}
    foreach($row in @($v.RosterRows.ItemsSource|Where-Object Shift -eq $v.ShiftCode.Text.Trim())){
        $a=Convert-TaipeiUtc ($row.Date+' '+$v.ShiftStart.Text);$b=Convert-TaipeiUtc ($row.Date+' '+$v.ShiftEnd.Text);if($b -le $a){$b=$b.AddDays(1)}
        $row.Start=Format-Taipei $a;$row.End=Format-Taipei $b
    };$v.RosterRows.Items.Refresh();$v.TeamStatus.Text='班別時間已套用草稿，請核對後發布。'
}catch{Show-TeamError}})
$v.ScheduleTable.Add_SelectionChanged({try{if($v.ScheduleTable.SelectedItem){
    $s=$v.ScheduleTable.SelectedItem;$v.ScheduleTime.Text=$s.Time;$p=Read-State (Get-StatePath 'schedules' $s.Id)
    $v.ScheduleContext.Text='本機原訊息：'+$p.Body
    $v.ChangeTarget.ItemsSource=@($script:snapshot.Plans|Where-Object {$_.Id -ne $s.Id -and $_.Status -in @('active','completed')}|ForEach-Object {[pscustomobject]@{Id=$_.Id;Version=$_.Version;Label=($_.Time+' / '+$_.Id.Substring(0,8))}})
    $v.ChangeTarget.IsEnabled=$s.Status -eq 'change_review'
}}catch{Show-TeamError}})
$v.SaveSchedule.Add_Click({try{$s=$v.ScheduleTable.SelectedItem;if(-not $s){return};$when=Convert-TaipeiUtc $v.ScheduleTime.Text
    if($s.Status -eq 'change_review'){$t=$v.ChangeTarget.SelectedItem;Resolve-TeamChange $s.Id $t.Id $when.ToString('o') -ExpectedVersion $t.Version}
    else{Set-TeamSchedule $s.Id $when.ToString('o') -ExpectedVersion $s.Version}
    Refresh-TeamView;$v.TeamStatus.Text='接刀時間已更新。'
}catch{Show-TeamError}})
$v.CancelSchedule.Add_Click({try{
    $s=$v.ScheduleTable.SelectedItem;if(-not $s){return}
    if([Windows.MessageBox]::Show('確認取消選取的接刀排程並停止相關提醒？異動待核對項目將取消下拉選單選取的原排程。','取消排程','YesNo','Question') -eq 'Yes'){
        if($s.Status -eq 'change_review'){$t=$v.ChangeTarget.SelectedItem;Resolve-TeamChange $s.Id $t.Id '' -Cancel -ExpectedVersion $t.Version}
        else{Set-TeamSchedule $s.Id '' -Cancel -ExpectedVersion $s.Version}
        Refresh-TeamView;$v.TeamStatus.Text='已取消；已送出的重複提醒將由確認程序停止。'
    }
}catch{Show-TeamError}})
$v.PreviewRoutes.Add_Click({try{
    $s=$v.ScheduleTable.SelectedItem;if(-not $s){return};$plan=Read-State (Get-StatePath 'schedules' $s.Id)
    $reasonLabels=@{all_enabled='所有已啟用人員（不使用班表）';direct_owner='直接通知原收件人（不使用班表）';always_on='全時段當班';roster='已發布班表';fallback='備援收件人';overdue_admin='逾時請管理者核對'}
    $v.RoutePreview.Text=if($plan.Status -in @('cancelled','completed')){'已取消或完成，沒有新的待發通知。'}else{(@(Get-TeamScheduleRoutes $plan (Get-TeamModel) ([datetime]::UtcNow)|ForEach-Object {$_.Person.Name+'：'+$(if($_.Kind -eq 'Confirmed'){'緊急提醒'}else{'一般提醒'})+' / '+(Format-Taipei $_.Due)+' / '+$reasonLabels[$_.Reason]}) -join "`n")}
    $v.TeamStatus.Text='試跑完成，沒有發送通知。'
}catch{Show-TeamError}})
$timer=New-Object Windows.Threading.DispatcherTimer;$timer.Interval=[TimeSpan]::FromMilliseconds(300)
$timer.Add_Tick({if($script:importJob -and $script:importJob.Pending.IsCompleted){
    try{$result=@($importJob.PowerShell.EndInvoke($importJob.Pending));if($importJob.PowerShell.HadErrors -or $result.Count -ne 1){throw 'ImportFailed'};$script:draft=$result[0];Set-RosterView;$v.TeamStatus.Text='辨識完成，請逐列核對，補齊空白時間及姓名對應。'}catch{$v.TeamStatus.Text='AI 辨識未完成；原檔與草稿仍保留，可重試或手動填寫。'}
    finally{$importJob.PowerShell.Dispose();$script:importJob=$null;foreach($name in @('RecognizeRoster','ImportRoster','LoadDraft','PublishRoster','SaveDraft','RosterRows')){$v[$name].IsEnabled=$true}}
}})
Refresh-TeamView
if($PreviewPath){
    if($PreviewDraftId){$script:draft=Read-State (Get-StatePath 'rosters' $PreviewDraftId);Set-RosterView}
    $window.FindName('TeamTabs').SelectedIndex=$PreviewTab
    $window.WindowStartupLocation='Manual';$window.Left=-20000;$window.ShowInTaskbar=$false;$window.Show();$window.UpdateLayout()
    [void]$window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle)
    $content=$window.Content
    $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new([int]$content.ActualWidth,[int]$content.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32);$bitmap.Render($content)
    $encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder;$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap));$stream=[IO.File]::Create([IO.Path]::GetFullPath($PreviewPath));try{$encoder.Save($stream)}finally{$stream.Dispose()};$window.Close();'TEAM_PREVIEW_OK';exit
}
if($SmokeTest){
    if(-not $v.EmergencyTestPerson -or -not $v.StopEmergencyTest){throw 'EmergencyTestControlsMissing'}
    if(-not (Test-RosterEnabled) -and ($window.FindName('RosterTab').Visibility -ne 'Collapsed' -or $window.FindName('RosterTab').IsEnabled)){throw 'RosterTabShouldBeHidden'}
    if((Get-NotificationRoutingMode) -eq 'AllEnabled' -and $v.TeamSummary.Text -notmatch '多人分派（班表停用）'){throw 'MultiModeSummaryMissing'}
    'TEAM_UI_OK';exit
}
$window.Add_Closing({if($script:importJob){$_.Cancel=$true;$v.TeamStatus.Text='請等待班表辨識完成後再關閉。'}})
$timer.Start();try{[void]$window.ShowDialog()}finally{$timer.Stop()}
