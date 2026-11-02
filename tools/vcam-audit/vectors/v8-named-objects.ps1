# V8: named kernel objects (shared-memory sections) with known virtual-camera
# names, probed via OpenFileMappingW. Machine-level vector: run while the
# virtual camera output is active for full coverage.
function Get-V8Vector {
	param($Inventory, $Blocklist)
	$open = @($Inventory.named_objects | Where-Object { $_.opened })
	$value = ($Inventory.named_objects | ForEach-Object { "$($_.name)=$( if ($_.opened) { 'OPEN' } else { 'none' })" }) -join ', '
	[pscustomobject]@{
		vector  = 'V8'
		device  = '(machine)'
		clsid   = ''
		value   = $value
		verdict = if ($open.Count) { 'FAIL' } else { 'PASS' }
		reason  = if ($open.Count) { "named sections visible while probing: $($open.name -join ', ')" } else { 'no known virtual-camera named section opened' }
	}
}
