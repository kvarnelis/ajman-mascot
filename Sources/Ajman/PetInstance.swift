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
    var hasSleepAnimation: Bool { loadedPet.sleepAnimation != nil }
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
                || animator.isPlayingCalmPose || scratchBehavior?.isPerforming == true,
            isAlreadyGlancing: isGlancing
        )
    }

    private let catalog: PetCatalog
    private let defaults: UserDefaults
    private let isManualMode: () -> Bool
    private let liveState = LiveStateBox()
    private var glanceTimer: Timer?
    private var scratchBehavior: ScratchBehavior?
    private(set) var isGlancing = false
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
        animator = Animator(sheet: loadedPet.sheet, view: view)
        scratchMover = ScratchPanelMover(panel: panel)
        petMode = PetMode(
            animator: animator,
            loafAnimation: loadedPet.loafAnimation,
            sleepAnimation: loadedPet.sleepAnimation,
            wakeAnimation: loadedPet.wakeAnimation,
            currentLiveState: { [liveState] in liveState.value },
            isManualMode: isManualMode,
            defaults: defaults
        )
        bubbleController = BubbleController(petPanel: panel)
        bubbleController.dismissHandler = dismissNotification
        panel.petWasClicked = petWasClicked
        animator.stateDidChange = { [weak self] state in
            guard state.isLively, let self, self.panel.isVisible else { return }
            livelyAnimationBegan(self.petID, self.screenCenter)
        }

        let scratchAnimation = loadedPet.scratchAnimation
        scratchBehavior = ScratchBehavior(
            animation: scratchAnimation,
            eligibility: { [weak self] in
                guard let self else {
                    return ScratchEligibility(
                        hasAsset: false, isShown: false, liveState: .idle,
                        displayedState: .idle, isManual: true, isPlayfulIdleEnabled: false,
                        isCalmPose: false, isGlancing: false
                    )
                }
                return ScratchEligibility(
                    hasAsset: scratchAnimation != nil,
                    isShown: self.panel.isVisible,
                    liveState: self.liveState.value,
                    displayedState: self.animator.currentState,
                    isManual: self.isManualMode(),
                    isPlayfulIdleEnabled: self.petMode.isEnabled,
                    isCalmPose: self.petMode.isLoafing || self.petMode.isSleeping
                        || self.petMode.isWaking || self.animator.isPlayingCalmPose,
                    isGlancing: self.isGlancing
                )
            },
            willStart: { [weak self] in
                self?.cancelGlance(returnToRest: false)
                self?.petMode.yieldToHigherPriorityDriver()
            },
            moveToEdge: { [weak self] side, completion in
                self?.moveToScratchEdge(side: side, completion: completion)
            },
            showPose: { [weak self] side in
                guard let self, let scratchAnimation else { return false }
                return self.animator.playHeldPose(scratchAnimation, frameIndex: side.poseIndex)
            },
            setRaking: { [weak self] enabled in self?.animator.setScratchRaking(enabled) },
            showIdle: { [weak self] in self?.animator.play(.idle) },
            didFinish: { [weak self] in
                guard let self, self.liveState.value == .idle, !self.isManualMode() else { return }
                self.petMode.resumeAtRest()
            },
            chooseSide: { [weak self] in self?.farScratchSide() }
        )
    }

    func show(useLegacyPositionFallback: Bool) {
        panel.restorePositionOrUseDefault(useLegacyFallback: useLegacyPositionFallback)
        panel.orderFrontRegardless()
        resumeLiveReactions()
        scratchBehavior?.resumeScheduling()
    }

    func applyState(_ state: AnimationState) {
        if state != .idle {
            cancelGlance(returnToRest: false)
            if !isManualMode() {
                scratchBehavior?.cancel(returnToIdle: false)
            }
        }
        liveState.value = state
        guard !isManualMode() else { return }
        // A rest wake-up owns the image for one brief held pose. The new live
        // state is retained above and PetMode hands off to it when the hold ends.
        guard !petMode.isWaking else { return }
        if state == .idle {
            guard !isGlancing, scratchBehavior?.isPerforming != true else { return }
            petMode.resumeAtRest()
            scratchBehavior?.resumeScheduling()
        } else {
            petMode.yieldToHigherPriorityDriver()
            animator.play(state)
        }
    }

    func resumeAtRest() {
        liveState.value = .idle
        guard !isManualMode() else { return }
        guard !isGlancing, scratchBehavior?.isPerforming != true else { return }
        petMode.resumeAtRest()
        scratchBehavior?.resumeScheduling()
    }

    func resumeLiveReactions() {
        cancelGlance(returnToRest: false)
        scratchBehavior?.cancel(returnToIdle: false)
        petMode.stir()
        applyState(liveState.value)
    }

    func wake() {
        cancelGlance(returnToRest: true)
        scratchBehavior?.cancel(returnToIdle: true)
        petMode.wake()
    }

    func handleAgentActivity() {
        cancelGlance(returnToRest: true)
        if !isManualMode() {
            scratchBehavior?.cancel(returnToIdle: true)
        }
        petMode.stir()
    }

    func handlePetSwitch() {
        cancelGlance(returnToRest: true)
        scratchBehavior?.cancel(returnToIdle: true)
        petMode.stir()
    }

    func apply(notificationChange: PetNotificationChange) {
        guard binding == nil || notificationChange.provider == binding else { return }
        bubbleController.apply(notificationChange)
    }

    func setBinding(_ binding: AgentEvent.Provider?) {
        guard self.binding != binding else { return }
        cancelGlance(returnToRest: true)
        scratchBehavior?.cancel(returnToIdle: true)
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

    func setSteadySize(_ enabled: Bool) throws {
        cancelGlance(returnToRest: true)
        scratchBehavior?.cancel(returnToIdle: true)
        let state = animator.currentState
        loadedPet = try catalog.load(id: petID, steadySize: enabled)
        petMode.replaceCalmAnimations(
            loaf: loadedPet.loafAnimation,
            sleep: loadedPet.sleepAnimation,
            wake: loadedPet.wakeAnimation
        )
        animator.replaceSheet(loadedPet.sheet, playing: state)
    }

    func setPlayfulIdle(_ enabled: Bool) {
        cancelGlance(returnToRest: true)
        scratchBehavior?.cancel(returnToIdle: true)
        petMode.setEnabled(enabled, defaults: defaults)
        if enabled { scratchBehavior?.resumeScheduling() }
    }

    func setDebugState(_ state: AnimationState) {
        guard animator.availableStates.contains(state) else { return }
        cancelGlance(returnToRest: false)
        scratchBehavior?.cancel(returnToIdle: false)
        petMode.yieldToHigherPriorityDriver()
        animator.play(state)
    }

    func setDebugSleep() {
        cancelGlance(returnToRest: false)
        scratchBehavior?.cancel(returnToIdle: false)
        _ = petMode.forceSleep()
    }

    func setDebugScratch() {
        cancelGlance(returnToRest: false)
        scratchBehavior?.cancel(returnToIdle: false)
        guard let side = farScratchSide() else { return }
        _ = scratchBehavior?.forceStart(side: side)
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
        scratchMover.cancel()
        panel.petWasClicked = nil
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

    private func moveToScratchEdge(
        side: ScratchSide,
        completion: @escaping @MainActor () -> Void
    ) {
        guard let screen = scratchScreen() else { return }

        animator.play(side.approachState)
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
}
