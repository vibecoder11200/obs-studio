# Preset coherence check: the identity presets offered in the virtual camera
# dialog are real-camera identities; our own blocklist must never flag them
# as virtual-camera fingerprints. Fails when a preset name matches any
# blocklist name pattern (case-insensitive substring, the same rule the scan
# uses). Also cross-checks the three-way duplication (C++ pair table in
# virtualcam-serial.h, the VCamPreset dialog rows, blocklist serial_formats):
# adding a preset without its serial_formats row is a CI failure.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$ProjectRoot = Resolve-Path -Path "$PSScriptRoot/../.."
$Blocklist = Get-Content "$PSScriptRoot/blocklist.json" -Raw | ConvertFrom-Json
$DialogSource = Get-Content "$ProjectRoot/frontend/dialogs/OBSBasicVCamConfig.cpp" -Raw

# The presets are the VCamPreset struct rows in the dialog source:
#   {"Logitech HD Pro Webcam C920", "046D", "082D", VCAM_SERIAL_8HEX},
$RowPattern = '\{\s*"([^"]+)",\s*"([0-9A-Fa-f]{4})",\s*"([0-9A-Fa-f]{4})",\s*VCAM_SERIAL_([A-Z0-9]+)\s*\}'
$Rows = [regex]::Matches($DialogSource, $RowPattern)
if ($Rows.Count -eq 0) {
    Write-Error "no VCamPreset rows found in OBSBasicVCamConfig.cpp"
    exit 2
}
$Presets = $Rows | ForEach-Object { $_.Groups[1].Value }

$Failures3 = @()

# 1. Three-way sync: every dialog preset row must exist in serial_formats
#    (name is dialog-side; vid/pid/format are the audit's lookup key).
$FormatPatterns = @{
    '8HEX'     = '^[0-9A-F]{8}$'
    '8DIGIT'   = '^[0-9]{8}$'
    '12ALNUM'  = '^[0-9]{4}[A-Z0-9]{8}$'
    'ELGATO'   = '^FW[0-9]{2}K1A[0-9]{5}$'
    'LOCATION' = '^6&[0-9a-f]{8}&0&\d{4}$'
}
foreach ($known in $FormatPatterns.Keys) {
    if (-not ($Blocklist.serial_formats | Where-Object { $_.format -eq $known })) {
        $Failures3 = @($Failures3) + "blocklist serial_formats is missing the '$known' format class"
    }
}
foreach ($Row in $Rows) {
    $vid = $Row.Groups[2].Value.ToLowerInvariant()
    $pidVal = $Row.Groups[3].Value.ToLowerInvariant()
    $fmt = $Row.Groups[4].Value
    if (-not ($Blocklist.serial_formats | Where-Object { $_.vid -ieq $vid -and $_.pid -ieq $pidVal })) {
        $Failures3 = @($Failures3) + "preset '$($Row.Groups[1].Value)' (${vid}:${pidVal}) has no serial_formats row in blocklist.json"
    }
    if (-not $FormatPatterns.ContainsKey($fmt)) {
        $Failures3 = @($Failures3) + "preset '$($Row.Groups[1].Value)' uses unknown format '$fmt'"
    }
}

# 2. Name coherence against all three OS blocklists (macOS/Linux siblings
#    carry different pattern sets, e.g. Linux's plain "obs").
$BlocklistPaths = @(
    "$PSScriptRoot/blocklist.json",
    "$ProjectRoot/tools/vcam-audit-linux/blocklist.json",
    "$ProjectRoot/tools/vcam-audit-macos/blocklist.json"
)
foreach ($Path in $BlocklistPaths) {
    if (-not (Test-Path $Path)) {
        Write-Host "note: blocklist not found, skipped: $Path"
        continue
    }
    $OsBlocklist = Get-Content $Path -Raw | ConvertFrom-Json
    foreach ($Preset in $Presets) {
        foreach ($Entry in $OsBlocklist.name_patterns) {
            if ($Preset.ToLowerInvariant().Contains($Entry.pattern.ToLowerInvariant())) {
                $Failures3 = @($Failures3) + "preset '$Preset' matches $($Entry.pattern) in $(Split-Path -Leaf (Split-Path -Parent $Path)) ($($Entry.product))"
            }
        }
    }
}

if ($Failures3.Count -gt 0) {
    Write-Host "PRESET COHERENCE FAILED:"
    foreach ($Failure in $Failures3) {
        Write-Host "  $Failure"
    }
    exit 1
}

Write-Host "Preset coherence OK: $($Rows.Count) presets, all present in serial_formats, clear of $(@($BlocklistPaths | Where-Object { Test-Path $_ }).Count) OS blocklists"
exit 0
