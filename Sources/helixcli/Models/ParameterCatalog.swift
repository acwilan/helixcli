import Foundation

struct HelixParameterValue {
    let index: Int
    let name: String
    let value: Any
    let displayValue: String?
    let displayKind: String?

    var json: [String: Any] {
        var data: [String: Any] = [
            "index": index,
            "name": name,
            "value": value,
        ]
        if let displayValue {
            data["displayValue"] = displayValue
        }
        if let displayKind {
            data["displayKind"] = displayKind
        }
        return data
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
            let display = display(for: value, name: names[index], category: category)
            return HelixParameterValue(
                index: index,
                name: names[index],
                value: value,
                displayValue: display?.value,
                displayKind: display?.kind
            )
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

    private static func display(for rawValue: Any, name: String, category: String) -> (value: String, kind: String)? {
        if let bool = rawValue as? Bool {
            return (bool ? "On" : "Off", "boolean")
        }

        guard let value = numeric(rawValue) else { return nil }
        let normalizedName = name.lowercased()

        if normalizedName.contains("trail") {
            return (value >= 0.5 ? "On" : "Off", "boolean")
        }

        if normalizedName.contains("mix") {
            if value >= 0.0 && value <= 1.0 {
                return (format(value * 100, decimals: 0) + "%", "percent")
            }
            return (format(value, decimals: abs(value) >= 100 ? 0 : 2), "raw")
        }

        if normalizedName.contains("low cut") || normalizedName.contains("high cut") {
            if value >= 20 {
                return (formatFrequency(value), "frequency")
            }
            return (format(value, decimals: 2), "raw")
        }

        if normalizedName.contains("time") {
            return (format(value, decimals: 3), "raw-time")
        }

        if normalizedName.contains("mic") {
            return (format(value, decimals: 0), "index")
        }

        if normalizedName.contains("distance") {
            return (format(value, decimals: 0), "raw-distance")
        }

        if value >= 0.0 && value <= 1.0 {
            return (format(value * 10, decimals: 1), "normalized-0-10")
        }

        return (format(value, decimals: abs(value) >= 100 ? 0 : 2), "raw")
    }

    private static func numeric(_ value: Any) -> Double? {
        switch value {
        case let value as Double:
            return value
        case let value as Float:
            return Double(value)
        case let value as Int:
            return Double(value)
        case let value as Bool:
            return value ? 1.0 : 0.0
        default:
            return nil
        }
    }

    private static func formatFrequency(_ value: Double) -> String {
        if value >= 1000 {
            return format(value / 1000, decimals: value >= 10000 ? 1 : 2) + " kHz"
        }
        return format(value, decimals: 0) + " Hz"
    }

    private static func format(_ value: Double, decimals: Int) -> String {
        String(format: "%.*f", decimals, value)
    }
}
