import Foundation

@MainActor
final class PetMode {
    static let defaultsKey = "AjmanPetModeEnabled"
    static let randomIntervalRange: ClosedRange<TimeInterval> = 20...70
    nonisolated static let wakeHoldRange: ClosedRange<TimeInterval> = 0.8...1.2
    nonisolated static let defaultLoafInterval: TimeInterval = 45
    nonisolated static let defaultDozeInterval: TimeInterval = 120

    private weak var animator: Animator?
    private var loafAnimation: SleepAnimation?
    private var sleepAnimation: SleepAnimation?
    private var wakeAnimation: SleepAnimation?
    private let loafInterval: TimeInterval
    private let dozeInterval: TimeInterval
    private let wakeHoldDurationRange: ClosedRange<TimeInterval>
    private let currentLiveState: () -> AnimationState
    private let isManualMode: () -> Bool
    private var idleTimer: Timer?
    private var beatTimer: Timer?
    private var loafTimer: Timer?
    private var dozeTimer: Timer?
    private var wakeTimer: Timer?
    private var wakeUntil: Date?
    private var lastFunState: AnimationState?
    private var ownsRestingAnimation = false

    private(set) var isEnabled: Bool
    private(set) var isLoafing = false
    private(set) var isSleeping = false
    private(set) var isWaking = false

    init(
        animator: Animator,
        loafAnimation: SleepAnimation?,
        sleepAnimation: SleepAnimation?,
        wakeAnimation: SleepAnimation?,
        currentLiveState: @escaping () -> AnimationState,
        isManualMode: @escaping () -> Bool,
        loafInterval: TimeInterval = PetMode.defaultLoafInterval,
        dozeInterval: TimeInterval = PetMode.defaultDozeInterval,
        wakeHoldRange: ClosedRange<TimeInterval> = PetMode.wakeHoldRange,
        defaults: UserDefaults = .standard
    ) {
        self.animator = animator
        self.loafAnimation = loafAnimation
        self.sleepAnimation = sleepAnimation
        self.wakeAnimation = wakeAnimation
        self.currentLiveState = currentLiveState
        self.isManualMode = isManualMode
        self.loafInterval = loafInterval
        self.dozeInterval = dozeInterval
        wakeHoldDurationRange = wakeHoldRange
        isEnabled = defaults.object(forKey: Self.defaultsKey) as? Bool ?? true
    }

    func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.defaultsKey)
        wakeUntil = nil
        clearCalmState()
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
        clearCalmState()
        animator?.play(.idle)
        if isEnabled { scheduleRestTimers() }
    }

    func yieldToHigherPriorityDriver() {
        ownsRestingAnimation = false
        wakeUntil = nil
        clearCalmState()
        cancelTimers()
    }

    /// Any agent event or explicit mode change restarts the calm-at-rest clock.
    func stir() {
        if isWaking { return }
        let wasResting = isLoafing || isSleeping
        loafTimer?.invalidate()
        loafTimer = nil
        dozeTimer?.invalidate()
        dozeTimer = nil
        if wasResting {
            beginWakeTransition()
            return
        }
        guard priorityAllowsPetMode else { return }
        if isEnabled { scheduleRestTimers() }
    }

    func wake() {
        guard isEnabled, priorityAllowsPetMode else { return }
        if isWaking { return }
        if isLoafing || isSleeping {
            beginWakeTransition()
            return
        }

        cancelTimers()
        clearCalmState()
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
        isLoafing = false
        isWaking = false
        guard let sleepAnimation else {
            isSleeping = false
            animator?.play(.idle)
            return false
        }
        isSleeping = true
        animator?.playSleep(sleepAnimation)
        return true
    }

    func replaceCalmAnimations(
        loaf: SleepAnimation?,
        sleep: SleepAnimation?,
        wake: SleepAnimation?
    ) {
        loafAnimation = loaf
        sleepAnimation = sleep
        wakeAnimation = wake
        if loaf == nil, isLoafing { returnToCalmIfAllowed() }
        if sleep == nil, isSleeping { returnToCalmIfAllowed() }
        if wake == nil, isWaking { finishWakeTransition() }
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
        scheduleLoaf()
        scheduleDoze()
    }

    private func scheduleLoaf() {
        guard isEnabled, priorityAllowsPetMode, loafAnimation != nil,
              !isLoafing, !isSleeping, !isWaking, loafTimer == nil else { return }
        loafTimer = Timer.scheduledTimer(withTimeInterval: loafInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.loafIfStillCalm() }
        }
    }

    private func scheduleDoze() {
        guard isEnabled, priorityAllowsPetMode, sleepAnimation != nil,
              !isSleeping, !isWaking, dozeTimer == nil else { return }
        dozeTimer = Timer.scheduledTimer(withTimeInterval: dozeInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dozeIfStillCalm() }
        }
    }

    private func loafIfStillCalm() {
        loafTimer = nil
        guard isEnabled, priorityAllowsPetMode, ownsRestingAnimation,
              !isSleeping, let loafAnimation else { return }
        idleTimer?.invalidate()
        idleTimer = nil
        beatTimer?.invalidate()
        beatTimer = nil
        isLoafing = true
        animator?.playLoaf(loafAnimation)
    }

    private func dozeIfStillCalm() {
        dozeTimer = nil
        guard isEnabled, priorityAllowsPetMode, ownsRestingAnimation else { return }
        _ = forceSleep()
    }

    private func beginWakeTransition() {
        cancelTimers()
        wakeUntil = nil
        ownsRestingAnimation = true
        isLoafing = false
        isSleeping = false
        guard let wakeAnimation else {
            isWaking = false
            animator?.play(.idle)
            finishWakeTransition()
            return
        }

        isWaking = true
        animator?.playWake(wakeAnimation)
        let hold = TimeInterval.random(in: wakeHoldDurationRange)
        wakeTimer = Timer.scheduledTimer(withTimeInterval: hold, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finishWakeTransition() }
        }
    }

    private func finishWakeTransition() {
        wakeTimer?.invalidate()
        wakeTimer = nil
        isWaking = false
        guard !isManualMode() else {
            ownsRestingAnimation = false
            return
        }

        let liveState = currentLiveState()
        if liveState == .idle {
            ownsRestingAnimation = true
            animator?.play(.idle)
            if isEnabled { scheduleRestTimers() }
        } else {
            ownsRestingAnimation = false
            animator?.play(liveState)
        }
    }

    private func scheduleOccasionalBeat() {
        guard isEnabled, priorityAllowsPetMode, !isLoafing, !isSleeping, !isWaking,
              idleTimer == nil, beatTimer == nil else { return }
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
        clearCalmState()
        guard priorityAllowsPetMode else { return }
        animator?.play(.idle)
        if isEnabled { scheduleRestTimers() }
    }

    private func clearCalmState() {
        isLoafing = false
        isSleeping = false
        isWaking = false
    }

    private func scheduleBeatTimer(after delay: TimeInterval, action: @escaping @MainActor () -> Void) {
        beatTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            Task { @MainActor in action() }
        }
    }

    private func cancelTimers() {
        idleTimer?.invalidate()
        beatTimer?.invalidate()
        loafTimer?.invalidate()
        dozeTimer?.invalidate()
        wakeTimer?.invalidate()
        idleTimer = nil
        beatTimer = nil
        loafTimer = nil
        dozeTimer = nil
        wakeTimer = nil
    }

    func teardown() {
        ownsRestingAnimation = false
        wakeUntil = nil
        clearCalmState()
        cancelTimers()
    }

    deinit {
        idleTimer?.invalidate()
        beatTimer?.invalidate()
        loafTimer?.invalidate()
        dozeTimer?.invalidate()
        wakeTimer?.invalidate()
    }
}
