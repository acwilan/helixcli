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
            GetCurrentPreset.self,
            GetPreset.self,
            ParsePresetFixture.self,
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
        abstract: "Get current preset name"
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

private enum PresetResponseSupport {
    static func responseData(for presetInfo: PresetInfo, requestedPresetId: Int?, currentPresetName: String? = nil, nameLookupError: String? = nil, rawPayloadHex: String? = nil, packetCount: Any? = nil, totalBytes: Any? = nil) -> [String: Any] {
        let resolvedName = currentPresetName ?? presetInfo.name
        let nameSource = currentPresetName != nil ? "current-name-request" : "preset-payload-parser"

        var responseData: [String: Any] = [
            "requestedPresetId": requestedPresetId as Any,
            "source": "currentPreset",
            "name": resolvedName,
            "nameSource": nameSource,
            "currentSnapshot": presetInfo.currentSnapshot,
            "blockCount": presetInfo.blocks.count,
            "blocks": presetInfo.blocks.map { block in
                [
                    "slot": block.slot,
                    "modelName": block.modelName,
                    "type": block.type,
                    "enabled": block.enabled,
                    "params": block.params,
                ]
            },
        ]

        if let nameLookupError {
            responseData["nameLookupError"] = nameLookupError
        }
        if let rawPayloadHex {
            responseData["rawPayloadHex"] = rawPayloadHex
        }
        if let packetCount {
            responseData["packetCount"] = packetCount
        }
        if let totalBytes {
            responseData["totalBytes"] = totalBytes
        }

        return responseData
    }
}

private enum CurrentPresetDataReader {
    static func read(timeout: UInt32, maxPackets: Int, verbose: Bool, requestedPresetId: Int?, includeName: Bool = true) throws -> [String: Any] {
        var currentPresetName: String? = nil
        var nameLookupError: String? = nil
        if includeName {
            do {
                let nameManager = USBManager()
                let nameResult = try nameManager.connectHandshake(timeoutMs: timeout, maxPackets: maxPackets, requestCurrentPresetName: true)
                currentPresetName = nameResult["currentPresetName"] as? String
                if currentPresetName == nil {
                    nameLookupError = "Current preset name was not present in device response"
                }
            } catch USBError.deviceNotFound {
                nameLookupError = "HX Stomp not connected via USB"
            } catch USBError.transferFailed(let message), USBError.connectionFailed(let message), USBError.invalidResponse(let message) {
                nameLookupError = message
            } catch {
                nameLookupError = error.localizedDescription
            }
        }

        let result = try requestPresetDataWithRetry(timeout: timeout, maxPackets: maxPackets, verbose: verbose, retryOnce: includeName)

        guard let connected = result["connected"] as? Bool, connected else {
            throw USBError.connectionFailed("Failed to connect to HX Stomp")
        }

        guard let payloadHex = result["payloadHex"] as? String, !payloadHex.isEmpty else {
            throw USBError.invalidResponse("No preset data received from device")
        }

        let parser = PresetDataParser(hexString: payloadHex)
        let presetInfo = parser.parse()

        return PresetResponseSupport.responseData(
            for: presetInfo,
            requestedPresetId: requestedPresetId,
            currentPresetName: currentPresetName,
            nameLookupError: nameLookupError,
            rawPayloadHex: verbose ? payloadHex : nil,
            packetCount: verbose ? result["packetCount"] : nil,
            totalBytes: verbose ? result["totalBytes"] : nil
        )
    }

    private static func requestPresetDataWithRetry(timeout: UInt32, maxPackets: Int, verbose: Bool, retryOnce: Bool) throws -> [String: Any] {
        do {
            let result = try USBManager().requestPresetData(timeoutMs: timeout, maxPackets: maxPackets, verbose: verbose)
            if retryOnce, (result["connected"] as? Bool) != true {
                return try USBManager().requestPresetData(timeoutMs: timeout, maxPackets: maxPackets, verbose: verbose)
            }
            return result
        } catch {
            guard retryOnce else { throw error }
            return try USBManager().requestPresetData(timeoutMs: timeout, maxPackets: maxPackets, verbose: verbose)
        }
    }
}

struct GetCurrentPreset: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get-current",
        abstract: "Get details for the currently loaded preset"
    )

    @Option(help: "USB read/write timeout in milliseconds")
    var timeout: UInt32 = 250

    @Option(help: "Maximum inbound packets to read")
    var maxPackets: Int = 200

    @Flag(name: .shortAndLong, help: "Include full raw data")
    var verbose = false

    @Flag(help: "Skip separate current-name request; faster but name may be Unknown")
    var skipName = false

    func run() throws {
        do {
            let responseData = try CurrentPresetDataReader.read(timeout: timeout, maxPackets: maxPackets, verbose: verbose, requestedPresetId: nil, includeName: !skipName)
            print(JSONResponse.success(data: responseData).toJSON())
        } catch USBError.deviceNotFound {
            print(JSONResponse.deviceNotFound().toJSON())
        } catch USBError.transferFailed(let message), USBError.connectionFailed(let message), USBError.invalidResponse(let message) {
            print(JSONResponse.failure(code: "USB_ERROR", message: message).toJSON())
        }
    }
}

struct GetPreset: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Deprecated alias for get-current; arbitrary preset reads are not implemented yet"
    )

    @Option(help: "Requested preset ID (0-125). Warning: currently ignored; reads current preset")
    var id: Int?

    @Option(help: "USB read/write timeout in milliseconds")
    var timeout: UInt32 = 250

    @Option(help: "Maximum inbound packets to read")
    var maxPackets: Int = 200

    @Flag(name: .shortAndLong, help: "Include full raw data")
    var verbose = false

    func run() throws {
        do {
            var responseData = try CurrentPresetDataReader.read(timeout: timeout, maxPackets: maxPackets, verbose: verbose, requestedPresetId: id)
            responseData["deprecated"] = true
            responseData["warning"] = "preset get is deprecated and reads the current preset only; use preset get-current. Arbitrary preset reads by ID are not implemented yet."
            print(JSONResponse.success(data: responseData).toJSON())
        } catch USBError.deviceNotFound {
            print(JSONResponse.deviceNotFound().toJSON())
        } catch USBError.transferFailed(let message), USBError.connectionFailed(let message), USBError.invalidResponse(let message) {
            print(JSONResponse.failure(code: "USB_ERROR", message: message).toJSON())
        }
    }
}

struct ParsePresetFixture: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "parse-fixture",
        abstract: "Parse a preset payload fixture from a hex file without connecting to USB"
    )

    @Argument(help: "Path to a preset payload hex fixture")
    var path: String

    @Flag(name: .shortAndLong, help: "Include full raw fixture data")
    var verbose = false

    func run() throws {
        do {
            let url = URL(fileURLWithPath: path)
            let payloadHex = try String(contentsOf: url, encoding: .utf8)
            let presetInfo = PresetDataParser(hexString: payloadHex).parse()
            let responseData = PresetResponseSupport.responseData(
                for: presetInfo,
                requestedPresetId: nil,
                rawPayloadHex: verbose ? payloadHex.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                packetCount: nil,
                totalBytes: nil
            )
            print(JSONResponse.success(data: responseData).toJSON())
        } catch {
            print(JSONResponse.failure(code: "FIXTURE_ERROR", message: error.localizedDescription).toJSON())
        }
    }
}
