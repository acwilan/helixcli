import ArgumentParser
import Foundation

struct DeviceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "device",
        abstract: "Inspect connected Line 6 / HX USB devices",
        subcommands: [
            ListDevices.self,
            DeviceInfo.self,
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
