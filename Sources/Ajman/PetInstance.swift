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

    var availableStates: [AnimationState] { animator.availableStates }
    var positionPersistenceKey: String { panel.positionPersistenceKey }

    private let catalog: PetCatalog
    private let defaults: UserDefaults
    private let isManualMode: () -> Bool
    private let liveState = LiveStateBox()
    private var tornDown = false

    init(
        petID: String,
        binding: AgentEvent.Provider?,
        catalog: PetCatalog,
        scale: PetScale,
        defaultPositionIndex: Int,
        defaults: UserDefaults = .standard,
        isManualMode: @escaping () -> Bool,
        dismissNotification: @escaping (String) -> Void
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
        petMode = PetMode(
            animator: animator,
            currentLiveState: { [liveState] in liveState.value },
            isManualMode: isManualMode,
            defaults: defaults
        )
        bubbleController = BubbleController(petPanel: panel)
        bubbleController.dismissHandler = dismissNotification
        panel.petWasClicked = { [weak petMode] in petMode?.wake() }
    }

    func show(useLegacyPositionFallback: Bool) {
        panel.restorePositionOrUseDefault(useLegacyFallback: useLegacyPositionFallback)
        panel.orderFrontRegardless()
        resumeLiveReactions()
    }

    func applyState(_ state: AnimationState) {
        liveState.value = state
        guard !isManualMode() else { return }
        if state == .idle {
            petMode.resumeAtRest()
        } else {
            petMode.yieldToHigherPriorityDriver()
            animator.play(state)
        }
    }

    func resumeAtRest() {
        liveState.value = .idle
        guard !isManualMode() else { return }
        petMode.resumeAtRest()
    }

    func resumeLiveReactions() {
        applyState(liveState.value)
    }

    func wake() {
        petMode.wake()
    }

    func apply(notificationChange: PetNotificationChange) {
        guard binding == nil || notificationChange.provider == binding else { return }
        bubbleController.apply(notificationChange)
    }

    func setBinding(_ binding: AgentEvent.Provider?) {
        guard self.binding != binding else { return }
        self.binding = binding
        bubbleController.removeAll()
    }

    func setScale(_ scale: PetScale) {
        panel.apply(scale: scale)
    }

    func setSteadySize(_ enabled: Bool) throws {
        let state = animator.currentState
        loadedPet = try catalog.load(id: petID, steadySize: enabled)
        animator.replaceSheet(loadedPet.sheet, playing: state)
    }

    func setPlayfulIdle(_ enabled: Bool) {
        petMode.setEnabled(enabled, defaults: defaults)
    }

    func setDebugState(_ state: AnimationState) {
        guard animator.availableStates.contains(state) else { return }
        petMode.yieldToHigherPriorityDriver()
        animator.play(state)
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
        panel.petWasClicked = nil
        bubbleController.dismissHandler = nil
        petMode.teardown()
        animator.stop()
        bubbleController.teardown()
        panel.teardown()
    }

    deinit {
        animator.stop()
    }
}
