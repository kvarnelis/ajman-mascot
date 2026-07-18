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
    private let moveDash: (NSPoint, @escaping @MainActor () -> Void) -> Void
    private let cancelMovement: () -> Void
    private let showIdle: () -> Void
    private let didFinish: () -> Void
    private let randomUnit: () -> Double
    private let dashCountRandomUnit: () -> Double
    private let now: () -> Date
    private let temperament: () -> Temperament

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
        moveDash: @escaping (NSPoint, @escaping @MainActor () -> Void) -> Void,
        cancelMovement: @escaping () -> Void,
        showIdle: @escaping () -> Void,
        didFinish: @escaping () -> Void,
        randomUnit: @escaping () -> Double = { Double.random(in: 0..<1) },
        dashCountRandomUnit: @escaping () -> Double = { Double.random(in: 0..<1) },
        now: @escaping () -> Date = Date.init,
        temperament: @escaping () -> Temperament = { .normal }
    ) {
        self.hasRunCompanions = hasRunCompanions
        self.eligibility = eligibility
        self.willStart = willStart
        self.nextTarget = nextTarget
        self.moveDash = moveDash
        self.cancelMovement = cancelMovement
        self.showIdle = showIdle
        self.didFinish = didFinish
        self.randomUnit = randomUnit
        self.dashCountRandomUnit = dashCountRandomUnit
        self.now = now
        self.temperament = temperament
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
        runDash(
            remaining: ZoomiesSchedule.dashCount(randomUnit: dashCountRandomUnit()),
            id: sequenceID
        )
    }

    private func runDash(remaining: Int, id: Int) {
        guard isCurrent(id) else { return }
        guard remaining > 0, let target = nextTarget() else {
            finish(id: id)
            return
        }
        moveDash(target) { [weak self] in
            guard let self, self.isCurrent(id) else { return }
            self.runDash(remaining: remaining - 1, id: id)
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
