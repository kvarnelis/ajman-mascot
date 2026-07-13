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
        case "Notification", "PermissionRequest": kind = .waiting
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

        let content = Self.content(for: event, kind: kind)
        let notification = PetNotification(
            id: id,
            provider: event.provider,
            sessionId: sessionId,
            kind: kind,
            title: content.title,
            preview: content.preview,
            fullText: content.fullText,
            timestamp: event.timestamp
        )
        notifications[id] = notification
        notificationDidChange?(.upsert(notification))
    }

    private static func content(for event: AgentEvent, kind: PetNotification.Kind) -> (title: String, preview: String, fullText: String) {
        let provider = event.provider == .claude ? "Claude" : "Codex"
        let message = bounded(event.message)
        let detail = bounded(event.detail)
        let combined = bounded([detail, message].compactMap { $0 }.reduce(into: [String]()) { values, value in
            if !values.contains(value) { values.append(value) }
        }.joined(separator: "\n\n"))

        switch kind {
        case .waiting:
            let title: String
            if let detail, isCommand(event) {
                title = "\(provider) · Run: \(headline(detail, limit: 32))"
            } else if let tool = event.toolName, !tool.isEmpty {
                title = "\(provider) · \(headline(tool, limit: 40))"
            } else if let sourceTitle = event.title {
                title = "\(provider) · \(headline(sourceTitle, limit: 40))"
            } else {
                title = "\(provider) needs you"
            }
            let preview = compact(detail ?? message) ?? "This session is waiting for your input."
            return (title, preview, combined ?? preview)

        case .done:
            guard let message else {
                let title = event.title.map { "\(provider) · \(headline($0, limit: 40))" } ?? "\(provider) finished"
                return (title, "The turn is ready for review.", "The turn is ready for review.")
            }
            if let sourceTitle = event.title {
                return ("\(provider) · \(headline(sourceTitle, limit: 40))", compact(message) ?? message, message)
            }
            let parts = headlineAndRemainder(message)
            return ("\(provider) · \(parts.headline)", compact(parts.remainder) ?? compact(message) ?? message, message)

        case .failed:
            guard let error = message ?? detail else {
                return ("\(provider) failed", "The session reported an error.", "The session reported an error.")
            }
            return ("\(provider) · \(headline(error, limit: 40))", compact(error) ?? error, error)

        case .running:
            let title = event.toolName.map { "\(provider) · \(headline($0, limit: 40))" } ?? "\(provider) is working"
            let preview = compact(detail ?? message) ?? "Work is in progress."
            return (title, preview, combined ?? preview)
        }
    }

    private static func isCommand(_ event: AgentEvent) -> Bool {
        if let tool = event.toolName?.lowercased(), ["bash", "shell", "exec", "command"].contains(where: tool.contains) { return true }
        if case .string(let type)? = event.raw["type"] {
            let normalized = type.lowercased().filter(\.isLetter)
            return normalized.contains("execcommand") || normalized.contains("execapproval")
        }
        return AgentEvent.commandText(in: event.raw.mapValues(anyValue)) != nil
    }

    private static func anyValue(_ value: JSONValue) -> Any {
        switch value {
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .object(let value): return value.mapValues(anyValue)
        case .array(let value): return value.map(anyValue)
        case .null: return NSNull()
        }
    }

    private static func headlineAndRemainder(_ value: String) -> (headline: String, remainder: String?) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLineEnd = trimmed.firstIndex(of: "\n")
        let sentenceEnd = trimmed.indices.first { index in
            ".!?".contains(trimmed[index]) && trimmed.index(after: index) < trimmed.endIndex && trimmed[trimmed.index(after: index)].isWhitespace
        }.map { trimmed.index(after: $0) }
        let boundary = [firstLineEnd, sentenceEnd].compactMap { $0 }.min()
        let source = boundary.map { String(trimmed[..<$0]) } ?? trimmed
        let remainder = boundary.map { String(trimmed[$0...]).trimmingCharacters(in: .whitespacesAndNewlines) }
        return (headline(source, limit: 40), remainder?.isEmpty == false ? remainder : nil)
    }

    private static func headline(_ value: String, limit: Int) -> String {
        let value = compact(value) ?? ""
        guard value.count > limit else { return value }
        return String(value.prefix(max(1, limit - 1))) + "…"
    }

    private static func compact(_ value: String?) -> String? {
        guard let value else { return nil }
        let compacted = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return compacted.isEmpty ? nil : compacted
    }

    private static func bounded(_ value: String?) -> String? {
        guard let value else { return nil }
        return AgentEvent.text(value, limit: AgentEvent.maximumCapturedTextLength)
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
