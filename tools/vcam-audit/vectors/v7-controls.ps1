# V7: camera controls (IAMCameraControl / IAMVideoProcAmp) - best effort.
# Physical webcams typically answer; pure software filters usually do not.
function Get-V7Vector {
	param($Inventory, $Blocklist)
	foreach ($dev in $Inventory.dshow_devices) {
		$value = $dev.camera_controls
		$verdict = 'WARN'
		$reason = 'camera-control probe did not complete (best-effort vector)'
		if ($value -match ':ok') {
			$verdict = 'PASS'
			$reason = 'filter answers camera-control range queries like hardware cameras'
		} elseif ($value -match ':absent') {
			$verdict = 'FAIL'
			$reason = 'filter exposes neither IAMCameraControl nor IAMVideoProcAmp'
		}
		[pscustomobject]@{
			vector  = 'V7'
			device  = $dev.friendly_name
			clsid   = $dev.clsid
			value   = $value
			verdict = $verdict
			reason  = $reason
		}
	}
}
