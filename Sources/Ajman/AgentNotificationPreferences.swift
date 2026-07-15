import Foundation

struct AgentNotificationPreferences {
    static let defaultsKey = "AjmanShowAgentNotifications"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        get { defaults.object(forKey: Self.defaultsKey) == nil ? false : defaults.bool(forKey: Self.defaultsKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.defaultsKey) }
    }
}
