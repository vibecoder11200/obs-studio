# V9: config-directory artifacts left by virtual cameras (e.g. the OBS
# virtualcam resolution file). Machine-level vector.
function Get-V9Vector {
	param($Inventory, $Blocklist)
	$found = @($Inventory.config_artifacts | Where-Object { $_.exists })
	$value = ($Inventory.config_artifacts | ForEach-Object { "$($_.path)=$( if ($_.exists) { 'EXISTS' } else { 'absent' })" }) -join ', '
	[pscustomobject]@{
		vector  = 'V9'
		device  = '(machine)'
		clsid   = ''
		value   = $value
		verdict = if ($found.Count) { 'FAIL' } else { 'PASS' }
		reason  = if ($found.Count) { "config artifacts present: $($found.path -join ', ')" } else { 'no known virtual-camera config artifact found' }
	}
}
