import Foundation

struct HelixParameterValue {
    let index: Int
    let name: String
    let value: Any

    var json: [String: Any] {
        [
            "index": index,
            "name": name,
            "value": value,
        ]
    }
}

enum HelixParameterCatalog {
    private static let modelSpecificNames: [String: [String]] = [
        // Amps
        "29": ["Drive", "Bass", "Mid", "Treble", "Presence", "Ch Vol", "Master", "Sag"], // US Double Nrm

        // Dynamics
        "78": ["Peak Reduction", "Gain", "Emphasis", "Mix", "Level"], // LA Studio Comp

        // Modulation
        "cd0127": ["Speed", "Depth", "Feedback", "Mix", "Level"], // Deluxe Phaser

        // Delay
        "cd014b": ["Time", "Feedback", "Bass", "Treble", "Mix", "Level", "Scale", "Trails", "Headroom"], // Vintage Digital
    ]

    private static let categoryDefaultNames: [String: [String]] = [
        "Amp": ["Drive", "Bass", "Mid", "Treble", "Presence", "Ch Vol", "Master", "Sag", "Hum", "Ripple", "Bias", "Bias X"],
        "Amp+Cab": ["Drive", "Bass", "Mid", "Treble", "Presence", "Ch Vol", "Master", "Sag", "Mic", "Distance", "Low Cut", "High Cut", "Cab Level"],
        "Cab": ["Mic", "Distance", "Low Cut", "High Cut", "Level"],
        "Delay": ["Time", "Feedback", "Bass", "Treble", "Mix", "Level", "Scale", "Trails", "Headroom"],
        "Distortion": ["Drive", "Tone", "Level", "Mix"],
        "Dynamic": ["Threshold", "Ratio", "Attack", "Release", "Mix", "Level"],
        "EQ": ["Low Freq", "Low Gain", "Mid Freq", "Mid Gain", "High Freq", "High Gain", "Level"],
        "Filter": ["Frequency", "Q", "Sensitivity", "Mix", "Level"],
        "Modulation": ["Speed", "Depth", "Feedback", "Mix", "Level"],
        "Pitch/Synth": ["Interval", "Cents", "Mix", "Level"],
        "Reverb": ["Decay", "Predelay", "Low Cut", "High Cut", "Mix", "Level"],
        "Wah": ["Position", "Mix", "Level"],
    ]

    static func namedValues(for values: [Any], modelIds: [String], category: String) -> [HelixParameterValue] {
        let names = names(for: modelIds, category: category, count: values.count)
        return values.enumerated().map { index, value in
            HelixParameterValue(index: index, name: names[index], value: value)
        }
    }

    static func names(for modelIds: [String], category: String, count: Int) -> [String] {
        let normalizedIds = modelIds.map { $0.lowercased() }

        if normalizedIds.count == 2, category == "Cab", count > 0 {
            let perCab = categoryDefaultNames["Cab"] ?? []
            return (0..<count).map { index in
                let cabNumber = index < perCab.count ? 1 : 2
                let localIndex = index % max(perCab.count, 1)
                let baseName = localIndex < perCab.count ? perCab[localIndex] : "Param \(localIndex + 1)"
                return "Cab \(cabNumber) \(baseName)"
            }
        }

        if normalizedIds.count == 1, let specific = modelSpecificNames[normalizedIds[0]], specific.count >= count {
            return Array(specific.prefix(count))
        }

        let categoryNames = categoryDefaultNames[category] ?? []
        return (0..<count).map { index in
            index < categoryNames.count ? categoryNames[index] : "Param \(index + 1)"
        }
    }
}
