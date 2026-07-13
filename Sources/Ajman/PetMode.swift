import Foundation

@MainActor
final class PetMode {
    static let defaultsKey = "AjmanPetModeEnabled"
    static let randomIntervalRange: ClosedRange<TimeInterval> = 20...70

    private weak var animator: Animator?
    private let currentLiveState: () -> AnimationState
    private let isManualMode: () -> Bool
    private var idleTimer: Timer?
    private var beatTimer: Timer?
    private var wakeUntil: Date?
    private var lastFunState: AnimationState?
    private var ownsRestingAnimation = false

    private(set) var isEnabled: Bool

    init(
        animator: Animator,
        currentLiveState: @escaping () -> AnimationState,
        isManualMode: @escaping () -> Bool,
        defaults: UserDefaults = .standard
    ) {
        self.animator = animator
        self.currentLiveState = currentLiveState
        self.isManualMode = isManualMode
        isEnabled = defaults.object(forKey: Self.defaultsKey) as? Bool ?? true
    }

    func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.defaultsKey)
        wakeUntil = nil
        cancelTimers()
        guard priorityAllowsPetMode else { return }
        ownsRestingAnimation = true
        animator?.play(.idle)
        if enabled { scheduleOccasionalBeat() }
    }

    /// Called whenever the live/manual driver changes who should own animation.
    /// Active agent and Debug states are deliberately played by their existing drivers.
    func resumeAtRest() {
        guard priorityAllowsPetMode, !ownsRestingAnimation else { return }
        ownsRestingAnimation = true
        cancelTimers()
        wakeUntil = nil
        animator?.play(.idle)
        if isEnabled { scheduleOccasionalBeat() }
    }

    func yieldToHigherPriorityDriver() {
        ownsRestingAnimation = false
        wakeUntil = nil
        cancelTimers()
    }

    func wake() {
        guard isEnabled, priorityAllowsPetMode else { return }
        idleTimer?.invalidate()
        idleTimer = nil

        let extensionLength = TimeInterval.random(in: 10...15)
        wakeUntil = max(wakeUntil ?? Date(), Date()).addingTimeInterval(extensionLength)
        playAwakeBeat()
    }

    private var priorityAllowsPetMode: Bool {
        !isManualMode() && currentLiveState() == .idle
    }

    private var funStates: [AnimationState] {
        let preferred: [AnimationState] = [
            .waving, .jumping, .review, .lookDirectionsA, .lookDirectionsB,
        ]
        let available = Set(animator?.availableStates ?? [])
        return preferred.filter(available.contains)
    }

    private func scheduleOccasionalBeat() {
        guard isEnabled, priorityAllowsPetMode else { return }
        let delay = TimeInterval.random(in: Self.randomIntervalRange)
        idleTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.playOccasionalBeat() }
        }
    }

    private func playOccasionalBeat() {
        idleTimer = nil
        guard isEnabled, priorityAllowsPetMode, let state = chooseFunState() else {
            returnToCalmIfAllowed()
            return
        }
        animator?.play(state)
        scheduleBeatTimer(after: animator?.duration(of: state) ?? 1) { [weak self] in
            self?.returnToCalmIfAllowed()
        }
    }

    private func playAwakeBeat() {
        beatTimer?.invalidate()
        beatTimer = nil
        guard isEnabled, priorityAllowsPetMode,
              let wakeUntil, wakeUntil > Date(),
              let state = chooseFunState() else {
            returnToCalmIfAllowed()
            return
        }

        animator?.play(state)
        // Let each lively state read clearly, repeating briefly when its authored loop is short.
        let dwell = max(animator?.duration(of: state) ?? 1, 1.6)
        scheduleBeatTimer(after: dwell) { [weak self] in self?.playAwakeBeat() }
    }

    private func chooseFunState() -> AnimationState? {
        let states = funStates
        guard !states.isEmpty else { return nil }
        let choices = states.count > 1 ? states.filter { $0 != lastFunState } : states
        let state = choices.randomElement()
        lastFunState = state
        return state
    }

    private func returnToCalmIfAllowed() {
        beatTimer?.invalidate()
        beatTimer = nil
        wakeUntil = nil
        guard priorityAllowsPetMode else { return }
        animator?.play(.idle)
        if isEnabled { scheduleOccasionalBeat() }
    }

    private func scheduleBeatTimer(after delay: TimeInterval, action: @escaping @MainActor () -> Void) {
        beatTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            Task { @MainActor in action() }
        }
    }

    private func cancelTimers() {
        idleTimer?.invalidate()
        beatTimer?.invalidate()
        idleTimer = nil
        beatTimer = nil
    }

    func teardown() {
        ownsRestingAnimation = false
        wakeUntil = nil
        cancelTimers()
    }

    deinit {
        idleTimer?.invalidate()
        beatTimer?.invalidate()
    }
}
