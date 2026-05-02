import CoreFoundation
import Foundation
import IOKit
import IOKit.usb
import Clibusb

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

    func usbTopology(line6Only: Bool = true) throws -> [[String: Any]] {
        var context: OpaquePointer?
        let initResult = libusb_init(&context)
        guard initResult == 0 else {
            throw USBError.connectionFailed("libusb_init failed: \(initResult)")
        }
        defer { libusb_exit(context) }

        var deviceList: UnsafeMutablePointer<OpaquePointer?>?
        let count = libusb_get_device_list(context, &deviceList)
        guard count >= 0, let deviceList else {
            throw USBError.connectionFailed("libusb_get_device_list failed: \(count)")
        }
        defer { libusb_free_device_list(deviceList, 1) }

        var results: [[String: Any]] = []
        for index in 0..<Int(count) {
            guard let device = deviceList[index] else { continue }

            var descriptor = libusb_device_descriptor()
            let descriptorResult = libusb_get_device_descriptor(device, &descriptor)
            guard descriptorResult == 0 else { continue }

            let vendorId = descriptor.idVendor
            let productId = descriptor.idProduct
            if line6Only && vendorId != Self.line6VendorId { continue }

            var configs: [[String: Any]] = []
            for configIndex in 0..<descriptor.bNumConfigurations {
                var configPointer: UnsafeMutablePointer<libusb_config_descriptor>?
                let configResult = libusb_get_config_descriptor(device, UInt8(configIndex), &configPointer)
                guard configResult == 0, let configPointer else { continue }
                defer { libusb_free_config_descriptor(configPointer) }

                let config = configPointer.pointee
                var interfaces: [[String: Any]] = []
                if let interfacePointer = config.interface {
                    for interfaceIndex in 0..<Int(config.bNumInterfaces) {
                        let interface = interfacePointer[interfaceIndex]
                        var alternates: [[String: Any]] = []
                        if let alternatePointer = interface.altsetting {
                            for alternateIndex in 0..<interface.num_altsetting {
                                let alternate = alternatePointer[Int(alternateIndex)]
                                var endpoints: [[String: Any]] = []
                                if let endpointPointer = alternate.endpoint {
                                    for endpointIndex in 0..<Int(alternate.bNumEndpoints) {
                                        let endpoint = endpointPointer[endpointIndex]
                                        endpoints.append([
                                            "address": String(format: "0x%02X", endpoint.bEndpointAddress),
                                            "number": Int(endpoint.bEndpointAddress & 0x0F),
                                            "direction": (endpoint.bEndpointAddress & 0x80) == 0x80 ? "in" : "out",
                                            "transferType": transferTypeName(endpoint.bmAttributes & 0x03),
                                            "attributes": String(format: "0x%02X", endpoint.bmAttributes),
                                            "maxPacketSize": Int(endpoint.wMaxPacketSize),
                                            "interval": Int(endpoint.bInterval),
                                        ])
                                    }
                                }

                                alternates.append([
                                    "alternateSetting": Int(alternate.bAlternateSetting),
                                    "interfaceNumber": Int(alternate.bInterfaceNumber),
                                    "interfaceClass": String(format: "0x%02X", alternate.bInterfaceClass),
                                    "interfaceSubClass": String(format: "0x%02X", alternate.bInterfaceSubClass),
                                    "interfaceProtocol": String(format: "0x%02X", alternate.bInterfaceProtocol),
                                    "endpointCount": Int(alternate.bNumEndpoints),
                                    "endpoints": endpoints,
                                ])
                            }
                        }
                        interfaces.append([
                            "alternateCount": interface.num_altsetting,
                            "alternates": alternates,
                        ])
                    }
                }

                configs.append([
                    "configurationValue": Int(config.bConfigurationValue),
                    "interfaceCount": Int(config.bNumInterfaces),
                    "maxPowerMilliAmps": Int(config.MaxPower) * 2,
                    "interfaces": interfaces,
                ])
            }

            results.append([
                "vendorId": String(format: "0x%04X", vendorId),
                "productId": String(format: "0x%04X", productId),
                "deviceId": String(format: "%04x:%04x", vendorId, productId),
                "busNumber": Int(libusb_get_bus_number(device)),
                "deviceAddress": Int(libusb_get_device_address(device)),
                "isSupportedHelixDevice": vendorId == Self.line6VendorId && Self.supportedProductIds.contains(productId),
                "configurations": configs,
            ])
        }

        return results
    }

    func probeProtocolInterface() throws -> [String: Any] {
        var context: OpaquePointer?
        let initResult = libusb_init(&context)
        guard initResult == 0 else {
            throw USBError.connectionFailed("libusb_init failed: \(initResult)")
        }
        defer { libusb_exit(context) }

        guard let device = try findSupportedDevice() else {
            throw USBError.deviceNotFound
        }

        guard let handle = libusb_open_device_with_vid_pid(context, Self.line6VendorId, device.productId) else {
            throw USBError.connectionFailed("libusb could not open device \(device.deviceId)")
        }
        defer { libusb_close(handle) }

        let interfaceNumber: Int32 = 0
        let kernelActive = libusb_kernel_driver_active(handle, interfaceNumber)
        let claimResult = libusb_claim_interface(handle, interfaceNumber)
        var releaseResult: Int32? = nil
        if claimResult == 0 {
            releaseResult = libusb_release_interface(handle, interfaceNumber)
        }

        return [
            "deviceId": device.deviceId,
            "interfaceNumber": Int(interfaceNumber),
            "kernelDriverActive": kernelActive,
            "claimResult": claimResult,
            "claimResultName": libusbResultName(claimResult),
            "releaseResult": releaseResult as Any,
            "releaseResultName": releaseResult.map(libusbResultName) as Any,
            "protocolEndpoints": [
                "out": "0x01",
                "in": "0x81",
            ],
        ]
    }

    func pingProtocolInterface(timeoutMs: UInt32 = 500) throws -> [String: Any] {
        let command = HelixPackets.connectStart.resolvedPacket(sequence: 0)
        let response = try withProtocolHandle { handle in
            var bytesWritten: Int32 = 0
            let writeResult = command.withUnsafeBytes { buffer in
                libusb_bulk_transfer(
                    handle,
                    0x01,
                    UnsafeMutablePointer<UInt8>(mutating: buffer.bindMemory(to: UInt8.self).baseAddress!),
                    Int32(command.count),
                    &bytesWritten,
                    timeoutMs
                )
            }

            var readBuffer = [UInt8](repeating: 0, count: 4096)
            var bytesRead: Int32 = 0
            let readResult = readBuffer.withUnsafeMutableBufferPointer { buffer in
                libusb_bulk_transfer(
                    handle,
                    0x81,
                    buffer.baseAddress!,
                    Int32(buffer.count),
                    &bytesRead,
                    timeoutMs
                )
            }

            let responseBytes = bytesRead > 0 ? Array(readBuffer.prefix(Int(bytesRead))) : []
            return [
                "writeResult": writeResult,
                "writeResultName": libusbResultName(writeResult),
                "bytesWritten": Int(bytesWritten),
                "readResult": readResult,
                "readResultName": libusbResultName(readResult),
                "bytesRead": Int(bytesRead),
                "requestHex": hex(command),
                "responseHex": hex(responseBytes),
            ]
        }

        return response
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

    private func withProtocolHandle<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var context: OpaquePointer?
        let initResult = libusb_init(&context)
        guard initResult == 0 else {
            throw USBError.connectionFailed("libusb_init failed: \(initResult)")
        }
        defer { libusb_exit(context) }

        guard let device = try findSupportedDevice() else {
            throw USBError.deviceNotFound
        }

        guard let handle = libusb_open_device_with_vid_pid(context, Self.line6VendorId, device.productId) else {
            throw USBError.connectionFailed("libusb could not open device \(device.deviceId)")
        }
        defer { libusb_close(handle) }

        let claimResult = libusb_claim_interface(handle, 0)
        guard claimResult == 0 else {
            throw USBError.connectionFailed("libusb_claim_interface(0) failed: \(libusbResultName(claimResult)) [\(claimResult)]")
        }
        defer { _ = libusb_release_interface(handle, 0) }

        return try body(handle)
    }

    private func hex(_ data: Data) -> String {
        hex(Array(data))
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private func libusbResultName(_ code: Int32) -> String {
        switch code {
        case 0: return "success"
        case LIBUSB_ERROR_IO.rawValue: return "io"
        case LIBUSB_ERROR_INVALID_PARAM.rawValue: return "invalid_param"
        case LIBUSB_ERROR_ACCESS.rawValue: return "access"
        case LIBUSB_ERROR_NO_DEVICE.rawValue: return "no_device"
        case LIBUSB_ERROR_NOT_FOUND.rawValue: return "not_found"
        case LIBUSB_ERROR_BUSY.rawValue: return "busy"
        case LIBUSB_ERROR_TIMEOUT.rawValue: return "timeout"
        case LIBUSB_ERROR_OVERFLOW.rawValue: return "overflow"
        case LIBUSB_ERROR_PIPE.rawValue: return "pipe"
        case LIBUSB_ERROR_INTERRUPTED.rawValue: return "interrupted"
        case LIBUSB_ERROR_NO_MEM.rawValue: return "no_mem"
        case LIBUSB_ERROR_NOT_SUPPORTED.rawValue: return "not_supported"
        default: return "other_\(code)"
        }
    }

    private func transferTypeName(_ value: UInt8) -> String {
        switch value {
        case UInt8(LIBUSB_TRANSFER_TYPE_CONTROL.rawValue): return "control"
        case UInt8(LIBUSB_TRANSFER_TYPE_ISOCHRONOUS.rawValue): return "isochronous"
        case UInt8(LIBUSB_TRANSFER_TYPE_BULK.rawValue): return "bulk"
        case UInt8(LIBUSB_TRANSFER_TYPE_INTERRUPT.rawValue): return "interrupt"
        default: return "unknown"
        }
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
