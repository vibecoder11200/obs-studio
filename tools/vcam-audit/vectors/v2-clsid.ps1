# V2: known CLSID blocklist.
function Get-V2Vector {
	param($Inventory, $Blocklist)
	foreach ($dev in $Inventory.dshow_devices) {
		$known = @($Blocklist.clsids | Where-Object { $_.clsid.Trim('{}') -ieq $dev.clsid.Trim('{}') })
		[pscustomobject]@{
			vector  = 'V2'
			device  = $dev.friendly_name
			clsid   = $dev.clsid
			value   = $dev.clsid
			verdict = if ($known.Count) { 'FAIL' } else { 'PASS' }
			reason  = if ($known.Count) { "CLSID is a known virtual camera: $($known[0].product)" } else { 'CLSID not in blocklist' }
		}
	}
}
