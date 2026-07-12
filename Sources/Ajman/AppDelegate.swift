import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: OverlayPanel?
    private var animator: Animator?
    private var statusMenu: StatusMenu?
    private var petMode: PetMode?
    private var registry: SessionRegistry?
    private var server: UDSServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let sheet = try SpriteSheet.load()
            let scale = PetScale.load()
            let view = PetView(frame: NSRect(origin: .zero, size: scale.displaySize))
            let panel = OverlayPanel(contentView: view, scale: scale)
            let animator = Animator(sheet: sheet, view: view)
            let registry = SessionRegistry()
            let server = UDSServer()
            var statusMenu: StatusMenu!
            let petMode = PetMode(
                animator: animator,
                currentLiveState: { [weak registry] in registry?.currentState ?? .idle },
                isManualMode: { [weak statusMenu] in statusMenu?.manualMode ?? false }
            )
            statusMenu = StatusMenu(animator: animator, panel: panel, registry: registry, petMode: petMode)
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
            server.eventHandler = { event in
                Task { @MainActor in registry.apply(event) }
            }
            try server.start()

            self.panel = panel
            self.animator = animator
            self.statusMenu = statusMenu
            self.petMode = petMode
            self.registry = registry
            self.server = server

            panel.restorePositionOrUseDefault()
            panel.orderFrontRegardless()
            petMode.resumeAtRest()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Ajman could not load his spritesheet."
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.runModal()
            NSApplication.shared.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) { server?.stop() }
}
