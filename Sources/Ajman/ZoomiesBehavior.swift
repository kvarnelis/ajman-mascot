import AppKit

struct ZoomiesWhimSettings: Equatable {
    let scheduleRange: ClosedRange<TimeInterval>
    let triggerProbability: Double
    let minimumSpacing: TimeInterval
    let reschedulesAfterMiss: Bool
}

enum ZoomiesSchedule {
    nonisolated static let dashCountRange = 1...3
    nonisolated static let minimumDashLength: CGFloat = 120
    nonisolated static let scratchTravelVelocity: CGFloat = 110
    nonisolated static let velocityMultiplier: CGFloat = 3.2
    nonisolated static let velocity = scratchTravelVelocity * velocityMultiplier

    nonisolated static func whimSettings(for temperament: Temperament) -> ZoomiesWhimSettings {
        switch temperament {
        case .catatonic:
            ZoomiesWhimSettings(
                scheduleRange: 0...0, triggerProbability: 0,
                minimumSpacing: .infinity, reschedulesAfterMiss: false
            )
        case .calm:
            ZoomiesWhimSettings(
                scheduleRange: 2_700...3_600, triggerProbability: 0.20,
                minimumSpacing: 7_200, reschedulesAfterMiss: true
            )
        case .normal:
            ZoomiesWhimSettings(
                scheduleRange: 1_200...1_800, triggerProbability: 0.40,
                minimumSpacing: 2_700, reschedulesAfterMiss: true
            )
        case .frisky:
            ZoomiesWhimSettings(
                scheduleRange: 600...900, triggerProbability: 0.45,
                minimumSpacing: 1_200, reschedulesAfterMiss: true
            )
        case .insane:
            ZoomiesWhimSettings(
                scheduleRange: 180...300, triggerProbability: 0.65,
                minimumSpacing: 300, reschedulesAfterMiss: true
            )
        }
    }

    nonisolated static func dashCount(randomUnit: Double) -> Int {
        let unit = min(max(randomUnit, 0), 0.999999999)
        return dashCountRange.lowerBound
            + Int(unit * Double(dashCountRange.count))
    }
}

enum ZoomiesFrameFacing: String, Equatable {
    case left
    case right
    case front
    case frontRight = "front-right"
}

enum ZoomiesChoreography {
    // Read from the owner-delivered pixels. Winnie is asymmetric, so these
    // authored directions must never be inferred by index or mirrored.
    nonisolated static let frameFacings: [ZoomiesFrameFacing] = [
        .right, .right, .right, .frontRight, .front, .left, .right, .right,
    ]
    nonisolated static let startFrames = [0, 1]
    nonisolated static let finishFrames = [3, 4]
    nonisolated static let startDurations: [TimeInterval] = [0.32, 0.12]
    nonisolated static let turnFrameDuration: TimeInterval = 0.09
    nonisolated static let turnFallbackDuration: TimeInterval = 0.12
    nonisolated static let finishDurations: [TimeInterval] = [0.14, 0.28]
    nonisolated static let travelFrameDuration: TimeInterval = 0.055

    nonisolated static func travelFrames(for side: ScratchSide) -> [Int] {
        switch side {
        case .left: [5]
        case .right: [2, 3]
        }
    }

    nonisolated static func turnFrames(toward side: ScratchSide) -> [Int] {
        switch side {
        case .left: [] // No owner-authored left-facing skid; use run-left briefly.
        case .right: [6, 7]
        }
    }
}

enum ZoomiesGeometry {
    /// Select an on-screen panel origin at least `minimumDistance` away. When
    /// both directions are available, either can be chosen for every dash.
    nonisolated static func targetOriginX(
        currentOriginX: CGFloat,
        visibleMinX: CGFloat,
        visibleMaxX: CGFloat,
        panelWidth: CGFloat,
        minimumDistance: CGFloat = ZoomiesSchedule.minimumDashLength,
        randomUnit: Double
    ) -> CGFloat? {
        let minimumX = visibleMinX
        let maximumX = max(minimumX, visibleMaxX - panelWidth)
        let currentX = min(max(currentOriginX, minimumX), maximumX)
        let canGoLeft = currentX - minimumX >= minimumDistance
        let canGoRight = maximumX - currentX >= minimumDistance
        guard canGoLeft || canGoRight else { return nil }

        let unit = min(max(randomUnit, 0), 0.999999999)
        let chooseLeft = canGoLeft && (!canGoRight || unit < 0.5)
        if chooseLeft {
            let localUnit = canGoRight ? unit * 2 : unit
            let upperX = currentX - minimumDistance
            return minimumX + (upperX - minimumX) * CGFloat(localUnit)
        }

        let localUnit = canGoLeft ? (unit - 0.5) * 2 : unit
        let lowerX = currentX + minimumDistance
        return lowerX + (maximumX - lowerX) * CGFloat(localUnit)
    }
}

struct ZoomiesEligibility {
    let hasRunCompanions: Bool
    let isShown: Bool
    let liveState: AnimationState
    let displayedState: AnimationState
    let isManual: Bool
    let isCalmPose: Bool
    let isGlancing: Bool

    var canStart: Bool {
        hasRunCompanions && isShown && liveState == .idle && displayedState == .idle
            && !isManual && !isCalmPose && !isGlancing
    }
}

/// A sudden idle-only burst of one to three purposeless ground-level dashes,
/// ending immediately in the ordinary seated idle.
@MainActor
final class ZoomiesBehavior {
    private let hasRunCompanions: Bool
    private let eligibility: () -> ZoomiesEligibility
    private let willStart: () -> Void
    private let nextTarget: () -> NSPoint?
    private let directionToTarget: (NSPoint) -> ScratchSide
    private let showFrame: (Int) -> Bool
    private let showTravel: (ScratchSide) -> Bool
    private let showRunFallback: (ScratchSide) -> Void
    private let moveDash: (NSPoint, @escaping @MainActor () -> Void) -> Void
    private let cancelMovement: () -> Void
    private let showIdle: () -> Void
    private let didFinish: () -> Void
    private let randomUnit: () -> Double
    private let dashCountRandomUnit: () -> Double
    private let now: () -> Date
    private let temperament: () -> Temperament
    private let scheduler: (TimeInterval, @escaping @MainActor () -> Void) -> Void

    private var whimTimer: Timer?
    private var sequenceID = 0
    private var lastPerformedAt: Date?
    private var recordsSpacing = false
    private(set) var isPerforming = false

    init(
        hasRunCompanions: Bool,
        eligibility: @escaping () -> ZoomiesEligibility,
        willStart: @escaping () -> Void,
        nextTarget: @escaping () -> NSPoint?,
        directionToTarget: @escaping (NSPoint) -> ScratchSide = { _ in .right },
        showFrame: @escaping (Int) -> Bool = { _ in true },
        showTravel: @escaping (ScratchSide) -> Bool = { _ in true },
        showRunFallback: @escaping (ScratchSide) -> Void = { _ in },
        moveDash: @escaping (NSPoint, @escaping @MainActor () -> Void) -> Void,
        cancelMovement: @escaping () -> Void,
        showIdle: @escaping () -> Void,
        didFinish: @escaping () -> Void,
        randomUnit: @escaping () -> Double = { Double.random(in: 0..<1) },
        dashCountRandomUnit: @escaping () -> Double = { Double.random(in: 0..<1) },
        now: @escaping () -> Date = Date.init,
        temperament: @escaping () -> Temperament = { .normal },
        scheduler: ((TimeInterval, @escaping @MainActor () -> Void) -> Void)? = nil
    ) {
        self.hasRunCompanions = hasRunCompanions
        self.eligibility = eligibility
        self.willStart = willStart
        self.nextTarget = nextTarget
        self.directionToTarget = directionToTarget
        self.showFrame = showFrame
        self.showTravel = showTravel
        self.showRunFallback = showRunFallback
        self.moveDash = moveDash
        self.cancelMovement = cancelMovement
        self.showIdle = showIdle
        self.didFinish = didFinish
        self.randomUnit = randomUnit
        self.dashCountRandomUnit = dashCountRandomUnit
        self.now = now
        self.temperament = temperament
        self.scheduler = scheduler ?? { delay, action in
            Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
                Task { @MainActor in action() }
            }
        }
    }

    func resumeScheduling() {
        guard hasRunCompanions, !isPerforming, whimTimer == nil else { return }
        let settings = ZoomiesSchedule.whimSettings(for: temperament())
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
        if wasPerforming { cancelMovement() }
        if returnToIdle, wasPerforming { showIdle() }
    }

    @discardableResult
    func startIfEligible() -> Bool {
        guard !isPerforming, hasRunCompanions, eligibility().canStart else { return false }
        begin(recordsSpacing: true)
        return true
    }

    @discardableResult
    func forceStart() -> Bool {
        guard !isPerforming, hasRunCompanions else { return false }
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
        let settings = ZoomiesSchedule.whimSettings(for: temperament())
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
        sequenceID += 1
        let id = sequenceID
        let dashCount = ZoomiesSchedule.dashCount(randomUnit: dashCountRandomUnit())
        playFrames(
            ZoomiesChoreography.startFrames,
            durations: ZoomiesChoreography.startDurations,
            id: id
        ) { [weak self] in
            self?.runDash(
                remaining: dashCount,
                previousDirection: nil,
                id: id
            )
        }
    }

    private func runDash(remaining: Int, previousDirection: ScratchSide?, id: Int) {
        guard isCurrent(id) else { return }
        guard remaining > 0, let target = nextTarget() else {
            finish(id: id)
            return
        }
        let direction = directionToTarget(target)
        let beginMovement = { [weak self] in
            guard let self, self.isCurrent(id) else { return }
            if !self.showTravel(direction) { self.showRunFallback(direction) }
            self.moveDash(target) { [weak self] in
                guard let self, self.isCurrent(id) else { return }
                self.runDash(
                    remaining: remaining - 1,
                    previousDirection: direction,
                    id: id
                )
            }
        }
        guard let previousDirection, previousDirection != direction else {
            beginMovement()
            return
        }
        let turnFrames = ZoomiesChoreography.turnFrames(toward: direction)
        guard !turnFrames.isEmpty else {
            showRunFallback(direction)
            scheduler(ZoomiesChoreography.turnFallbackDuration, beginMovement)
            return
        }
        playFrames(
            turnFrames,
            durations: Array(repeating: ZoomiesChoreography.turnFrameDuration, count: turnFrames.count),
            id: id,
            completion: beginMovement
        )
    }

    private func finish(id: Int) {
        guard isCurrent(id) else { return }
        playFrames(
            ZoomiesChoreography.finishFrames,
            durations: ZoomiesChoreography.finishDurations,
            id: id
        ) { [weak self] in
            guard let self, self.isCurrent(id) else { return }
            self.showIdle()
            self.isPerforming = false
            if self.recordsSpacing { self.lastPerformedAt = self.now() }
            self.didFinish()
        }
    }

    private func playFrames(
        _ indices: [Int],
        durations: [TimeInterval],
        id: Int,
        completion: @escaping @MainActor () -> Void
    ) {
        guard indices.count == durations.count, !indices.isEmpty else {
            completion()
            return
        }
        func play(at offset: Int) {
            guard isCurrent(id), indices.indices.contains(offset) else { return }
            _ = showFrame(indices[offset])
            scheduler(durations[offset]) { [weak self] in
                guard let self, self.isCurrent(id) else { return }
                let next = offset + 1
                if indices.indices.contains(next) { play(at: next) }
                else { completion() }
            }
        }
        play(at: 0)
    }

    private func isCurrent(_ id: Int) -> Bool {
        isPerforming && sequenceID == id
    }
}
