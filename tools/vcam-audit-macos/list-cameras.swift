// Lists video capture devices the way an AVFoundation app sees them:
// one line per device, tab-separated: name, uniqueID, modelID.
//
// Run with: swift list-cameras.swift
// (a helper for audit-virtualcam.sh; not a `swift -e` one-liner, which is
// unverified and portable-hostile)

import AVFoundation

let deviceTypes: [AVCaptureDevice.DeviceType]
if #available(macOS 14.0, *) {
    deviceTypes = [.builtInWideAngleCamera, .external]
} else {
    deviceTypes = [.builtInWideAngleCamera, .externalUnknown]
}

let session = AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes, mediaType: .video, position: .unspecified)

let devices = session.devices
if devices.isEmpty {
    print("<no-video-devices>")
    exit(0)
}

for device in devices {
    print("\(device.localizedName)\t\(device.uniqueID)\t\(device.modelID)")
}
