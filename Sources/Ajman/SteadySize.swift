import Foundation

enum SteadySize {
    static let defaultsKey = "AjmanSteadySize"

    static func load(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) == nil ? true : defaults.bool(forKey: defaultsKey)
    }

    static func save(_ enabled: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: defaultsKey)
    }
}
