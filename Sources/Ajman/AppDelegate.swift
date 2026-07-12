import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: OverlayPanel?
    private var animator: Animator?
    private var statusMenu: StatusMenu?
    private var registry: SessionRegistry?
    private var server: UDSServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let sheet = try SpriteSheet.load()
            let view = PetView(frame: NSRect(origin: .zero, size: OverlayPanel.displaySize))
            let panel = OverlayPanel(contentView: view)
            let animator = Animator(sheet: sheet, view: view)
            let registry = SessionRegistry()
            let server = UDSServer()
            let statusMenu = StatusMenu(animator: animator, panel: panel, registry: registry)
            registry.didChange = { [weak animator, weak statusMenu] state, count in
                if statusMenu?.manualMode == true { return }   // Debug menu holds the reins; don't fight it
                animator?.play(state)
                statusMenu?.updateActivity(state: state, sessionCount: count)
            }
            server.eventHandler = { event in
                Task { @MainActor in registry.apply(event) }
            }
            try server.start()

            self.panel = panel
            self.animator = animator
            self.statusMenu = statusMenu
            self.registry = registry
            self.server = server

            panel.restorePositionOrUseDefault()
            panel.orderFrontRegardless()
            animator.play(.idle)
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
