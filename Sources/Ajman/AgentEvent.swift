import Foundation

enum JSONValue: Equatable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(_ value: Any) {
        switch value {
        case let value as String: self = .string(value)
        case let value as NSNumber:
            self = CFGetTypeID(value) == CFBooleanGetTypeID() ? .bool(value.boolValue) : .number(value.doubleValue)
        case let value as [String: Any]: self = .object(value.mapValues(JSONValue.init))
        case let value as [Any]: self = .array(value.map(JSONValue.init))
        default: self = .null
        }
    }
}

struct PetNotification: Identifiable, Equatable {
    enum Kind: Equatable { case waiting, done, failed, running }

    let id: String
    let provider: AgentEvent.Provider
    let sessionId: String
    let kind: Kind
    let title: String
    let preview: String
    let fullText: String
    let timestamp: Date
}

enum PetNotificationChange: Equatable {
    case upsert(PetNotification)
    case dismiss(id: String, provider: AgentEvent.Provider)

    var provider: AgentEvent.Provider {
        switch self {
        case .upsert(let notification): notification.provider
        case .dismiss(_, let provider): provider
        }
    }
}

struct AgentEvent {
    enum Provider: String { case claude, codex }

    static let maximumCapturedTextLength = 4_096

    let provider: Provider
    let event: String
    let sessionId: String?
    let cwd: String?
    let toolName: String?
    let transcriptPath: String?
    let title: String?
    let message: String?
    let detail: String?
    let timestamp: Date
    let raw: [String: JSONValue]

    static func decode(frame: Data, provider: Provider = .claude, now: Date = Date()) -> AgentEvent? {
        guard frame.count <= 64 * 1_024,
              let object = try? JSONSerialization.jsonObject(with: frame),
              let dictionary = object as? [String: Any],
              let event = dictionary["hook_event_name"] as? String,
              !event.isEmpty else { return nil }
        let toolName = text(dictionary["tool_name"], limit: 256)
        return AgentEvent(
            provider: provider,
            event: event,
            sessionId: text(dictionary["session_id"], limit: 1_024),
            cwd: text(dictionary["cwd"], limit: 4_096),
            toolName: toolName,
            transcriptPath: text(dictionary["transcript_path"], limit: 4_096),
            title: firstText(in: dictionary, keys: ["title", "turn_title"], limit: 512),
            message: firstText(
                in: dictionary,
                keys: ["last_assistant_message", "last-assistant-message", "last_agent_message", "message", "reason", "error"],
                limit: maximumCapturedTextLength
            ),
            detail: toolDetail(in: dictionary, toolName: toolName),
            timestamp: now,
            raw: dictionary.mapValues(JSONValue.init)
        )
    }

    static func text(_ value: Any?, limit: Int = maximumCapturedTextLength) -> String? {
        guard let value = value as? String else { return nil }
        let normalized = value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let safe = normalized.unicodeScalars.map { scalar -> String in
            if CharacterSet.controlCharacters.contains(scalar), scalar != "\n", scalar != "\t" { return " " }
            return String(scalar)
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safe.isEmpty else { return nil }
        var bounded = ""
        var byteCount = 0
        for character in safe {
            let segment = String(character)
            let segmentBytes = segment.utf8.count
            guard byteCount + segmentBytes <= limit else { break }
            bounded.append(character)
            byteCount += segmentBytes
        }
        return bounded.isEmpty ? nil : bounded
    }

    static func firstText(in dictionary: [String: Any], keys: [String], limit: Int = maximumCapturedTextLength) -> String? {
        for key in keys {
            if let value = text(dictionary[key], limit: limit) { return value }
        }
        return nil
    }

    static func toolDetail(in dictionary: [String: Any], toolName: String?) -> String? {
        if let command = commandText(in: dictionary) { return command }
        guard let input = dictionary["tool_input"] else { return nil }
        if let value = text(input) { return value }
        guard JSONSerialization.isValidJSONObject(input),
              let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return text(json)
    }

    static func commandText(in value: Any) -> String? {
        if let dictionary = value as? [String: Any] {
            for key in ["command", "cmd", "shell_command", "proposed_command"] {
                if let command = commandValue(dictionary[key]) { return command }
            }
            for key in ["tool_input", "input", "request", "permissions"] {
                if let nested = dictionary[key], let command = commandText(in: nested) { return command }
            }
        } else if let array = value as? [Any] {
            for item in array {
                if let command = commandText(in: item) { return command }
            }
        }
        return nil
    }

    private static func commandValue(_ value: Any?) -> String? {
        if let command = text(value) { return command }
        if let parts = value as? [String], !parts.isEmpty { return text(parts.joined(separator: " ")) }
        if let parts = value as? [Any] {
            let strings = parts.compactMap { $0 as? String }
            if strings.count == parts.count, !strings.isEmpty { return text(strings.joined(separator: " ")) }
        }
        return nil
    }
}
