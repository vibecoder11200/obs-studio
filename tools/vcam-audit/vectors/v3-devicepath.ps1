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

				# Serial-format coherence: when the pair is a known camera
				# identity, the serial must match that hardware's real serial
				# format. WARN-only by design (never FAIL): the location-ID
				# form is itself Windows-generated, so a mismatch there is
				# informational, not distinguishing evidence.
				if ($path -imatch '^\\\\\?\\usb#vid_([0-9a-f]{4})&pid_([0-9a-f]{4})(&mi_[0-9a-f]{2})?#([^#]+)#') {
					$vid = $Matches[1]
					$pidVal = $Matches[2]
					$serial = $Matches[4]
					$expected = $Blocklist.serial_formats |
						Where-Object { $_.vid -ieq $vid -and $_.pid -ieq $pidVal } |
						Select-Object -First 1
					if ($expected) {
						$formatPatterns = @{
							'8HEX'     = '^[0-9A-F]{8}$'
							'8DIGIT'   = '^[0-9]{8}$'
							'12ALNUM'  = '^[0-9]{4}[A-Z0-9]{8}$'
							'ELGATO'   = '^FW[0-9]{2}K1A[0-9]{5}$'
							'LOCATION' = '^6&[0-9a-f]{8}&0&\d{4}$'
						}
						$serialPattern = $formatPatterns[$expected.format]
						if ($serialPattern -and ($serial -cnotmatch $serialPattern)) {
							$verdict = 'WARN'
							$reason = "serial '$serial' does not match the recorded ${vid}:${pidVal} format $($expected.format); regenerate the identity's serial"
						}
					}
				}
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
