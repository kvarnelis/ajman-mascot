import AppKit

/// One independently animated, positioned, and notified desktop pet.
@MainActor
final class PetInstance {
    private final class LiveStateBox {
        var value: AnimationState = .idle
    }

    let petID: String
    private(set) var binding: AgentEvent.Provider?
    private(set) var loadedPet: LoadedPet
    let panel: OverlayPanel
    let animator: Animator
    let petMode: PetMode
    let bubbleController: BubbleController
    private let scratchMover: ScratchPanelMover

    var availableStates: [AnimationState] { animator.availableStates }
    private(set) var temperament: Temperament
    var hasLoafAnimation: Bool { loadedPet.loafAnimation != nil }
    var hasSleepAnimation: Bool { loadedPet.sleepAnimation != nil }
    var hasStretchAnimation: Bool { loadedPet.wakeAnimation != nil }
    var hasScratchAnimation: Bool { loadedPet.scratchAnimation != nil }
    var hasGroomAnimation: Bool { loadedPet.groomAnimation != nil }
    var hasScreamAnimation: Bool { loadedPet.screamAnimation != nil }
    var hasTravelGait: Bool { loadedPet.runLeftAnimation != nil && loadedPet.runRightAnimation != nil }
    var hasZoomies: Bool { hasTravelGait }
    var availableDirectActions: [PetCycleAction] {
        PetActionCycle.availableActions(
            availableStates: animator.availableStates,
            hasLoaf: hasLoafAnimation,
            hasSleep: hasSleepAnimation,
            hasStretch: hasStretchAnimation,
            hasScratch: hasScratchAnimation,
            hasGroom: hasGroomAnimation,
            hasScream: hasScreamAnimation,
            hasZoomies: hasZoomies
        )
    }
    var positionPersistenceKey: String { panel.positionPersistenceKey }
    var screenCenter: NSPoint { NSPoint(x: panel.frame.midX, y: panel.frame.midY) }
    var glanceEligibility: InterCatGlanceEligibility {
        let available = Set(animator.availableStates)
        return InterCatGlanceEligibility(
            isShown: panel.isVisible,
            supportsLookDirections: available.contains(.lookDirectionsA) && available.contains(.lookDirectionsB),
            liveState: liveState.value,
            displayedState: animator.currentState,
            isManual: isManualMode(),
            isSleeping: petMode.isLoafing || petMode.isSleeping || petMode.isWaking
                || animator.isPlayingCalmPose || scratchBehavior?.isPerforming == true
                || groomingBehavior?.isPerforming == true || screamingBehavior?.isPerforming == true
                || zoomiesBehavior?.isPerforming == true,
            isAlreadyGlancing: isGlancing
        )
    }

    private let catalog: PetCatalog
    private let defaults: UserDefaults
    private let isManualMode: () -> Bool
    private let liveState = LiveStateBox()
    private var glanceTimer: Timer?
    private var scratchBehavior: ScratchBehavior?
    private var groomingBehavior: HeldSequenceBehavior?
    private var screamingBehavior: HeldSequenceBehavior?
    private var zoomiesBehavior: ZoomiesBehavior?
    private var scratchStartingOrigin: NSPoint?
    private(set) var isGlancing = false
    private var isDirectCycling = false
    private var actionCycleCursor = PetActionCycle.Cursor()
    private var pendingManualActionCompletion: (PetCycleAction, @MainActor () -> Void)?
    private var tornDown = false

    init(
        petID: String,
        binding: AgentEvent.Provider?,
        catalog: PetCatalog,
        scale: PetScale,
        defaultPositionIndex: Int,
        defaults: UserDefaults = .standard,
        isManualMode: @escaping () -> Bool,
        petWasClicked: @escaping () -> Void,
        dismissNotification: @escaping (String) -> Void,
        livelyAnimationBegan: @escaping (String, NSPoint) -> Void
    ) throws {
        self.petID = petID
        self.binding = binding
        self.catalog = catalog
        self.defaults = defaults
        self.isManualMode = isManualMode
        temperament = Temperament.load(for: petID, from: defaults)
        loadedPet = try catalog.load(id: petID)

        let relativeScale = catalog.relativeScale(for: petID)
        let initialSize = NSSize(
            width: CGFloat(SpriteSheet.cellWidth) * CGFloat(scale.rawValue) * CGFloat(relativeScale),
            height: CGFloat(SpriteSheet.cellHeight) * CGFloat(scale.rawValue) * CGFloat(relativeScale)
        )
        let view = PetView(frame: NSRect(origin: .zero, size: initialSize))
        panel = OverlayPanel(
            contentView: view,
            scale: scale,
            relativeScale: relativeScale,
            petID: petID,
            defaultPositionIndex: defaultPositionIndex,
            defaults: defaults
        )
        animator = Animator(sheet: loadedPet.sheet, view: view, temperament: temperament)
        scratchMover = ScratchPanelMover(panel: panel)
        petMode = PetMode(
            animator: animator,
            loafAnimation: loadedPet.loafAnimation,
            sleepAnimation: loadedPet.sleepAnimation,
            wakeAnimation: loadedPet.wakeAnimation,
            currentLiveState: { [liveState] in liveState.value },
            isManualMode: isManualMode,
            temperament: temperament
        )
        bubbleController = BubbleController(petPanel: panel)
        bubbleController.dismissHandler = dismissNotification
        panel.petWasClicked = petWasClicked
        panel.petActionCycleRequested = { [weak self] in self?.cycleToNextAction() }
        animator.stateDidChange = { [weak self] state in
            guard state.isLively, let self, self.panel.isVisible, !self.isDirectCycling else { return }
            livelyAnimationBegan(self.petID, self.screenCenter)
        }

        let scratchAnimation = loadedPet.scratchAnimation
        scratchBehavior = ScratchBehavior(
            animation: scratchAnimation,
            eligibility: { [weak self] in
                guard let self else {
                    return ScratchEligibility(
                        hasAsset: false, isShown: false, liveState: .idle,
                        displayedState: .idle, isManual: true,
                        isCalmPose: false, isGlancing: false
                    )
                }
                return ScratchEligibility(
                    hasAsset: scratchAnimation != nil,
                    isShown: self.panel.isVisible,
                    liveState: self.liveState.value,
                    displayedState: self.animator.currentState,
                    isManual: self.isManualMode(),
                    isCalmPose: self.petMode.isLoafing || self.petMode.isSleeping
                        || self.petMode.isWaking || self.animator.isPlayingCalmPose
                        || self.groomingBehavior?.isPerforming == true
                        || self.screamingBehavior?.isPerforming == true
                        || self.zoomiesBehavior?.isPerforming == true,
                    isGlancing: self.isGlancing
                )
            },
            willStart: { [weak self] in
                self?.scratchStartingOrigin = self?.panel.frame.origin
                self?.cancelGlance(returnToRest: false)
                self?.petMode.yieldToHigherPriorityDriver()
            },
            moveToEdge: { [weak self] side, completion in
                self?.moveToScratchEdge(side: side, completion: completion)
            },
            moveBackToStart: { [weak self] completion in
                self?.moveBackToScratchStart(completion: completion)
            },
            showPose: { [weak self] side in
                guard let self, let scratchAnimation else { return false }
                return self.animator.playHeldPose(scratchAnimation, frameIndex: side.poseIndex)
            },
            setRaking: { [weak self] enabled, amplitude in
                self?.animator.setScratchRaking(enabled, amplitude: amplitude)
            },
            showIdle: { [weak self] in self?.animator.play(.idle) },
            didFinish: { [weak self] in
                guard let self else { return }
                self.scratchStartingOrigin = nil
                self.finishManualActionIfNeeded(.scratch)
                guard self.liveState.value == .idle, !self.isManualMode() else { return }
                self.petMode.resumeAtRest()
                self.groomingBehavior?.resumeScheduling()
                self.screamingBehavior?.resumeScheduling()
                self.zoomiesBehavior?.resumeScheduling()
            },
            chooseSide: { [weak self] in self?.autonomousScratchSide() },
            temperament: { [weak self] in self?.temperament ?? .normal }
        )

        let groomAnimation = loadedPet.groomAnimation
        groomingBehavior = HeldSequenceBehavior(
            animation: groomAnimation,
            frameDurations: GroomingSequence.frameDurations,
            scheduleRange: GroomingSequence.scheduleRange,
            triggerProbability: GroomingSequence.triggerProbability,
            minimumSpacing: GroomingSequence.minimumSpacing,
            eligibility: { [weak self] in
                guard let self else {
                    return HeldSequenceEligibility(
                        hasAsset: false, isShown: false, liveState: .idle,
                        displayedState: .idle, isManual: true,
                        isCalmPose: false, isGlancing: false
                    )
                }
                return HeldSequenceEligibility(
                    hasAsset: groomAnimation != nil,
                    isShown: self.panel.isVisible,
                    liveState: self.liveState.value,
                    displayedState: self.animator.currentState,
                    isManual: self.isManualMode(),
                    isCalmPose: self.petMode.isLoafing || self.petMode.isSleeping
                        || self.petMode.isWaking || self.animator.isPlayingCalmPose
                        || self.scratchBehavior?.isPerforming == true
                        || self.screamingBehavior?.isPerforming == true
                        || self.zoomiesBehavior?.isPerforming == true,
                    isGlancing: self.isGlancing
                )
            },
            willStart: { [weak self] in
                self?.scratchBehavior?.cancel(returnToIdle: false)
                self?.zoomiesBehavior?.cancel(returnToIdle: false)
                self?.cancelGlance(returnToRest: false)
                self?.petMode.yieldToHigherPriorityDriver()
            },
            showFrame: { [weak self] index in
                guard let self, let groomAnimation else { return false }
                return self.animator.playHeldPose(groomAnimation, frameIndex: index)
            },
            showIdle: { [weak self] in self?.animator.play(.idle) },
            didFinish: { [weak self] in
                guard let self else { return }
                self.finishManualActionIfNeeded(.groom)
                guard self.liveState.value == .idle, !self.isManualMode() else { return }
                self.petMode.resumeAtRest()
                self.scratchBehavior?.resumeScheduling()
                self.groomingBehavior?.resumeScheduling()
                self.screamingBehavior?.resumeScheduling()
                self.zoomiesBehavior?.resumeScheduling()
            },
            temperament: { [weak self] in self?.temperament ?? .normal }
        )

        let screamAnimation = loadedPet.screamAnimation
        screamingBehavior = HeldSequenceBehavior(
            animation: screamAnimation,
            frameDurations: ScreamSequence.frameDurations,
            scheduleRange: 0...0,
            triggerProbability: 0,
            minimumSpacing: 0,
            frameSequences: ScreamSequence.variants,
            eligibility: { [weak self] in
                guard let self else {
                    return HeldSequenceEligibility(
                        hasAsset: false, isShown: false, liveState: .idle,
                        displayedState: .idle, isManual: true,
                        isCalmPose: false, isGlancing: false
                    )
                }
                return HeldSequenceEligibility(
                    hasAsset: screamAnimation != nil,
                    isShown: self.panel.isVisible,
                    liveState: self.liveState.value,
                    displayedState: self.animator.currentState,
                    isManual: self.isManualMode(),
                    isCalmPose: self.petMode.isLoafing || self.petMode.isSleeping
                        || self.petMode.isWaking || self.animator.isPlayingCalmPose
                        || self.scratchBehavior?.isPerforming == true
                        || self.groomingBehavior?.isPerforming == true
                        || self.zoomiesBehavior?.isPerforming == true,
                    isGlancing: self.isGlancing
                )
            },
            willStart: { [weak self] in
                self?.scratchBehavior?.cancel(returnToIdle: false)
                self?.groomingBehavior?.cancel(returnToIdle: false)
                self?.zoomiesBehavior?.cancel(returnToIdle: false)
                self?.cancelGlance(returnToRest: false)
                self?.petMode.yieldToHigherPriorityDriver()
            },
            showFrame: { [weak self] index in
                guard let self, let screamAnimation else { return false }
                return self.animator.playHeldPose(screamAnimation, frameIndex: index)
            },
            showIdle: { [weak self] in self?.animator.play(.idle) },
            didFinish: { [weak self] in
                guard let self else { return }
                self.finishManualActionIfNeeded(.scream)
                guard self.liveState.value == .idle, !self.isManualMode() else { return }
                self.petMode.resumeAtRest()
                self.scratchBehavior?.resumeScheduling()
                self.groomingBehavior?.resumeScheduling()
                self.screamingBehavior?.resumeScheduling()
                self.zoomiesBehavior?.resumeScheduling()
            },
            temperament: { [weak self] in self?.temperament ?? .normal },
            whimSettings: ScreamSequence.whimSettings
        )

        zoomiesBehavior = ZoomiesBehavior(
            hasRunCompanions: hasTravelGait,
            eligibility: { [weak self] in
                guard let self else {
                    return ZoomiesEligibility(
                        hasRunCompanions: false, isShown: false, liveState: .idle,
                        displayedState: .idle, isManual: true,
                        isCalmPose: false, isGlancing: false
                    )
                }
                return ZoomiesEligibility(
                    hasRunCompanions: self.hasTravelGait,
                    isShown: self.panel.isVisible,
                    liveState: self.liveState.value,
                    displayedState: self.animator.currentState,
                    isManual: self.isManualMode(),
                    isCalmPose: self.petMode.isLoafing || self.petMode.isSleeping
                        || self.petMode.isWaking || self.animator.isPlayingCalmPose
                        || self.scratchBehavior?.isPerforming == true
                        || self.groomingBehavior?.isPerforming == true
                        || self.screamingBehavior?.isPerforming == true,
                    isGlancing: self.isGlancing
                )
            },
            willStart: { [weak self] in
                self?.scratchBehavior?.cancel(returnToIdle: false)
                self?.groomingBehavior?.cancel(returnToIdle: false)
                self?.screamingBehavior?.cancel(returnToIdle: false)
                self?.cancelGlance(returnToRest: false)
                self?.petMode.yieldToHigherPriorityDriver()
            },
            nextTarget: { [weak self] in self?.nextZoomiesTarget() },
            moveDash: { [weak self] target, completion in
                self?.moveZoomiesDash(to: target, completion: completion)
            },
            cancelMovement: { [weak self] in self?.scratchMover.cancel() },
            showIdle: { [weak self] in self?.animator.play(.idle) },
            didFinish: { [weak self] in
                guard let self else { return }
                self.finishManualActionIfNeeded(.zoomies)
                guard self.liveState.value == .idle, !self.isManualMode() else { return }
                self.petMode.resumeAtRest()
                self.resumeWhimScheduling()
            },
            temperament: { [weak self] in self?.temperament ?? .normal }
        )
    }

    func show(useLegacyPositionFallback: Bool) {
        panel.restorePositionOrUseDefault(useLegacyFallback: useLegacyPositionFallback)
        panel.orderFrontRegardless()
        panel.ensureVisible()
        DispatchQueue.main.async { [weak panel] in panel?.ensureVisible() }
        resumeLiveReactions()
        scratchBehavior?.resumeScheduling()
        groomingBehavior?.resumeScheduling()
        screamingBehavior?.resumeScheduling()
        zoomiesBehavior?.resumeScheduling()
    }

    func applyState(_ state: AnimationState) {
        if state != .idle {
            cancelGlance(returnToRest: false)
            if !isManualMode() {
                scratchBehavior?.cancel(returnToIdle: false)
                groomingBehavior?.cancel(returnToIdle: false)
                screamingBehavior?.cancel(returnToIdle: false)
                zoomiesBehavior?.cancel(returnToIdle: false)
            }
        }
        liveState.value = state
        guard !isManualMode() else { return }
        // A rest wake-up owns the image for one brief held pose. The new live
        // state is retained above and PetMode hands off to it when the hold ends.
        guard !petMode.isWaking else { return }
        if state == .idle {
            guard !isGlancing, scratchBehavior?.isPerforming != true,
                  groomingBehavior?.isPerforming != true,
                  screamingBehavior?.isPerforming != true,
                  zoomiesBehavior?.isPerforming != true else { return }
            petMode.resumeAtRest()
            scratchBehavior?.resumeScheduling()
            groomingBehavior?.resumeScheduling()
            screamingBehavior?.resumeScheduling()
            zoomiesBehavior?.resumeScheduling()
        } else {
            petMode.yieldToHigherPriorityDriver()
            animator.play(state)
        }
    }

    func resumeAtRest() {
        liveState.value = .idle
        guard !isManualMode() else { return }
        guard !isGlancing, scratchBehavior?.isPerforming != true,
              groomingBehavior?.isPerforming != true,
              screamingBehavior?.isPerforming != true,
              zoomiesBehavior?.isPerforming != true else { return }
        petMode.resumeAtRest()
        scratchBehavior?.resumeScheduling()
        groomingBehavior?.resumeScheduling()
        screamingBehavior?.resumeScheduling()
        zoomiesBehavior?.resumeScheduling()
    }

    func resumeLiveReactions(currentState: AnimationState? = nil) {
        let wasResting = petMode.isLoafing || petMode.isSleeping
        cancelGlance(returnToRest: false)
        scratchBehavior?.cancel(returnToIdle: false)
        groomingBehavior?.cancel(returnToIdle: false)
        screamingBehavior?.cancel(returnToIdle: false)
        zoomiesBehavior?.cancel(returnToIdle: false)
        if wasResting {
            // Hand ownership back without replaying agent state that accumulated
            // while manual mode was deliberately holding Loaf or Sleep.
            liveState.value = .idle
            return
        }
        if let currentState { liveState.value = currentState }
        petMode.stir()
        applyState(liveState.value)
    }

    func wake() {
        cancelGlance(returnToRest: true)
        scratchBehavior?.cancel(returnToIdle: true)
        groomingBehavior?.cancel(returnToIdle: true)
        screamingBehavior?.cancel(returnToIdle: true)
        zoomiesBehavior?.cancel(returnToIdle: true)
        petMode.wake()
    }

    func handleAgentActivity() {
        guard !isManualMode() else { return }
        cancelGlance(returnToRest: true)
        scratchBehavior?.cancel(returnToIdle: true)
        groomingBehavior?.cancel(returnToIdle: true)
        screamingBehavior?.cancel(returnToIdle: true)
        zoomiesBehavior?.cancel(returnToIdle: true)
        petMode.stir()
    }

    func handlePetSwitch() {
        cancelGlance(returnToRest: true)
        scratchBehavior?.cancel(returnToIdle: true)
        groomingBehavior?.cancel(returnToIdle: true)
        screamingBehavior?.cancel(returnToIdle: true)
        zoomiesBehavior?.cancel(returnToIdle: true)
        petMode.stir()
    }

    func apply(notificationChange: PetNotificationChange) {
        guard binding == nil || notificationChange.provider == binding else { return }
        bubbleController.apply(notificationChange)
    }

    func removeNotifications() {
        bubbleController.removeAll()
    }

    func setBinding(_ binding: AgentEvent.Provider?) {
        guard self.binding != binding else { return }
        cancelGlance(returnToRest: true)
        scratchBehavior?.cancel(returnToIdle: true)
        groomingBehavior?.cancel(returnToIdle: true)
        screamingBehavior?.cancel(returnToIdle: true)
        zoomiesBehavior?.cancel(returnToIdle: true)
        self.binding = binding
        bubbleController.removeAll()
        petMode.stir()
    }

    func setScale(_ scale: PetScale) {
        panel.apply(scale: scale)
    }

    func setRelativeScale(_ scale: Double) {
        panel.apply(relativeScale: scale)
    }

    func setTemperament(_ temperament: Temperament) {
        guard self.temperament != temperament else { return }
        self.temperament = temperament
        temperament.save(for: petID, to: defaults)
        animator.setTemperament(temperament)
        petMode.setTemperament(temperament)
        scratchBehavior?.rescheduleForTemperamentChange()
        groomingBehavior?.rescheduleForTemperamentChange()
        screamingBehavior?.rescheduleForTemperamentChange()
        zoomiesBehavior?.rescheduleForTemperamentChange()
    }

    func cycleToNextAction() {
        guard let next = actionCycleCursor.next(
            availableActions: availableDirectActions,
            startingAfter: .animation(animator.currentState)
        ) else { return }
        performDirectAction(next)
    }

    func performDirectAction(
        _ action: PetCycleAction,
        actionDidSettle: (@MainActor () -> Void)? = nil
    ) {
        guard availableDirectActions.contains(action) else { return }
        cancelGlance(returnToRest: false)
        scratchBehavior?.cancel(returnToIdle: false)
        groomingBehavior?.cancel(returnToIdle: false)
        screamingBehavior?.cancel(returnToIdle: false)
        zoomiesBehavior?.cancel(returnToIdle: false)
        pendingManualActionCompletion = nil
        switch action {
        case let .animation(state):
            petMode.yieldToHigherPriorityDriver()
            isDirectCycling = true
            animator.play(state)
            isDirectCycling = false
            actionDidSettle?()
        case .loaf:
            _ = petMode.forceLoaf()
            actionDidSettle?()
        case .sleep:
            _ = petMode.forceSleep()
            actionDidSettle?()
        case .stretch:
            guard petMode.forceStretch(completion: actionDidSettle) else {
                actionDidSettle?()
                return
            }
        case .scratch:
            pendingManualActionCompletion = actionDidSettle.map { (.scratch, $0) }
            guard let side = farScratchSide() else {
                finishManualActionIfNeeded(.scratch)
                return
            }
            if scratchBehavior?.forceStart(side: side) != true { finishManualActionIfNeeded(.scratch) }
        case .groom:
            pendingManualActionCompletion = actionDidSettle.map { (.groom, $0) }
            if groomingBehavior?.forceStart() != true { finishManualActionIfNeeded(.groom) }
        case .scream:
            pendingManualActionCompletion = actionDidSettle.map { (.scream, $0) }
            if screamingBehavior?.forceStart() != true { finishManualActionIfNeeded(.scream) }
        case .zoomies:
            pendingManualActionCompletion = actionDidSettle.map { (.zoomies, $0) }
            if zoomiesBehavior?.forceStart() != true { finishManualActionIfNeeded(.zoomies) }
        }
    }

    private func finishManualActionIfNeeded(_ action: PetCycleAction) {
        guard let pending = pendingManualActionCompletion, pending.0 == action else { return }
        pendingManualActionCompletion = nil
        pending.1()
    }

    func setDebugState(_ state: AnimationState) {
        guard animator.availableStates.contains(state) else { return }
        cancelGlance(returnToRest: false)
        scratchBehavior?.cancel(returnToIdle: false)
        groomingBehavior?.cancel(returnToIdle: false)
        screamingBehavior?.cancel(returnToIdle: false)
        zoomiesBehavior?.cancel(returnToIdle: false)
        petMode.yieldToHigherPriorityDriver()
        animator.play(state)
    }

    @discardableResult
    func glanceToward(screenPoint: NSPoint) -> Bool {
        guard glanceEligibility.canReact,
              let direction = LookDirection.toward(source: screenCenter, target: screenPoint) else {
            return false
        }

        petMode.yieldToHigherPriorityDriver()
        isGlancing = true
        guard animator.playSingleFrame(direction.state, frameIndex: direction.frameIndex) else {
            isGlancing = false
            petMode.resumeAtRest()
            return false
        }

        let hold = TimeInterval.random(in: 1.2...1.8)
        glanceTimer = Timer.scheduledTimer(withTimeInterval: hold, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finishGlance() }
        }
        return true
    }

    func resetPosition() {
        panel.resetPosition()
    }

    func setDefaultPositionIndex(_ index: Int) {
        panel.setDefaultPositionIndex(index)
    }

    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        cancelGlance(returnToRest: false)
        scratchBehavior?.teardown()
        groomingBehavior?.teardown()
        screamingBehavior?.teardown()
        zoomiesBehavior?.teardown()
        scratchMover.cancel()
        panel.petWasClicked = nil
        panel.petActionCycleRequested = nil
        animator.stateDidChange = nil
        bubbleController.dismissHandler = nil
        petMode.teardown()
        animator.stop()
        bubbleController.teardown()
        panel.teardown()
    }

    deinit {
        glanceTimer?.invalidate()
        animator.stop()
    }

    private func finishGlance() {
        guard isGlancing else { return }
        glanceTimer?.invalidate()
        glanceTimer = nil
        isGlancing = false
        guard liveState.value == .idle, !isManualMode() else { return }
        petMode.resumeAtRest()
    }

    private func cancelGlance(returnToRest: Bool) {
        guard isGlancing else { return }
        glanceTimer?.invalidate()
        glanceTimer = nil
        isGlancing = false
        if returnToRest, liveState.value == .idle, !isManualMode() {
            petMode.resumeAtRest()
        }
    }

    private func resumeWhimScheduling() {
        scratchBehavior?.resumeScheduling()
        groomingBehavior?.resumeScheduling()
        screamingBehavior?.resumeScheduling()
        zoomiesBehavior?.resumeScheduling()
    }

    private func nextZoomiesTarget() -> NSPoint? {
        guard let screen = scratchScreen() else { return nil }
        let visible = screen.visibleFrame
        let liveFrame = panel.frame
        guard let targetX = ZoomiesGeometry.targetOriginX(
            currentOriginX: liveFrame.minX,
            visibleMinX: visible.minX,
            visibleMaxX: visible.maxX,
            panelWidth: liveFrame.width,
            randomUnit: Double.random(in: 0..<1)
        ) else { return nil }
        return NSPoint(
            x: targetX,
            y: min(max(liveFrame.minY, visible.minY), visible.maxY - liveFrame.height)
        )
    }

    private func moveZoomiesDash(
        to target: NSPoint,
        completion: @escaping @MainActor () -> Void
    ) {
        let current = panel.frame.origin
        let side: ScratchSide = target.x < current.x ? .left : .right
        playTravelGait(side: side, frameDuration: 0.055)
        let distance = hypot(target.x - current.x, target.y - current.y)
        let duration = max(TimeInterval(distance / ZoomiesSchedule.velocity), 0.12)
        scratchMover.move(
            to: target,
            duration: duration,
            shouldContinue: { [weak self] in self?.zoomiesBehavior?.isPerforming == true },
            completion: completion
        )
    }

    private func moveToScratchEdge(
        side: ScratchSide,
        completion: @escaping @MainActor () -> Void
    ) {
        guard let screen = scratchScreen() else { return }

        playTravelGait(side: side)
        let visible = screen.visibleFrame
        let scale = panel.frame.width / CGFloat(SpriteSheet.cellWidth)
        let edgeX = ScratchEdgeGeometry.targetOriginX(
            side: side, visibleMinX: visible.minX, visibleMaxX: visible.maxX, scale: scale
        )
        let target = NSPoint(
            x: edgeX,
            y: min(max(panel.frame.minY, visible.minY), visible.maxY - panel.frame.height)
        )
        let distance = hypot(target.x - panel.frame.minX, target.y - panel.frame.minY)
        let duration = min(max(TimeInterval(distance / 110), 0.8), 4.0)

        scratchMover.move(
            to: target,
            duration: duration,
            shouldContinue: { [weak self] in self?.scratchBehavior?.isPerforming == true },
            completion: completion
        )
    }

    private func farScratchSide() -> ScratchSide? {
        guard let screen = scratchScreen() else { return nil }
        let visible = screen.visibleFrame
        let scale = panel.frame.width / CGFloat(SpriteSheet.cellWidth)
        return ScratchEdgeGeometry.farSide(
            currentOriginX: panel.frame.minX,
            visibleMinX: visible.minX,
            visibleMaxX: visible.maxX,
            scale: scale
        )
    }

    private func autonomousScratchSide() -> ScratchSide? {
        guard let screen = scratchScreen() else { return nil }
        let visible = screen.visibleFrame
        let liveFrame = panel.frame
        let scale = liveFrame.width / CGFloat(SpriteSheet.cellWidth)
        return ScratchEdgeGeometry.autonomousSide(
            currentOriginX: liveFrame.minX,
            visibleMinX: visible.minX,
            visibleMaxX: visible.maxX,
            scale: scale,
            randomUnit: Double.random(in: 0..<1)
        )
    }

    private func moveBackToScratchStart(completion: @escaping @MainActor () -> Void) {
        guard let target = scratchStartingOrigin else {
            completion()
            return
        }

        let current = panel.frame.origin
        let travelState = ScratchEdgeGeometry.travelState(fromOriginX: current.x, toOriginX: target.x)
        playTravelGait(side: travelState == .runningLeft ? .left : .right)
        let distance = hypot(target.x - current.x, target.y - current.y)
        let duration = min(max(TimeInterval(distance / 110), 0.8), 4.0)
        scratchMover.move(
            to: target,
            duration: duration,
            shouldContinue: { [weak self] in self?.scratchBehavior?.isPerforming == true },
            completion: completion
        )
    }

    private func scratchScreen() -> NSScreen? {
        if let screen = panel.screen { return screen }
        if let containing = NSScreen.screens.first(where: { $0.frame.contains(screenCenter) }) {
            return containing
        }
        return NSScreen.screens.max { left, right in
            left.visibleFrame.intersection(panel.frame).width * left.visibleFrame.intersection(panel.frame).height
                < right.visibleFrame.intersection(panel.frame).width * right.visibleFrame.intersection(panel.frame).height
        }
    }

    private func playTravelGait(side: ScratchSide, frameDuration: TimeInterval = 0.09) {
        if let animation = loadedPet.travelAnimation(for: side) {
            animator.playLoop(animation, as: side.approachState, frameDuration: frameDuration)
        } else {
            animator.play(side.approachState)
        }
    }
}
