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
        case .catatonic: 0.05
        case .calm: 0.3
        case .normal: 1
        case .frisky: 2
        case .insane: 4
        }
    }

    var intervalMultiplier: Double { 1 / frequencyMultiplier }

    /// The always-visible authored idle loop (breathing, blinks, ear/tail
    /// twitches, and body motion) is the main signal of a pet's energy.
    var idleLivelinessMultiplier: Double { frequencyMultiplier }

    /// Autonomous playful-idle actions need a steeper low end than ordinary
    /// whims: Catatonic should effectively stop fidgeting and Calm should only
    /// fidget rarely. The established Normal/Frisky/Insane rates stay intact.
    var playfulIdleFidgetFrequencyMultiplier: Double {
        switch self {
        case .catatonic: 0.01
        case .calm: 0.15
        case .normal: 1
        case .frisky: 2
        case .insane: 4
        }
    }

    /// Scale layer-local fidget displacement without diminishing the lively
    /// end. Large authored actions remain full-size from Normal upward.
    var playfulIdleFidgetAmplitudeMultiplier: Double {
        switch self {
        case .catatonic: 0.02
        case .calm: 0.25
        case .normal, .frisky, .insane: 1
        }
    }

    /// Loaf/sleep pose changes and breathing are passive idle motion too. Slow
    /// and shrink them only at the low end; preserve the existing high end.
    var calmPoseMotionMultiplier: Double {
        switch self {
        case .catatonic: 0.05
        case .calm: 0.3
        case .normal, .frisky, .insane: 1
        }
    }

    func scaled(interval: TimeInterval) -> TimeInterval {
        interval * intervalMultiplier
    }

    func scaled(range: ClosedRange<TimeInterval>) -> ClosedRange<TimeInterval> {
        scaled(interval: range.lowerBound)...scaled(interval: range.upperBound)
    }

    func scaled(probability: Double) -> Double {
        min(max(probability * frequencyMultiplier, 0), 1)
    }

    func scaledFidget(interval: TimeInterval) -> TimeInterval {
        interval / playfulIdleFidgetFrequencyMultiplier
    }

    func scaledFidget(range: ClosedRange<TimeInterval>) -> ClosedRange<TimeInterval> {
        scaledFidget(interval: range.lowerBound)...scaledFidget(interval: range.upperBound)
    }

    func scaledFidget(probability: Double) -> Double {
        min(max(probability * playfulIdleFidgetFrequencyMultiplier, 0), 1)
    }

    func scaledCalmPose(interval: TimeInterval) -> TimeInterval {
        interval / calmPoseMotionMultiplier
    }

    func scaledCalmPose(range: ClosedRange<TimeInterval>) -> ClosedRange<TimeInterval> {
        scaledCalmPose(interval: range.lowerBound)...scaledCalmPose(interval: range.upperBound)
    }

    func scaledBreathingScale(_ scale: Double) -> Double {
        1 + (scale - 1) * calmPoseMotionMultiplier
    }

    func scaledIdleFrameDuration(_ duration: TimeInterval) -> TimeInterval {
        duration / idleLivelinessMultiplier
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
