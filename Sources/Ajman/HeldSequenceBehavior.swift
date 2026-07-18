import Foundation

enum GroomingSequence {
    nonisolated static let frameDurations: [TimeInterval] = [0.75, 0.7, 0.85, 0.85, 1.0, 0.9]
    nonisolated static let scheduleRange: ClosedRange<TimeInterval> = 18...30
    nonisolated static let triggerProbability = 0.28
    nonisolated static let minimumSpacing: TimeInterval = 75
}

struct HeldSequenceEligibility {
    let hasAsset: Bool
    let isShown: Bool
    let liveState: AnimationState
    let displayedState: AnimationState
    let isManual: Bool
    let isCalmPose: Bool
    let isGlancing: Bool

    var canStart: Bool {
        hasAsset && isShown && liveState == .idle && displayedState == .idle
            && !isManual && !isCalmPose && !isGlancing
    }
}

/// A finite authored pose ritual with individually held frames. It is separate
/// from the looping sprite-sheet states and returns the pet to its seated idle.
@MainActor
final class HeldSequenceBehavior {
    typealias Scheduler = (TimeInterval, @escaping @MainActor () -> Void) -> Void

    private let animation: SleepAnimation?
    private let frameDurations: [TimeInterval]
    private let scheduleRange: ClosedRange<TimeInterval>
    private let triggerProbability: Double
    private let minimumSpacing: TimeInterval
    private let eligibility: () -> HeldSequenceEligibility
    private let willStart: () -> Void
    private let showFrame: (Int) -> Bool
    private let showIdle: () -> Void
    private let didFinish: () -> Void
    private let scheduler: Scheduler
    private let randomUnit: () -> Double
    private let now: () -> Date
    private let temperament: () -> Temperament

    private var whimTimer: Timer?
    private var sequenceID = 0
    private var lastPerformedAt: Date?
    private var recordsSpacing = false
    private(set) var isPerforming = false

    init(
        animation: SleepAnimation?,
        frameDurations: [TimeInterval],
        scheduleRange: ClosedRange<TimeInterval>,
        triggerProbability: Double,
        minimumSpacing: TimeInterval,
        eligibility: @escaping () -> HeldSequenceEligibility,
        willStart: @escaping () -> Void,
        showFrame: @escaping (Int) -> Bool,
        showIdle: @escaping () -> Void,
        didFinish: @escaping () -> Void,
        scheduler: Scheduler? = nil,
        randomUnit: @escaping () -> Double = { Double.random(in: 0..<1) },
        now: @escaping () -> Date = Date.init,
        temperament: @escaping () -> Temperament = { .normal }
    ) {
        self.animation = animation
        self.frameDurations = frameDurations
        self.scheduleRange = scheduleRange
        self.triggerProbability = triggerProbability
        self.minimumSpacing = minimumSpacing
        self.eligibility = eligibility
        self.willStart = willStart
        self.showFrame = showFrame
        self.showIdle = showIdle
        self.didFinish = didFinish
        self.scheduler = scheduler ?? { delay, action in
            Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
                Task { @MainActor in action() }
            }
        }
        self.randomUnit = randomUnit
        self.now = now
        self.temperament = temperament
    }

    func resumeScheduling() {
        guard animation != nil, frameDurations.count == animation?.frameCount,
              !isPerforming, whimTimer == nil else { return }
        let delay = TimeInterval.random(in: temperament().scaledFidget(range: scheduleRange))
        whimTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.considerWhim() }
        }
    }

    func cancel(returnToIdle: Bool) {
        whimTimer?.invalidate()
        whimTimer = nil
        sequenceID += 1
        let wasPerforming = isPerforming
        isPerforming = false
        if returnToIdle, wasPerforming { showIdle() }
    }

    @discardableResult
    func startIfEligible() -> Bool {
        guard !isPerforming, animation != nil, frameDurations.count == animation?.frameCount,
              eligibility().canStart else { return false }
        begin(recordsSpacing: true)
        return true
    }

    @discardableResult
    func forceStart() -> Bool {
        guard !isPerforming, animation != nil, frameDurations.count == animation?.frameCount else { return false }
        begin(recordsSpacing: false)
        return true
    }

    func rescheduleForTemperamentChange() {
        guard !isPerforming else { return }
        whimTimer?.invalidate()
        whimTimer = nil
        resumeScheduling()
    }

    func teardown() {
        cancel(returnToIdle: false)
    }

    private func considerWhim() {
        whimTimer?.invalidate()
        whimTimer = nil
        let temperament = temperament()
        guard randomUnit() < temperament.scaledFidget(probability: triggerProbability) else { return }
        if let lastPerformedAt,
           now().timeIntervalSince(lastPerformedAt) < temperament.scaledFidget(interval: minimumSpacing) {
            return
        }
        _ = startIfEligible()
    }

    private func begin(recordsSpacing: Bool) {
        willStart()
        isPerforming = true
        self.recordsSpacing = recordsSpacing
        sequenceID += 1
        playFrame(0, id: sequenceID)
    }

    private func playFrame(_ index: Int, id: Int) {
        guard isCurrent(id) else { return }
        guard frameDurations.indices.contains(index), showFrame(index) else {
            finish(id: id)
            return
        }
        scheduler(frameDurations[index]) { [weak self] in
            guard let self, self.isCurrent(id) else { return }
            let next = index + 1
            if next < self.frameDurations.count {
                self.playFrame(next, id: id)
            } else {
                self.finish(id: id)
            }
        }
    }

    private func finish(id: Int) {
        guard isCurrent(id) else { return }
        showIdle()
        isPerforming = false
        if recordsSpacing { lastPerformedAt = now() }
        didFinish()
    }

    private func isCurrent(_ id: Int) -> Bool {
        isPerforming && sequenceID == id
    }
}
