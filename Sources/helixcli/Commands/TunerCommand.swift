import ArgumentParser
import Foundation

struct TunerCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tuner",
        abstract: "Show tuner display"
    )
    
    func run() {
        print("Tuner mode - not yet implemented")
        print("Press Ctrl+C to exit")
        
        // Keep running until interrupted
        RunLoop.main.run()
    }
}
