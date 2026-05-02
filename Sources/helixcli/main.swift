import ArgumentParser

@available(macOS 14, *)
struct HelixCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "helixcli",
        abstract: "Control Line 6 HX Stomp via USB",
        version: "0.1.0",
        subcommands: [
            PresetCommand.self,
            SnapshotCommand.self,
            BlockCommand.self,
            TunerCommand.self,
        ]
    )
}

HelixCLI.main()
