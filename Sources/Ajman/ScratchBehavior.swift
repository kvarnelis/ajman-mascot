import AppKit

enum ScratchSide: CaseIterable {
    case left
    case right

    var approachState: AnimationState {
        switch self {
        case .left: .runningLeft
        case .right: .runningRight
        }
    }

    var poseIndex: Int {
        switch self {
        case .right: 0
        case .left: 1
        }
    }
}

struct ScratchEligibility {
    let hasAsset: Bool
    let isShown: Bool
    let liveState: AnimationState
    let displayedState: AnimationState
    let isManual: Bool
    let isPlayfulIdleEnabled: Bool
    let isCalmPose: Bool
    let isGlancing: Bool

    var canStart: Bool {
        hasAsset
            && isShown
            && liveState == .idle
            && displayedState == .idle
            && !isManual
            && isPlayfulIdleEnabled
            && !isCalmPose
            && !isGlancing
    }
}

/// An infrequent idle-only trip to a display edge, followed by a held reach-up
/// pose and a brief layer-local rake. The panel remains at the edge afterward.
@MainActor
final class ScratchBehavior {
    nonisolated static let scheduleRange: ClosedRange<TimeInterval> = 24...38
    nonisolated static let triggerProbability = 0.14
    nonisolated static let minimumSpacing: TimeInterval = 240
    nonisolated static let rakeAmplitude: CGFloat = 5
    nonisolated static let rakeCycles = 4
    nonisolated static let rakeDuration: TimeInterval = 0.64

    typealias Scheduler = (TimeInterval, @escaping @MainActor () -> Void) -> Void

    private let animation: SleepAnimation?
    private let eligibility: () -> ScratchEligibility
    private let willStart: () -> Void
    private let moveToEdge: (ScratchSide, @escaping @MainActor () -> Void) -> Void
    private let showPose: (ScratchSide) -> Bool
    private let setRaking: (Bool) -> Void
    private let showIdle: () -> Void
    private let didFinish: () -> Void
    private let scheduler: Scheduler
    private let randomUnit: () -> Double
    private let chooseSide: () -> ScratchSide
    private let now: () -> Date

    private var whimTimer: Timer?
    private var sequenceID = 0
    private var lastScratchAt: Date?
    private var isRaking = false
    private var recordsSpacing = false
    private(set) var isPerforming = false

    init(
        animation: SleepAnimation?,
        eligibility: @escaping () -> ScratchEligibility,
        willStart: @escaping () -> Void,
        moveToEdge: @escaping (ScratchSide, @escaping @MainActor () -> Void) -> Void,
        showPose: @escaping (ScratchSide) -> Bool,
        setRaking: @escaping (Bool) -> Void,
        showIdle: @escaping () -> Void,
        didFinish: @escaping () -> Void,
        scheduler: Scheduler? = nil,
        randomUnit: @escaping () -> Double = { Double.random(in: 0..<1) },
        chooseSide: @escaping () -> ScratchSide = { ScratchSide.allCases.randomElement() ?? .left },
        now: @escaping () -> Date = Date.init
    ) {
        self.animation = animation
        self.eligibility = eligibility
        self.willStart = willStart
        self.moveToEdge = moveToEdge
        self.showPose = showPose
        self.setRaking = setRaking
        self.showIdle = showIdle
        self.didFinish = didFinish
        self.scheduler = scheduler ?? { delay, action in
            Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
                Task { @MainActor in action() }
            }
        }
        self.randomUnit = randomUnit
        self.chooseSide = chooseSide
        self.now = now
    }

    func resumeScheduling() {
        guard animation != nil, !isPerforming, whimTimer == nil else { return }
        let delay = TimeInterval.random(in: Self.scheduleRange)
        whimTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.considerWhim() }
        }
    }

    func cancel(returnToIdle: Bool) {
        whimTimer?.invalidate()
        whimTimer = nil
        sequenceID += 1
        updateRaking(false)
        let wasPerforming = isPerforming
        isPerforming = false
        if returnToIdle, wasPerforming { showIdle() }
    }

    @discardableResult
    func startIfEligible(side: ScratchSide? = nil) -> Bool {
        guard !isPerforming, animation != nil, eligibility().canStart else { return false }
        begin(side: side ?? chooseSide(), recordsSpacing: true)
        return true
    }

    @discardableResult
    func forceStart(side: ScratchSide) -> Bool {
        guard !isPerforming, animation != nil else { return false }
        begin(side: side, recordsSpacing: false)
        return true
    }

    func teardown() {
        cancel(returnToIdle: false)
    }

    private func considerWhim() {
        whimTimer?.invalidate()
        whimTimer = nil
        guard randomUnit() < Self.triggerProbability else { return }
        if let lastScratchAt, now().timeIntervalSince(lastScratchAt) < Self.minimumSpacing { return }
        _ = startIfEligible()
    }

    private func begin(side: ScratchSide, recordsSpacing: Bool) {
        willStart()
        isPerforming = true
        self.recordsSpacing = recordsSpacing
        sequenceID += 1
        let id = sequenceID
        moveToEdge(side) { [weak self] in
            guard let self, self.isCurrent(id) else { return }
            guard self.showPose(side) else {
                self.finish(id: id)
                return
            }
            self.after(0.24, id: id) { [weak self] in
                guard let self else { return }
                self.updateRaking(true)
                self.after(Self.rakeDuration, id: id) { [weak self] in
                    guard let self else { return }
                    self.updateRaking(false)
                    self.after(0.18, id: id) { [weak self] in self?.finish(id: id) }
                }
            }
        }
    }

    private func finish(id: Int) {
        guard isCurrent(id) else { return }
        updateRaking(false)
        showIdle()
        isPerforming = false
        if recordsSpacing { lastScratchAt = now() }
        didFinish()
    }

    private func after(_ delay: TimeInterval, id: Int, action: @escaping @MainActor () -> Void) {
        scheduler(delay) { [weak self] in
            guard let self, self.isCurrent(id) else { return }
            action()
        }
    }

    private func isCurrent(_ id: Int) -> Bool {
        isPerforming && sequenceID == id
    }

    private func updateRaking(_ enabled: Bool) {
        guard isRaking != enabled else { return }
        isRaking = enabled
        setRaking(enabled)
    }
}
