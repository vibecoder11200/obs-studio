[CmdletBinding()]
param(
    [ValidateSet('x64', 'arm64')]
    [string] $Target = 'x64',
    [ValidateSet('Debug', 'RelWithDebInfo', 'Release', 'MinSizeRel')]
    [string] $Configuration = 'RelWithDebInfo'
)

$ErrorActionPreference = 'Stop'

if ( $DebugPreference -eq 'Continue' ) {
    $VerbosePreference = 'Continue'
    $InformationPreference = 'Continue'
}

if ( $env:CI -eq $null ) {
    throw "Package-Windows.ps1 requires CI environment"
}

if ( ! ( [System.Environment]::Is64BitOperatingSystem ) ) {
    throw "obs-studio requires a 64-bit system to build and run."
}

if ( $PSVersionTable.PSVersion -lt '7.2.0' ) {
    Write-Warning 'The obs-studio packaging script requires PowerShell Core 7. Install or upgrade your PowerShell version: https://aka.ms/pscore6'
    exit 2
}

function Package {
    trap {
        Write-Error $_
        exit 2
    }

    $ScriptHome = $PSScriptRoot
    $ProjectRoot = Resolve-Path -Path "$PSScriptRoot/../.."

    $UtilityFunctions = Get-ChildItem -Path $PSScriptRoot/utils.pwsh/*.ps1 -Recurse

    foreach( $Utility in $UtilityFunctions ) {
        Write-Debug "Loading $($Utility.FullName)"
        . $Utility.FullName
    }

    Install-BuildDependencies -WingetFile "${ScriptHome}/.Wingetfile"

    $GitDescription = Invoke-External git describe --tags --long
    $Tokens = ($GitDescription -split '-')
    $CommitVersion = $Tokens[0..$($Tokens.Count - 3)] -join '-'
    $CommitHash = $($Tokens[-1]).SubString(1)
    $CommitDistance = $Tokens[-2]

    if ( $CommitDistance -gt 0 ) {
        $OutputName = "obs-studio-${CommitVersion}-${CommitHash}"
    } else {
        $OutputName = "obs-studio-${CommitVersion}"
    }

    $CpackArgs = @(
        '-C', "${Configuration}"
    )

    if ( $DebugPreference -eq 'Continue' ) {
        $CpackArgs += ('--verbose')
    }

    Log-Group "Packaging obs-studio..."

    Push-Location -Stack PackageTemp "build_${Target}"

    cpack @CpackArgs

    # Remove all PDB files from the package: the fork ships no debug symbols,
    # and symbol files embed identifying strings (CLSID names, build paths).
    # Applies to every configuration, including Release.
    Log-Group "Removing PDB files from package..."
    $PackageZip = Get-ChildItem -filter "obs-studio-*-windows-${Target}.zip" -File
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $ZipArchive = [System.IO.Compression.ZipFile]::Open($PackageZip.FullName, [System.IO.Compression.ZipArchiveMode]::Update)
    try {
        $PdbEntries = @($ZipArchive.Entries | Where-Object { $_.Name -like '*.pdb' })
        foreach ( $PdbEntry in $PdbEntries ) {
            $PdbEntry.Delete()
        }
        Log-Information "Removed $($PdbEntries.Count) PDB files from $($PackageZip.Name)"

        # Ship the self-audit harness with every release so users can verify
        # the camera identity without leaving the package (script, blocklist,
        # vector definitions, README - no samples).
        Log-Group "Copying virtual camera audit tooling into package..."
        $AuditSource = Join-Path $ProjectRoot 'tools/vcam-audit'
        $AuditFiles = Get-ChildItem -Path $AuditSource -Recurse -File |
            Where-Object { $_.FullName -notmatch '[\\/]samples[\\/]' }
        foreach ( $AuditFile in $AuditFiles ) {
            $RelativePath = $AuditFile.FullName.Substring($AuditSource.Length + 1) -replace '[\\/]', '/'
            $EntryName = "auxdata/vcam-audit/${RelativePath}"
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($ZipArchive, $AuditFile.FullName, $EntryName) | Out-Null
        }
        Log-Information "Added $($AuditFiles.Count) audit files to auxdata/vcam-audit/"

        # Portable-mode marker at the package root: OBS looks for it at
        # BASE_PATH "../.." from bin/64bit, i.e. the folder that contains
        # bin/ — not next to the binaries.
        Log-Group "Adding portable_mode marker..."
        $MarkerEntry = $ZipArchive.CreateEntry("portable_mode")
        $MarkerStream = $MarkerEntry.Open()
        $MarkerStream.Dispose()
        Log-Information "Added portable_mode (package root)"
    } finally {
        $ZipArchive.Dispose()
    }

    $Package = Get-ChildItem -filter "obs-studio-*-windows-${Target}.zip" -File
    Move-Item -Path $Package -Destination "${OutputName}-windows-${Target}.zip"

    Pop-Location -Stack PackageTemp
}

Package
