import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: OverlayPanel?
    private var animator: Animator?
    private var statusMenu: StatusMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let sheet = try SpriteSheet.load()
            let view = PetView(frame: NSRect(origin: .zero, size: OverlayPanel.displaySize))
            let panel = OverlayPanel(contentView: view)
            let animator = Animator(sheet: sheet, view: view)
            let statusMenu = StatusMenu(animator: animator, panel: panel)

            self.panel = panel
            self.animator = animator
            self.statusMenu = statusMenu

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
}
