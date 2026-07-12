import AppKit

final class OverlayPanel: NSPanel, NSWindowDelegate {
    private static let positionKey = "AjmanPanelOrigin"
    private var saveWorkItem: DispatchWorkItem?
    private(set) var petScale: PetScale
    var petWasClicked: (() -> Void)?
    private var mouseDownScreenLocation: NSPoint?
    private var mouseDownTimestamp: TimeInterval?
    var displaySize: NSSize { petScale.displaySize }

    init(contentView: NSView, scale: PetScale) {
        petScale = scale
        super.init(
            contentRect: NSRect(origin: .zero, size: scale.displaySize),
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

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            mouseDownScreenLocation = NSEvent.mouseLocation
            mouseDownTimestamp = event.timestamp
        case .leftMouseUp:
            if let start = mouseDownScreenLocation,
               let timestamp = mouseDownTimestamp,
               hypot(NSEvent.mouseLocation.x - start.x, NSEvent.mouseLocation.y - start.y) < 4,
               event.timestamp - timestamp < 0.4 {
                petWasClicked?()
            }
            mouseDownScreenLocation = nil
            mouseDownTimestamp = nil
        default:
            break
        }
        super.sendEvent(event)
    }

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

    func apply(scale: PetScale) {
        guard scale != petScale else { return }

        let oldFrame = frame
        let bottomCenter = NSPoint(x: oldFrame.midX, y: oldFrame.minY)
        let newSize = scale.displaySize
        var newFrame = NSRect(
            x: bottomCenter.x - newSize.width / 2,
            y: bottomCenter.y,
            width: newSize.width,
            height: newSize.height
        )
        let targetScreen = screen
            ?? NSScreen.screens.first(where: { $0.visibleFrame.contains(bottomCenter) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        if let visibleFrame = targetScreen?.visibleFrame {
            newFrame.origin.x = min(max(newFrame.minX, visibleFrame.minX), visibleFrame.maxX - newFrame.width)
            newFrame.origin.y = min(max(newFrame.minY, visibleFrame.minY), visibleFrame.maxY - newFrame.height)
        }

        petScale = scale
        contentView?.frame = NSRect(origin: .zero, size: newSize)
        setFrame(newFrame, display: true)
        scale.save()
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
