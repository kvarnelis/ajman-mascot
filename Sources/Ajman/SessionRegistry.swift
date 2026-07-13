import Foundation

@MainActor
final class SessionRegistry {
    struct Session {
        let key: String
        let provider: AgentEvent.Provider
        var lastEvent: String
        var lastActivity: Date
        var derivedState: AnimationState
    }

    private(set) var sessions: [String: Session] = [:]
    private(set) var notifications: [String: PetNotification] = [:]
    private(set) var currentState: AnimationState = .idle
    var didChange: ((AnimationState, Int) -> Void)?
    var notificationDidChange: ((PetNotificationChange) -> Void)?
    private var timer: Timer?

    init(startTimer: Bool = true) {
        if startTimer {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.reduce() }
            }
        }
    }

    func apply(_ event: AgentEvent) {
        let identifier = event.sessionId ?? "unknown"
        let key = "\(event.provider.rawValue):\(identifier)"
        updateNotification(for: event, id: key, sessionId: identifier)
        if event.event == "SessionEnd" {
            sessions.removeValue(forKey: key)
        } else {
            let old = sessions[key]?.derivedState ?? .idle
            let next = ActivityReducer.state(for: event, previous: old) ?? old
            sessions[key] = Session(
                key: key,
                provider: event.provider,
                lastEvent: event.event,
                lastActivity: event.timestamp,
                derivedState: next
            )
        }
        reduce(now: event.timestamp)
    }

    func dismissNotification(id: String) {
        guard let notification = notifications.removeValue(forKey: id) else { return }
        notificationDidChange?(.dismiss(id: id, provider: notification.provider))
    }

    private func updateNotification(for event: AgentEvent, id: String, sessionId: String) {
        let kind: PetNotification.Kind?
        switch event.event {
        case "Notification": kind = .waiting
        case "Stop": kind = .done
        default: kind = event.event.hasSuffix("Failure") ? .failed : nil
        }

        guard let kind else {
            // Any subsequent progress/user-presence/end signal supersedes a card.
            if ["UserPromptSubmit", "PreToolUse", "PostToolUse", "SessionEnd"].contains(event.event) {
                notifications.removeValue(forKey: id)
                notificationDidChange?(.dismiss(id: id, provider: event.provider))
            }
            return
        }

        let notification = PetNotification(
            id: id,
            provider: event.provider,
            sessionId: sessionId,
            kind: kind,
            title: Self.title(for: event, kind: kind),
            preview: Self.preview(for: event, kind: kind),
            timestamp: event.timestamp
        )
        notifications[id] = notification
        notificationDidChange?(.upsert(notification))
    }

    private static func title(for event: AgentEvent, kind: PetNotification.Kind) -> String {
        let provider = event.provider == .claude ? "Claude" : "Codex"
        switch kind {
        case .waiting: return "\(provider) needs you"
        case .done: return "\(provider) finished"
        case .failed: return "\(provider) hit an error"
        case .running: return event.toolName.map { "\(provider): \($0)" } ?? "\(provider) is working"
        }
    }

    private static func preview(for event: AgentEvent, kind: PetNotification.Kind) -> String {
        let preferredKeys = ["message", "last_assistant_message", "lastAssistantMessage", "summary", "reason", "error", "content", "text"]
        if let message = firstString(in: .object(event.raw), preferredKeys: preferredKeys) {
            return clean(message)
        }
        if let tool = event.toolName, !tool.isEmpty {
            return kind == .waiting ? "Approval needed for \(tool)." : tool
        }
        switch kind {
        case .waiting: return "This session is waiting for your input."
        case .done: return "The turn is ready for review."
        case .failed: return "The session reported an error."
        case .running: return "Work is in progress."
        }
    }

    private static func firstString(in value: JSONValue, preferredKeys: [String]) -> String? {
        switch value {
        case .object(let dictionary):
            for key in preferredKeys {
                if let candidate = dictionary[key], let string = firstString(in: candidate, preferredKeys: preferredKeys), !string.isEmpty {
                    return string
                }
            }
            for candidate in dictionary.values {
                if case .object = candidate, let string = firstString(in: candidate, preferredKeys: preferredKeys), !string.isEmpty { return string }
                if case .array = candidate, let string = firstString(in: candidate, preferredKeys: preferredKeys), !string.isEmpty { return string }
            }
        case .array(let values):
            for candidate in values {
                if let string = firstString(in: candidate, preferredKeys: preferredKeys), !string.isEmpty { return string }
            }
        case .string(let string): return string
        default: break
        }
        return nil
    }

    private static func clean(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    func reduce(now: Date = Date()) {
        sessions = sessions.filter { now.timeIntervalSince($0.value.lastActivity) <= 600 }
        let newState = ActivityReducer.currentState(in: Array(sessions.values), now: now)
        let count = sessions.count
        guard newState != currentState else { didChange?(newState, count); return }
        currentState = newState
        didChange?(newState, count)
    }

    func currentState(for provider: AgentEvent.Provider?) -> AnimationState {
        ActivityReducer.currentState(in: filteredSessions(for: provider))
    }

    func sessionCount(for provider: AgentEvent.Provider?) -> Int {
        filteredSessions(for: provider).count
    }

    func currentNotifications(for provider: AgentEvent.Provider?) -> [PetNotification] {
        notifications.values.filter { provider == nil || $0.provider == provider }
    }

    private func filteredSessions(for provider: AgentEvent.Provider?) -> [Session] {
        guard let provider else { return Array(sessions.values) }
        return sessions.values.filter { $0.provider == provider }
    }
}
