import AppKit

final class OverlayPanel: NSPanel, NSWindowDelegate {
    static let displaySize = NSSize(width: 96, height: 104)
    private static let positionKey = "AjmanPanelOrigin"
    private var saveWorkItem: DispatchWorkItem?

    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.displaySize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.contentView = contentView
        delegate = self
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func restorePositionOrUseDefault() {
        if let value = UserDefaults.standard.string(forKey: Self.positionKey) {
            let origin = NSPointFromString(value)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(NSRect(origin: origin, size: frame.size)) }) {
                setFrameOrigin(origin)
                return
            }
        }
        resetPosition()
    }

    func resetPosition() {
        guard let visibleFrame = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame else { return }
        setFrameOrigin(NSPoint(
            x: visibleFrame.maxX - frame.width - 24,
            y: visibleFrame.minY + 24
        ))
        savePosition()
    }

    func windowDidMove(_ notification: Notification) {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.savePosition() }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func savePosition() {
        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: Self.positionKey)
    }
}
