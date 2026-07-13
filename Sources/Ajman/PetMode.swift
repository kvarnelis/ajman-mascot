import Foundation

@MainActor
final class PetMode {
    static let defaultsKey = "AjmanPetModeEnabled"
    static let randomIntervalRange: ClosedRange<TimeInterval> = 20...70
    nonisolated static let defaultDozeInterval: TimeInterval = 120

    private weak var animator: Animator?
    private var sleepAnimation: SleepAnimation?
    private let dozeInterval: TimeInterval
    private let currentLiveState: () -> AnimationState
    private let isManualMode: () -> Bool
    private var idleTimer: Timer?
    private var beatTimer: Timer?
    private var dozeTimer: Timer?
    private var wakeUntil: Date?
    private var lastFunState: AnimationState?
    private var ownsRestingAnimation = false

    private(set) var isEnabled: Bool
    private(set) var isSleeping = false

    init(
        animator: Animator,
        sleepAnimation: SleepAnimation?,
        currentLiveState: @escaping () -> AnimationState,
        isManualMode: @escaping () -> Bool,
        dozeInterval: TimeInterval = PetMode.defaultDozeInterval,
        defaults: UserDefaults = .standard
    ) {
        self.animator = animator
        self.sleepAnimation = sleepAnimation
        self.currentLiveState = currentLiveState
        self.isManualMode = isManualMode
        self.dozeInterval = dozeInterval
        isEnabled = defaults.object(forKey: Self.defaultsKey) as? Bool ?? true
    }

    func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.defaultsKey)
        wakeUntil = nil
        isSleeping = false
        cancelTimers()
        guard priorityAllowsPetMode else { return }
        ownsRestingAnimation = true
        animator?.play(.idle)
        if enabled { scheduleRestTimers() }
    }

    /// Called whenever the live/manual driver changes who should own animation.
    /// Active agent and Debug states are deliberately played by their existing drivers.
    func resumeAtRest() {
        guard priorityAllowsPetMode, !ownsRestingAnimation else { return }
        ownsRestingAnimation = true
        cancelTimers()
        wakeUntil = nil
        isSleeping = false
        animator?.play(.idle)
        if isEnabled { scheduleRestTimers() }
    }

    func yieldToHigherPriorityDriver() {
        ownsRestingAnimation = false
        wakeUntil = nil
        isSleeping = false
        cancelTimers()
    }

    /// Any agent event or explicit mode change restarts the calm-at-rest clock.
    func stir() {
        let wasSleeping = isSleeping
        isSleeping = false
        dozeTimer?.invalidate()
        dozeTimer = nil
        if wasSleeping { animator?.play(.idle) }
        guard priorityAllowsPetMode else { return }
        if isEnabled { scheduleDoze() }
    }

    func wake() {
        guard isEnabled, priorityAllowsPetMode else { return }
        cancelTimers()
        isSleeping = false
        animator?.play(.idle)

        let extensionLength = TimeInterval.random(in: 10...15)
        wakeUntil = max(wakeUntil ?? Date(), Date()).addingTimeInterval(extensionLength)
        playAwakeBeat()
    }

    @discardableResult
    func forceSleep() -> Bool {
        cancelTimers()
        wakeUntil = nil
        ownsRestingAnimation = true
        guard let sleepAnimation else {
            isSleeping = false
            animator?.play(.idle)
            return false
        }
        isSleeping = true
        animator?.playSleep(sleepAnimation)
        return true
    }

    func replaceSleepAnimation(_ animation: SleepAnimation?) {
        sleepAnimation = animation
        if animation == nil, isSleeping {
            isSleeping = false
            animator?.play(.idle)
        }
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

    private func scheduleRestTimers() {
        scheduleOccasionalBeat()
        scheduleDoze()
    }

    private func scheduleDoze() {
        guard isEnabled, priorityAllowsPetMode, sleepAnimation != nil, dozeTimer == nil else { return }
        dozeTimer = Timer.scheduledTimer(withTimeInterval: dozeInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dozeIfStillCalm() }
        }
    }

    private func dozeIfStillCalm() {
        dozeTimer = nil
        guard isEnabled, priorityAllowsPetMode, ownsRestingAnimation else { return }
        _ = forceSleep()
    }

    private func scheduleOccasionalBeat() {
        guard isEnabled, priorityAllowsPetMode, !isSleeping else { return }
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
        isSleeping = false
        guard priorityAllowsPetMode else { return }
        animator?.play(.idle)
        if isEnabled { scheduleRestTimers() }
    }

    private func scheduleBeatTimer(after delay: TimeInterval, action: @escaping @MainActor () -> Void) {
        beatTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            Task { @MainActor in action() }
        }
    }

    private func cancelTimers() {
        idleTimer?.invalidate()
        beatTimer?.invalidate()
        dozeTimer?.invalidate()
        idleTimer = nil
        beatTimer = nil
        dozeTimer = nil
    }

    func teardown() {
        ownsRestingAnimation = false
        wakeUntil = nil
        isSleeping = false
        cancelTimers()
    }

    deinit {
        idleTimer?.invalidate()
        beatTimer?.invalidate()
        dozeTimer?.invalidate()
    }
}
