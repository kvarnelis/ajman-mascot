import AppKit

final class OverlayPanel: NSPanel, NSWindowDelegate {
    private static let positionKey = "AjmanPanelOrigin"
    private var saveWorkItem: DispatchWorkItem?
    private(set) var petScale: PetScale
    private(set) var relativeScale: Double
    var petWasClicked: (() -> Void)?
    private var mouseDownScreenLocation: NSPoint?
    private var mouseDownTimestamp: TimeInterval?
    var displaySize: NSSize { Self.displaySize(global: petScale, relative: relativeScale) }

    init(contentView: NSView, scale: PetScale, relativeScale: Double = 1.0) {
        petScale = scale
        self.relativeScale = relativeScale
        let size = Self.displaySize(global: scale, relative: relativeScale)
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
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

    func apply(scale: PetScale? = nil, relativeScale: Double? = nil) {
        let nextScale = scale ?? petScale
        let nextRelativeScale = relativeScale ?? self.relativeScale
        guard nextScale != petScale || nextRelativeScale != self.relativeScale else { return }

        let oldFrame = frame
        let bottomCenter = NSPoint(x: oldFrame.midX, y: oldFrame.minY)
        let newSize = Self.displaySize(global: nextScale, relative: nextRelativeScale)
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

        petScale = nextScale
        self.relativeScale = nextRelativeScale
        contentView?.frame = NSRect(origin: .zero, size: newSize)
        setFrame(newFrame, display: true)
        if scale != nil { nextScale.save() }
        savePosition()
    }

    private static func displaySize(global: PetScale, relative: Double) -> NSSize {
        NSSize(
            width: (CGFloat(SpriteSheet.cellWidth) * CGFloat(global.rawValue) * CGFloat(relative)).rounded(),
            height: (CGFloat(SpriteSheet.cellHeight) * CGFloat(global.rawValue) * CGFloat(relative)).rounded()
        )
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
