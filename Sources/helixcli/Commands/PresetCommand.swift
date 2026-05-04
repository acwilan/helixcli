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
            BackupCurrentPreset.self,
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
            "snapshots": presetInfo.snapshots.map { snapshot in
                [
                    "id": snapshot.id,
                    "name": snapshot.name,
                    "isCurrent": snapshot.id == presetInfo.currentSnapshot,
                ]
            },
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


private enum PresetBackupSupport {
    static let format = "helixcli-preset-backup"
    static let formatVersion = 1

    static func backupData(presetData: [String: Any], device: USBDeviceDescriptor?) -> [String: Any] {
        var data: [String: Any] = [
            "format": format,
            "formatVersion": formatVersion,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "tool": [
                "name": "helixcli",
                "version": "0.1.0",
            ],
            "source": "currentPreset",
            "restoreStatus": "not-implemented",
            "restoreWarning": "This file is a read-only backup artifact. helixcli restore is intentionally not implemented yet.",
            "preset": presetData,
        ]

        if let device {
            data["device"] = device.dictionary
        }

        return data
    }

    static func defaultOutputPath(for presetName: String?) -> String {
        let name = sanitizeFilenameComponent(presetName ?? "current-preset")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())
        return "backups/\(timestamp)-\(name).helixbackup.json"
    }

    static func writeJSON(_ object: [String: Any], to path: String) throws -> (path: String, byteCount: Int) {
        let expandedPath = (path as NSString).expandingTildeInPath
        let url: URL
        if expandedPath.hasPrefix("/") {
            url = URL(fileURLWithPath: expandedPath)
        } else {
            url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(expandedPath)
        }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sanitized = sanitizeJSONValue(object)
        let jsonData = try JSONSerialization.data(withJSONObject: sanitized, options: [.prettyPrinted, .sortedKeys])
        try jsonData.write(to: url, options: [.atomic])
        return (url.path, jsonData.count)
    }

    private static func sanitizeFilenameComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars).replacingOccurrences(of: #"-+"#, with: "-", options: .regularExpression)
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "current-preset" : trimmed.lowercased()
    }

    private static func sanitizeJSONValue(_ value: Any) -> Any {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let child = mirror.children.first else { return NSNull() }
            return sanitizeJSONValue(child.value)
        }

        if let dict = value as? [String: Any] {
            return dict.mapValues { sanitizeJSONValue($0) }
        }
        if let array = value as? [Any] {
            return array.map { sanitizeJSONValue($0) }
        }
        if value is NSNull || value is String || value is Int || value is Double || value is Bool {
            return value
        }
        if let float = value as? Float {
            return Double(float)
        }
        return String(describing: value)
    }
}

struct BackupCurrentPreset: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "backup-current",
        abstract: "Backup the currently loaded preset to a local JSON file"
    )

    @Option(help: "Output backup file path. Defaults to backups/<timestamp>-<preset-name>.helixbackup.json")
    var output: String?

    @Option(help: "USB read/write timeout in milliseconds")
    var timeout: UInt32 = 250

    @Option(help: "Maximum inbound packets to read")
    var maxPackets: Int = 200

    @Flag(help: "Skip separate current-name request; faster but backup name may be Unknown")
    var skipName = false

    func run() throws {
        do {
            let presetData = try CurrentPresetDataReader.read(timeout: timeout, maxPackets: maxPackets, verbose: true, requestedPresetId: nil, includeName: !skipName)
            let device = try? USBManager().findSupportedDevice()
            let backupData = PresetBackupSupport.backupData(presetData: presetData, device: device ?? nil)
            let presetName = presetData["name"] as? String
            let targetPath = output ?? PresetBackupSupport.defaultOutputPath(for: presetName)
            let written = try PresetBackupSupport.writeJSON(backupData, to: targetPath)

            print(JSONResponse.success(data: [
                "path": written.path,
                "byteCount": written.byteCount,
                "format": PresetBackupSupport.format,
                "formatVersion": PresetBackupSupport.formatVersion,
                "source": "currentPreset",
                "presetName": presetName as Any,
                "blockCount": presetData["blockCount"] as Any,
                "snapshotCount": (presetData["snapshots"] as? [[String: Any]])?.count as Any,
                "restoreStatus": "not-implemented",
            ]).toJSON())
        } catch USBError.deviceNotFound {
            print(JSONResponse.deviceNotFound().toJSON())
        } catch USBError.transferFailed(let message), USBError.connectionFailed(let message), USBError.invalidResponse(let message) {
            print(JSONResponse.failure(code: "USB_ERROR", message: message).toJSON())
        } catch {
            print(JSONResponse.failure(code: "BACKUP_ERROR", message: error.localizedDescription).toJSON())
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
