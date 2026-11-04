# Preset coherence check: the identity presets offered in the virtual camera
# dialog are real-camera identities; our own blocklist must never flag them
# as virtual-camera fingerprints. Fails when a preset name matches any
# blocklist name pattern (case-insensitive substring, the same rule the scan
# uses).
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$ProjectRoot = Resolve-Path -Path "$PSScriptRoot/../.."
$Blocklist = Get-Content "$PSScriptRoot/blocklist.json" -Raw | ConvertFrom-Json
$DialogSource = Get-Content "$ProjectRoot/frontend/dialogs/OBSBasicVCamConfig.cpp" -Raw

# The preset table in IdentityPresetChanged():
#   static const char *preset_names[] = { "A", "B", ... };
$Pattern = 'preset_names\[\]\s*=\s*\{([^}]*)\}'
$Match = [regex]::Match($DialogSource, $Pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
if (-not $Match.Success) {
    Write-Error "preset_names table not found in OBSBasicVCamConfig.cpp"
    exit 2
}

$Presets = [regex]::Matches($Match.Groups[1].Value, '"([^"]*)"') | ForEach-Object { $_.Groups[1].Value }
if (-not $Presets -or @($Presets).Count -eq 0) {
    Write-Error "preset_names table is empty"
    exit 2
}

$Failures = @()
foreach ($Preset in $Presets) {
    foreach ($Entry in $Blocklist.name_patterns) {
        if ($Preset.ToLowerInvariant().Contains($Entry.pattern.ToLowerInvariant())) {
            $Failures += "preset '$Preset' matches blocklist pattern '$($Entry.pattern)' ($($Entry.product))"
        }
    }
}

if ($Failures.Count -gt 0) {
    Write-Host "PRESET COHERENCE FAILED:"
    foreach ($Failure in $Failures) {
        Write-Host "  $Failure"
    }
    exit 1
}

Write-Host "Preset coherence OK: $($Presets.Count) presets checked against $($Blocklist.name_patterns.Count) patterns"
exit 0
