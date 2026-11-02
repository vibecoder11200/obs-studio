# V5: binary metadata (DLL VERSIONINFO fields + file name) against the
# blocklist metadata patterns.
function Get-V5Vector {
	param($Inventory, $Blocklist)
	foreach ($dev in $Inventory.dshow_devices) {
		$dllPath = $dev.inprocserver
		$verdict = 'WARN'
		$reason = 'no InprocServer32 path - cannot read binary metadata'
		$value = '(unavailable)'
		$fileName = $null

		if ($dllPath) {
			$fileName = [System.IO.Path]::GetFileName($dllPath)
			$matchesFound = [System.Collections.Generic.List[string]]::new()
			foreach ($pattern in $Blocklist.metadata_patterns) {
				if ($fileName -and $fileName.ToLowerInvariant().Contains($pattern.ToLowerInvariant())) {
					$matchesFound.Add("filename contains '$pattern'")
				}
			}
			$fields = @{}
			try {
				$bytes = [System.IO.File]::ReadAllBytes($dllPath)
				$fields = Get-VsVersionInfoFields (Get-VersionResourceBlob $bytes)
			} catch {
				$matchesFound.Add("metadata unreadable: $($_.Exception.Message)")
			}
			foreach ($field in @('CompanyName', 'FileDescription', 'ProductName', 'Comments', 'LegalCopyright', 'InternalName', 'OriginalFilename')) {
				$val = $fields[$field]
				if (-not $val) { continue }
				foreach ($pattern in $Blocklist.metadata_patterns) {
					if ($val.ToLowerInvariant().Contains($pattern.ToLowerInvariant())) {
						$matchesFound.Add("$field='$val' contains '$pattern'")
					}
				}
			}
			if ($fields.Count -eq 0 -and -not ($matchesFound | Where-Object { $_ -like 'metadata unreadable*' })) {
				$verdict = 'WARN'
				$reason = 'DLL has no VERSIONINFO string data (absence itself is atypical for hardware drivers)'
			} elseif ($matchesFound.Count) {
				$verdict = 'FAIL'
				$reason = $matchesFound -join '; '
			} else {
				$verdict = 'PASS'
				$reason = 'no blocklist metadata pattern in file name or VERSIONINFO fields'
			}
			$value = "$fileName | Company='$($fields['CompanyName'])' Product='$($fields['ProductName'])' Desc='$($fields['FileDescription'])'"
		}
		[pscustomobject]@{
			vector  = 'V5'
			device  = $dev.friendly_name
			clsid   = $dev.clsid
			value   = $value
			verdict = $verdict
			reason  = $reason
		}
	}
}
