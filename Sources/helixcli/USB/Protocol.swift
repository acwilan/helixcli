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
    /// Pattern: 83 66 cd 04 04 ... 6d aa <name>
    private func extractPresetName() -> String {
        let pattern: [UInt8] = [0x83, 0x66, 0xcd, 0x04, 0x04]
        guard let markerIndex = find(pattern, in: data, startingAt: 0) else {
            return "Unknown"
        }

        // Look for 0x6d marker which precedes the name
        let searchStart = markerIndex + pattern.count
        for i in searchStart..<min(searchStart + 50, data.count) {
            if data[i] == 0x6d {
                // Name starts after 0x6d and length byte
                let nameStart = i + 2
                var nameBytes: [UInt8] = []
                for j in nameStart..<min(nameStart + 32, data.count) {
                    if data[j] == 0x00 { break }
                    if data[j] >= 32 && data[j] <= 126 {
                        nameBytes.append(data[j])
                    }
                }
                if let name = String(bytes: nameBytes, encoding: .ascii), !name.isEmpty {
                    return name
                }
            }
        }

        return "Unknown"
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

        // Skip to where actual slot data starts (look for 80 13 pattern)
        while cursor < data.count - 1 {
            if data[cursor] == 0x80 && (data[cursor + 1] == 0x13 || data[cursor + 1] == 0x14) {
                break
            }
            cursor += 1
        }

        // Parse each slot
        var slotIndex = 0
        while cursor < data.count - 2 && slotIndex < slotPositions.count {
            // Slot header: 80 13 or 80 14
            guard data[cursor] == 0x80 else {
                cursor += 1
                continue
            }

            let slotStart = cursor

            // Find end of this slot (next 80 13/14 or end marker)
            var slotEnd = cursor + 2
            while slotEnd < data.count - 1 {
                if data[slotEnd] == 0x80 && (data[slotEnd + 1] == 0x13 || data[slotEnd + 1] == 0x14) {
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

        guard slotData.count >= 4 else {
            return PresetBlock(slot: position, modelName: modelName, type: type, enabled: enabled, params: params)
        }

        // Check if empty slot (81 14 c0)
        if slotData.contains(0x81) && slotData.contains(0x14) && slotData.contains(0xc0) {
            return PresetBlock(slot: position, modelName: "Empty", type: "None", enabled: false, params: params)
        }

        // Check enabled status (0x0a c3 = enabled, 0x0a c2 = disabled)
        if let enabledIndex = slotData.firstIndex(of: 0x0a) {
            if enabledIndex + 1 < slotData.count {
                enabled = slotData[enabledIndex + 1] == 0xc3
            }
        }

        // Extract model ID (look for pattern around 14 or 17 marker)
        // This is a simplified extraction - full parsing would require
        // the complete modules dictionary from the Python reference
        if let modelMarker = slotData.firstIndex(of: 0x14) {
            if modelMarker + 2 < slotData.count {
                let modelId = String(format: "%02x%02x", slotData[modelMarker + 1], slotData[modelMarker + 2])
                modelName = modelIdToName(modelId)

                // Determine type based on slot position and content
                if position.starts(with: "A") {
                    type = "Effect"
                } else {
                    type = "Effect"
                }
            }
        }

        // Try to extract parameters
        // Look for parameter markers (typically starting with 0x07)
        if let paramMarker = slotData.firstIndex(of: 0x07) {
            if paramMarker + 5 < slotData.count {
                // Simplified parameter extraction
                // Full implementation would parse IEEE 754 floats
                let paramCount = Int(slotData[paramMarker + 2])
                params["paramCount"] = paramCount
            }
        }

        return PresetBlock(slot: position, modelName: modelName, type: type, enabled: enabled, params: params)
    }

    /// Convert model ID to name (simplified - would need full module mapping)
    private func modelIdToName(_ id: String) -> String {
        // This is a simplified mapping
        // Full implementation would include all the modules from the Python reference
        return "Model \(id)"
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
