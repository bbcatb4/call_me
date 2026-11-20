# Lightweight checks for pure helper behavior; run after dot-sourcing only in a test copy.
$root = Split-Path $PSScriptRoot -Parent
$config = Join-Path $PSScriptRoot 'dutybot.settings.example.json'
$settings = Get-Content $config -Raw -Encoding UTF8 | ConvertFrom-Json
function Assert-Equal($Actual, $Expected, $Label) { if ($Actual -ne $Expected) { throw "${Label}: expected $Expected, got $Actual" }; Write-Host "PASS $Label" }
function Find-Term($Terms, [string]$Text) { foreach ($term in @($Terms)) { if ($Text.IndexOf([string]$term, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return [string]$term } }; return $null }
function Assess([string]$Text) { if(Find-Term $settings.Rules.NegativeTerms $Text){return 'cancelled'}; if(Find-Term $settings.Rules.HighConfidenceTerms $Text){return 'confirmed'}; if(Find-Term $settings.Rules.UncertainTerms $Text){return 'candidate'}; if(Find-Term $settings.Rules.RequiredContextTerms $Text){return 'candidate'}; return 'ignored' }
Assert-Equal (Assess $settings.Rules.HighConfidenceTerms[0]) 'confirmed' 'confirmed-duty'
Assert-Equal (Assess $settings.Rules.NegativeTerms[0]) 'cancelled' 'cancelled-duty'
Assert-Equal (Assess $settings.Rules.UncertainTerms[0]) 'candidate' 'candidate-duty'
Assert-Equal (Assess 'general notice') 'ignored' 'irrelevant-message'
Assert-Equal $settings.Pushover.RetrySeconds 30 'pushover-retry-default'
