import AppKit

enum PetScale: Double, CaseIterable {
    static let defaultsKey = "AjmanPetScale"
    static let defaultValue: PetScale = .small

    case small = 0.5
    case twoThirds = 0.6667
    case threeQuarter = 0.75
    case medium = 1.0
    case oneAndHalf = 1.5
    case large = 2.0
    case huge = 3.0

    var displaySize: NSSize {
        NSSize(
            width: (192 * rawValue).rounded(),
            height: (208 * rawValue).rounded()
        )
    }

    var menuTitle: String {
        switch self {
        case .small: "0.5× (Small)"
        case .twoThirds: "Two-Thirds (⅔)"
        case .threeQuarter: "0.75×"
        case .medium: "1.0× (Medium)"
        case .oneAndHalf: "1.5×"
        case .large: "2.0× (Large)"
        case .huge: "3.0× (Huge)"
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> PetScale {
        guard defaults.object(forKey: defaultsKey) != nil else { return defaultValue }
        return PetScale(rawValue: defaults.double(forKey: defaultsKey)) ?? defaultValue
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}
