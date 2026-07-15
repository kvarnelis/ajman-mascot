import Foundation

@MainActor
final class PetMode {
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
    private var temperament: Temperament
    private var ownsRestingAnimation = false

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
        temperament: Temperament = .normal
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
        self.temperament = temperament
    }

    func setTemperament(_ temperament: Temperament) {
        guard self.temperament != temperament else { return }
        self.temperament = temperament
        guard priorityAllowsPetMode, ownsRestingAnimation else { return }
        if temperament == .insane, isLoafing || isSleeping {
            beginWakeTransition()
            return
        }
        guard !isLoafing, !isSleeping, !isWaking else { return }
        idleTimer?.invalidate()
        idleTimer = nil
        loafTimer?.invalidate()
        loafTimer = nil
        dozeTimer?.invalidate()
        dozeTimer = nil
        scheduleOccasionalBeat()
        scheduleLoaf()
        scheduleDoze()
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
        scheduleRestTimers()
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
        scheduleRestTimers()
    }

    func wake() {
        guard priorityAllowsPetMode else { return }
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
    func forceLoaf() -> Bool {
        cancelTimers()
        wakeUntil = nil
        ownsRestingAnimation = true
        isSleeping = false
        isWaking = false
        guard let loafAnimation else {
            isLoafing = false
            animator?.play(.idle)
            return false
        }
        isLoafing = true
        animator?.playLoaf(loafAnimation)
        return true
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
        guard priorityAllowsPetMode, loafAnimation != nil,
              !isLoafing, !isSleeping, !isWaking, loafTimer == nil,
              temperament.allowsAutomaticRest else { return }
        let interval = temperament.scaledAutomaticRest(interval: loafInterval)
        loafTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.loafIfStillCalm() }
        }
    }

    private func scheduleDoze() {
        guard priorityAllowsPetMode, sleepAnimation != nil,
              !isSleeping, !isWaking, dozeTimer == nil,
              temperament.allowsAutomaticRest else { return }
        let interval = temperament.scaledAutomaticRest(interval: dozeInterval)
        dozeTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dozeIfStillCalm() }
        }
    }

    private func loafIfStillCalm() {
        loafTimer = nil
        guard priorityAllowsPetMode, ownsRestingAnimation,
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
        guard priorityAllowsPetMode, ownsRestingAnimation else { return }
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
            scheduleRestTimers()
        } else {
            ownsRestingAnimation = false
            animator?.play(liveState)
        }
    }

    private func scheduleOccasionalBeat() {
        guard priorityAllowsPetMode, !isLoafing, !isSleeping, !isWaking,
              idleTimer == nil, beatTimer == nil else { return }
        let delay = TimeInterval.random(in: temperament.scaledFidget(range: Self.randomIntervalRange))
        idleTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.playOccasionalBeat() }
        }
    }

    private func playOccasionalBeat() {
        idleTimer = nil
        guard priorityAllowsPetMode else {
            returnToCalmIfAllowed()
            return
        }

        let amplitude = temperament.idleFidgetAmplitudeMultiplier
        guard amplitude >= 0.05 else {
            // Catatonic is intentionally too still for an authored full-body beat.
            returnToCalmIfAllowed()
            return
        }

        let duration: TimeInterval
        if amplitude < 1,
           animator?.availableStates.contains(.lookDirectionsA) == true,
           animator?.playSingleFrame(.lookDirectionsA, frameIndex: Int.random(in: 0...1)) == true {
            // Calm gets a brief head-only look instead of a jump, wave, or
            // other full-body action. This is the visible amplitude reduction.
            duration = 0.6 + amplitude
        } else if let state = chooseFunState() {
            animator?.play(state)
            duration = animator?.duration(of: state) ?? 1
        } else {
            returnToCalmIfAllowed()
            return
        }

        scheduleBeatTimer(after: duration) { [weak self] in
            self?.returnToCalmIfAllowed()
        }
    }

    private func playAwakeBeat() {
        beatTimer?.invalidate()
        beatTimer = nil
        guard priorityAllowsPetMode,
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
        scheduleRestTimers()
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
