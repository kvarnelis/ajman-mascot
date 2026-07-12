import Foundation

@MainActor
final class SessionRegistry {
    struct Session {
        let key: String
        var lastEvent: String
        var lastActivity: Date
        var derivedState: AnimationState
    }

    private(set) var sessions: [String: Session] = [:]
    private(set) var currentState: AnimationState = .idle
    var didChange: ((AnimationState, Int) -> Void)?
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
        if event.event == "SessionEnd" {
            sessions.removeValue(forKey: key)
        } else {
            let old = sessions[key]?.derivedState ?? .idle
            let next = ActivityReducer.state(for: event, previous: old) ?? old
            sessions[key] = Session(key: key, lastEvent: event.event, lastActivity: event.timestamp, derivedState: next)
        }
        reduce(now: event.timestamp)
    }

    func reduce(now: Date = Date()) {
        sessions = sessions.filter { now.timeIntervalSince($0.value.lastActivity) <= 600 }
        let newState = ActivityReducer.currentState(in: Array(sessions.values), now: now)
        let count = sessions.count
        guard newState != currentState else { didChange?(newState, count); return }
        currentState = newState
        didChange?(newState, count)
    }
}
