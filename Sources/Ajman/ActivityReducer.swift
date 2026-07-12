import Foundation

enum ActivityReducer {
    static let readOnlyTools: Set<String> = ["Read", "Grep", "Glob", "LS", "NotebookRead"]

    static func state(for event: AgentEvent, previous: AnimationState) -> AnimationState? {
        switch event.event {
        case "SessionStart": return .idle
        case "UserPromptSubmit", "PostToolUse", "SubagentStart", "SubagentStop": return .running
        case "PreToolUse": return readOnlyTools.contains(event.toolName ?? "") ? .review : .running
        case "Notification": return .waiting
        case "Stop": return .review
        case "SessionEnd": return nil
        default:
            return event.event.hasSuffix("Failure") ? .failed : previous
        }
    }

    static func currentState(in sessions: [SessionRegistry.Session], now: Date = Date()) -> AnimationState {
        sessions
            .map { session -> (AnimationState, Date) in
                let age = now.timeIntervalSince(session.lastActivity)
                let state: AnimationState
                switch session.derivedState {
                case .failed, .review: state = age >= 6 ? .idle : session.derivedState
                case .running: state = age >= 8 ? .idle : .running
                default: state = session.derivedState
                }
                return (state, session.lastActivity)
            }
            .max { lhs, rhs in
                let lp = priority(lhs.0), rp = priority(rhs.0)
                return lp == rp ? lhs.1 < rhs.1 : lp < rp
            }?.0 ?? .idle
    }

    private static func priority(_ state: AnimationState) -> Int {
        switch state {
        case .waiting: 5
        case .failed: 4
        case .review, .waving: 3
        case .running, .jumping: 2
        default: 1
        }
    }
}
