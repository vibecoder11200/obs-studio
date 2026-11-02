#!/usr/bin/env pwsh
#Requires -Version 7
<#
.SYNOPSIS
  Detection audit harness for virtual cameras on Windows (vectors V1-V9) plus a
  cross-platform static package gate for CI.

.DESCRIPTION
  Subcommands:
    scan   - enumerate DirectShow, PnP, camera-device interfaces, named kernel
             objects and config artifacts; emit per-device detection vectors.
    diff   - live scan joined (by CLSID, never by friendly name) with a baseline
             scan of a real webcam; prints per-vector PASS/WARN/FAIL gaps.
    static - canonical static gate: scan a build zip for OBS fingerprints
             (VERSIONINFO, file names, UTF-8/UTF-16 strings) with allowlist.
             Exit 0 = pass, 1 = violations, 2 = tool error. Works on any OS.

  Read-only: never writes registry, files or device state.

.EXAMPLE
  ./Audit-VirtualCam.ps1 scan -Json -OutFile vcam-report.json
.EXAMPLE
  ./Audit-VirtualCam.ps1 diff -Baseline real-webcam.json
.EXAMPLE
  ./Audit-VirtualCam.ps1 static -Package build_x64/obs-studio-33.0.1-windows-x64.zip
#>
[CmdletBinding()]
param(
	[Parameter(Position = 0)]
	[ValidateSet('scan', 'diff', 'static')]
	[string]$Command = 'scan',

	# scan / diff
	[switch]$Json,
	[string]$OutFile,

	# diff
	[string]$Baseline,
	[string]$Clsid = '76692E1E-F28F-4DD6-9024-C3A999D30EFB',
	[string]$ReferenceClsid,

	# static
	[string]$Package,

	[string]$BlocklistPath
)

$ErrorActionPreference = 'Stop'
$script:ToolRoot = $PSScriptRoot

# ---------------------------------------------------------------- utilities

function Write-Status([string]$Message) {
	Write-Host "[vcam-audit] $Message"
}

function Get-Blocklist {
	param([string]$Path)
	if (-not $Path) {
		$Path = Join-Path $script:ToolRoot 'blocklist.json'
	}
	if (-not (Test-Path $Path)) {
		throw "Blocklist not found: $Path"
	}
	return Get-Content $Path -Raw | ConvertFrom-Json
}

function ConvertTo-GuidBytes([string]$GuidText) {
	$parts = $GuidText.Trim('{', '}', ' ').Split('-')
	if ($parts.Count -ne 5) { throw "Malformed GUID: $GuidText" }
	$bytes = [System.Collections.Generic.List[byte]]::new()
	$bytes.AddRange([BitConverter]::GetBytes([Convert]::ToUInt32($parts[0], 16)))   # Data1, little-endian
	$bytes.AddRange([BitConverter]::GetBytes([Convert]::ToUInt16($parts[1], 16)))   # Data2, little-endian
	$bytes.AddRange([BitConverter]::GetBytes([Convert]::ToUInt16($parts[2], 16)))   # Data3, little-endian
	for ($i = 0; $i -lt $parts[3].Length; $i += 2) { $bytes.Add([Convert]::ToByte($parts[3].Substring($i, 2), 16)) }
	for ($i = 0; $i -lt $parts[4].Length; $i += 2) { $bytes.Add([Convert]::ToByte($parts[4].Substring($i, 2), 16)) }
	return $bytes.ToArray()
}

function Test-BytePattern([byte[]]$Haystack, [byte[]]$Needle) {
	if ($Needle.Count -eq 0 -or $Haystack.Count -lt $Needle.Count) { return $false }
	$first = $Needle[0]
	$last = $Haystack.Count - $Needle.Count
	for ($i = 0; $i -le $last; $i++) {
		if ($Haystack[$i] -ne $first) { continue }
		$ok = $true
		for ($j = 1; $j -lt $Needle.Count; $j++) {
			if ($Haystack[$i + $j] -ne $Needle[$j]) { $ok = $false; break }
		}
		if ($ok) { return $true }
	}
	return $false
}

function Get-PrintableStrings([byte[]]$Bytes, [int]$MinLength = 5) {
	# ASCII / UTF-8 runs of printable characters.
	$strings = [System.Collections.Generic.List[string]]::new()
	$sb = [System.Text.StringBuilder]::new()
	for ($i = 0; $i -lt $Bytes.Length; $i++) {
		$b = $Bytes[$i]
		if ($b -ge 0x20 -and $b -le 0x7E) {
			[void]$sb.Append([char]$b)
		} else {
			if ($sb.Length -ge $MinLength) { $strings.Add($sb.ToString()) }
			[void]$sb.Clear()
		}
	}
	if ($sb.Length -ge $MinLength) { $strings.Add($sb.ToString()) }
	return $strings
}

function Get-Utf16LeStrings([byte[]]$Bytes, [int]$MinLength = 5) {
	# Runs of printable chars in UTF-16LE (printable byte followed by 0x00).
	$strings = [System.Collections.Generic.List[string]]::new()
	$sb = [System.Text.StringBuilder]::new()
	for ($i = 0; $i + 1 -lt $Bytes.Length; $i += 2) {
		$lo = $Bytes[$i]; $hi = $Bytes[$i + 1]
		if ($hi -eq 0 -and $lo -ge 0x20 -and $lo -le 0x7E) {
			[void]$sb.Append([char]$lo)
		} elseif ($hi -eq 0 -and $lo -ge 0xA0) {
			# Latin supplement etc. - keep scanning wide chars, decode later if needed
			[void]$sb.Append([char](($hi -shl 8) -bor $lo))
		} else {
			if ($sb.Length -ge $MinLength) { $strings.Add($sb.ToString()) }
			[void]$sb.Clear()
		}
	}
	if ($sb.Length -ge $MinLength) { $strings.Add($sb.ToString()) }
	return $strings
}

function Get-DeviceInstanceId($Device) {
	# PnP instance id derived from a DirectShow DevicePath (moniker property bag
	# value, falling back to the registry Instance key), e.g.
	# \\?\usb#vid_xxxx&pid_xxxx#serial#{guid} -> USB\VID_XXXX&PID_XXXX\SERIAL.
	$path = $Device.devicepath_moniker
	if (-not $path) { $path = $Device.devicepath_registry }
	if ($path -match '^\\\\\?\\([^#]+)#([^#]+)#([^#]+)#') {
		return ('{0}\{1}\{2}' -f $Matches[1], $Matches[2], $Matches[3]).ToUpperInvariant()
	}
	return $null
}

# ------------------------------------------------- PE VERSIONINFO (cross-platform)

function Resolve-PeOffset([byte[]]$Bytes, [uint32]$Rva, $Sections) {
	foreach ($s in $Sections) {
		$size = [Math]::Max($s.VirtualSize, $s.RawSize)
		if ($Rva -ge $s.VirtualAddress -and $Rva -lt ($s.VirtualAddress + $size)) {
			return ($Rva - $s.VirtualAddress + $s.RawOffset)
		}
	}
	return $null
}

function Get-PeHeaders([byte[]]$Bytes) {
	# Common PE header walk: DOS 'MZ' -> e_lfanew (0x3C) -> 'PE' signature ->
	# optional-header magic (0x20B PE32+ / 0x10B PE32) -> data-directory offset,
	# plus the section table used to map RVAs to file offsets. Returns $null
	# when $Bytes is not a parseable PE image.
	if ($Bytes.Length -lt 0x200) { return $null }
	if ($Bytes[0] -ne 0x4D -or $Bytes[1] -ne 0x5A) { return $null }   # 'MZ'
	$peOff = [BitConverter]::ToUInt32($Bytes, 0x3C)
	if (($peOff + 24) -gt $Bytes.Length) { return $null }
	if ($Bytes[$peOff] -ne 0x50 -or $Bytes[$peOff + 1] -ne 0x45) { return $null }   # 'PE'
	$numSections = [BitConverter]::ToUInt16($Bytes, $peOff + 6)
	$optSize = [BitConverter]::ToUInt16($Bytes, $peOff + 20)
	$optOff = $peOff + 24
	if (($optOff + $optSize) -gt $Bytes.Length) { return $null }
	$magic = [BitConverter]::ToUInt16($Bytes, $optOff)
	$dataDirOff = if ($magic -eq 0x20B) { $optOff + 112 } elseif ($magic -eq 0x10B) { $optOff + 96 } else { return $null }

	$secOff = $optOff + $optSize
	$sections = [System.Collections.Generic.List[object]]::new()
	for ($i = 0; $i -lt $numSections; $i++) {
		$o = $secOff + 40 * $i
		if (($o + 40) -gt $Bytes.Length) { break }
		$sections.Add([pscustomobject]@{
				VirtualSize    = [BitConverter]::ToUInt32($Bytes, $o + 8)
				VirtualAddress = [BitConverter]::ToUInt32($Bytes, $o + 12)
				RawSize        = [BitConverter]::ToUInt32($Bytes, $o + 16)
				RawOffset      = [BitConverter]::ToUInt32($Bytes, $o + 20)
			})
	}
	return [pscustomobject]@{ DataDirOff = $dataDirOff; Sections = $sections }
}

function Get-VersionResourceBlob([byte[]]$Bytes) {
	$headers = Get-PeHeaders $Bytes
	if ($null -eq $headers) { return $null }
	$sections = $headers.Sections
	$resRva = [BitConverter]::ToUInt32($Bytes, $headers.DataDirOff + 16)   # directory index 2
	$resSize = [BitConverter]::ToUInt32($Bytes, $headers.DataDirOff + 20)
	if ($resRva -eq 0 -or $resSize -eq 0) { return $null }
	$resOff = Resolve-PeOffset $Bytes $resRva $sections
	if ($null -eq $resOff) { return $null }

	# Resource tree: root -> type RT_VERSION (16) -> name (first) -> lang (first)
	$level1Count = [BitConverter]::ToUInt16($Bytes, $resOff + 12) + [BitConverter]::ToUInt16($Bytes, $resOff + 14)
	for ($i = 0; $i -lt $level1Count; $i++) {
		$e = $resOff + 16 + 8 * $i
		if (([BitConverter]::ToUInt32($Bytes, $e)) -ne 16) { continue }   # RT_VERSION
		if (([BitConverter]::ToUInt32($Bytes, $e + 4)) -band 0x80000000 -eq 0) { continue }
		$nameDir = $resOff + (([BitConverter]::ToUInt32($Bytes, $e + 4)) -band 0x7FFFFFFF)
		$count2 = [BitConverter]::ToUInt16($Bytes, $nameDir + 12) + [BitConverter]::ToUInt16($Bytes, $nameDir + 14)
		if ($count2 -lt 1) { continue }
		$e2 = $nameDir + 16
		if (([BitConverter]::ToUInt32($Bytes, $e2 + 4)) -band 0x80000000 -eq 0) { continue }
		$langDir = $resOff + (([BitConverter]::ToUInt32($Bytes, $e2 + 4)) -band 0x7FFFFFFF)
		$count3 = [BitConverter]::ToUInt16($Bytes, $langDir + 12) + [BitConverter]::ToUInt16($Bytes, $langDir + 14)
		if ($count3 -lt 1) { continue }
		$e3 = $langDir + 16
		if (([BitConverter]::ToUInt32($Bytes, $e3 + 4)) -band 0x80000000) { continue }
		$dataEntry = $resOff + ([BitConverter]::ToUInt32($Bytes, $e3 + 4))
		$dataRva = [BitConverter]::ToUInt32($Bytes, $dataEntry)
		$dataSize = [BitConverter]::ToUInt32($Bytes, $dataEntry + 4)
		$dataOff = Resolve-PeOffset $Bytes $dataRva $sections
		if ($null -eq $dataOff -or ($dataOff + $dataSize) -gt $Bytes.Length) { return $null }
		$blob = New-Object byte[] $dataSize
		[Array]::Copy($Bytes, $dataOff, $blob, 0, $dataSize)
		return $blob
	}
	return $null
}

function Read-VsSzKey([byte[]]$Blob, [int]$Offset) {
	# Returns [string, offsetAfterTerminator] - caller applies 32-bit alignment.
	$start = $Offset
	while (($Offset + 1) -lt $Blob.Length -and [BitConverter]::ToUInt16($Blob, $Offset) -ne 0) { $Offset += 2 }
	$text = if ($Offset -gt $start) { [Text.Encoding]::Unicode.GetString($Blob, $start, $Offset - $start) } else { '' }
	return , @($text, ($Offset + 2))
}

function Format-Align4([int]$Offset) {
	return ($Offset + 3) -band (-bnot 3)
}

function Get-VsVersionInfoFields([byte[]]$Blob) {
	# Parses VS_VERSIONINFO StringFileInfo into a hashtable of field -> value.
	$fields = @{}
	if ($null -eq $Blob -or $Blob.Length -lt 40) { return $fields }
	$blockLen = [Math]::Min([BitConverter]::ToUInt16($Blob, 0), $Blob.Length)
	$valueLen = [BitConverter]::ToUInt16($Blob, 2)
	$off = Format-Align4 (6 + (2 * (15 + 1)))   # header + "VS_VERSION_INFO" + null
	if ($valueLen -gt 0) { $off = Format-Align4 ($off + $valueLen) }

	while ($off -lt ($blockLen - 6)) {
		$childLen = [BitConverter]::ToUInt16($Blob, $off)
		if ($childLen -le 0) { break }
		$keyInfo = Read-VsSzKey $Blob ($off + 6)
		$childKey = $keyInfo[0]
		$body = Format-Align4 $keyInfo[1]

		if ($childKey -ieq 'StringFileInfo') {
			$innerEnd = [Math]::Min(($off + $childLen), $blockLen)
			$tableOff = $body
			while ($tableOff -lt ($innerEnd - 6)) {
				$tableLen = [BitConverter]::ToUInt16($Blob, $tableOff)
				if ($tableLen -le 0) { break }
				$tKeyInfo = Read-VsSzKey $Blob ($tableOff + 6)
				$strOff = Format-Align4 $tKeyInfo[1]
				$strEnd = [Math]::Min(($tableOff + $tableLen), $innerEnd)
				while ($strOff -lt ($strEnd - 6)) {
					$strLen = [BitConverter]::ToUInt16($Blob, $strOff)
					if ($strLen -le 0) { break }
					$sKeyInfo = Read-VsSzKey $Blob ($strOff + 6)
					$field = $sKeyInfo[0]
					$valOff = Format-Align4 $sKeyInfo[1]
					$probe = $valOff
					while (($probe + 1) -lt $strEnd -and [BitConverter]::ToUInt16($Blob, $probe) -ne 0) { $probe += 2 }
					$value = if ($probe -gt $valOff) { [Text.Encoding]::Unicode.GetString($Blob, $valOff, $probe - $valOff) } else { '' }
					if ($field -and -not $fields.ContainsKey($field)) { $fields[$field] = $value }
					$strOff = Format-Align4 ($strOff + $strLen)
				}
				$tableOff = Format-Align4 ($tableOff + $tableLen)
			}
		}
		$off = Format-Align4 ($off + $childLen)
	}
	return $fields
}

function Get-PeExportNames([byte[]]$Bytes) {
	# Minimal PE export-directory reader; used to identify registrable COM
	# modules (DllRegisterServer) without relying on file names.
	$names = [System.Collections.Generic.List[string]]::new()
	$headers = Get-PeHeaders $Bytes
	if ($null -eq $headers) { return $names }
	$sections = $headers.Sections
	$expRva = [BitConverter]::ToUInt32($Bytes, $headers.DataDirOff)   # directory index 0
	if ($expRva -eq 0) { return $names }
	$expOff = Resolve-PeOffset $Bytes $expRva $sections
	if ($null -eq $expOff) { return $names }
	$numNames = [BitConverter]::ToUInt32($Bytes, $expOff + 24)
	$namesRva = [BitConverter]::ToUInt32($Bytes, $expOff + 32)
	$namesOff = Resolve-PeOffset $Bytes $namesRva $sections
	if ($null -eq $namesOff) { return $names }
	for ($i = 0; $i -lt $numNames; $i++) {
		if (($namesOff + 4 * $i + 4) -gt $Bytes.Length) { break }
		$nameRva = [BitConverter]::ToUInt32($Bytes, $namesOff + 4 * $i)
		$nOff = Resolve-PeOffset $Bytes $nameRva $sections
		if ($null -eq $nOff) { continue }
		$end = $nOff
		while ($end -lt $Bytes.Length -and $Bytes[$end] -ne 0) { $end++ }
		$names.Add([Text.Encoding]::ASCII.GetString($Bytes, $nOff, $end - $nOff))
	}
	return $names
}

# ------------------------------------------------------------ static gate

function Add-PatternFindings {
	param($Findings, [string[]]$Patterns, $AllowReason, [string]$File, [string]$Kind, [string]$Token, [string]$AllowToken = $Token)
	# Records one finding per blocklist pattern contained in $Token (ordinal,
	# case-insensitive substring match). $AllowReason is a scriptblock mapping
	# $AllowToken to an allowlist reason (marking the finding allowed instead of
	# a violation), or $null for checks that can never be allowlisted.
	# $AllowToken differs from $Token for zip entries, where the allowlist keys
	# on the bare entry name while the gate matches the full entry path.
	foreach ($pattern in $Patterns) {
		if ($Token.IndexOf($pattern, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
			$allowed = if ($AllowReason) { & $AllowReason $AllowToken } else { $null }
			$Findings.Add([pscustomobject]@{ file = $File; kind = $Kind; token = $Token; pattern = $pattern; allowed = [bool]$allowed; reason = $allowed })
		}
	}
}

function Invoke-VcamStaticGate {
	param($Blocklist, [string]$PackagePath)

	if (-not (Test-Path $PackagePath)) { throw "Package not found: $PackagePath" }
	$resolved = (Resolve-Path $PackagePath).Path
	Add-Type -AssemblyName System.IO.Compression.FileSystem

	$gate = $Blocklist.static_gate
	$patterns = @($gate.patterns)
	$allowlist = @{}
	foreach ($prop in $gate.allowlist.PSObject.Properties) { $allowlist[$prop.Name.ToLowerInvariant()] = $prop.Value }
	$guidBytes = ConvertTo-GuidBytes $gate.clsid_resource

	$zip = [System.IO.Compression.ZipFile]::OpenRead($resolved)
	try {
		# 1. Locate the virtualcam DLL by CLSID resource (never by file name).
		# The main win-dshow plugin also compiles the GUID into its binary, so a
		# subject must additionally be a registrable COM module (DllRegisterServer
		# export) - which is exactly what regsvr32 registers as the camera filter.
		$targets = @()
		foreach ($entry in $zip.Entries) {
			if ($entry.Name -notmatch '\.(dll|ax)$') { continue }
			$stream = $entry.Open()
			try {
				$ms = [System.IO.MemoryStream]::new()
				$stream.CopyTo($ms)
				$bytes = $ms.ToArray()
			} finally { $stream.Dispose() }
			if (-not (Test-BytePattern $bytes $guidBytes)) { continue }
			if (-not ((Get-PeExportNames $bytes) -contains 'DllRegisterServer')) { continue }
			$targets += [pscustomobject]@{ Entry = $entry; Bytes = $bytes }
		}
		if ($targets.Count -eq 0) {
			throw ("Gate failed closed: no DLL containing the virtualcam CLSID resource " +
				"($($gate.clsid_resource)) found in package. Cannot verify - treating as violation.")
		}

		$findings = [System.Collections.Generic.List[object]]::new()
		$allowReason = { param([string]$token) $key = $token.ToLowerInvariant(); if ($allowlist.ContainsKey($key)) { $allowlist[$key] } }

		foreach ($target in $targets) {
			$file = $target.Entry.FullName

			# 2. File name of the virtualcam DLL (never allowlisted).
			Add-PatternFindings $findings $patterns $null $file 'filename' $target.Entry.Name

			# 3. VERSIONINFO string fields (7 gate fields).
			$vi = Get-VsVersionInfoFields (Get-VersionResourceBlob $target.Bytes)
			foreach ($field in @('CompanyName', 'FileDescription', 'ProductName', 'Comments', 'LegalCopyright', 'InternalName', 'OriginalFilename')) {
				$value = $vi[$field]
				if (-not $value) { continue }
				Add-PatternFindings $findings $patterns $allowReason $file "versioninfo:$field" $value
			}

			# 4. Embedded strings, UTF-8 and UTF-16.
			foreach ($token in (Get-PrintableStrings $target.Bytes)) {
				Add-PatternFindings $findings $patterns $allowReason $file 'string-utf8' $token
			}
			foreach ($token in (Get-Utf16LeStrings $target.Bytes)) {
				Add-PatternFindings $findings $patterns $allowReason $file 'string-utf16' $token
			}
		}

		# 5. Zip entry names of the virtualcam's own artifacts (the DLL's
		# directory + the DLL entries): catches stale .bat names and leftover
		# PDBs next to the module. The OBS application's own data tree is not
		# part of the gate - the fork scrubs the camera device, not the app.
		$subjectDirs = @($targets | ForEach-Object {
				$dir = $_.Entry.FullName -replace '[^/]*$', ''
				if ($dir) { $dir.ToLowerInvariant() }
			} | Sort-Object -Unique)
		$subjectNames = @($targets | ForEach-Object { $_.Entry.FullName.ToLowerInvariant() })
		foreach ($entry in $zip.Entries) {
			$fullName = $entry.FullName.ToLowerInvariant()
			$inScope = ($subjectNames -contains $fullName) -or (($subjectDirs | Where-Object { $fullName.StartsWith($_) }).Count -gt 0)
			if (-not $inScope) { continue }
			Add-PatternFindings $findings $patterns $allowReason $entry.FullName 'zip-entry-name' $entry.FullName $entry.Name
		}

		$violations = @($findings | Where-Object { -not $_.allowed })
		return [pscustomobject]@{
			package          = $resolved
			gate             = $gate.definition
			dlls_scanned     = @($targets.Entry.FullName)
			total_findings   = $findings.Count
			allowed_findings = @($findings | Where-Object { $_.allowed })
			violations       = $violations
			pass             = ($violations.Count -eq 0)
		}
	} finally { $zip.Dispose() }
}

# ------------------------------------------------------- C# COM helper (Windows)

function Add-VcamComType {
	if (-not ('VCamAudit.Native' -as [type])) {
		Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

namespace VCamAudit
{
    public static class Native
    {
        [DllImport("ole32.dll")]
        public static extern int CoInitializeEx(IntPtr pvReserved, uint dwCoInit);

        [DllImport("ole32.dll")]
        public static extern void CoUninitialize();

        [DllImport("ole32.dll", CharSet = CharSet.Unicode)]
        public static extern int CreateBindCtx(uint reserved, out IBindCtx ppbc);

        [ComImport, Guid("62BE5D10-60EB-11d0-BD3B-00A0C911CE86")]
        public class SystemDeviceEnum { }

        [ComImport, Guid("29840822-5B84-11D0-BD3B-00A0C911CE86"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        public interface ICreateDevEnum
        {
            [PreserveSig]
            int CreateClassEnumerator(ref Guid classType, out IEnumMoniker ppEnumMoniker, int dwFlags);
        }

        [ComImport, Guid("55272A00-42CB-11CE-8135-00AA004BB851"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        public interface IPropertyBag
        {
            [PreserveSig]
            int Read([MarshalAs(UnmanagedType.LPWStr)] string pszPropName, out object pVar, IntPtr pErrorLog);

            [PreserveSig]
            int Write([MarshalAs(UnmanagedType.LPWStr)] string pszPropName, ref object pVar);
        }

        // IAMCameraControl vtable order per strmif.h: GetRange, Set, Get
        [ComImport, Guid("C6E13360-30AC-11d0-A18C-00A0C9118956"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        public interface IAMCameraControl
        {
            [PreserveSig]
            int GetRange(int Property, out int pMin, out int pMax, out int pSteppingDelta, out int pDefault, out int pCapsFlags);

            [PreserveSig]
            int Set(int Property, int lValue, int Flags);

            [PreserveSig]
            int Get(int Property, out int lValue, out int Flags);
        }

        // IAMVideoProcAmp vtable order per strmif.h: GetRange, Set, Get
        [ComImport, Guid("C6E13340-30AC-11d0-A18C-00A0C9118956"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        public interface IAMVideoProcAmp
        {
            [PreserveSig]
            int GetRange(int Property, out int pMin, out int pMax, out int pSteppingDelta, out int pDefault, out int pCapsFlags);

            [PreserveSig]
            int Set(int Property, int lValue, int Flags);

            [PreserveSig]
            int Get(int Property, out int lValue, out int Flags);
        }

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern IntPtr OpenFileMappingW(uint dwDesiredAccess, bool bInheritHandle, string lpName);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool CloseHandle(IntPtr hObject);

        public const uint FILE_MAP_READ = 0x0004;
        public const uint COINIT_APARTMENTTHREADED = 0x2;
        public const int CLSCTX_INPROC_SERVER = 0x1;

        public static int InitializeCom()
        {
            // RPC_E_CHANGED_MODE means the thread is already COM-initialized in
            // another apartment model; enumeration works in either model.
            int hr = CoInitializeEx(IntPtr.Zero, COINIT_APARTMENTTHREADED);
            if (hr == unchecked((int)0x80010106)) return 0;
            return hr;
        }

        public static object CreateDeviceEnum()
        {
            return new SystemDeviceEnum();
        }

        public static int CreateClassEnumerator(object devEnum, ref Guid category, out IEnumMoniker enumerator)
        {
            return ((ICreateDevEnum)devEnum).CreateClassEnumerator(ref category, out enumerator, 0);
        }

        public static IBindCtx CreateBindCtx()
        {
            IBindCtx ctx;
            int hr = CreateBindCtx(0, out ctx);
            if (hr != 0) Marshal.ThrowExceptionForHR(hr);
            return ctx;
        }

        public static string GetMonikerDisplayName(IBindCtx ctx, IMoniker moniker)
        {
            string name;
            moniker.GetDisplayName(ctx, null, out name);
            return name;
        }

        public static object GetMonikerPropertyBag(IBindCtx ctx, IMoniker moniker)
        {
            Guid iid = new Guid("55272A00-42CB-11CE-8135-00AA004BB851");
            object storage;
            moniker.BindToStorage(ctx, null, ref iid, out storage);
            return storage;
        }

        public static string ReadPropertyBag(object propertyBag, string name)
        {
            IPropertyBag bag = (IPropertyBag)propertyBag;
            object value;
            int hr = bag.Read(name, out value, IntPtr.Zero);
            if (hr != 0 || value == null) return null;
            try { return value.ToString(); }
            catch { return null; }
        }

        public static object BindMonikerToObject(IBindCtx ctx, IMoniker moniker, string iidText)
        {
            Guid iid = new Guid(iidText);
            object obj;
            moniker.BindToObject(ctx, null, ref iid, out obj);
            return obj;
        }

        public static string ProbeCameraControls(object filter)
        {
            // Queries the filter for camera-control interfaces; returns a summary.
            string result = "";
            try
            {
                IAMCameraControl cc = filter as IAMCameraControl;
                if (cc != null)
                {
                    int min, max, step, def, caps;
                    // CameraControl_Exposure = 4
                    int hr = cc.GetRange(4, out min, out max, out step, out def, out caps);
                    result += "IAMCameraControl:" + (hr == 0 ? "ok" : "hr=0x" + hr.ToString("X8"));
                    Marshal.ReleaseComObject(cc);
                }
                else
                {
                    result += "IAMCameraControl:absent";
                }
            }
            catch (Exception ex) { result += "IAMCameraControl:error(" + ex.GetType().Name + ")"; }

            try
            {
                IAMVideoProcAmp vp = filter as IAMVideoProcAmp;
                if (vp != null)
                {
                    int min, max, step, def, caps;
                    // VideoProcAmp_Brightness = 0
                    int hr = vp.GetRange(0, out min, out max, out step, out def, out caps);
                    result += " IAMVideoProcAmp:" + (hr == 0 ? "ok" : "hr=0x" + hr.ToString("X8"));
                    Marshal.ReleaseComObject(vp);
                }
                else
                {
                    result += " IAMVideoProcAmp:absent";
                }
            }
            catch (Exception ex) { result += " IAMVideoProcAmp:error(" + ex.GetType().Name + ")"; }

            return result.Trim();
        }

        public static bool ProbeNamedObject(string name)
        {
            IntPtr h = OpenFileMappingW(FILE_MAP_READ, false, name);
            if (h != IntPtr.Zero)
            {
                CloseHandle(h);
                return true;
            }
            return false;
        }
    }
}
'@
	}
}

# -------------------------------------------------------------- inventory

function Get-VcamInventory {
	param($Blocklist)

	if (-not $IsWindows) {
		throw "The scan/diff subcommands enumerate live Windows COM/registry state; run them on Windows 10/11. Use the 'static' subcommand for cross-platform CI gating."
	}
	Add-VcamComType
	[VCamAudit.Native]::InitializeCom() | Out-Null

	$inventory = [ordered]@{
		meta             = [ordered]@{
			timestamp  = (Get-Date).ToUniversalTime().ToString('o')
			host       = $env:COMPUTERNAME
			os         = [System.Environment]::OSVersion.VersionString
			ps_version = $PSVersionTable.PSVersion.ToString()
			mode       = 'scan'
		}
		dshow_devices    = @()
		system_cameras   = @()
		pnp_devices      = @()
		named_objects    = @()
		config_artifacts = @()
	}

	# --- DirectShow video input devices (V1/V2/V3/V5/V7 source data) ---
	$devEnum = [VCamAudit.Native]::CreateDeviceEnum()
	$category = [Guid]'860BB310-5D01-11D0-BD3B-00A0C911CE86'   # CLSID_VideoInputDeviceCategory
	$enumMoniker = $null
	$hr = [VCamAudit.Native]::CreateClassEnumerator($devEnum, [ref]$category, [ref]$enumMoniker)
	if ($hr -eq 0 -and $enumMoniker) {
		$bindCtx = [VCamAudit.Native]::CreateBindCtx()
		$monikers = @($null)
		$fetched = [Runtime.InteropServices.Marshal]::AllocHGlobal(4)
		try {
			while ($enumMoniker.Next(1, $monikers, $fetched) -eq 0) {
				$mk = $monikers[0]
				$displayName = [VCamAudit.Native]::GetMonikerDisplayName($bindCtx, $mk)
				$clsid = ''
				if ($displayName -match '\{([0-9A-Fa-f\-]{36})\}\s*$') { $clsid = $Matches[1] }

				$friendlyName = $null; $description = $null; $bagPath = $null
				$bag = $null
				try {
					$bag = [VCamAudit.Native]::GetMonikerPropertyBag($bindCtx, $mk)
					if ($bag) {
						$friendlyName = [VCamAudit.Native]::ReadPropertyBag($bag, 'FriendlyName')
						$description = [VCamAudit.Native]::ReadPropertyBag($bag, 'Description')
						$bagPath = [VCamAudit.Native]::ReadPropertyBag($bag, 'DevicePath')
					}
				} catch { } finally { if ($bag) { [Runtime.InteropServices.Marshal]::ReleaseComObject($bag) | Out-Null } }

				# Registry cross-check: instance key under the device category.
				$instancePath = "Registry::HKEY_CLASSES_ROOT\CLSID\{$category}\Instance\{$clsid}"
				$regDevicePath = $null; $inproc = $null
				if (Test-Path $instancePath) {
					$ip = Get-ItemProperty -Path $instancePath -ErrorAction SilentlyContinue
					if ($ip) { $regDevicePath = $ip.DevicePath }
					$inprocKey = "Registry::HKEY_CLASSES_ROOT\CLSID\{$clsid}\InprocServer32"
					if (Test-Path $inprocKey) {
						$inproc = (Get-ItemProperty -Path $inprocKey -ErrorAction SilentlyContinue).'(default)'
					}
				}

				# V7 best-effort: instantiate the filter and query camera controls.
				$controls = 'not-probed'
				try {
					$filterObj = [VCamAudit.Native]::BindMonikerToObject($bindCtx, $mk, '56A868A9-0AD4-11CE-B03A-0020AF0BA770')   # IID_IBaseFilter
					if ($filterObj) {
						$controls = [VCamAudit.Native]::ProbeCameraControls($filterObj)
						[Runtime.InteropServices.Marshal]::ReleaseComObject($filterObj) | Out-Null
					}
				} catch {
					$controls = 'probe-error'
				}

				$inventory.dshow_devices += [pscustomobject]@{
					moniker             = $displayName
					clsid               = $clsid
					friendly_name       = $friendlyName
					description         = $description
					devicepath_moniker  = $bagPath
					devicepath_registry = $regDevicePath
					inprocserver        = $inproc
					camera_controls     = $controls
				}
				[Runtime.InteropServices.Marshal]::ReleaseComObject($mk) | Out-Null
			}
		} finally {
			[Runtime.InteropServices.Marshal]::FreeHGlobal($fetched)
			[Runtime.InteropServices.Marshal]::ReleaseComObject($enumMoniker) | Out-Null
			[Runtime.InteropServices.Marshal]::ReleaseComObject($devEnum) | Out-Null
		}
	} elseif ($hr -eq 1) {
		Write-Status 'DirectShow video input category is empty on this machine.'
	} else {
		Write-Status "DirectShow enumeration failed: hr=0x$($hr.ToString('X8'))"
	}

	# --- System camera device interfaces (V3-deep/V4/V6 source data) ---
	# MF VIDCAP sources enumerate exactly the KSCATEGORY_VIDEO / KSCATEGORY_CAPTURE
	# device interfaces; DeviceClasses in the registry is that enumeration's ground truth.
	$interfaceGuids = @(
		'{E5323777-F976-4F5B-9B55-B94699C46E44}'   # KSCATEGORY_VIDEO
		'{65E8773D-8F56-11D0-A3B9-00A0C9223196}'   # KSCATEGORY_CAPTURE
	)
	$seen = @{}
	foreach ($ifGuid in $interfaceGuids) {
		$classRoot = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\DeviceClasses\$ifGuid"
		if (-not (Test-Path $classRoot)) { continue }
		foreach ($linkKey in Get-ChildItem $classRoot -ErrorAction SilentlyContinue) {
			$symbolicLink = $linkKey.PSChildName
			if ($seen.ContainsKey($symbolicLink)) { continue }
			$seen[$symbolicLink] = $true
			$props = Get-ItemProperty -Path $linkKey.PSPath -ErrorAction SilentlyContinue
			# Derive the PnP instance id from the symbolic link: ##?#USB#VID_x&PID_x#serial#{guid}
			$instanceId = $null
			if ($symbolicLink -match '^##\?#([^#]+)#([^#]+)#([^#]+)#') {
				$instanceId = ('{0}\{1}\{2}' -f $Matches[1], $Matches[2], $Matches[3]).ToUpperInvariant()
			}
			$inventory.system_cameras += [pscustomobject]@{
				symbolic_link     = $symbolicLink
				friendly_name     = $props.FriendlyName
				pnp_instance_id   = $instanceId
				interface_class   = $ifGuid
			}
		}
	}

	# --- PnP devices (V4) ---
	$pnpClasses = @('Camera', 'Image')
	$inventory.pnp_devices = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $pnpClasses -contains $_.Class } | ForEach-Object {
			[pscustomobject]@{
				instance_id     = $_.InstanceId
				class           = $_.Class
				friendly_name   = $_.FriendlyName
				manufacturer    = $_.Manufacturer
				status          = $_.Status
			}
		})

	# --- Named kernel object probes (V8) ---
	$inventory.named_objects = @($Blocklist.named_sections | ForEach-Object {
			[pscustomobject]@{
				name   = $_.name
				opened = [VCamAudit.Native]::ProbeNamedObject($_.name)
			}
		})

	# --- Config artifacts (V9) ---
	$inventory.config_artifacts = @($Blocklist.config_artifacts | ForEach-Object {
			$path = [Environment]::ExpandEnvironmentVariables($_.path)
			[pscustomobject]@{
				path   = $_.path
				exists = (Test-Path -LiteralPath $path)
			}
		})

	[VCamAudit.Native]::CoUninitialize()
	return $inventory
}

# ------------------------------------------------------------- vector rows

function Get-VcamVectors {
	param($Inventory, $Blocklist)

	$rows = [System.Collections.Generic.List[object]]::new()
	foreach ($collector in (Get-ChildItem (Join-Path $script:ToolRoot 'vectors') -Filter '*.ps1' | Sort-Object Name)) {
		. $collector.FullName
	}

	foreach ($fn in @('Get-V1Vector', 'Get-V2Vector', 'Get-V3Vector', 'Get-V4Vector', 'Get-V5Vector', 'Get-V6Vector', 'Get-V7Vector', 'Get-V8Vector', 'Get-V9Vector')) {
		$cmd = Get-Command $fn -ErrorAction SilentlyContinue
		if ($cmd) {
			foreach ($row in (& $fn $Inventory $Blocklist)) { $rows.Add($row) }
		}
	}
	return @($rows)
}

# ------------------------------------------------------------------- diff

function Invoke-VcamDiff {
	param($Inventory, $Blocklist, [string]$BaselinePath, [string]$TargetClsid, [string]$RefClsid)

	if (-not $BaselinePath -or -not (Test-Path $BaselinePath)) { throw "Baseline file not found: $BaselinePath" }
	$baseline = Get-Content $BaselinePath -Raw | ConvertFrom-Json

	$targets = @($Inventory.dshow_devices | Where-Object { $_.clsid -ieq $TargetClsid })
	if ($targets.Count -gt 1) {
		throw "Ambiguity: $($targets.Count) DShow devices share CLSID $TargetClsid in the live scan. Join must be unique - refusing to guess."
	}
	if ($targets.Count -eq 0) {
		throw "Target device CLSID $TargetClsid not found in the live scan. Is the virtual camera installed?"
	}
	$target = $targets[0]

	$baseTargets = @($baseline.dshow_devices | Where-Object { $_.clsid -ieq $TargetClsid })
	if ($baseTargets.Count -gt 1) {
		throw "Ambiguity: target CLSID appears $($baseTargets.Count) times in the baseline scan. Refusing to guess."
	}

	if ($RefClsid) {
		$refs = @($baseline.dshow_devices | Where-Object { $_.clsid -ieq $RefClsid })
		if ($refs.Count -ne 1) { throw "Reference CLSID $RefClsid matched $($refs.Count) devices in baseline; expected exactly 1." }
		$reference = $refs[0]
	} else {
		# Default reference: a baseline device with a genuine USB DevicePath.
		$refs = @($baseline.dshow_devices | Where-Object {
				($_.clsid -ine $TargetClsid) -and ($_.devicepath_moniker -match '^\\\\\?\\usb#')
			})
		if ($refs.Count -eq 0) {
			throw "No reference webcam with a USB DevicePath found in the baseline. Capture the baseline on a machine with a physical webcam, or pass -ReferenceClsid."
		}
		if ($refs.Count -gt 1) {
			throw "Ambiguity: $($refs.Count) USB-webcam candidates in baseline. Pass -ReferenceClsid with one of: $($refs.clsid -join ', ')"
		}
		$reference = $refs[0]
	}

	$vectors = Get-VcamVectors $Inventory $Blocklist

	# Join rule: per-device vectors join by CLSID (never by friendly name - the
	# virtual camera deliberately shares the reference camera's name); the
	# machine-level vectors (V8/V9, empty clsid) join by vector alone.
	$severity = @{ FAIL = 0; WARN = 1; PASS = 2 }
	$targetRows = @($vectors | Where-Object { $_.clsid -ieq $TargetClsid })
	$machineRows = @($vectors | Where-Object { -not $_.clsid })
	$baseRows = @($baseline.vectors | Where-Object { $_.clsid -ieq $reference.clsid })
	$baseMachine = @($baseline.vectors | Where-Object { -not $_.clsid })

	$comparison = [System.Collections.Generic.List[object]]::new()
	foreach ($vectorId in @('V1', 'V2', 'V3', 'V4', 'V5', 'V6', 'V7', 'V8', 'V9')) {
		$t = @($targetRows + $machineRows | Where-Object { $_.vector -eq $vectorId })
		$r = @($baseRows + $baseMachine | Where-Object { $_.vector -eq $vectorId })
		if ($t.Count -gt 1 -or $r.Count -gt 1) {
			throw "Ambiguity: vector $vectorId produced multiple rows (target=$($t.Count), reference=$($r.Count)). Join must be unique."
		}
		$tv = if ($t.Count) { $t[0].verdict } else { 'MISSING' }
		$rv = if ($r.Count) { $r[0].verdict } else { 'MISSING' }
		$final = $tv
		if ($severity.ContainsKey($rv) -and $severity.ContainsKey($tv) -and $severity[$rv] -lt $severity[$tv]) { $final = $rv }
		$comparison.Add([pscustomobject]@{
				vector            = $vectorId
				target_value      = if ($t.Count) { $t[0].value } else { $null }
				target_verdict    = $tv
				reference_value   = if ($r.Count) { $r[0].value } else { $null }
				reference_verdict = $rv
				verdict           = $final
			})
	}
	return [pscustomobject]@{
		meta            = $Inventory.meta
		target          = $target
		target_baseline = $baseTargets
		reference       = $reference
		vectors         = $comparison
	}
}

# ------------------------------------------------------------------ main

$blocklist = Get-Blocklist -Path $BlocklistPath

switch ($Command) {
	'static' {
		if (-not $Package) { throw "static requires -Package <zip>" }
		$result = Invoke-VcamStaticGate -Blocklist $blocklist -PackagePath $Package
		if ($Json) {
			$result | ConvertTo-Json -Depth 8
		} else {
			Write-Status "Package: $($result.package)"
			Write-Status "Virtualcam DLL(s) located by CLSID resource: $($result.dlls_scanned -join ', ')"
			if ($result.allowed_findings.Count -gt 0) {
				Write-Status "Allowed matches (documented in blocklist.json):"
				$result.allowed_findings | ForEach-Object { Write-Host ("  ALLOWED  {0}  {1}  matched '{2}'" -f $_.file, $_.kind, $_.pattern) }
			}
			if ($result.pass) {
				Write-Status "PASS - no violations ($($result.total_findings) total matches, all allowlisted)."
			} else {
				Write-Host ""
				Write-Host "FAIL - $($result.violations.Count) violation(s):" -ForegroundColor Red
				$result.violations | ForEach-Object {
					Write-Host ("  {0}  [{1}]  pattern '{2}' in token: {3}" -f $_.file, $_.kind, $_.pattern, $_.token)
				}
			}
		}
		if ($OutFile) { $result | ConvertTo-Json -Depth 8 | Set-Content -Path $OutFile -Encoding utf8NoBOM }
		if (-not $result.pass) { exit 1 }
		exit 0
	}

	'scan' {
		$inventory = Get-VcamInventory -Blocklist $blocklist
		$vectors = Get-VcamVectors $Inventory $blocklist
		$report = [pscustomobject]@{
			meta      = $inventory.meta
			dshow     = $inventory.dshow_devices
			cameras   = $inventory.system_cameras
			pnp       = $inventory.pnp_devices
			named     = $inventory.named_objects
			artifacts = $inventory.config_artifacts
			vectors   = $vectors
		}
		if ($Json) {
			$json = $report | ConvertTo-Json -Depth 8
			if ($OutFile) { $json | Set-Content -Path $OutFile -Encoding utf8NoBOM } else { $json }
		} else {
			$report.vectors | Format-Table vector, device, verdict, value -AutoSize | Out-String | Write-Host
			if ($OutFile) { $report | ConvertTo-Json -Depth 8 | Set-Content -Path $OutFile -Encoding utf8NoBOM }
		}
		exit 0
	}

	'diff' {
		$inventory = Get-VcamInventory -Blocklist $blocklist
		$comparison = Invoke-VcamDiff -Inventory $inventory -Blocklist $blocklist -BaselinePath $Baseline -TargetClsid $Clsid -RefClsid $ReferenceClsid
		if ($Json) {
			$json = $comparison | ConvertTo-Json -Depth 8
			if ($OutFile) { $json | Set-Content -Path $OutFile -Encoding utf8NoBOM } else { $json }
		} else {
			Write-Status "Target:    $($comparison.target.friendly_name) (CLSID $($comparison.target.clsid))"
			Write-Status "Reference: $($comparison.reference.friendly_name) (CLSID $($comparison.reference.clsid))"
			$comparison.vectors | Format-Table vector, verdict, target_verdict, target_value -AutoSize | Out-String | Write-Host
			if ($OutFile) { $comparison | ConvertTo-Json -Depth 8 | Set-Content -Path $OutFile -Encoding utf8NoBOM }
		}
		exit 0
	}
}
