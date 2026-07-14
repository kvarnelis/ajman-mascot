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
        case .left: 0
        case .right: 1
        }
    }
}

enum ScratchEdgeGeometry {
    // Measured from the authored 192 px reach-up frames. The right paw's
    // outermost opaque pixel is x=155; the left paw's is x=37.
    nonisolated static let leftPawX: CGFloat = 37
    nonisolated static let rightPawX: CGFloat = 155

    nonisolated static func targetOriginX(
        side: ScratchSide,
        visibleMinX: CGFloat,
        visibleMaxX: CGFloat,
        scale: CGFloat
    ) -> CGFloat {
        switch side {
        case .left: visibleMinX - leftPawX * scale
        case .right: visibleMaxX - rightPawX * scale
        }
    }

    nonisolated static func farSide(
        currentOriginX: CGFloat,
        visibleMinX: CGFloat,
        visibleMaxX: CGFloat,
        scale: CGFloat
    ) -> ScratchSide {
        let leftX = targetOriginX(
            side: .left, visibleMinX: visibleMinX, visibleMaxX: visibleMaxX, scale: scale
        )
        let rightX = targetOriginX(
            side: .right, visibleMinX: visibleMinX, visibleMaxX: visibleMaxX, scale: scale
        )
        return abs(leftX - currentOriginX) >= abs(rightX - currentOriginX) ? .left : .right
    }

    nonisolated static func travelState(fromOriginX: CGFloat, toOriginX: CGFloat) -> AnimationState {
        toOriginX < fromOriginX ? .runningLeft : .runningRight
    }
}

/// `NSWindow` does not animate `frameOrigin` through its animator proxy. Move
/// the real panel explicitly so completion cannot run until the window reaches
/// its destination.
@MainActor
final class ScratchPanelMover {
    private let currentOrigin: () -> NSPoint?
    private let setOrigin: (NSPoint) -> Void
    private var timer: Timer?
    private var movementID = 0

    init(panel: NSWindow) {
        currentOrigin = { [weak panel] in panel?.frame.origin }
        setOrigin = { [weak panel] origin in panel?.setFrameOrigin(origin) }
    }

    init(
        currentOrigin: @escaping () -> NSPoint?,
        setOrigin: @escaping (NSPoint) -> Void
    ) {
        self.currentOrigin = currentOrigin
        self.setOrigin = setOrigin
    }

    func move(
        to target: NSPoint,
        duration: TimeInterval,
        shouldContinue: @escaping @MainActor () -> Bool = { true },
        completion: @escaping @MainActor () -> Void
    ) {
        cancel()
        guard let start = currentOrigin() else { return }
        guard duration > 0, hypot(target.x - start.x, target.y - start.y) > 0.5 else {
            setOrigin(target)
            completion()
            return
        }

        movementID += 1
        let id = movementID
        let startTime = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self, self.movementID == id, shouldContinue(), self.currentOrigin() != nil else {
                    timer.invalidate()
                    return
                }
                let elapsed = ProcessInfo.processInfo.systemUptime - startTime
                let progress = min(max(elapsed / duration, 0), 1)
                let eased = progress * progress * (3 - 2 * progress)
                self.setOrigin(NSPoint(
                    x: start.x + (target.x - start.x) * eased,
                    y: start.y + (target.y - start.y) * eased
                ))
                guard progress >= 1 else { return }
                timer.invalidate()
                self.timer = nil
                completion()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func cancel() {
        movementID += 1
        timer?.invalidate()
        timer = nil
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

/// An infrequent idle-only round trip to a display edge, followed by a held
/// reach-up pose and a brief layer-local rake before returning home.
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
    private let moveBackToStart: (@escaping @MainActor () -> Void) -> Void
    private let showPose: (ScratchSide) -> Bool
    private let setRaking: (Bool) -> Void
    private let showIdle: () -> Void
    private let didFinish: () -> Void
    private let scheduler: Scheduler
    private let randomUnit: () -> Double
    private let chooseSide: () -> ScratchSide?
    private let now: () -> Date
    private let temperament: () -> Temperament

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
        moveBackToStart: @escaping (@escaping @MainActor () -> Void) -> Void,
        showPose: @escaping (ScratchSide) -> Bool,
        setRaking: @escaping (Bool) -> Void,
        showIdle: @escaping () -> Void,
        didFinish: @escaping () -> Void,
        scheduler: Scheduler? = nil,
        randomUnit: @escaping () -> Double = { Double.random(in: 0..<1) },
        chooseSide: @escaping () -> ScratchSide? = { ScratchSide.allCases.randomElement() },
        now: @escaping () -> Date = Date.init,
        temperament: @escaping () -> Temperament = { .normal }
    ) {
        self.animation = animation
        self.eligibility = eligibility
        self.willStart = willStart
        self.moveToEdge = moveToEdge
        self.moveBackToStart = moveBackToStart
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
        self.temperament = temperament
    }

    func resumeScheduling() {
        guard animation != nil, !isPerforming, whimTimer == nil else { return }
        let delay = TimeInterval.random(in: temperament().scaled(range: Self.scheduleRange))
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
        guard !isPerforming, animation != nil, eligibility().canStart,
              let side = side ?? chooseSide() else { return false }
        begin(side: side, recordsSpacing: true)
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

    func rescheduleForTemperamentChange() {
        guard !isPerforming else { return }
        whimTimer?.invalidate()
        whimTimer = nil
        resumeScheduling()
    }

    private func considerWhim() {
        whimTimer?.invalidate()
        whimTimer = nil
        let temperament = temperament()
        guard randomUnit() < temperament.scaled(probability: Self.triggerProbability) else { return }
        if let lastScratchAt,
           now().timeIntervalSince(lastScratchAt) < temperament.scaled(interval: Self.minimumSpacing) {
            return
        }
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
                    self.after(0.18, id: id) { [weak self] in
                        guard let self else { return }
                        self.moveBackToStart { [weak self] in self?.finish(id: id) }
                    }
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
