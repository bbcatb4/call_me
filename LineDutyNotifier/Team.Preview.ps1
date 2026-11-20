# Native in-memory PDF rendering, no plaintext export of imported roster files.
function Wait-RosterWinRt($Operation,[type]$ResultType) {
    if($ResultType){
        $method=@([System.WindowsRuntimeSystemExtensions].GetMethods()|Where-Object {$_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetGenericArguments().Count -eq 1 -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'})[0]
        $task=$method.MakeGenericMethod($ResultType).Invoke($null,@($Operation))
    }else{
        $method=@([System.WindowsRuntimeSystemExtensions].GetMethods()|Where-Object {$_.Name -eq 'AsTask' -and -not $_.IsGenericMethod -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction'})[0]
        $task=$method.Invoke($null,@($Operation))
    }
    return $task.GetAwaiter().GetResult()
}
function Get-RosterImage($Draft,[int]$Page=0) {
    Add-Type -AssemblyName PresentationCore
    $bytes=[Convert]::FromBase64String($Draft.Data);$count=1
    if($Draft.Mime -eq 'application/pdf'){
        Add-Type -AssemblyName System.Runtime.WindowsRuntime
        [void][Windows.Data.Pdf.PdfDocument,Windows.Data.Pdf,ContentType=WindowsRuntime]
        [void][Windows.Storage.Streams.InMemoryRandomAccessStream,Windows.Storage.Streams,ContentType=WindowsRuntime]
        [void][Windows.Storage.Streams.DataWriter,Windows.Storage.Streams,ContentType=WindowsRuntime]
        [void][Windows.Storage.Streams.DataReader,Windows.Storage.Streams,ContentType=WindowsRuntime]
        $inputStream=New-Object Windows.Storage.Streams.InMemoryRandomAccessStream
        $writer=New-Object Windows.Storage.Streams.DataWriter($inputStream)
        try {
            $writer.WriteBytes($bytes);[void](Wait-RosterWinRt ($writer.StoreAsync()) ([uint32]));$inputStream.Seek(0)
            $pdf=Wait-RosterWinRt ([Windows.Data.Pdf.PdfDocument]::LoadFromStreamAsync($inputStream)) ([Windows.Data.Pdf.PdfDocument]);$count=[int]$pdf.PageCount
            $Page=[Math]::Max(0,[Math]::Min($count-1,$Page));$pdfPage=$pdf.GetPage([uint32]$Page)
            $output=New-Object Windows.Storage.Streams.InMemoryRandomAccessStream
            try {
                [void](Wait-RosterWinRt ($pdfPage.RenderToStreamAsync($output)) $null);$output.Seek(0)
                $reader=New-Object Windows.Storage.Streams.DataReader($output)
                try {[void](Wait-RosterWinRt ($reader.LoadAsync([uint32]$output.Size)) ([uint32]));$bytes=New-Object byte[] ([int]$output.Size);$reader.ReadBytes($bytes)}finally{$reader.Dispose()}
            }finally{$pdfPage.Dispose();$output.Dispose()}
        }finally{$writer.Dispose();$inputStream.Dispose()}
    }
    $stream=New-Object IO.MemoryStream(,$bytes)
    try {
        $bitmap=New-Object Windows.Media.Imaging.BitmapImage;$bitmap.BeginInit();$bitmap.CacheOption='OnLoad';$bitmap.StreamSource=$stream;$bitmap.EndInit();$bitmap.Freeze()
    }finally{$stream.Dispose()}
    return [pscustomobject]@{Image=$bitmap;Page=$Page;Count=$count}
}
