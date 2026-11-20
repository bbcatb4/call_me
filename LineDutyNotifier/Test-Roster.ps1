param([switch]$LiveAi)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Notifier.Core.ps1')
. (Join-Path $PSScriptRoot 'Team.Preview.ps1')
$root=Join-Path $PSScriptRoot ('state/roster-test-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$config=Join-Path $root 'appsettings.json'
[IO.File]::WriteAllText($config,[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'appsettings.example.json')),[Text.Encoding]::UTF8)
Initialize-Notifier $config
$script:Settings.NotificationRouting.Mode='Roster'
$realSecret=${function:Get-UserSecret};function Get-UserSecret {return 'uuuuuuuuuuuuuuuuuuuuuuuuuuuuuu'}
Enable-Team;Set-Item Function:Get-UserSecret $realSecret;$script:Settings.Ai.Enabled=$true
# Small synthetic PDF fixture, never a real roster or patient record.
$content="BT /F1 18 Tf 30 150 Td (Duty roster 2027-01-01) Tj 0 -30 Td (Alice 08:00 - 17:00) Tj ET"
$objects=@('<< /Type /Catalog /Pages 2 0 R >>','<< /Type /Pages /Kids [3 0 R] /Count 1 >>','<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 200] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>','<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',('<< /Length '+$content.Length+" >>`nstream`n"+$content+"`nendstream"))
$pdf="%PDF-1.4`n";$offsets=@(0)
for($i=0;$i -lt $objects.Count;$i++){$offsets+=@($pdf.Length);$pdf+=($i+1).ToString()+" 0 obj`n"+$objects[$i]+"`nendobj`n"}
$xref=$pdf.Length;$pdf+="xref`n0 6`n0000000000 65535 f `n";foreach($n in $offsets|Select-Object -Skip 1){$pdf+=('{0:0000000000} 00000 n ' -f $n)+"`n"};$pdf+="trailer`n<< /Size 6 /Root 1 0 R >>`nstartxref`n$xref`n%%EOF"
$path=Join-Path $root 'synthetic.pdf';[IO.File]::WriteAllBytes($path,[Text.Encoding]::ASCII.GetBytes($pdf))
$draft=New-RosterDraft $path
$preview=Get-RosterImage $draft
if($preview.Count -ne 1 -or $preview.Image.PixelWidth -lt 100){throw 'PDF preview failed'}
Add-Type -AssemblyName PresentationCore
$encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder;$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($preview.Image))
$png=Join-Path $root 'synthetic.png';$stream=[IO.File]::Create($png);try{$encoder.Save($stream)}finally{$stream.Dispose()}
'PASS: PDF renders from encrypted in-memory draft'
$imageDraft=New-RosterDraft $png
if((Get-RosterImage $imageDraft).Image.PixelWidth -lt 100){throw 'Image preview failed'}
'PASS: image draft renders'
if(-not $LiveAi){
    function Get-UserSecret {return 'fixture-key'}
    function Invoke-RestMethod {
        param($Method,$Uri,$Headers,$ContentType,$Body,$TimeoutSec,$ErrorAction)
        $request=[Text.Encoding]::UTF8.GetString($Body)|ConvertFrom-Json
        if($request.store -ne $false -or $request.text.format.type -ne 'json_schema'){throw 'Invalid request'}
        $attachment=$request.input[0].content[1]
        if($attachment.type -notin @('input_file','input_image')){throw 'Missing source'}
        $r=@{Rows=@(@{Name='Alice';Date='2027-01-01';Shift='Day';Start='2027-01-01 08:00';End='2027-01-01 17:00';Note=''});Notes='Check source';PeriodStart='2027-01-01';PeriodEnd='2027-01-01'}
        return [pscustomobject]@{id=[guid]::NewGuid().ToString('N');usage=@{input_tokens=100;output_tokens=50;total_tokens=150};output=@(@{content=@(@{type='output_text';text=($r|ConvertTo-Json -Depth 8)})})}
    }
    [void](Invoke-RosterAi $imageDraft)
}
$result=Invoke-RosterAi $draft
if(-not $result.Rows.Count -or $result.Rows[0].Name -ne 'Alice' -or $result.Status -ne 'draft'){throw 'Roster recognition failed'}
if((Get-TeamModel).Shifts.Count -ne 0){throw 'AI draft published without approval'}
if(-not @(Get-ChildItem (Join-Path $script:StateRoot 'usage') -Filter '*.dat').Count){throw 'Usage missing'}
'PASS: PDF AI request returns editable draft and tracks actual usage'
'PASS: recognition never auto-publishes'
"PREVIEW=$png"
