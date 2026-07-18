import Foundation

struct CodexMonitorPreferences {
    static let defaultsKey = "AjmanHearCodex"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        get { defaults.object(forKey: Self.defaultsKey) == nil ? true : defaults.bool(forKey: Self.defaultsKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.defaultsKey) }
    }
}
