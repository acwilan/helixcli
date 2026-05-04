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

    func resetUSBDevice() throws -> [String: Any] {
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

        let result = libusb_reset_device(handle)
        return [
            "deviceId": device.deviceId,
            "resetResult": result,
            "resetResultName": libusbResultName(result),
        ]
    }

    func connectHandshake(timeoutMs: UInt32 = 200, maxPackets: Int = 80, requestPresetNames: Bool = false, requestCurrentPresetName: Bool = false) throws -> [String: Any] {
        try withProtocolHandle { handle in
            var x1: UInt8 = 0x02
            var x2: UInt8 = 0x02
            var x80: UInt8 = 0x02
            var receivedX2 = false
            var receivedX80 = false
            var trace: [[String: Any]] = []

            func nextSeq(for stream: UInt8) -> UInt8 {
                switch stream {
                case 0x01:
                    defer { x1 &+= 1 }
                    return x1
                case 0x02:
                    defer { x2 &+= 1 }
                    return x2
                case 0x80:
                    defer { x80 &+= 1 }
                    return x80
                default:
                    return 0
                }
            }

            func resolve(_ template: [Int]) -> [UInt8] {
                var packet = template.map { $0 < 0 ? UInt8(0) : UInt8($0) }
                if template.count > 9, template[9] < 0, template.count > 4 {
                    packet[9] = nextSeq(for: packet[4])
                }
                return packet
            }

            func write(_ name: String, _ template: [Int]) throws {
                var packet = resolve(template)
                let packetCount = packet.count
                var written: Int32 = 0
                let result = packet.withUnsafeMutableBufferPointer { buffer in
                    libusb_bulk_transfer(handle, 0x01, buffer.baseAddress!, Int32(packetCount), &written, timeoutMs)
                }
                trace.append([
                    "direction": "out",
                    "name": name,
                    "result": libusbResultName(result),
                    "bytes": Int(written),
                    "hex": hex(packet),
                ])
                if result != 0 {
                    throw USBError.transferFailed("write \(name) failed: \(libusbResultName(result)) [\(result)]")
                }
            }

            func frameLength(_ bytes: [UInt8], at offset: Int) -> Int? {
                guard offset + 4 <= bytes.count else { return nil }
                let first = bytes[offset]
                let fourth = bytes[offset + 3]
                // The HX stream may concatenate multiple protocol frames in one USB read.
                // These lengths are the frame sizes observed in kempline/helix_usb and live traces.
                switch (first, fourth) {
                case (0x08, 0x18): return 16
                case (0x0c, 0x28): return 20
                case (0x11, 0x18): return 28
                case (0x19, 0x18): return 36
                case (0x1c, 0x18): return 36
                case (0x1d, 0x18): return 40
                case (0x1f, 0x18): return 40
                case (0x28, 0x18): return 48
                case (0x54, 0x18): return 92
                default:
                    let candidate = Int(first) + 8
                    return candidate > 0 ? candidate : nil
                }
            }

            func splitFrames(_ bytes: [UInt8]) -> [[UInt8]] {
                var frames: [[UInt8]] = []
                var offset = 0
                while offset < bytes.count {
                    guard let length = frameLength(bytes, at: offset), length > 0, offset + length <= bytes.count else {
                        frames.append(Array(bytes[offset...]))
                        break
                    }
                    frames.append(Array(bytes[offset..<offset + length]))
                    offset += length
                }
                return frames
            }

            func readFrames() -> [[UInt8]] {
                var buffer = [UInt8](repeating: 0, count: 4096)
                var read: Int32 = 0
                let result = buffer.withUnsafeMutableBufferPointer { ptr in
                    libusb_bulk_transfer(handle, 0x81, ptr.baseAddress!, Int32(ptr.count), &read, timeoutMs)
                }
                if result == LIBUSB_ERROR_TIMEOUT.rawValue { return [] }
                let bytes = read > 0 ? Array(buffer.prefix(Int(read))) : []
                let frames = result == 0 ? splitFrames(bytes) : []
                if frames.isEmpty {
                    trace.append([
                        "direction": "in",
                        "result": libusbResultName(result),
                        "bytes": Int(read),
                        "hex": hex(bytes),
                    ])
                } else {
                    for frame in frames {
                        trace.append([
                            "direction": "in",
                            "result": libusbResultName(result),
                            "bytes": frame.count,
                            "hex": hex(frame),
                        ])
                    }
                }
                return frames
            }

            func matches(_ packet: [UInt8], _ pattern: [Int], length: Int? = nil) -> Bool {
                let len = length ?? min(packet.count, pattern.count)
                guard packet.count >= len, pattern.count >= len else { return false }
                for idx in 0..<len {
                    if pattern[idx] >= 0 && packet[idx] != UInt8(pattern[idx]) { return false }
                }
                return true
            }

            _ = libusb_clear_halt(handle, 0x01)
            _ = libusb_clear_halt(handle, 0x81)

            var drainedFrames = 0
            while true {
                let frames = readFrames()
                if frames.isEmpty { break }
                drainedFrames += frames.count
                if drainedFrames > 200 { break }
            }
            trace.append(["direction": "internal", "name": "drain-complete", "frames": drainedFrames])

            try write("connect-x1-start", [0x0c, 0x00, 0x00, 0x28, 0x01, 0x10, 0xef, 0x03, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01, 0x00, 0x21, 0x00, 0x10, 0x00, 0x00])

            func runConnectLoop() throws {
                for _ in 0..<maxPackets {
                    let packets = readFrames()
                    if packets.isEmpty { continue }
                    for packet in packets {

                    if matches(packet, [0x0c,0x00,0x00,0x28,0xef,0x03,0x01,0x10,0x00,0x00,0x00,0x02,0x00,0x01,0x00,0x01,0x00,0x02,0x00,0x00], length: 20) {
                    try write("x1-hello-reply", [0x11,0x00,0x00,0x18,0x01,0x10,0xef,0x03,0x00,-1,0x00,0x04,0x00,0x10,0x00,0x00,0x01,0x00,0x05,0x00,0x01,0x00,0x00,0x00,0x05,0x00,0x00,0x00])
                } else if matches(packet, [0x28,0x00,0x00,0x18,0xef,0x03,0x01,0x10,0x00,0x02,0x00,0x04,0x09,0x02], length: 14) {
                    try write("x1-ack-20", [0x08,0x00,0x00,0x18,0x01,0x10,0xef,0x03,0x00,-1,0x00,0x08,0x20,0x10,0x00,0x00])
                } else if matches(packet, [0x08,0x00,0x00,0x18,0xef,0x03,0x01,0x10,0x00,0x03,0x00,-1,0x09,0x02,0x00,0x00], length: 16) {
                    try write("x1-ack-20-short", [0x08,0x00,0x00,0x18,0x01,0x10,0xef,0x03,0x00,-1,0x00,0x02,0x20,0x10,0x00,0x00])
                } else if matches(packet, [0x08,0x00,0x00,0x18,0xef,0x03,0x01,0x10,0x00,0x04,0x00,-1,0x09,0x02,0x00,0x00], length: 16) {
                    try write("connect-x80-start", [0x0c,0x00,0x00,0x28,0x80,0x10,0xed,0x03,0x00,0x00,0x00,0x02,0x00,0x01,0x00,0x21,0x00,0x10,0x00,0x00])
                } else if matches(packet, [0x0c,0x00,0x00,0x28,0xed,0x03,0x80,0x10,0x00,0x00,0x00,0x02,0x00,0x01,0x00,0x01,0x00,0x02,0x00,0x00], length: 20) {
                    try write("x80-hello-reply", [0x11,0x00,0x00,0x18,0x80,0x10,0xed,0x03,0x00,-1,0x00,0x04,0x00,0x10,0x00,0x00,0x01,0x00,0x06,0x00,0x01,0x00,0x00,0x00,0x06,0x00,0x00,0x00])
                } else if matches(packet, [0x11,0x00,0x00,0x18,0xed,0x03,0x80,0x10,0x00,0x02], length: 10) {
                    receivedX80 = true
                    try write("connect-x2-start", [0x0c,0x00,0x00,0x28,0x02,0x10,0xf0,0x03,0x00,0x00,0x00,0x02,0x00,0x01,0x00,0x21,0x00,0x10,0x00,0x00])
                } else if matches(packet, [0x0c,0x00,0x00,0x28,0xf0,0x03,0x02,0x10,0x00,0x00,0x00,0x02,0x00,0x01,0x00,0x01,0x00,0x02,0x00,0x00], length: 20) {
                    try write("x2-hello-reply", [0x11,0x00,0x00,0x18,0x02,0x10,0xf0,0x03,0x00,-1,0x00,0x04,0x00,0x10,0x00,0x00,0x01,0x00,0x04,0x00,0x01,0x00,0x00,0x00,0x04,0x00,0x00,0x00])
                } else if matches(packet, [0x11,0x00,0x00,0x18,0xf0,0x03,0x02,0x10,0x00,0x02,0x00,0x04,0x09,0x02], length: 14) {
                    receivedX2 = true
                } else if matches(packet, [0x08,0x00,0x00,0x18,0xef,0x03,0x01,0x10,0x00,-1,0x00,0x10], length: 12) ||
                          matches(packet, [0x08,0x00,0x00,0x18,0xf0,0x03,0x02,0x10,0x00,-1,0x00,0x10], length: 12) ||
                          matches(packet, [0x08,0x00,0x00,0x18,0xed,0x03,0x80,0x10,0x00,-1,0x00,0x10], length: 12) {
                    // keep-alive response; expected during connect
                }

                    if receivedX2 && receivedX80 { break }
                    }
                    if receivedX2 && receivedX80 { break }
                }
            }

            try runConnectLoop()

            var reconfiguredX1 = false
            var presetNamePackets: [Data] = []
            var presetNameReadTimeouts = 0
            var currentPresetName: String? = nil

            if receivedX2 && receivedX80 && (requestPresetNames || requestCurrentPresetName) {
                // Python's next mode reconfigures stream x1 and resets its sequence counter.
                x1 = 0x02
                try write("reconfigure-x1-start", [0x0c,0x00,0x00,0x28,0x01,0x10,0xef,0x03,0x00,0x00,0x00,0x02,0x00,0x01,0x00,0x21,0x00,0x10,0x00,0x00])

                for _ in 0..<maxPackets {
                    let frames = readFrames()
                    if frames.isEmpty { continue }
                    for packet in frames {
                        if matches(packet, [0x0c,0x00,0x00,0x28,0xef,0x03,0x01,0x10,0x00,0x00,0x00,0x02,0x00,0x01,0x00,0x01,0x00,0x02,0x00,0x00], length: 20) {
                            try write("reconfigure-x1-reply", [0x11,0x00,0x00,0x18,0x01,0x10,0xef,0x03,0x00,-1,0x00,0x04,0x00,0x10,0x00,0x00,0x01,0x00,0x02,0x00,0x01,0x00,0x00,0x00,0x02,0x00,0x00,0x00])
                        } else if matches(packet, [0x11,0x00,0x00,0x18,0xef,0x03,0x01,0x10,0x00,0x02,0x00,0x04], length: 12) {
                            reconfiguredX1 = true
                        }
                    }
                    if reconfiguredX1 { break }
                }

                if reconfiguredX1 && requestCurrentPresetName {
                    var currentPresetPayload: [UInt8] = []
                    var timeouts = 0
                    try write("request-current-preset-name", [0x19,0x00,0x00,0x18,0x80,0x10,0xed,0x03,0x00,-1,0x00,0x04,0x1a,0x1e,0x00,0x00,0x01,0x00,0x06,0x00,0x09,0x00,0x00,0x00,0x83,0x66,0xcd,0x04,0x04,0x64,0x17,0x65,0xc0,0x00,0x00,0x00])

                    while timeouts < 4 && currentPresetName == nil {
                        let frames = readFrames()
                        if frames.isEmpty {
                            timeouts += 1
                            continue
                        }
                        timeouts = 0
                        for packet in frames {
                            currentPresetPayload.append(contentsOf: packet.dropFirst(min(16, packet.count)))
                            if currentPresetName == nil {
                                currentPresetName = HelixResponseParser.parseCurrentPresetName(from: Data(currentPresetPayload))
                            }
                        }
                    }
                }

                if reconfiguredX1 && requestPresetNames {
                    try write("request-preset-names", [0x1d,0x00,0x00,0x18,0x01,0x10,0xef,0x03,0x00,-1,0x00,0x0c,0x38,0x10,0x00,0x00,0x01,0x00,0x02,0x00,0x0d,0x00,0x00,0x00,0x83,0x66,0xcd,0x03,0xea,0x64,0x01,0x65,0x82,0x6b,0x00,0x65,0x02,0x00,0x00,0x00])

                    while presetNameReadTimeouts < 4 && presetNamePackets.count < 180 {
                        let frames = readFrames()
                        if frames.isEmpty {
                            presetNameReadTimeouts += 1
                            continue
                        }
                        presetNameReadTimeouts = 0

                        for packet in frames {
                            // Keep the complete incoming stream. The actual name records
                            // can start/end mid-read, so parsing only matched protocol
                            // frames loses most records.
                            presetNamePackets.append(Data(packet))

                            if matches(packet, [0x08,0x01,0x00,0x18,0xef,0x03,0x01,0x10,0x00,-1,0x00,0x04,-1,0x02,0x00,0x00,-1], length: 17) ||
                               matches(packet, [-1,0x00,0x00,0x18,0xef,0x03,0x01,0x10,0x00,-1,0x00,0x04,-1,0x02,0x00,0x00], length: 16) {
                                let ackByte = packet[9] &+ 9
                                try write("ack-preset-name-packet", [0x08,0x00,0x00,0x18,0x01,0x10,0xef,0x03,0x00,-1,0x00,0x08,0x38,Int(ackByte),0x00,0x00])
                            }
                        }

                        let parsed = HelixResponseParser.parsePresetNames(from: presetNamePackets)
                        let nonEmpty = parsed.filter { $0.name != "<empty>" }.count
                        if nonEmpty >= 125 { break }
                    }
                }
            }

            let presets = HelixResponseParser.parsePresetNames(from: presetNamePackets)
            let namedPresets = presets.filter { $0.name != "<empty>" }

            return [
                "connected": receivedX2 && receivedX80,
                "receivedX80": receivedX80,
                "receivedX2": receivedX2,
                "reconfiguredX1": reconfiguredX1,
                "presetNamePacketCount": presetNamePackets.count,
                "decodedPresetNameCount": namedPresets.count,
                "currentPresetName": currentPresetName as Any,
                "presetNames": presets.prefix(125).map { ["id": $0.id, "name": $0.name, "bank": $0.bank] },
                "traceCount": trace.count,
                "trace": trace,
            ]
        }
    }

    /// Request full preset data from the device.
    /// This performs a full handshake, then sends the preset data request (subcommand 0x03)
    /// and reads the multi-packet response.
    func requestPresetData(timeoutMs: UInt32 = 250, maxPackets: Int = 200, verbose: Bool = false) throws -> [String: Any] {
        try withProtocolHandle { handle in
            var x1: UInt8 = 0x02
            var x2: UInt8 = 0x02
            var x80: UInt8 = 0x02
            var receivedX2 = false
            var receivedX80 = false
            var trace: [[String: Any]] = []
            var packets: [[UInt8]] = []
            var totalBytes = 0

            func nextSeq(for stream: UInt8) -> UInt8 {
                switch stream {
                case 0x01:
                    defer { x1 &+= 1 }
                    return x1
                case 0x02:
                    defer { x2 &+= 1 }
                    return x2
                case 0x80:
                    defer { x80 &+= 1 }
                    return x80
                default:
                    return 0
                }
            }

            func resolve(_ template: [Int]) -> [UInt8] {
                var packet = template.map { $0 < 0 ? UInt8(0) : UInt8($0) }
                if template.count > 9, template[9] < 0, template.count > 4 {
                    packet[9] = nextSeq(for: packet[4])
                }
                return packet
            }

            func write(_ name: String, _ template: [Int]) throws {
                var packet = resolve(template)
                let packetCount = packet.count
                var written: Int32 = 0
                let result = packet.withUnsafeMutableBufferPointer { buffer in
                    libusb_bulk_transfer(handle, 0x01, buffer.baseAddress!, Int32(packetCount), &written, timeoutMs)
                }
                trace.append([
                    "direction": "out",
                    "name": name,
                    "result": libusbResultName(result),
                    "bytes": Int(written),
                    "hex": hex(packet),
                ])
                if result != 0 {
                    throw USBError.transferFailed("write \(name) failed: \(libusbResultName(result)) [\(result)]")
                }
            }

            func frameLength(_ bytes: [UInt8], at offset: Int) -> Int? {
                guard offset + 4 <= bytes.count else { return nil }
                let first = bytes[offset]
                let fourth = bytes[offset + 3]
                switch (first, fourth) {
                case (0x08, 0x18): return 16
                case (0x0c, 0x28): return 20
                case (0x11, 0x18): return 28
                case (0x19, 0x18): return 36
                case (0x1c, 0x18): return 36
                case (0x1d, 0x18): return 40
                case (0x1f, 0x18): return 40
                case (0x28, 0x18): return 48
                case (0x54, 0x18): return 92
                default:
                    let candidate = Int(first) + 8
                    return candidate > 0 ? candidate : nil
                }
            }

            func splitFrames(_ bytes: [UInt8]) -> [[UInt8]] {
                var frames: [[UInt8]] = []
                var offset = 0
                while offset < bytes.count {
                    guard let length = frameLength(bytes, at: offset), length > 0, offset + length <= bytes.count else {
                        frames.append(Array(bytes[offset...]))
                        break
                    }
                    frames.append(Array(bytes[offset..<offset + length]))
                    offset += length
                }
                return frames
            }

            func readFrames() -> [[UInt8]] {
                var buffer = [UInt8](repeating: 0, count: 4096)
                var read: Int32 = 0
                let result = buffer.withUnsafeMutableBufferPointer { ptr in
                    libusb_bulk_transfer(handle, 0x81, ptr.baseAddress!, Int32(ptr.count), &read, timeoutMs)
                }
                if result == LIBUSB_ERROR_TIMEOUT.rawValue { return [] }
                let bytes = read > 0 ? Array(buffer.prefix(Int(read))) : []
                let frames = result == 0 ? splitFrames(bytes) : []
                if frames.isEmpty {
                    trace.append([
                        "direction": "in",
                        "result": libusbResultName(result),
                        "bytes": Int(read),
                        "hex": hex(bytes),
                    ])
                } else {
                    for frame in frames {
                        trace.append([
                            "direction": "in",
                            "result": libusbResultName(result),
                            "bytes": frame.count,
                            "hex": hex(frame),
                        ])
                    }
                }
                return frames
            }

            func matches(_ packet: [UInt8], _ pattern: [Int], length: Int? = nil) -> Bool {
                let len = length ?? min(packet.count, pattern.count)
                guard packet.count >= len, pattern.count >= len else { return false }
                for idx in 0..<len {
                    if pattern[idx] >= 0 && packet[idx] != UInt8(pattern[idx]) { return false }
                }
                return true
            }

            _ = libusb_clear_halt(handle, 0x01)
            _ = libusb_clear_halt(handle, 0x81)

            var drainedFrames = 0
            while true {
                let frames = readFrames()
                if frames.isEmpty { break }
                drainedFrames += frames.count
                if drainedFrames > 200 { break }
            }
            trace.append(["direction": "internal", "name": "drain-complete", "frames": drainedFrames])

            try write("connect-x1-start", [0x0c, 0x00, 0x00, 0x28, 0x01, 0x10, 0xef, 0x03, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01, 0x00, 0x21, 0x00, 0x10, 0x00, 0x00])

            func runConnectLoop() throws {
                for _ in 0..<maxPackets {
                    let packets = readFrames()
                    if packets.isEmpty { continue }
                    for packet in packets {

                        if matches(packet, [0x0c,0x00,0x00,0x28,0xef,0x03,0x01,0x10,0x00,0x00,0x00,0x02,0x00,0x01,0x00,0x01,0x00,0x02,0x00,0x00], length: 20) {
                            try write("x1-hello-reply", [0x11,0x00,0x00,0x18,0x01,0x10,0xef,0x03,0x00,-1,0x00,0x04,0x00,0x10,0x00,0x00,0x01,0x00,0x05,0x00,0x01,0x00,0x00,0x00,0x05,0x00,0x00,0x00])
                        } else if matches(packet, [0x28,0x00,0x00,0x18,0xef,0x03,0x01,0x10,0x00,0x02,0x00,0x04,0x09,0x02], length: 14) {
                            try write("x1-ack-20", [0x08,0x00,0x00,0x18,0x01,0x10,0xef,0x03,0x00,-1,0x00,0x08,0x20,0x10,0x00,0x00])
                        } else if matches(packet, [0x08,0x00,0x00,0x18,0xef,0x03,0x01,0x10,0x00,0x03,0x00,-1,0x09,0x02,0x00,0x00], length: 16) {
                            try write("x1-ack-20-short", [0x08,0x00,0x00,0x18,0x01,0x10,0xef,0x03,0x00,-1,0x00,0x02,0x20,0x10,0x00,0x00])
                        } else if matches(packet, [0x08,0x00,0x00,0x18,0xef,0x03,0x01,0x10,0x00,0x04,0x00,-1,0x09,0x02,0x00,0x00], length: 16) {
                            try write("connect-x80-start", [0x0c,0x00,0x00,0x28,0x80,0x10,0xed,0x03,0x00,0x00,0x00,0x02,0x00,0x01,0x00,0x21,0x00,0x10,0x00,0x00])
                        } else if matches(packet, [0x0c,0x00,0x00,0x28,0xed,0x03,0x80,0x10,0x00,0x00,0x00,0x02,0x00,0x01,0x00,0x01,0x00,0x02,0x00,0x00], length: 20) {
                            try write("x80-hello-reply", [0x11,0x00,0x00,0x18,0x80,0x10,0xed,0x03,0x00,-1,0x00,0x04,0x00,0x10,0x00,0x00,0x01,0x00,0x06,0x00,0x01,0x00,0x00,0x00,0x06,0x00,0x00,0x00])
                        } else if matches(packet, [0x11,0x00,0x00,0x18,0xed,0x03,0x80,0x10,0x00,0x02], length: 10) {
                            receivedX80 = true
                            try write("connect-x2-start", [0x0c,0x00,0x00,0x28,0x02,0x10,0xf0,0x03,0x00,0x00,0x00,0x02,0x00,0x01,0x00,0x21,0x00,0x10,0x00,0x00])
                        } else if matches(packet, [0x0c,0x00,0x00,0x28,0xf0,0x03,0x02,0x10,0x00,0x00,0x00,0x02,0x00,0x01,0x00,0x01,0x00,0x02,0x00,0x00], length: 20) {
                            try write("x2-hello-reply", [0x11,0x00,0x00,0x18,0x02,0x10,0xf0,0x03,0x00,-1,0x00,0x04,0x00,0x10,0x00,0x00,0x01,0x00,0x04,0x00,0x01,0x00,0x00,0x00,0x04,0x00,0x00,0x00])
                        } else if matches(packet, [0x11,0x00,0x00,0x18,0xf0,0x03,0x02,0x10,0x00,0x02,0x00,0x04,0x09,0x02], length: 14) {
                            receivedX2 = true
                        } else if matches(packet, [0x08,0x00,0x00,0x18,0xef,0x03,0x01,0x10,0x00,-1,0x00,0x10], length: 12) ||
                                  matches(packet, [0x08,0x00,0x00,0x18,0xf0,0x03,0x02,0x10,0x00,-1,0x00,0x10], length: 12) ||
                                  matches(packet, [0x08,0x00,0x00,0x18,0xed,0x03,0x80,0x10,0x00,-1,0x00,0x10], length: 12) {
                        }

                        if receivedX2 && receivedX80 { break }
                    }
                    if receivedX2 && receivedX80 { break }
                }
            }

            try runConnectLoop()

            // After handshake, request preset data (subcommand 0x03 instead of 0x04 for current preset name)
            let sessionNo: UInt8 = 0x1a
            let packetDouble: [UInt8] = [0x1e, 0x00]
            let requestSessionId: UInt8 = 0xf4
            var presetData: [UInt8] = []
            var timeouts = 0
            var packetCounter: UInt16 = 0x001e
            var consecutiveNonData = 0
            var dataPhaseStarted = false

            // Send the preset data request
            try write("request-preset-data", [0x19, 0x00, 0x00, 0x18, 0x80, 0x10, 0xed, 0x03, 0x00, -1, 0x00, 0x0c, Int(sessionNo), Int(packetDouble[0]), Int(packetDouble[1]), 0x00, 0x01, 0x00, 0x06, 0x00, 0x09, 0x00, 0x00, 0x00, 0x83, 0x66, 0xcd, 0x03, Int(requestSessionId), 0x64, 0x16, 0x65, 0xc0, 0x00, 0x00, 0x00])

            // Read response packets
            for _ in 0..<maxPackets {
                let frames = readFrames()
                if frames.isEmpty {
                    timeouts += 1
                    if timeouts >= 4 { break }
                    continue
                }
                timeouts = 0

                for frame in frames {
                    // Check if this is a data packet from the device
                    // The device sends preset data as multiple packets on stream x80
                    // Data packets have pos11 == 0x04 or 0x08 (not 16-byte ACKs which have pos11 == 0x10)
                    // NOTE: We check frame.count > 16 to identify packets with payload data.
                    // The device sends packets in small chunks; we capture ALL of them.
                    if frame.count > 16 && (frame[11] == 0x04 || frame[11] == 0x08) {
                        dataPhaseStarted = true
                        consecutiveNonData = 0
                    } else if dataPhaseStarted {
                        consecutiveNonData += 1
                        if consecutiveNonData >= 3 { break }
                    }

                    // Capture payload from ANY frame that has data beyond the 16-byte header
                    // This ensures we collect data from all packets, even small chunks
                    if frame.count > 16 {
                        let payload = Array(frame.dropFirst(16))
                        presetData.append(contentsOf: payload)
                    }
                    packets.append(frame)
                    totalBytes += frame.count

                    // Send ACK for data packets (pos11 == 0x04 or 0x08)
                    // Skip ACK for first packet (per Python reference)
                    if frame.count > 16 && (frame[11] == 0x04 || frame[11] == 0x08) {
                        if packets.count > 1 {
                            let nextPacketDoubleLow = UInt8(packetCounter & 0xFF)
                            let nextPacketDoubleHigh = UInt8((packetCounter >> 8) & 0xFF)
                            try write("ack-preset-data", [0x08, 0x00, 0x00, 0x18, 0x80, 0x10, 0xed, 0x03, 0x00, -1, 0x00, 0x08, Int(sessionNo), Int(nextPacketDoubleLow), Int(nextPacketDoubleHigh), 0x00])
                        }
                        packetCounter += 1
                    }
                }
                if consecutiveNonData >= 3 { break }
            }

            return [
                "connected": receivedX2 && receivedX80,
                "packetCount": packets.count,
                "totalBytes": totalBytes,
                "payloadBytes": presetData.count,
                "packets": packets.enumerated().map { ["index": $0.offset, "bytes": $0.element.count, "hex": hex($0.element)] },
                "payloadHex": hex(presetData),
                "trace": verbose ? trace : [],
                "traceCount": trace.count,
            ]
        }
    }

    func sendMidiProgramChange(_ program: Int, channel: Int = 0, timeoutMs: UInt32 = 500) throws -> [String: Any] {
        guard (0...125).contains(program) else {
            throw USBError.invalidResponse("MIDI Program Change must be between 0 and 125")
        }
        guard (0...15).contains(channel) else {
            throw USBError.invalidResponse("MIDI channel must be between 0 and 15")
        }

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

        let interfaceNumber: Int32 = 4
        let kernelActive = libusb_kernel_driver_active(handle, interfaceNumber)
        let claimResult = libusb_claim_interface(handle, interfaceNumber)
        guard claimResult == 0 else {
            throw USBError.connectionFailed("libusb_claim_interface(4) failed: \(libusbResultName(claimResult)) [\(claimResult)]. Close apps using HX Stomp MIDI and retry.")
        }
        defer { _ = libusb_release_interface(handle, interfaceNumber) }

        let status = UInt8(0xC0 | (channel & 0x0F))
        var packet: [UInt8] = [0x0C, status, UInt8(program), 0x00]
        var bytesWritten: Int32 = 0
        let packetCount = packet.count
        let writeResult = packet.withUnsafeMutableBufferPointer { buffer in
            libusb_bulk_transfer(handle, 0x02, buffer.baseAddress!, Int32(packetCount), &bytesWritten, timeoutMs)
        }
        guard writeResult == 0 else {
            throw USBError.transferFailed("MIDI Program Change write failed: \(libusbResultName(writeResult)) [\(writeResult)]")
        }

        return [
            "deviceId": device.deviceId,
            "interfaceNumber": Int(interfaceNumber),
            "kernelDriverActive": kernelActive,
            "endpoint": "0x02",
            "program": program,
            "channel": channel + 1,
            "bytesWritten": Int(bytesWritten),
            "packetHex": hex(packet),
        ]
    }


    func sendMidiControlChange(_ controller: Int, value: Int, channel: Int = 0, timeoutMs: UInt32 = 500) throws -> [String: Any] {
        guard (0...127).contains(controller) else {
            throw USBError.invalidResponse("MIDI Control Change controller must be between 0 and 127")
        }
        guard (0...127).contains(value) else {
            throw USBError.invalidResponse("MIDI Control Change value must be between 0 and 127")
        }
        guard (0...15).contains(channel) else {
            throw USBError.invalidResponse("MIDI channel must be between 0 and 15")
        }

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

        let interfaceNumber: Int32 = 4
        let kernelActive = libusb_kernel_driver_active(handle, interfaceNumber)
        let claimResult = libusb_claim_interface(handle, interfaceNumber)
        guard claimResult == 0 else {
            throw USBError.connectionFailed("libusb_claim_interface(4) failed: \(libusbResultName(claimResult)) [\(claimResult)]. Close apps using HX Stomp MIDI and retry.")
        }
        defer { _ = libusb_release_interface(handle, interfaceNumber) }

        let status = UInt8(0xB0 | (channel & 0x0F))
        var packet: [UInt8] = [0x0B, status, UInt8(controller), UInt8(value)]
        var bytesWritten: Int32 = 0
        let packetCount = packet.count
        let writeResult = packet.withUnsafeMutableBufferPointer { buffer in
            libusb_bulk_transfer(handle, 0x02, buffer.baseAddress!, Int32(packetCount), &bytesWritten, timeoutMs)
        }
        guard writeResult == 0 else {
            throw USBError.transferFailed("MIDI Control Change write failed: \(libusbResultName(writeResult)) [\(writeResult)]")
        }

        return [
            "deviceId": device.deviceId,
            "interfaceNumber": Int(interfaceNumber),
            "kernelDriverActive": kernelActive,
            "endpoint": "0x02",
            "controller": controller,
            "value": value,
            "channel": channel + 1,
            "bytesWritten": Int(bytesWritten),
            "packetHex": hex(packet),
        ]
    }

    func sendRawProtocolPacket(_ packet: [UInt8], timeoutMs: UInt32 = 500, reads: Int = 1) throws -> [String: Any] {
        try withProtocolHandle { handle in
            var mutablePacket = packet
            let packetCount = mutablePacket.count
            var bytesWritten: Int32 = 0
            let writeResult = mutablePacket.withUnsafeMutableBufferPointer { buffer in
                libusb_bulk_transfer(handle, 0x01, buffer.baseAddress!, Int32(packetCount), &bytesWritten, timeoutMs)
            }

            var responses: [[String: Any]] = []
            for _ in 0..<reads {
                var readBuffer = [UInt8](repeating: 0, count: 4096)
                var bytesRead: Int32 = 0
                let readResult = readBuffer.withUnsafeMutableBufferPointer { buffer in
                    libusb_bulk_transfer(handle, 0x81, buffer.baseAddress!, Int32(buffer.count), &bytesRead, timeoutMs)
                }
                let responseBytes = bytesRead > 0 ? Array(readBuffer.prefix(Int(bytesRead))) : []
                responses.append([
                    "readResult": readResult,
                    "readResultName": libusbResultName(readResult),
                    "bytesRead": Int(bytesRead),
                    "responseHex": hex(responseBytes),
                ])
                if readResult == LIBUSB_ERROR_TIMEOUT.rawValue { break }
            }

            return [
                "writeResult": writeResult,
                "writeResultName": libusbResultName(writeResult),
                "bytesWritten": Int(bytesWritten),
                "requestHex": hex(packet),
                "responses": responses,
            ]
        }
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

    static func parseHexBytes(_ hexString: String) throws -> [UInt8] {
        let tokens = hexString
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        return try tokens.map { token in
            let cleaned = token.lowercased().hasPrefix("0x") ? String(token.dropFirst(2)) : String(token)
            guard let value = UInt8(cleaned, radix: 16) else {
                throw USBError.invalidResponse("Invalid hex byte: \(token)")
            }
            return value
        }
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
