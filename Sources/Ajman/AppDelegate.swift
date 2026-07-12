import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: OverlayPanel?
    private var animator: Animator?
    private var statusMenu: StatusMenu?
    private var petMode: PetMode?
    private var registry: SessionRegistry?
    private var server: UDSServer?
    private var codexMonitor: CodexMonitor?
    private var bubbleController: BubbleController?
    private var catalog: PetCatalog?
    private var activePetID = PetCatalog.defaultPetID

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let catalog = PetCatalog()
            let loadedPet = try catalog.loadSelected()
            let sheet = loadedPet.sheet
            let scale = PetScale.load()
            let relativeScale = catalog.relativeScale(for: loadedPet.descriptor.id)
            let initialSize = NSSize(
                width: CGFloat(SpriteSheet.cellWidth) * CGFloat(scale.rawValue) * CGFloat(relativeScale),
                height: CGFloat(SpriteSheet.cellHeight) * CGFloat(scale.rawValue) * CGFloat(relativeScale)
            )
            let view = PetView(frame: NSRect(origin: .zero, size: initialSize))
            let panel = OverlayPanel(contentView: view, scale: scale, relativeScale: relativeScale)
            let animator = Animator(sheet: sheet, view: view)
            let registry = SessionRegistry()
            let bubbleController = BubbleController(petPanel: panel)
            let server = UDSServer()
            let codexMonitor = CodexMonitor()
            var statusMenu: StatusMenu!
            let petMode = PetMode(
                animator: animator,
                currentLiveState: { [weak registry] in registry?.currentState ?? .idle },
                isManualMode: { [weak statusMenu] in statusMenu?.manualMode ?? false }
            )
            statusMenu = StatusMenu(
                animator: animator,
                panel: panel,
                registry: registry,
                petMode: petMode,
                pets: catalog.discover(),
                activePetID: loadedPet.descriptor.id
            )
            statusMenu.petSelectionHandler = { [weak self] id in self?.switchPet(to: id) }
            registry.didChange = { [weak animator, weak statusMenu, weak petMode] state, count in
                statusMenu?.updateActivity(state: state, sessionCount: count)
                guard statusMenu?.manualMode != true else { return }
                if state == .idle {
                    petMode?.resumeAtRest()
                } else {
                    petMode?.yieldToHigherPriorityDriver()
                    animator?.play(state)
                }
            }
            registry.notificationDidChange = { [weak bubbleController] change in
                bubbleController?.apply(change)
            }
            bubbleController.dismissHandler = { [weak registry] id in
                registry?.dismissNotification(id: id)
            }
            server.eventHandler = { event in
                Task { @MainActor in registry.apply(event) }
            }
            try server.start()
            codexMonitor.eventHandler = { event in
                Task { @MainActor in registry.apply(event) }
            }
            codexMonitor.start()

            self.panel = panel
            self.animator = animator
            self.statusMenu = statusMenu
            self.petMode = petMode
            self.registry = registry
            self.server = server
            self.codexMonitor = codexMonitor
            self.bubbleController = bubbleController
            self.catalog = catalog
            activePetID = loadedPet.descriptor.id
            catalog.saveSelection(activePetID)

            panel.restorePositionOrUseDefault()
            panel.orderFrontRegardless()
            petMode.resumeAtRest()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Ajman could not load a pet spritesheet."
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.runModal()
            NSApplication.shared.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        codexMonitor?.stop()
        server?.stop()
    }

    private func switchPet(to id: String) {
        guard id != activePetID, let catalog, let animator, let panel, let statusMenu, let petMode, let registry else { return }
        do {
            let loadedPet = try catalog.load(id: id)
            let previousState = animator.currentState
            petMode.yieldToHigherPriorityDriver()
            animator.replaceSheet(loadedPet.sheet, playing: previousState)
            panel.apply(relativeScale: catalog.relativeScale(for: loadedPet.descriptor.id))
            activePetID = loadedPet.descriptor.id
            catalog.saveSelection(activePetID)
            statusMenu.refreshForPet(pets: catalog.discover(), activePetID: activePetID)

            if statusMenu.manualMode {
                animator.play(animator.availableStates.contains(previousState) ? previousState : .idle)
            } else if registry.currentState == .idle {
                petMode.resumeAtRest()
            } else {
                animator.play(registry.currentState)
            }
        } catch {
            FileHandle.standardError.write(Data("Ajman: could not switch to pet '\(id)': \(error.localizedDescription)\n".utf8))
        }
    }
}
