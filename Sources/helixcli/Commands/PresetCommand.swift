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
    
    func run() {
        let response = JSONResponse.success(data: [
            "message": "Listing presets - not yet implemented",
            "presets": []
        ])
        print(response.toJSON())
    }
}

struct CurrentPreset: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "current",
        abstract: "Get current preset"
    )
    
    func run() {
        let response = JSONResponse.success(data: [
            "message": "Getting current preset - not yet implemented"
        ])
        print(response.toJSON())
    }
}

struct SwitchPreset: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "switch",
        abstract: "Switch to a preset"
    )
    
    @Argument(help: "Preset ID (0-127)")
    var presetId: Int
    
    func run() {
        guard presetId >= 0 && presetId <= 127 else {
            print(JSONResponse.failure(code: "INVALID_PRESET", message: "Preset ID must be between 0 and 127").toJSON())
            return
        }
        
        let response = JSONResponse.success(data: [
            "message": "Switching to preset \(presetId) - not yet implemented",
            "presetId": presetId
        ])
        print(response.toJSON())
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
