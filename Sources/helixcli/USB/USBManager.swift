import CoreFoundation
import Foundation
import IOKit
import IOKit.usb

enum USBError: Error {
    case deviceNotFound
    case connectionFailed(String)
    case transferFailed(String)
    case invalidResponse(String)
}

/// Manages USB communication with HX Stomp.
///
/// The Python reference (`helix_usb`) talks to Line 6 devices with vendor id
/// `0x0E41` and observed product ids `0x4246` / `0x5055`.
final class USBManager {
    static let line6VendorId: UInt16 = 0x0E41

    /// Product IDs observed in `helix_usb`. We keep this intentionally narrow for v1
    /// and can expand once we verify more Helix-family hardware.
    static let supportedProductIds: Set<UInt16> = [0x4246, 0x5055]

    private var connectedDevice: USBDeviceDescriptor?

    init() {}

    /// Connect to the first supported HX/Helix device.
    func connect() throws {
        guard let device = try findSupportedDevice() else {
            throw USBError.deviceNotFound
        }

        connectedDevice = device
        var stderr = StandardErrorOutputStream()
        print("Found supported Line 6 device \(device.deviceId) \(device.productName ?? "")", to: &stderr)
    }

    func disconnect() {
        connectedDevice = nil
    }

    func findSupportedDevice() throws -> USBDeviceDescriptor? {
        try listDevices(line6Only: true).first(where: { $0.isSupportedHelixDevice })
    }

    func listDevices(line6Only: Bool = true) throws -> [USBDeviceDescriptor] {
        let matchingDict = IOServiceMatching(kIOUSBDeviceClassName)
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator)
        guard result == KERN_SUCCESS else {
            throw USBError.connectionFailed("IOServiceGetMatchingServices failed: \(result)")
        }
        defer { IOObjectRelease(iterator) }

        var devices: [USBDeviceDescriptor] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }

            guard let vendorId = uint16Property(service, "idVendor"),
                  let productId = uint16Property(service, "idProduct") else {
                continue
            }

            if line6Only && vendorId != Self.line6VendorId {
                continue
            }

            let descriptor = USBDeviceDescriptor(
                vendorId: vendorId,
                productId: productId,
                vendorName: stringProperty(service, "USB Vendor Name") ?? stringProperty(service, "kUSBVendorString"),
                productName: stringProperty(service, "USB Product Name") ?? stringProperty(service, "kUSBProductString"),
                serialNumber: stringProperty(service, "USB Serial Number") ?? stringProperty(service, "kUSBSerialNumberString"),
                registryPath: registryPath(for: service),
                isSupportedHelixDevice: vendorId == Self.line6VendorId && Self.supportedProductIds.contains(productId)
            )
            devices.append(descriptor)
        }

        return devices.sorted { $0.deviceId < $1.deviceId }
    }

    /// Send a raw Helix protocol command. Endpoint transfers are the next step after
    /// discovery; this shape lets commands compile against a real protocol boundary.
    func sendCommand(_ command: HelixCommand) throws -> Data {
        guard connectedDevice != nil else {
            throw USBError.deviceNotFound
        }

        // TODO: Open IOUSBHostInterface / endpoint 0x01 bulk OUT and 0x81 bulk IN,
        // then write command.resolvedPacket(...) and read the response stream.
        throw USBError.transferFailed("Bulk endpoint transfers are not implemented yet")
    }

    private func uint16Property(_ service: io_object_t, _ key: String) -> UInt16? {
        guard let value = registryProperty(service, key) else { return nil }
        if let number = value as? NSNumber {
            return UInt16(truncating: number)
        }
        return nil
    }

    private func stringProperty(_ service: io_object_t, _ key: String) -> String? {
        registryProperty(service, key) as? String
    }

    private func registryProperty(_ service: io_object_t, _ key: String) -> Any? {
        let unmanaged = IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        )
        return unmanaged?.takeRetainedValue()
    }

    private func registryPath(for service: io_object_t) -> String? {
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: 4096)
        defer { buffer.deallocate() }

        let result = IORegistryEntryGetPath(service, kIOServicePlane, buffer)
        guard result == KERN_SUCCESS else { return nil }
        return String(cString: buffer)
    }
}

/// Standard error output stream for debug messages.
struct StandardErrorOutputStream: TextOutputStream {
    mutating func write(_ string: String) {
        guard !string.isEmpty else { return }
        FileHandle.standardError.write(Data(string.utf8))
    }
}
