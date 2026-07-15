import Foundation

struct FirstRunLaunchPrompt {
    static let didAskKey = "AjmanDidAskLaunchAtLogin"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    @discardableResult
    func performIfNeeded(
        prompt: () -> Bool,
        enableLaunchAtLogin: () throws -> Void
    ) throws -> Bool {
        guard !defaults.bool(forKey: Self.didAskKey) else { return false }

        // Record the prompt before presenting it so either answer (or an
        // enablement error) still makes this a genuinely one-time question.
        defaults.set(true, forKey: Self.didAskKey)
        if prompt() {
            try enableLaunchAtLogin()
        }
        return true
    }
}
