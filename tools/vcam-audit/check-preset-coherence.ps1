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

# The preset names are the plain literals the constructor feeds into the
# preset combo (the localized "Custom" entry is a QTStr key, not a camera
# identity, and cannot match the addItem("...") form):
#   ui->identityPreset->addItem("Logitech HD Pro Webcam C920");
$Pattern = 'identityPreset->addItem\("([^"]+)"\)'
$Matches = [regex]::Matches($DialogSource, $Pattern)
if ($Matches.Count -eq 0) {
    Write-Error "no identityPreset addItem literals found in OBSBasicVCamConfig.cpp"
    exit 2
}
$Presets = $Matches | ForEach-Object { $_.Groups[1].Value }
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
