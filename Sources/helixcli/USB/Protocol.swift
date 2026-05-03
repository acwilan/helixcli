import Foundation

/// Logical streams used by the Helix USB protocol on endpoint 0x01/0x81.
enum HelixStream: UInt8 {
    case x1 = 0x01
    case x2 = 0x02
    case x80 = 0x80

    var hostStreamBytes: (UInt8, UInt8, UInt8) {
        switch self {
        case .x1: return (0x01, 0x10, 0xef)
        case .x2: return (0x02, 0x10, 0xf0)
        case .x80: return (0x80, 0x10, 0xed)
        }
    }

    var deviceStreamBytes: (UInt8, UInt8, UInt8) {
        switch self {
        case .x1: return (0xef, 0x03, 0x01)
        case .x2: return (0xf0, 0x03, 0x02)
        case .x80: return (0xed, 0x03, 0x80)
        }
    }
}

/// Protocol command packet, directly inspired by kempline/helix_usb.
struct HelixCommand {
    let template: [UInt8?]
    let stream: HelixStream

    func resolvedPacket(sequence: UInt8) -> Data {
        Data(template.map { $0 ?? sequence })
    }
}

/// Packet templates copied from the Python reference. `nil` marks the dynamic
/// sequence byte (`"XX"` in helix_usb).
enum HelixPackets {
    static let connectStart = HelixCommand(
        template: [0x0c, 0x00, 0x00, 0x28, 0x01, 0x10, 0xef, 0x03, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01, 0x00, 0x21, 0x00, 0x10, 0x00, 0x00],
        stream: .x1
    )

    static let requestPresetNames = HelixCommand(
        template: [0x1d, 0x00, 0x00, 0x18, 0x01, 0x10, 0xef, 0x03, 0x00, nil, 0x00, 0x0c, 0x38, 0x10, 0x00, 0x00, 0x01, 0x00, 0x02, 0x00, 0x0d, 0x00, 0x00, 0x00, 0x83, 0x66, 0xcd, 0x03, 0xea, 0x64, 0x01, 0x65, 0x82, 0x6b, 0x00, 0x65, 0x02, 0x00, 0x00, 0x00],
        stream: .x1
    )

    static func requestPresetData(session: UInt8, packetLow: UInt8, packetHigh: UInt8, requestSession: UInt8) -> HelixCommand {
        HelixCommand(
            template: [0x19, 0x00, 0x00, 0x18, 0x80, 0x10, 0xed, 0x03, 0x00, nil, 0x00, 0x0c, session, packetLow, packetHigh, 0x00, 0x01, 0x00, 0x06, 0x00, 0x09, 0x00, 0x00, 0x00, 0x83, 0x66, 0xcd, 0x03, requestSession, 0x64, 0x16, 0x65, 0xc0, 0x00, 0x00, 0x00],
            stream: .x80
        )
    }

    static func ackPresetNames(packetSequence: UInt8) -> HelixCommand {
        HelixCommand(
            template: [0x08, 0x00, 0x00, 0x18, 0x01, 0x10, 0xef, 0x03, 0x00, nil, 0x00, 0x08, 0x38, packetSequence &+ 9, 0x00, 0x00],
            stream: .x1
        )
    }
}

/// Incrementing sequence state for each protocol stream.
struct HelixSequenceState {
    private(set) var x1: UInt8 = 0x02
    private(set) var x2: UInt8 = 0x02
    private(set) var x80: UInt8 = 0x02

    mutating func next(for stream: HelixStream) -> UInt8 {
        switch stream {
        case .x1:
            defer { x1 &+= 1 }
            return x1
        case .x2:
            defer { x2 &+= 1 }
            return x2
        case .x80:
            defer { x80 &+= 1 }
            return x80
        }
    }
}

/// Parsers for response payloads from HX Stomp.
struct HelixResponseParser {
    static func parseCurrentPresetName(from data: Data) -> String? {
        let bytes = Array(data)
        let pattern: [UInt8] = [0x83, 0x66, 0xcd, 0x04, 0x04]
        let searchStart: Int
        if let marker = find(pattern, in: bytes, startingAt: 0) {
            searchStart = marker + pattern.count
        } else {
            // Fallback for the observed response shape in the Python reference:
            // payload has metadata before a 24-byte ASCII name around offset 27.
            guard bytes.count > 51 else { return nil }
            return decodeASCIIName(Array(bytes[27..<min(bytes.count, 51)]))
        }

        guard searchStart < bytes.count else { return nil }
        let tail = Array(bytes[searchStart...])

        // Current-preset response observed live:
        //   ... 83 66 cd 04 04 67 00 68 86 6b cd 00 00 6c cd 00 01 6d aa <ASCII name> 00 ...
        // The 0x6d tag precedes a length-ish byte, then the null-terminated name.
        for idx in 0..<max(0, min(tail.count - 2, 48)) where tail[idx] == 0x6d {
            if let candidate = decodeASCIIName(Array(tail.dropFirst(idx + 2).prefix(24))), candidate.count >= 2 {
                return candidate
            }
        }

        // Last-resort scan for a readable null-terminated ASCII run.
        for offset in 0..<min(tail.count, 48) {
            let candidate = decodeASCIIName(Array(tail.dropFirst(offset).prefix(24)))
            if let candidate, candidate.count >= 4, candidate.range(of: #"^[A-Za-z0-9].*"#, options: .regularExpression) != nil {
                return candidate
            }
        }
        return nil
    }

    static func parsePresetNames(from packets: [Data], expectedCount: Int = 125) -> [Preset] {
        // Preset-name records can be split across USB reads, and libusb may also
        // concatenate multiple protocol frames in one read. Scan the continuous byte
        // stream directly instead of assuming each Data starts with exactly one
        // 16-byte protocol header.
        let stream = packets.flatMap { Array($0) }
        let pattern: [UInt8] = [0x81, 0xcd, 0x00]
        let recordLength = 25
        var presetsByIndex: [Int: String] = [:]
        var fallback: [String] = []
        var idx = 0

        while idx <= stream.count - pattern.count {
            guard let marker = find(pattern, in: stream, startingAt: idx) else { break }
            guard marker + recordLength <= stream.count else { break }

            let record = Array(stream[marker..<marker + recordLength])
            let nameBytes = record[9..<25]
            let name = String(bytes: nameBytes.prefix { $0 != 0x00 }.map { (32...126).contains($0) ? $0 : UInt8(ascii: "?") }, encoding: .ascii) ?? "<unknown>"

            if let presetIndex = extractPresetIndex(record), presetIndex < expectedCount {
                presetsByIndex[presetIndex] = name
            } else {
                fallback.append(name)
            }
            idx = marker + recordLength
        }

        var fallbackIndex = 0
        return (0..<expectedCount).map { presetId in
            let name = presetsByIndex[presetId] ?? {
                defer { fallbackIndex += 1 }
                return fallbackIndex < fallback.count ? fallback[fallbackIndex] : "<empty>"
            }()
            return Preset(id: presetId, name: name, bank: "User")
        }
    }

    private static func decodeASCIIName(_ bytes: [UInt8]) -> String? {
        let nameBytes = bytes.prefix { $0 != 0x00 }.map { (32...126).contains($0) ? $0 : UInt8(ascii: "?") }
        guard !nameBytes.isEmpty else { return nil }
        return String(bytes: nameBytes, encoding: .ascii)
    }

    private static func find(_ pattern: [UInt8], in bytes: [UInt8], startingAt start: Int) -> Int? {
        guard !pattern.isEmpty, bytes.count >= pattern.count else { return nil }
        for i in start...(bytes.count - pattern.count) where Array(bytes[i..<i + pattern.count]) == pattern {
            return i
        }
        return nil
    }

    private static func extractPresetIndex(_ record: [UInt8]) -> Int? {
        guard record.count >= 9 else { return nil }
        let metadata = record[3..<9]
        var idx6b: Int?
        var idx6c: Int?
        for (offset, byte) in metadata.enumerated() {
            let nextIndex = metadata.index(metadata.startIndex, offsetBy: offset + 1)
            guard nextIndex < metadata.endIndex else { continue }
            if byte == 0x6b { idx6b = Int(metadata[nextIndex]) }
            if byte == 0x6c { idx6c = Int(metadata[nextIndex]) }
        }
        guard let idx6b, let idx6c else { return nil }
        return (idx6b * 25) + idx6c
    }
}

/// Represents a parsed preset block/slot
struct PresetBlock {
    let slot: String
    let modelName: String
    let type: String
    let enabled: Bool
    let params: [String: Any]
}

/// Parsed preset information
struct PresetInfo {
    let name: String
    let currentSnapshot: Int
    let blocks: [PresetBlock]
}

/// Parser for preset data from HX Stomp
/// Based on Python reference: helix_usb/utils/preset_parser.py
class PresetDataParser {
    private let hexString: String
    private var data: [UInt8]

    /// Convert 4-byte IEEE 754 big-endian float to Swift Float
    private func ieee754ToFloat(_ bytes: [UInt8]) -> Float {
        guard bytes.count == 4 else { return 0.0 }
        // IEEE 754 big-endian: sign(1) | exponent(8) | mantissa(23)
        let bits = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        return Float(bitPattern: bits)
    }

    init(hexString: String) {
        self.hexString = hexString
        // Convert hex string to bytes
        var bytes: [UInt8] = []
        let cleanHex = hexString.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\n", with: "")
        var index = cleanHex.startIndex
        while index < cleanHex.endIndex {
            let nextIndex = cleanHex.index(index, offsetBy: 2, limitedBy: cleanHex.endIndex) ?? cleanHex.endIndex
            if let byte = UInt8(cleanHex[index..<nextIndex], radix: 16) {
                bytes.append(byte)
            }
            index = nextIndex
        }
        self.data = bytes
    }

    /// Parse the preset data and extract information
    func parse() -> PresetInfo {
        let name = extractPresetName()
        let currentSnapshot = extractCurrentSnapshot()
        let blocks = extractBlocks()

        return PresetInfo(
            name: name,
            currentSnapshot: currentSnapshot,
            blocks: blocks
        )
    }

    /// Extract preset name from the data
    /// Looks for ASCII string patterns in the preset data.
    /// The preset data contains multiple ASCII strings (model names, firmware versions, etc.)
    /// plus the preset name itself. We scan for strings >= 5 chars and filter.
    private func extractPresetName() -> String {
        // Strategy: Look for common ASCII strings that are NOT firmware version, SNAPSHOT, or model names
        // The preset name typically appears near model data and has specific characteristics:
        // - It's a single string, not part of a repeating pattern
        // - It appears before slot data
        // - It contains alphanumeric characters, spaces, hyphens, and common punctuation

        // Find all ASCII strings >= 5 chars
        var strings: [(offset: Int, value: String)] = []
        var currentOffset = 0
        var currentString = ""
        var stringStart = 0

        while currentOffset < data.count {
            let byte = data[currentOffset]
            if byte >= 32 && byte <= 126 {
                if currentString.isEmpty {
                    stringStart = currentOffset
                }
                currentString.append(Character(UnicodeScalar(byte)))
            } else {
                if currentString.count >= 5 {
                    strings.append((stringStart, currentString))
                }
                currentString = ""
            }
            currentOffset += 1
        }
        if currentString.count >= 5 {
            strings.append((stringStart, currentString))
        }

        // Filter: exclude firmware version patterns, SNAPSHOT, model names
        let excludePatterns = ["v3.", "SNAPSHOT", "Deluxe", "Vintage", "Phaser", "Distortion", "Reverb", "Delay", "Chorus", "Flanger", "Tremolo", "Wah", "Compressor", "EQ", "Gate", "Limit", "Pitch", "Synth", "Filter", "Looper", "Cab", "Amp", "Tube", "Screamer", "Overdrive", "Fuzz"]

        let candidates = strings.filter { s in
            !s.value.hasPrefix("v3.") &&
            !s.value.hasPrefix("SNAPSHOT") &&
            !excludePatterns.contains(where: { s.value.contains($0) })
        }

        // The preset name is typically the first non-excluded string after firmware version
        // or the string immediately before the slot section (8215 marker)
        if let slotSectionStart = find([0x82, 0x15], in: data, startingAt: 0) {
            let nearbyStrings = candidates.filter { $0.offset < slotSectionStart && $0.offset > 0 }
            if !nearbyStrings.isEmpty {
                // Return the string closest to but before slot section
                return nearbyStrings.sorted { $0.offset > $1.offset }.first?.value ?? "Unknown"
            }
        }

        // Fallback: first substantial string that's not firmware
        let firmwareString = strings.first { $0.value.hasPrefix("v3.") }
        let firmwareOffset = firmwareString?.offset ?? 0
        let postFirmware = candidates.filter { $0.offset > firmwareOffset + 20 }
        return postFirmware.first?.value ?? "Unknown"
    }

    /// Extract current snapshot from the data
    /// Pattern: 86 06 00/01/02 07 02 08
    private func extractCurrentSnapshot() -> Int {
        // Snapshot patterns in the data
        if find([0x86, 0x06, 0x00, 0x07, 0x02, 0x08], in: data, startingAt: 0) != nil {
            return 1
        }
        if find([0x86, 0x06, 0x01, 0x07, 0x02, 0x08], in: data, startingAt: 0) != nil {
            return 2
        }
        if find([0x86, 0x06, 0x02, 0x07, 0x02, 0x08], in: data, startingAt: 0) != nil {
            return 3
        }
        return 1 // Default to snapshot 1
    }

    /// Extract blocks/slots from the preset data
    private func extractBlocks() -> [PresetBlock] {
        var blocks: [PresetBlock] = []

        // Look for slot markers: 82 15 or 82 13
        // These mark the beginning of slot information
        var cursor = 0
        let slotPositions = ["A1", "A2", "A3", "A4", "A5", "A6", "A7", "A8",
                             "B1", "B2", "B3", "B4", "B5", "B6", "B7", "B8"]

        // Find the slot section
        guard let slotSectionStart = find([0x82, 0x15], in: data, startingAt: 0) else {
            return blocks
        }

        cursor = slotSectionStart + 2

        // Skip to where actual slot data starts (look for 82 13 pattern)
        while cursor < data.count - 1 {
            if data[cursor] == 0x82 && (data[cursor + 1] == 0x13 || data[cursor + 1] == 0x14) {
                break
            }
            cursor += 1
        }

        // Parse each slot
        // The slot data uses 82 13 / 82 14 markers (not 80 13 / 80 14)
        var slotIndex = 0
        while cursor < data.count - 2 && slotIndex < slotPositions.count {
            // Slot header: 82 13 or 82 14
            guard data[cursor] == 0x82 else {
                cursor += 1
                continue
            }

            let slotStart = cursor

            // Find end of this slot (next 82 13/14 or end marker)
            var slotEnd = cursor + 2
            while slotEnd < data.count - 1 {
                if data[slotEnd] == 0x82 && (data[slotEnd + 1] == 0x13 || data[slotEnd + 1] == 0x14) {
                    break
                }
                if data[slotEnd] == 0x08 && data[slotEnd + 1] == 0x95 {
                    break // Footswitch section marker
                }
                slotEnd += 1
            }

            let slotData = Array(data[slotStart..<slotEnd])
            let block = parseSlot(slotData, position: slotPositions[slotIndex])
            blocks.append(block)

            slotIndex += 1
            cursor = slotEnd
        }

        return blocks
    }

    /// Parse a single slot's data
    private func parseSlot(_ slotData: [UInt8], position: String) -> PresetBlock {
        var modelName = "Empty"
        var type = "None"
        var enabled = false
        var params: [String: Any] = [:]

        guard slotData.count >= 6 else {
            return PresetBlock(slot: position, modelName: modelName, type: type, enabled: enabled, params: params)
        }

        // Empty slots are compact records like: 82 13 08 14 c0.
        // Do not treat any slot containing c0 bytes as empty; c0 also appears inside
        // normal float/parameter payloads.
        if slotData.count <= 5 && slotData.last == 0xc0 {
            return PresetBlock(slot: position, modelName: "Empty", type: "None", enabled: false, params: params)
        }

        // Check enabled status (0x0a c3 = enabled, 0x0a c2 = disabled)
        if let enabledIndex = slotData.firstIndex(of: 0x0a) {
            if enabledIndex + 1 < slotData.count {
                enabled = slotData[enabledIndex + 1] == 0xc3
            }
        }

        // Extract model IDs from Helix slot fields.
        // Standard effect/amp blocks encode the primary module after marker 0x19
        // and before marker 0x1a. Dual blocks can also include a second module
        // after 0x1a and before 0x09. This matches helix_usb's SlotInfo parser
        // (`amp_effect_slot_a` / `amp_effect_slot_b`).
        let modelIds = extractModelIds(from: slotData)
        if !modelIds.isEmpty {
            params["modelIds"] = modelIds
            if let first = modelIds.first {
                params["modelId"] = first
            }

            let modelInfos = modelIds.map { id -> (id: String, info: HelixModelInfo?) in
                (id, HelixModelCatalog.lookup(id))
            }
            let displayNames = modelInfos.map { item in
                item.info?.name ?? "Unknown Model \(item.id)"
            }
            modelName = displayNames.joined(separator: " + ")

            let categories = modelInfos.compactMap { $0.info?.category }
            if !categories.isEmpty {
                type = Array(Set(categories)).sorted().joined(separator: " + ")
            } else {
                type = "Unknown"
            }
        }

        // Try to extract parameters.
        // Look for the first 83 02 pair; many slots also contain other 83 markers
        // such as 83 17, so firstIndex(of: 0x83) is not specific enough.
        if let paramMarker = find([0x83, 0x02], in: slotData, startingAt: 0) {
            let paramStart = paramMarker + 2
            var values: [Double] = []
            var cursor = paramStart

            while cursor < slotData.count {
                if cursor + 4 < slotData.count && slotData[cursor] == 0xca {
                    let floatBytes = slotData[cursor + 1..<cursor + 5]
                    values.append(Double(self.ieee754ToFloat(Array(floatBytes))))
                    cursor += 5
                } else if slotData[cursor] == 0xc2 {
                    values.append(0.0)
                    cursor += 1
                } else if slotData[cursor] == 0xc3 {
                    values.append(1.0)
                    cursor += 1
                } else if slotData[cursor] == 0x90 {
                    break
                } else {
                    cursor += 1
                }
            }

            if !values.isEmpty {
                params["values"] = values
                params["paramCount"] = values.count
                params["namedValues"] = HelixParameterCatalog.namedValues(for: values, modelIds: modelIds, category: type).map(\.json)
            }
        }

        return PresetBlock(slot: position, modelName: modelName, type: type, enabled: enabled, params: params)
    }

    private func extractModelIds(from slotData: [UInt8]) -> [String] {
        var ids: [String] = []
        if let primary = bytesBetween(startMarker: 0x19, endMarker: 0x1a, in: slotData), !primary.isEmpty, primary != [0xff] {
            ids.append(hex(primary))
        }
        if let secondary = bytesBetween(startMarker: 0x1a, endMarker: 0x09, in: slotData), !secondary.isEmpty, secondary != [0xff] {
            ids.append(hex(secondary))
        }
        return ids
    }

    private func bytesBetween(startMarker: UInt8, endMarker: UInt8, in bytes: [UInt8]) -> [UInt8]? {
        guard let start = bytes.firstIndex(of: startMarker) else { return nil }
        var cursor = start + 1
        var result: [UInt8] = []
        while cursor < bytes.count {
            if bytes[cursor] == endMarker {
                return result
            }
            result.append(bytes[cursor])
            cursor += 1
        }
        return nil
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Find pattern in byte array
    private func find(_ pattern: [UInt8], in bytes: [UInt8], startingAt start: Int) -> Int? {
        guard !pattern.isEmpty, bytes.count >= pattern.count else { return nil }
        for i in start...(bytes.count - pattern.count) {
            if Array(bytes[i..<i + pattern.count]) == pattern {
                return i
            }
        }
        return nil
    }
}
