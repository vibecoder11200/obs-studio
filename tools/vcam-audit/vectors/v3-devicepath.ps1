# V3: DevicePath string (moniker property bag + registry Instance key).
# String-level check only: a value that merely LOOKS like a USB camera path
# passes here. Whether it resolves to a real devnode is V4's job.
function Get-V3Vector {
	param($Inventory, $Blocklist)
	# Genuine paths end with the interface GUID; moniker-bag values also carry
	# a trailing symbolic-link suffix (e.g. '...\{guid}\global').
	$usbPattern = '^\\\\\?\\usb#vid_[0-9a-f]{4}&pid_[0-9a-f]{4}(&mi_[0-9a-f]{2})?#[^#]+#\{[0-9a-f\-]{36}\}(\\global)?$'
	foreach ($dev in $Inventory.dshow_devices) {
		$path = $dev.devicepath_moniker
		$source = 'moniker'
		if (-not $path) {
			$path = $dev.devicepath_registry
			$source = 'registry'
		}
		$verdict = 'FAIL'
		$reason = 'no DevicePath value (soft-registered filters get none unless one is written explicitly)'
		if ($path) {
			if ($path -imatch $usbPattern) {
				$verdict = 'PASS'
				$reason = "DevicePath ($source) has genuine-looking usb#vid&pid format (string level; resolvability is V4)"
			} else {
				$verdict = 'WARN'
				$reason = "DevicePath ($source) present but not usb# format: $path"
			}
		}
		[pscustomobject]@{
			vector  = 'V3'
			device  = $dev.friendly_name
			clsid   = $dev.clsid
			value   = if ($path) { $path } else { '(missing)' }
			verdict = $verdict
			reason  = $reason
		}
	}
}
