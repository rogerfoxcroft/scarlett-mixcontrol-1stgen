import Foundation
import IOKit
import IOKit.usb
import IOKit.usb.IOUSBLib

// MARK: - UUIDs (Swift can't import the CFUUIDGetConstantUUIDWithBytes macros)

private func makeUUID(_ b: UInt8...) -> CFUUID {
    precondition(b.count == 16)
    let bytes = CFUUIDBytes(
        byte0: b[0],  byte1: b[1],  byte2: b[2],  byte3: b[3],
        byte4: b[4],  byte5: b[5],  byte6: b[6],  byte7: b[7],
        byte8: b[8],  byte9: b[9],  byte10: b[10], byte11: b[11],
        byte12: b[12], byte13: b[13], byte14: b[14], byte15: b[15]
    )
    return CFUUIDCreateFromUUIDBytes(nil, bytes)
}

// C244E858-109C-11D4-91D4-0050E4C6426F
private let UUID_IOCFPlugInInterfaceID = makeUUID(
    0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4,
    0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F
)
// 9DC7B780-9EC0-11D4-A54F-000A27052861
private let UUID_IOUSBDeviceUserClientTypeID = makeUUID(
    0x9D, 0xC7, 0xB7, 0x80, 0x9E, 0xC0, 0x11, 0xD4,
    0xA5, 0x4F, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61
)
// 5C8187D0-9EF3-11D4-8B45-000A27052861 (IOUSBDeviceInterface — base, has DeviceRequest)
private let UUID_IOUSBDeviceInterfaceID100 = makeUUID(
    0x5C, 0x81, 0x87, 0xD0, 0x9E, 0xF3, 0x11, 0xD4,
    0x8B, 0x45, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61
)

// MARK: - Errors

public enum ScarlettError: Error, CustomStringConvertible {
    case deviceNotFound(vid: UInt16, pid: UInt16)
    /// A recognised 1st-gen Scarlett with no software mixer (e.g. 2i4).
    case noSoftwareMixer(modelName: String, pid: UInt16)
    case ioReturn(String, IOReturn)
    case queryInterface(HRESULT)
    case invalidArgument(String)

    public var description: String {
        switch self {
        case .deviceNotFound(let v, let p):
            return String(format: "Scarlett not found (VID 0x%04x / PID 0x%04x).", v, p)
        case .noSoftwareMixer(let name, let p):
            return String(format: "%@ (1st Gen, PID 0x%04x) has no software mixer — it is controlled from its front panel.", name, p)
        case .ioReturn(let op, let r):
            return String(format: "%@ failed: 0x%08x (%d)", op, UInt32(bitPattern: r), r)
        case .queryInterface(let h):
            return String(format: "QueryInterface failed: 0x%08x", UInt32(bitPattern: Int32(h)))
        case .invalidArgument(let m):
            return "invalid argument: \(m)"
        }
    }
}

// MARK: - ScarlettDevice
//
// Wraps an `IOUSBDeviceInterface**` and exposes the two control-transfer
// primitives the Scarlett protocol uses:
//   - controlOut(cmd, value, index, data)  →  bmRequestType 0x21, write
//   - controlIn (cmd, value, index, len)   →  bmRequestType 0xa1, read
//
// We do NOT call USBDeviceOpen — it returns kIOReturnExclusiveAccess on
// macOS because usbaudiod has the device's audio interfaces claimed.
// DeviceRequest on endpoint 0 works without opening the device.
// (See memory: project-usb-access-path.)

public final class ScarlettDevice {
    typealias DeviceIface = UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface>?>

    public static let focusriteVID: UInt16 = 0x1235

    /// The profile that matched the connected device's PID.  Drives every
    /// model-specific decision in the UI and protocol layer (byte values,
    /// matrix dimensions, hardware-switch availability).
    public let profile: DeviceProfile

    private let service: io_service_t
    private let iface: DeviceIface

    /// Open the first 1st-gen Scarlett we find on the bus.  Tries each
    /// `DeviceProfile.all` PID in turn; the matching profile is exposed
    /// as `self.profile`.
    public init() throws {
        // Rather than enumerate Focusrite-VID devices and read each one's
        // PID property (which requires fiddly Unmanaged<CFTypeRef>
        // bridging in Swift), we just ask IOKit for each known
        // {VID, PID} pair directly and take the first match.  Linear in
        // the number of known profiles, but that's only 3 today.
        var picked: (svc: io_service_t, profile: DeviceProfile)? = nil
        for profile in DeviceProfile.all {
            let match = IOServiceMatching(kIOUSBDeviceClassName) as NSMutableDictionary
            match[kUSBVendorID]  = NSNumber(value: Self.focusriteVID)
            match[kUSBProductID] = NSNumber(value: profile.productID)
            var iter: io_iterator_t = 0
            let kr = IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter)
            guard kr == KERN_SUCCESS else { continue }
            let svc = IOIteratorNext(iter)
            IOObjectRelease(iter)
            if svc != 0 {
                picked = (svc, profile)
                break
            }
        }
        guard let picked else {
            // Nothing drivable — but if a mixer-less 1st-gen model is on
            // the bus, say so rather than reporting "not found".
            for model in DeviceProfile.mixerlessModels {
                let match = IOServiceMatching(kIOUSBDeviceClassName) as NSMutableDictionary
                match[kUSBVendorID]  = NSNumber(value: Self.focusriteVID)
                match[kUSBProductID] = NSNumber(value: model.productID)
                var iter: io_iterator_t = 0
                guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) == KERN_SUCCESS
                else { continue }
                let svc = IOIteratorNext(iter)
                IOObjectRelease(iter)
                if svc != 0 {
                    IOObjectRelease(svc)
                    throw ScarlettError.noSoftwareMixer(modelName: model.modelName, pid: model.productID)
                }
            }
            throw ScarlettError.deviceNotFound(vid: Self.focusriteVID, pid: 0)
        }
        self.service = picked.svc
        self.profile = picked.profile

        var pluginPtr: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        let kp = IOCreatePlugInInterfaceForService(
            picked.svc,
            UUID_IOUSBDeviceUserClientTypeID,
            UUID_IOCFPlugInInterfaceID,
            &pluginPtr,
            &score
        )
        guard kp == KERN_SUCCESS, let plugin = pluginPtr else {
            IOObjectRelease(picked.svc)
            throw ScarlettError.ioReturn("IOCreatePlugInInterfaceForService", kp)
        }
        defer { _ = plugin.pointee?.pointee.Release(plugin) }

        let uuid = CFUUIDGetUUIDBytes(UUID_IOUSBDeviceInterfaceID100)
        var rawIface: LPVOID?
        let hr = withUnsafeMutablePointer(to: &rawIface) { ptr -> HRESULT in
            plugin.pointee!.pointee.QueryInterface(plugin, uuid, ptr)
        }
        guard hr == 0, let raw = rawIface else {
            IOObjectRelease(picked.svc)
            throw ScarlettError.queryInterface(hr)
        }
        self.iface = DeviceIface(OpaquePointer(raw))
    }

    deinit {
        _ = iface.pointee?.pointee.Release(iface)
        IOObjectRelease(service)
    }

    // MARK: - Control transfers

    /// Class request, OUT (Host→Device).  bmRequestType = 0x21.
    public func controlOut(cmd: UInt8, value: UInt16, index: UInt16, data: [UInt8]) throws {
        var buf = data
        let len = UInt16(buf.count)
        let kr = buf.withUnsafeMutableBufferPointer { bp -> IOReturn in
            var req = IOUSBDevRequest(
                bmRequestType: 0x21,
                bRequest: cmd,
                wValue: value,
                wIndex: index,
                wLength: len,
                pData: bp.baseAddress,
                wLenDone: 0
            )
            return iface.pointee!.pointee.DeviceRequest(iface, &req)
        }
        guard kr == kIOReturnSuccess else {
            throw ScarlettError.ioReturn(
                String(format: "controlOut(cmd=0x%02x val=0x%04x idx=0x%04x len=%d)",
                       cmd, value, index, data.count),
                kr
            )
        }
    }

    /// Class request, IN (Device→Host).  bmRequestType = 0xa1.
    public func controlIn(cmd: UInt8, value: UInt16, index: UInt16, length: UInt16) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: Int(length))
        let kr = buf.withUnsafeMutableBufferPointer { bp -> IOReturn in
            var req = IOUSBDevRequest(
                bmRequestType: 0xa1,
                bRequest: cmd,
                wValue: value,
                wIndex: index,
                wLength: length,
                pData: bp.baseAddress,
                wLenDone: 0
            )
            return iface.pointee!.pointee.DeviceRequest(iface, &req)
        }
        guard kr == kIOReturnSuccess else {
            throw ScarlettError.ioReturn(
                String(format: "controlIn(cmd=0x%02x val=0x%04x idx=0x%04x len=%d)",
                       cmd, value, index, length),
                kr
            )
        }
        return buf
    }

    // MARK: - Device info

    public func firmwareBCD() -> UInt16? {
        let key = "bcdDevice" as CFString
        guard let cf = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0) else {
            return nil
        }
        return (cf.takeRetainedValue() as? NSNumber)?.uint16Value
    }

    public func serialNumber() -> String? {
        let key = "USB Serial Number" as CFString
        guard let cf = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0) else {
            return nil
        }
        return cf.takeRetainedValue() as? String
    }
}
