import Foundation

/// HX Stomp USB protocol command types
enum HelixCommandType: UInt8 {
    case getPresetNames = 0x01
    case switchPreset = 0x02
    case getCurrentPreset = 0x03
    case setBlockParam = 0x04
    case getSnapshots = 0x05
    case switchSnapshot = 0x06
    case toggleBlock = 0x07
    case getBlockData = 0x08
}

/// Represents a command packet to send to HX Stomp
struct HelixCommand {
    let type: HelixCommandType
    let payload: Data
    
    /// Build the full packet with header and checksum
    func buildPacket() -> Data {
        var packet = Data()
        
        // Protocol header (based on helix_usb reverse engineering)
        packet.append(0xF0) // Start byte
        packet.append(type.rawValue)
        packet.append(contentsOf: payload)
        packet.append(0xF7) // End byte
        
        return packet
    }
}

/// Parses responses from HX Stomp
struct HelixResponseParser {
    /// Parse preset name list response
    static func parsePresetNames(from data: Data) -> [Preset] {
        // TODO: Implement based on helix_usb protocol
        return []
    }
    
    /// Parse current preset data
    static func parseCurrentPreset(from data: Data) -> Preset? {
        // TODO: Implement based on helix_usb protocol
        return nil
    }
    
    /// Parse block data
    static func parseBlockData(from data: Data) -> Block? {
        // TODO: Implement based on helix_usb protocol
        return nil
    }
    
    /// Parse snapshot list
    static func parseSnapshotList(from data: Data) -> [Snapshot] {
        // TODO: Implement based on helix_usb protocol
        return []
    }
}
