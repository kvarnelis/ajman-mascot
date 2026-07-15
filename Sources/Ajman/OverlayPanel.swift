import AppKit

final class OverlayPanel: NSPanel, NSWindowDelegate {
    private static let legacyPositionKey = "AjmanPanelOrigin"
    private var saveWorkItem: DispatchWorkItem?
    private let defaults: UserDefaults
    private var defaultPositionIndex: Int
    let positionPersistenceKey: String
    private(set) var petScale: PetScale
    private(set) var relativeScale: Double
    var petWasClicked: (() -> Void)?
    var petActionCycleRequested: (() -> Void)?
    private var mouseDownScreenLocation: NSPoint?
    private var mouseDownTimestamp: TimeInterval?
    private var mouseDownDisposition: PetClickDisposition?
    var displaySize: NSSize { Self.displaySize(global: petScale, relative: relativeScale) }

    static func positionPersistenceKey(for petID: String) -> String {
        "AjmanPanelOrigin.\(petID)"
    }

    init(
        contentView: NSView,
        scale: PetScale,
        relativeScale: Double = 1.0,
        petID: String,
        defaultPositionIndex: Int,
        defaults: UserDefaults = .standard
    ) {
        petScale = scale
        self.relativeScale = relativeScale
        self.defaultPositionIndex = defaultPositionIndex
        self.defaults = defaults
        positionPersistenceKey = Self.positionPersistenceKey(for: petID)
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
            mouseDownDisposition = PetClickDisposition.classify(
                buttonNumber: event.buttonNumber,
                modifiers: event.modifierFlags
            )
            if mouseDownDisposition == .advanceAction { return }
        case .leftMouseUp:
            if let start = mouseDownScreenLocation,
               let timestamp = mouseDownTimestamp,
               hypot(NSEvent.mouseLocation.x - start.x, NSEvent.mouseLocation.y - start.y) < 4,
               event.timestamp - timestamp < 0.4 {
                if mouseDownDisposition == .advanceAction {
                    petActionCycleRequested?()
                } else {
                    petWasClicked?()
                }
            }
            mouseDownScreenLocation = nil
            mouseDownTimestamp = nil
            let disposition = mouseDownDisposition
            mouseDownDisposition = nil
            if disposition == .advanceAction { return }
        case .rightMouseDown:
            mouseDownScreenLocation = NSEvent.mouseLocation
            mouseDownTimestamp = event.timestamp
            mouseDownDisposition = .advanceAction
            return
        case .rightMouseUp:
            if let start = mouseDownScreenLocation,
               let timestamp = mouseDownTimestamp,
               hypot(NSEvent.mouseLocation.x - start.x, NSEvent.mouseLocation.y - start.y) < 4,
               event.timestamp - timestamp < 0.4 {
                petActionCycleRequested?()
            }
            mouseDownScreenLocation = nil
            mouseDownTimestamp = nil
            mouseDownDisposition = nil
            return
        default:
            break
        }
        super.sendEvent(event)
    }

    func restorePositionOrUseDefault(useLegacyFallback: Bool = false) {
        let stored = defaults.string(forKey: positionPersistenceKey)
            ?? (useLegacyFallback ? defaults.string(forKey: Self.legacyPositionKey) : nil)
        if let value = stored {
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
        setFrameOrigin(Self.defaultOrigin(
            visibleFrame: visibleFrame,
            displaySize: frame.size,
            defaultPositionIndex: defaultPositionIndex
        ))
        savePosition()
    }

    static func defaultOrigin(
        visibleFrame: NSRect,
        displaySize: NSSize,
        defaultPositionIndex: Int
    ) -> NSPoint {
        let groundLine = visibleFrame.minY + 24
        let scaledGroundMargin = CGFloat(SpriteSheet.contentMargin)
            * displaySize.height / CGFloat(SpriteSheet.cellHeight)
        return NSPoint(
            x: max(
                visibleFrame.minX,
                visibleFrame.maxX - displaySize.width - 24
                    - CGFloat(defaultPositionIndex) * displaySize.width * 1.5
            ),
            y: min(visibleFrame.maxY - displaySize.height, groundLine - scaledGroundMargin)
        )
    }

    static func renderedGroundLine(originY: CGFloat, displayHeight: CGFloat) -> CGFloat {
        originY + CGFloat(SpriteSheet.contentMargin) * displayHeight / CGFloat(SpriteSheet.cellHeight)
    }

    func setDefaultPositionIndex(_ index: Int) {
        defaultPositionIndex = index
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
        defaults.set(NSStringFromPoint(frame.origin), forKey: positionPersistenceKey)
    }

    func teardown() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        orderOut(nil)
        close()
    }
}
