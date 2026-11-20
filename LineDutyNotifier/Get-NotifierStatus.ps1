# Read-only, content-free status for the durable notification pipeline.
param([string]$ConfigPath=(Join-Path $PSScriptRoot 'appsettings.json'))
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Dashboard.Status.ps1')
Get-DashboardSnapshot $ConfigPath | ConvertTo-Json -Depth 8
