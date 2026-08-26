# 安全設定 OpenAI API 金鑰：金鑰不會顯示或寫入專案檔案。
Write-Host '請貼上 OpenAI API Key 後按 Enter。輸入不會顯示。' -ForegroundColor Cyan
$secureKey = Read-Host 'OPENAI_API_KEY' -AsSecureString
$pointer = [IntPtr]::Zero
try {
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
    $plainKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    if ([string]::IsNullOrWhiteSpace($plainKey)) { throw '未輸入 API Key。' }
    [Environment]::SetEnvironmentVariable('OPENAI_API_KEY', $plainKey, 'User')
    Write-Host '設定完成。請關閉並重新開啟監測器。' -ForegroundColor Green
} finally {
    if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
    Remove-Variable plainKey -ErrorAction SilentlyContinue
}
