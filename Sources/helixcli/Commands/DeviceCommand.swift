import ArgumentParser
import Foundation

struct DeviceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "device",
        abstract: "Inspect connected Line 6 / HX USB devices",
        subcommands: [
            ListDevices.self,
            DeviceInfo.self,
            DeviceTopology.self,
            DeviceProbe.self,
            DevicePing.self,
            DeviceConnect.self,
            DeviceReset.self,
            DeviceSendRaw.self,
            DevicePresetNames.self,
        ]
    )
}

struct ListDevices: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List connected Line 6 USB devices"
    )

    @Flag(help: "Show every USB device, not just Line 6 devices")
    var all = false

    func run() throws {
        let manager = USBManager()
        let devices = try manager.listDevices(line6Only: !all)
        print(JSONResponse.success(data: [
            "count": devices.count,
            "devices": devices.map(\ .dictionary),
        ]).toJSON())
    }
}

struct DevicePresetNames: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "preset-names",
        abstract: "Connect, reconfigure, request, and decode preset names"
    )

    @Option(help: "USB read/write timeout in milliseconds")
    var timeout: UInt32 = 250

    @Option(help: "Maximum inbound packets per handshake phase")
    var maxPackets: Int = 120

    func run() throws {
        let manager = USBManager()
        do {
            let result = try manager.connectHandshake(timeoutMs: timeout, maxPackets: maxPackets, requestPresetNames: true)
            print(JSONResponse.success(data: result).toJSON())
        } catch USBError.deviceNotFound {
            print(JSONResponse.deviceNotFound().toJSON())
        } catch USBError.transferFailed(let message), USBError.connectionFailed(let message) {
            print(JSONResponse.failure(code: "USB_ERROR", message: message).toJSON())
        }
    }
}

struct DeviceSendRaw: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send-raw",
        abstract: "Send one raw hex packet to endpoint 0x01 and read responses from 0x81"
    )

    @Argument(help: "Hex bytes, e.g. '0c 00 00 28 ...'")
    var hex: String

    @Option(help: "USB transfer timeout in milliseconds")
    var timeout: UInt32 = 500

    @Option(help: "Maximum reads after writing")
    var reads: Int = 1

    func run() throws {
        let manager = USBManager()
        do {
            let packet = try USBManager.parseHexBytes(hex)
            let result = try manager.sendRawProtocolPacket(packet, timeoutMs: timeout, reads: reads)
            print(JSONResponse.success(data: result).toJSON())
        } catch USBError.deviceNotFound {
            print(JSONResponse.deviceNotFound().toJSON())
        } catch USBError.connectionFailed(let message), USBError.transferFailed(let message), USBError.invalidResponse(let message) {
            print(JSONResponse.failure(code: "USB_ERROR", message: message).toJSON())
        }
    }
}

struct DeviceReset: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reset",
        abstract: "Reset the HX Stomp USB device session"
    )

    func run() throws {
        let manager = USBManager()
        do {
            let result = try manager.resetUSBDevice()
            print(JSONResponse.success(data: result).toJSON())
        } catch USBError.deviceNotFound {
            print(JSONResponse.deviceNotFound().toJSON())
        } catch USBError.connectionFailed(let message) {
            print(JSONResponse.failure(code: "USB_ERROR", message: message).toJSON())
        }
    }
}

struct DeviceConnect: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "connect",
        abstract: "Run the initial Helix USB connect handshake and print a trace"
    )

    @Option(help: "USB read/write timeout in milliseconds")
    var timeout: UInt32 = 200

    @Option(help: "Maximum inbound packets to process")
    var maxPackets: Int = 80

    func run() throws {
        let manager = USBManager()
        do {
            let result = try manager.connectHandshake(timeoutMs: timeout, maxPackets: maxPackets)
            print(JSONResponse.success(data: result).toJSON())
        } catch USBError.deviceNotFound {
            print(JSONResponse.deviceNotFound().toJSON())
        } catch USBError.transferFailed(let message), USBError.connectionFailed(let message) {
            print(JSONResponse.failure(code: "USB_ERROR", message: message).toJSON())
        }
    }
}

struct DevicePing: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ping",
        abstract: "Send the initial Helix USB connect packet and read one response"
    )

    @Option(help: "USB transfer timeout in milliseconds")
    var timeout: UInt32 = 500

    func run() throws {
        let manager = USBManager()
        do {
            let result = try manager.pingProtocolInterface(timeoutMs: timeout)
            print(JSONResponse.success(data: result).toJSON())
        } catch USBError.deviceNotFound {
            print(JSONResponse.deviceNotFound().toJSON())
        }
    }
}

struct DeviceProbe: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "probe",
        abstract: "Open and claim the HX protocol interface without sending data"
    )

    func run() throws {
        let manager = USBManager()
        do {
            let result = try manager.probeProtocolInterface()
            print(JSONResponse.success(data: result).toJSON())
        } catch USBError.deviceNotFound {
            print(JSONResponse.deviceNotFound().toJSON())
        }
    }
}

struct DeviceTopology: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "topology",
        abstract: "Show USB configurations, interfaces, and endpoints via libusb"
    )

    @Flag(help: "Show every USB device, not just Line 6 devices")
    var all = false

    func run() throws {
        let manager = USBManager()
        let devices = try manager.usbTopology(line6Only: !all)
        print(JSONResponse.success(data: [
            "count": devices.count,
            "devices": devices,
        ]).toJSON())
    }
}

struct DeviceInfo: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Show the first supported HX/Helix USB device"
    )

    func run() throws {
        let manager = USBManager()
        guard let device = try manager.findSupportedDevice() else {
            print(JSONResponse.deviceNotFound().toJSON())
            return
        }

        print(JSONResponse.success(data: device.dictionary).toJSON())
    }
}
