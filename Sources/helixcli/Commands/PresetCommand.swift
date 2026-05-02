import ArgumentParser
import Foundation

struct PresetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "preset",
        abstract: "Manage HX Stomp presets",
        subcommands: [
            ListPresets.self,
            CurrentPreset.self,
            SwitchPreset.self,
            GetPreset.self,
        ]
    )
}

struct ListPresets: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all presets"
    )
    
    @Option(help: "USB read/write timeout in milliseconds")
    var timeout: UInt32 = 250

    @Option(help: "Maximum inbound packets per handshake phase")
    var maxPackets: Int = 120

    func run() throws {
        let manager = USBManager()
        do {
            let result = try manager.connectHandshake(timeoutMs: timeout, maxPackets: maxPackets, requestPresetNames: true)
            let presets = result["presetNames"] as? [[String: Any]] ?? []
            print(JSONResponse.success(data: [
                "count": presets.count,
                "decodedPresetNameCount": result["decodedPresetNameCount"] as? Int ?? 0,
                "connected": result["connected"] as? Bool ?? false,
                "presets": presets,
            ]).toJSON())
        } catch USBError.deviceNotFound {
            print(JSONResponse.deviceNotFound().toJSON())
        } catch USBError.connectionFailed(let message), USBError.transferFailed(let message) {
            print(JSONResponse.failure(code: "USB_ERROR", message: message).toJSON())
        }
    }
}

struct CurrentPreset: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "current",
        abstract: "Get current preset"
    )
    
    @Option(help: "USB read/write timeout in milliseconds")
    var timeout: UInt32 = 250

    @Option(help: "Maximum inbound packets per handshake phase")
    var maxPackets: Int = 120

    func run() throws {
        let manager = USBManager()
        do {
            let result = try manager.connectHandshake(timeoutMs: timeout, maxPackets: maxPackets, requestCurrentPresetName: true)
            print(JSONResponse.success(data: [
                "connected": result["connected"] as? Bool ?? false,
                "currentPresetName": result["currentPresetName"] as Any,
            ]).toJSON())
        } catch USBError.deviceNotFound {
            print(JSONResponse.deviceNotFound().toJSON())
        } catch USBError.connectionFailed(let message), USBError.transferFailed(let message) {
            print(JSONResponse.failure(code: "USB_ERROR", message: message).toJSON())
        }
    }
}

struct SwitchPreset: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "switch",
        abstract: "Switch to a preset"
    )
    
    @Argument(help: "Preset ID (0-127)")
    var presetId: Int
    
    @Option(help: "MIDI channel, 1-16")
    var channel: Int = 1

    @Option(help: "USB transfer timeout in milliseconds")
    var timeout: UInt32 = 500

    func run() throws {
        guard presetId >= 0 && presetId <= 125 else {
            print(JSONResponse.failure(code: "INVALID_PRESET", message: "Preset ID must be between 0 and 125").toJSON())
            return
        }
        guard channel >= 1 && channel <= 16 else {
            print(JSONResponse.failure(code: "INVALID_CHANNEL", message: "MIDI channel must be between 1 and 16").toJSON())
            return
        }

        let manager = USBManager()
        do {
            let result = try manager.sendMidiProgramChange(presetId, channel: channel - 1, timeoutMs: timeout)
            print(JSONResponse.success(data: result).toJSON())
        } catch USBError.deviceNotFound {
            print(JSONResponse.deviceNotFound().toJSON())
        } catch USBError.connectionFailed(let message), USBError.transferFailed(let message), USBError.invalidResponse(let message) {
            print(JSONResponse.failure(code: "USB_ERROR", message: message).toJSON())
        }
    }
}

struct GetPreset: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Get preset details"
    )
    
    @Option(help: "Preset ID")
    var id: Int?
    
    @Option(name: .shortAndLong, help: "Output format")
    var format: OutputFormat = .json
    
    enum OutputFormat: String, CaseIterable, ExpressibleByArgument {
        case json
        case table
    }
    
    func run() {
        let response = JSONResponse.success(data: [
            "message": "Getting preset details - not yet implemented",
            "presetId": id as Any
        ])
        print(response.toJSON())
    }
}
