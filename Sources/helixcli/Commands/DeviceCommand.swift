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
