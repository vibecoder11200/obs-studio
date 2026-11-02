# V4: PnP devnode presence (Device Manager visibility). User-mode DShow
# filters have no devnode; this is the vector only a kernel driver or a
# Windows 11 Frame Server virtual camera can satisfy.
function Get-V4Vector {
	param($Inventory, $Blocklist)
	foreach ($dev in $Inventory.dshow_devices) {
		$instanceId = Get-DeviceInstanceId $dev
		$pnpMatch = @()
		if ($instanceId) {
			$pnpMatch = @($Inventory.pnp_devices | Where-Object { $_.instance_id -eq $instanceId })
		}
		if (-not $pnpMatch) {
			# Fall back to friendly-name matching when no usable DevicePath exists.
			$pnpMatch = @($Inventory.pnp_devices | Where-Object { $_.friendly_name -eq $dev.friendly_name })
		}
		$verdict = 'FAIL'
		$reason = 'no PnP devnode / no Device Manager entry for this device'
		$value = '(none)'
		if ($pnpMatch.Count -ge 1) {
			$value = $pnpMatch[0].instance_id
			if ($pnpMatch[0].status -eq 'OK') {
				$verdict = 'PASS'
				$reason = "PnP devnode present (class $($pnpMatch[0].class), manufacturer $($pnpMatch[0].manufacturer))"
			} else {
				$verdict = 'WARN'
				$reason = "PnP devnode present but status $($pnpMatch[0].status)"
			}
		}
		[pscustomobject]@{
			vector  = 'V4'
			device  = $dev.friendly_name
			clsid   = $dev.clsid
			value   = $value
			verdict = $verdict
			reason  = $reason
		}
	}
}
