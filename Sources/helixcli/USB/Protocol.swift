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
