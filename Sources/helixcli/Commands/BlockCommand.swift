import ArgumentParser
import Foundation

struct BlockCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "block",
        abstract: "Manage HX Stomp effect blocks",
        subcommands: [
            ListBlocks.self,
            ToggleBlock.self,
            SetParam.self,
            GetBlock.self,
        ]
    )
}

private enum BlockReadSupport {
    static func readCurrentBlocks(timeout: UInt32, maxPackets: Int) throws -> [PresetBlock] {
        let manager = USBManager()
        let result = try manager.requestPresetData(timeoutMs: timeout, maxPackets: maxPackets, verbose: false)

        guard let connected = result["connected"] as? Bool, connected else {
            throw USBError.connectionFailed("Failed to connect to HX Stomp")
        }

        guard let payloadHex = result["payloadHex"] as? String, !payloadHex.isEmpty else {
            throw USBError.invalidResponse("No preset data received from device")
        }

        return PresetDataParser(hexString: payloadHex).parse().blocks
    }

    static func json(_ block: PresetBlock) -> [String: Any] {
        [
            "slot": block.slot,
            "modelName": block.modelName,
            "type": block.type,
            "enabled": block.enabled,
            "params": block.params,
        ]
    }
}

struct ListBlocks: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List blocks in current preset"
    )

    @Option(help: "USB read/write timeout in milliseconds")
    var timeout: UInt32 = 250

    @Option(help: "Maximum inbound packets to read")
    var maxPackets: Int = 200

    @Flag(help: "Include empty slots")
    var includeEmpty = false

    func run() {
        do {
            let blocks = try BlockReadSupport.readCurrentBlocks(timeout: timeout, maxPackets: maxPackets)
            let filteredBlocks = includeEmpty ? blocks : blocks.filter { $0.modelName != "Empty" }
            let response = JSONResponse.success(data: [
                "blockCount": filteredBlocks.count,
                "includeEmpty": includeEmpty,
                "blocks": filteredBlocks.map(BlockReadSupport.json),
            ])
            print(response.toJSON())
        } catch USBError.deviceNotFound {
            print(JSONResponse.deviceNotFound().toJSON())
        } catch USBError.connectionFailed(let message), USBError.transferFailed(let message), USBError.invalidResponse(let message) {
            print(JSONResponse.failure(code: "USB_ERROR", message: message).toJSON())
        } catch {
            print(JSONResponse.failure(code: "UNKNOWN_ERROR", message: error.localizedDescription).toJSON())
        }
    }
}

struct ToggleBlock: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "toggle",
        abstract: "Toggle a block on/off"
    )
    
    @Argument(help: "Block slot (A1-A8, B1-B8)")
    var slot: String
    
    func run() {
        let response = JSONResponse.success(data: [
            "message": "Toggling block \(slot.uppercased()) - not yet implemented",
            "slot": slot.uppercased()
        ])
        print(response.toJSON())
    }
}

struct SetParam: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "param",
        abstract: "Set block parameter"
    )
    
    @Argument(help: "Block slot")
    var slot: String
    
    @Argument(help: "Parameter name")
    var param: String
    
    @Argument(help: "Parameter value")
    var value: String
    
    func run() {
        let response = JSONResponse.success(data: [
            "message": "Setting \(param)=\(value) on block \(slot.uppercased()) - not yet implemented",
            "slot": slot.uppercased(),
            "param": param,
            "value": value
        ])
        print(response.toJSON())
    }
}

struct GetBlock: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Get block details"
    )
    
    @Argument(help: "Block slot, e.g. A3")
    var slot: String

    @Option(help: "USB read/write timeout in milliseconds")
    var timeout: UInt32 = 250

    @Option(help: "Maximum inbound packets to read")
    var maxPackets: Int = 200
    
    func run() {
        let normalizedSlot = slot.uppercased()
        do {
            let blocks = try BlockReadSupport.readCurrentBlocks(timeout: timeout, maxPackets: maxPackets)
            guard let block = blocks.first(where: { $0.slot == normalizedSlot }) else {
                print(JSONResponse.failure(code: "BLOCK_NOT_FOUND", message: "No block found in slot \(normalizedSlot)").toJSON())
                return
            }

            print(JSONResponse.success(data: BlockReadSupport.json(block)).toJSON())
        } catch USBError.deviceNotFound {
            print(JSONResponse.deviceNotFound().toJSON())
        } catch USBError.connectionFailed(let message), USBError.transferFailed(let message), USBError.invalidResponse(let message) {
            print(JSONResponse.failure(code: "USB_ERROR", message: message).toJSON())
        } catch {
            print(JSONResponse.failure(code: "UNKNOWN_ERROR", message: error.localizedDescription).toJSON())
        }
    }
}
