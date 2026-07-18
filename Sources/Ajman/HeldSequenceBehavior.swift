import Foundation

enum GroomingSequence {
    nonisolated static let frameDurations: [TimeInterval] = [0.8, 0.65, 0.75, 0.9, 0.9, 1.1, 0.65, 0.75]
    nonisolated static let ajmanFrameDurations: [TimeInterval] = [0.9, 0.8, 0.85, 0.9, 1.05, 1.1, 0.8, 0.8]
    nonisolated static let scheduleRange: ClosedRange<TimeInterval> = 18...30
    nonisolated static let triggerProbability = 0.28
    nonisolated static let minimumSpacing: TimeInterval = 75

    nonisolated static func frameDurations(for petID: String) -> [TimeInterval] {
        petID == "ajman" ? ajmanFrameDurations : frameDurations
    }
}

struct HeldSequenceWhimSettings: Equatable {
    let scheduleRange: ClosedRange<TimeInterval>
    let triggerProbability: Double
    let minimumSpacing: TimeInterval
    let reschedulesAfterMiss: Bool
}

enum ScreamSequence {
    nonisolated static let frameDurations: [TimeInterval] = [0.7, 0.8, 1.0, 1.5]
    nonisolated static let variants = [[0, 1, 2, 3], [4, 5, 6, 7]]
    nonisolated static let ajmanFrameDurations: [TimeInterval] = [0.55, 0.55, 0.6, 0.7, 1.0, 0.9, 0.65, 0.55]
    nonisolated static let ajmanArc = [Array(0..<8)]

    nonisolated static func frameDurations(for petID: String) -> [TimeInterval] {
        petID == "ajman" ? ajmanFrameDurations : frameDurations
    }

    nonisolated static func frameSequences(for petID: String) -> [[Int]] {
        petID == "ajman" ? ajmanArc : variants
    }

    nonisolated static func whimSettings(for temperament: Temperament) -> HeldSequenceWhimSettings {
        switch temperament {
        case .catatonic:
            HeldSequenceWhimSettings(
                scheduleRange: 0...0, triggerProbability: 0,
                minimumSpacing: .infinity, reschedulesAfterMiss: false
            )
        case .calm:
            HeldSequenceWhimSettings(
                scheduleRange: 1_800...2_700, triggerProbability: 0.15,
                minimumSpacing: 7_200, reschedulesAfterMiss: true
            )
        case .normal:
            HeldSequenceWhimSettings(
                scheduleRange: 1_200...1_800, triggerProbability: 0.25,
                minimumSpacing: 3_600, reschedulesAfterMiss: true
            )
        case .frisky:
            HeldSequenceWhimSettings(
                scheduleRange: 600...900, triggerProbability: 0.35,
                minimumSpacing: 1_200, reschedulesAfterMiss: true
            )
        case .insane:
            HeldSequenceWhimSettings(
                scheduleRange: 360...600, triggerProbability: 0.35,
                minimumSpacing: 720, reschedulesAfterMiss: true
            )
        }
    }
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
    private let frameSequences: [[Int]]
    private let eligibility: () -> HeldSequenceEligibility
    private let willStart: () -> Void
    private let showFrame: (Int) -> Bool
    private let showIdle: () -> Void
    private let didFinish: () -> Void
    private let scheduler: Scheduler
    private let randomUnit: () -> Double
    private let now: () -> Date
    private let temperament: () -> Temperament
    private let whimSettings: (Temperament) -> HeldSequenceWhimSettings
    private let sequenceRandomUnit: () -> Double

    private var whimTimer: Timer?
    private var sequenceID = 0
    private var lastPerformedAt: Date?
    private var recordsSpacing = false
    private var activeFrameSequence: [Int] = []
    private(set) var isPerforming = false

    init(
        animation: SleepAnimation?,
        frameDurations: [TimeInterval],
        scheduleRange: ClosedRange<TimeInterval>,
        triggerProbability: Double,
        minimumSpacing: TimeInterval,
        frameSequences: [[Int]]? = nil,
        eligibility: @escaping () -> HeldSequenceEligibility,
        willStart: @escaping () -> Void,
        showFrame: @escaping (Int) -> Bool,
        showIdle: @escaping () -> Void,
        didFinish: @escaping () -> Void,
        scheduler: Scheduler? = nil,
        randomUnit: @escaping () -> Double = { Double.random(in: 0..<1) },
        now: @escaping () -> Date = Date.init,
        temperament: @escaping () -> Temperament = { .normal },
        whimSettings: ((Temperament) -> HeldSequenceWhimSettings)? = nil,
        sequenceRandomUnit: @escaping () -> Double = { Double.random(in: 0..<1) }
    ) {
        self.animation = animation
        self.frameDurations = frameDurations
        self.frameSequences = frameSequences ?? []
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
        self.whimSettings = whimSettings ?? { temperament in
            HeldSequenceWhimSettings(
                scheduleRange: temperament.scaledFidget(range: scheduleRange),
                triggerProbability: temperament.scaledFidget(probability: triggerProbability),
                minimumSpacing: temperament.scaledFidget(interval: minimumSpacing),
                reschedulesAfterMiss: false
            )
        }
        self.sequenceRandomUnit = sequenceRandomUnit
    }

    func resumeScheduling() {
        guard isConfigured, !isPerforming, whimTimer == nil else { return }
        let settings = whimSettings(temperament())
        guard settings.triggerProbability > 0 else { return }
        let delay = TimeInterval.random(in: settings.scheduleRange)
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
        guard !isPerforming, isConfigured,
              eligibility().canStart else { return false }
        begin(recordsSpacing: true)
        return true
    }

    @discardableResult
    func forceStart() -> Bool {
        guard !isPerforming, isConfigured else { return false }
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
        let settings = whimSettings(temperament())
        guard randomUnit() < settings.triggerProbability else {
            if settings.reschedulesAfterMiss { resumeScheduling() }
            return
        }
        if let lastPerformedAt,
           now().timeIntervalSince(lastPerformedAt) < settings.minimumSpacing {
            if settings.reschedulesAfterMiss { resumeScheduling() }
            return
        }
        if !startIfEligible() {
            if settings.reschedulesAfterMiss { resumeScheduling() }
        }
    }

    private func begin(recordsSpacing: Bool) {
        willStart()
        isPerforming = true
        self.recordsSpacing = recordsSpacing
        if frameSequences.isEmpty {
            activeFrameSequence = Array(0..<frameDurations.count)
        } else {
            let unit = min(max(sequenceRandomUnit(), 0), 0.999999999)
            activeFrameSequence = frameSequences[min(Int(unit * Double(frameSequences.count)), frameSequences.count - 1)]
        }
        sequenceID += 1
        playFrame(0, id: sequenceID)
    }

    private func playFrame(_ index: Int, id: Int) {
        guard isCurrent(id) else { return }
        guard frameDurations.indices.contains(index), activeFrameSequence.indices.contains(index),
              showFrame(activeFrameSequence[index]) else {
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

    private var isConfigured: Bool {
        guard let animation else { return false }
        if frameSequences.isEmpty { return frameDurations.count == animation.frameCount }
        return frameSequences.allSatisfy { sequence in
            sequence.count == frameDurations.count
                && sequence.allSatisfy { animation.frames.indices.contains($0) }
        }
    }
}
