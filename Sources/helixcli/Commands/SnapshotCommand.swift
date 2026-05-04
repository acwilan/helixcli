import ArgumentParser
import Foundation

struct SnapshotCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshot",
        abstract: "Manage HX Stomp snapshots",
        subcommands: [
            ListSnapshots.self,
            SwitchSnapshot.self,
        ]
    )
}

private enum SnapshotReadSupport {
    static func readCurrentSnapshots(timeout: UInt32, maxPackets: Int) throws -> (currentSnapshot: Int, snapshots: [PresetSnapshot]) {
        let result = try USBManager().requestPresetData(timeoutMs: timeout, maxPackets: maxPackets, verbose: false)

        guard let connected = result["connected"] as? Bool, connected else {
            throw USBError.connectionFailed("Failed to connect to HX Stomp")
        }

        guard let payloadHex = result["payloadHex"] as? String, !payloadHex.isEmpty else {
            throw USBError.invalidResponse("No preset data received from device")
        }

        let presetInfo = PresetDataParser(hexString: payloadHex).parse()
        return (presetInfo.currentSnapshot, presetInfo.snapshots)
    }

    static func json(currentSnapshot: Int, snapshots: [PresetSnapshot]) -> [String: Any] {
        [
            "currentSnapshot": currentSnapshot,
            "snapshots": snapshots.map { snapshot in
                [
                    "id": snapshot.id,
                    "name": snapshot.name,
                    "isCurrent": snapshot.id == currentSnapshot,
                ]
            },
        ]
    }
}

struct ListSnapshots: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List snapshots for current preset"
    )

    @Option(help: "USB read/write timeout in milliseconds")
    var timeout: UInt32 = 250

    @Option(help: "Maximum inbound packets to read")
    var maxPackets: Int = 200
    
    func run() {
        do {
            let result = try SnapshotReadSupport.readCurrentSnapshots(timeout: timeout, maxPackets: maxPackets)
            print(JSONResponse.success(data: SnapshotReadSupport.json(currentSnapshot: result.currentSnapshot, snapshots: result.snapshots)).toJSON())
        } catch USBError.deviceNotFound {
            print(JSONResponse.deviceNotFound().toJSON())
        } catch USBError.connectionFailed(let message), USBError.transferFailed(let message), USBError.invalidResponse(let message) {
            print(JSONResponse.failure(code: "USB_ERROR", message: message).toJSON())
        } catch {
            print(JSONResponse.failure(code: "UNKNOWN_ERROR", message: error.localizedDescription).toJSON())
        }
    }
}

struct SwitchSnapshot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "switch",
        abstract: "Switch to a snapshot using USB-MIDI CC 69"
    )

    @Argument(help: "Snapshot ID (1-3 for HX Stomp)")
    var snapshotId: Int

    @Option(help: "MIDI channel, 1-16")
    var channel: Int = 1

    @Option(help: "USB transfer/read timeout in milliseconds")
    var timeout: UInt32 = 500

    @Option(help: "Maximum inbound packets to read during verification")
    var maxPackets: Int = 120

    @Flag(help: "Skip read-back verification after sending the snapshot switch")
    var noVerify = false

    func run() {
        guard snapshotId >= 1 && snapshotId <= 3 else {
            print(JSONResponse.failure(code: "INVALID_SNAPSHOT", message: "Snapshot ID must be between 1 and 3").toJSON())
            return
        }
        guard channel >= 1 && channel <= 16 else {
            print(JSONResponse.failure(code: "INVALID_CHANNEL", message: "MIDI channel must be between 1 and 16").toJSON())
            return
        }

        do {
            let ccNumber = 69
            let ccValue = snapshotId - 1
            let midiResult = try USBManager().sendMidiControlChange(ccNumber, value: ccValue, channel: channel - 1, timeoutMs: timeout)
            var responseData: [String: Any] = [
                "snapshotId": snapshotId,
                "midi": midiResult,
                "verificationSkipped": noVerify,
            ]

            if !noVerify {
                Thread.sleep(forTimeInterval: 0.25)
                let snapshotResult = try SnapshotReadSupport.readCurrentSnapshots(timeout: timeout, maxPackets: maxPackets)
                responseData["currentSnapshot"] = snapshotResult.currentSnapshot
                let verified = snapshotResult.currentSnapshot == snapshotId
                responseData["verified"] = verified
                if !verified {
                    responseData["warning"] = "MIDI CC 69 was sent successfully, but read-back did not report the requested snapshot. Snapshot switching remains experimental on this device/configuration."
                }
                responseData["snapshots"] = SnapshotReadSupport.json(currentSnapshot: snapshotResult.currentSnapshot, snapshots: snapshotResult.snapshots)["snapshots"]
            }

            print(JSONResponse.success(data: responseData).toJSON())
        } catch USBError.deviceNotFound {
            print(JSONResponse.deviceNotFound().toJSON())
        } catch USBError.connectionFailed(let message), USBError.transferFailed(let message), USBError.invalidResponse(let message) {
            print(JSONResponse.failure(code: "USB_ERROR", message: message).toJSON())
        } catch {
            print(JSONResponse.failure(code: "UNKNOWN_ERROR", message: error.localizedDescription).toJSON())
        }
    }
}
