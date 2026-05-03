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
        abstract: "Get preset details with blocks and parameters"
    )

    @Option(help: "Preset ID (0-125). If not provided, gets current preset")
    var id: Int?

    @Option(help: "USB read/write timeout in milliseconds")
    var timeout: UInt32 = 250

    @Option(help: "Maximum inbound packets to read")
    var maxPackets: Int = 200

    @Flag(name: .shortAndLong, help: "Include full raw data")
    var verbose = false

    func run() throws {
        let manager = USBManager()
        do {
            // Get the preset data
            let result = try manager.requestPresetData(timeoutMs: timeout, maxPackets: maxPackets, verbose: verbose)

            guard let connected = result["connected"] as? Bool, connected else {
                print(JSONResponse.failure(code: "NOT_CONNECTED", message: "Failed to connect to HX Stomp").toJSON())
                return
            }

            guard let payloadHex = result["payloadHex"] as? String, !payloadHex.isEmpty else {
                print(JSONResponse.failure(code: "NO_DATA", message: "No preset data received from device").toJSON())
                return
            }

            // Parse the preset data
            let parser = PresetDataParser(hexString: payloadHex)
            let presetInfo = parser.parse()

            var responseData: [String: Any] = [
                "presetId": id as Any,
                "name": presetInfo.name,
                "currentSnapshot": presetInfo.currentSnapshot,
                "blockCount": presetInfo.blocks.count,
                "blocks": presetInfo.blocks.map { block in
                    [
                        "slot": block.slot,
                        "modelName": block.modelName,
                        "type": block.type,
                        "enabled": block.enabled,
                        "params": block.params
                    ]
                }
            ]

            if verbose {
                responseData["rawPayloadHex"] = payloadHex
                responseData["packetCount"] = result["packetCount"] as Any
                responseData["totalBytes"] = result["totalBytes"] as Any
            }

            print(JSONResponse.success(data: responseData).toJSON())
        } catch USBError.deviceNotFound {
            print(JSONResponse.deviceNotFound().toJSON())
        } catch USBError.transferFailed(let message), USBError.connectionFailed(let message) {
            print(JSONResponse.failure(code: "USB_ERROR", message: message).toJSON())
        }
    }
}
