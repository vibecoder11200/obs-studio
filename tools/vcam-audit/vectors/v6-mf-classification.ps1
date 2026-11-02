# V6: presence as a system camera device (MF/WebRTC-visible) and hardware vs
# software classification. Ground truth: KSCATEGORY_VIDEO/CAPTURE device
# interfaces (what MF VIDCAP enumeration returns) plus the PnP device class.
function Get-V6Vector {
	param($Inventory, $Blocklist)
	foreach ($dev in $Inventory.dshow_devices) {
		$instanceId = Get-DeviceInstanceId $dev
		$cam = @()
		if ($instanceId) {
			$cam = @($Inventory.system_cameras | Where-Object { $_.pnp_instance_id -eq $instanceId })
		}
		if (-not $cam) {
			# Fall back to friendly-name matching when no usable DevicePath exists.
			$cam = @($Inventory.system_cameras | Where-Object { $_.friendly_name -eq $dev.friendly_name })
		}
		$verdict = 'FAIL'
		$reason = 'not exposed as a system camera device interface (MF-only and WebRTC apps cannot enumerate it)'
		$value = '(absent)'
		if ($cam.Count -ge 1) {
			$pnp = @($Inventory.pnp_devices | Where-Object { $_.instance_id -eq $cam[0].pnp_instance_id })
			$class = if ($pnp.Count) { $pnp[0].class } else { '(unknown)' }
			$value = "$($cam[0].symbolic_link) class=$class"
			if ($class -in @('Camera', 'Image')) {
				$verdict = 'PASS'
				$reason = 'present as a hardware-class camera device interface'
			} else {
				$verdict = 'WARN'
				$reason = "present as system camera but classified '$class' (software device classification is detectable)"
			}
		}
		[pscustomobject]@{
			vector  = 'V6'
			device  = $dev.friendly_name
			clsid   = $dev.clsid
			value   = $value
			verdict = $verdict
			reason  = $reason
		}
	}
}
