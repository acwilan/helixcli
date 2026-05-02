import Foundation

/// Represents an HX Stomp preset
struct Preset: Codable {
    let id: Int
    let name: String
    let bank: String
    
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case bank
    }
}

/// Represents an effect block in a preset
struct Block: Codable {
    let slot: String
    let type: BlockType
    let model: String
    let enabled: Bool
    let params: [String: Double]?
    
    enum CodingKeys: String, CodingKey {
        case slot
        case type
        case model
        case enabled
        case params
    }
}

/// HX Stomp block types
enum BlockType: String, Codable {
    case distortion
    case delay
    case reverb
    case modulation
    case filter
    case wah
    case amp
    case cab
    case ir = "impulse_response"
    case eq
    case dynamics
    case pitch
    case synth
    case volume
    case sendReturn = "send_return"
    case looper
    case unknown
}

/// Represents a snapshot in a preset
struct Snapshot: Codable {
    let id: Int
    let name: String
    
    enum CodingKeys: String, CodingKey {
        case id
        case name
    }
}
