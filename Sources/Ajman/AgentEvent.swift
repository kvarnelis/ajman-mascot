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
    let timestamp: Date
}

enum PetNotificationChange: Equatable {
    case upsert(PetNotification)
    case dismiss(id: String)
}

struct AgentEvent {
    enum Provider: String { case claude, codex }

    let provider: Provider
    let event: String
    let sessionId: String?
    let cwd: String?
    let toolName: String?
    let transcriptPath: String?
    let timestamp: Date
    let raw: [String: JSONValue]

    static func decode(frame: Data, provider: Provider = .claude, now: Date = Date()) -> AgentEvent? {
        guard frame.count <= 64 * 1_024,
              let object = try? JSONSerialization.jsonObject(with: frame),
              let dictionary = object as? [String: Any],
              let event = dictionary["hook_event_name"] as? String,
              !event.isEmpty else { return nil }
        return AgentEvent(
            provider: provider,
            event: event,
            sessionId: dictionary["session_id"] as? String,
            cwd: dictionary["cwd"] as? String,
            toolName: dictionary["tool_name"] as? String,
            transcriptPath: dictionary["transcript_path"] as? String,
            timestamp: now,
            raw: dictionary.mapValues(JSONValue.init)
        )
    }
}
