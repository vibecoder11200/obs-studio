// Prints one line per CMIO DAL device: name<TAB>serial-number.
//
// The serial is the DAL property kCMIOObjectPropertyElementNumberName — the
// same value the audit's V3 row evaluates. A helper script cannot read it
// through AVFoundation (which exposes no serial), so this talks to the DAL
// directly via CoreMediaIO.
//
// Run with: swift vcam-serial.swift

import CoreMediaIO

let deviceSelector = CMIOObjectPropertyAddress(
    mSelector: kCMIOHardwarePropertyDevices,
    mScope: kCMIOObjectPropertyScopeGlobal,
    mElement: kCMIOObjectPropertyElementMaster)

var size: UInt32 = 0
guard CMIOObjectGetPropertyDataSize(kCMIOObjectSystemObject, &deviceSelector, 0, nil, &size) == noErr, size > 0 else {
    print("<no-cmio-devices>")
    exit(0)
}

let count = Int(size) / MemoryLayout<CMIOObjectID>.size
var deviceIDs = [CMIOObjectID](repeating: 0, count: count)
guard CMIOObjectGetPropertyData(kCMIOObjectSystemObject, &deviceSelector, 0, nil, size, &size, &deviceIDs) == noErr else {
    print("<cmio-enumeration-failed>")
    exit(0)
}

func readStringProperty(_ objectID: CMIOObjectID, _ selector: CMIOObjectPropertySelector) -> String? {
    var address = CMIOObjectPropertyAddress(
        mSelector: selector,
        mScope: kCMIOObjectPropertyScopeGlobal,
        mElement: kCMIOObjectPropertyElementMaster)
    var dataSize: UInt32 = UInt32(MemoryLayout<CFStringRef>.size)
    var value: CFStringRef? = nil
    guard CMIOObjectGetPropertyData(objectID, &address, 0, nil, dataSize, &dataSize, &value) == noErr,
          let ref = value else {
        return nil
    }
    let str = ref as String? ?? ""
    return str
}

for deviceID in deviceIDs {
    let name = readStringProperty(deviceID, kCMIOObjectPropertyName) ?? "<no-name>"
    let serial = readStringProperty(deviceID, kCMIOObjectPropertyElementNumberName) ?? "<no-serial>"
    print("\(name)\t\(serial)")
}
