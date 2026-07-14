import Foundation

enum Temperament: String, CaseIterable {
    case catatonic
    case calm
    case normal
    case frisky
    case insane

    var title: String { rawValue.capitalized }

    /// Frequency scales up probabilities and scales wait/cooldown intervals down.
    var frequencyMultiplier: Double {
        switch self {
        case .catatonic: 0.15
        case .calm: 0.5
        case .normal: 1
        case .frisky: 2
        case .insane: 4
        }
    }

    var intervalMultiplier: Double { 1 / frequencyMultiplier }

    func scaled(interval: TimeInterval) -> TimeInterval {
        interval * intervalMultiplier
    }

    func scaled(range: ClosedRange<TimeInterval>) -> ClosedRange<TimeInterval> {
        scaled(interval: range.lowerBound)...scaled(interval: range.upperBound)
    }

    func scaled(probability: Double) -> Double {
        min(max(probability * frequencyMultiplier, 0), 1)
    }

    static func defaultsKey(for petID: String) -> String {
        "AjmanTemperament.\(petID)"
    }

    static func defaultValue(for petID: String) -> Temperament {
        switch petID.lowercased() {
        case "ajman": .calm
        case "winnie": .frisky
        default: .normal
        }
    }

    static func load(for petID: String, from defaults: UserDefaults = .standard) -> Temperament {
        guard let rawValue = defaults.string(forKey: defaultsKey(for: petID)),
              let value = Temperament(rawValue: rawValue) else {
            return defaultValue(for: petID)
        }
        return value
    }

    func save(for petID: String, to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey(for: petID))
    }
}
