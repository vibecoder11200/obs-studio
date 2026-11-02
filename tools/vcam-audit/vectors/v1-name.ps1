# V1: friendly-name / substring detection (blocklist name patterns).
function Get-V1Vector {
	param($Inventory, $Blocklist)
	foreach ($dev in $Inventory.dshow_devices) {
		$name = $dev.friendly_name
		$matched = @()
		foreach ($entry in $Blocklist.name_patterns) {
			if ($name -and $name.ToLowerInvariant().Contains($entry.pattern.ToLowerInvariant())) {
				$matched += $entry.product
			}
		}
		[pscustomobject]@{
			vector  = 'V1'
			device  = $name
			clsid   = $dev.clsid
			value   = $name
			verdict = if ($matched.Count) { 'FAIL' } else { 'PASS' }
			reason  = if ($matched.Count) { "name matches blocklist patterns: $($matched -join ', ')" } else { 'no blocklist name pattern matched' }
		}
	}
}
