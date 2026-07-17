import AppKit

final class OverlayPanel: NSPanel, NSWindowDelegate {
    private static let legacyPositionKey = "AjmanPanelOrigin"
    static let substantialOverlapThreshold: CGFloat = 0.55
    private var saveWorkItem: DispatchWorkItem?
    private var screenParametersObserver: NSObjectProtocol?
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

        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.ensureVisible() }
        }
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
            if Self.hasSubstantialOverlap(
                panelFrame: NSRect(origin: origin, size: frame.size),
                visibleFrames: Self.currentVisibleFrames()
            ) {
                setFrameOrigin(origin)
                return
            }
        }
        resetPosition()
    }

    func resetPosition() {
        guard let visibleFrame = Self.preferredVisibleFrame() else {
            return
        }
        setFrameOrigin(Self.defaultOrigin(
            visibleFrame: visibleFrame,
            displaySize: frame.size,
            defaultPositionIndex: defaultPositionIndex
        ))
        ensureVisible()
        savePosition()
    }

    /// Repairs a stale, invalid, or not-yet-positioned panel whenever usable screen
    /// geometry is available. This is intentionally safe to call repeatedly.
    func ensureVisible() {
        let visibleFrames = Self.currentVisibleFrames()
        guard !visibleFrames.isEmpty, let preferredFrame = Self.preferredVisibleFrame() else {
            return
        }
        guard !Self.hasSubstantialOverlap(panelFrame: frame, visibleFrames: visibleFrames) else { return }
        setFrameOrigin(Self.defaultOrigin(
            visibleFrame: preferredFrame,
            displaySize: frame.size,
            defaultPositionIndex: defaultPositionIndex
        ))
        savePosition()
    }

    private static func currentVisibleFrames() -> [NSRect] {
        NSScreen.screens.map(\.visibleFrame).filter(Self.isUsableScreenFrame)
    }

    private static func preferredVisibleFrame() -> NSRect? {
        if let main = NSScreen.main?.visibleFrame, isUsableScreenFrame(main) { return main }
        return NSScreen.screens.map(\.visibleFrame).first(where: isUsableScreenFrame)
    }

    private static func isUsableScreenFrame(_ frame: NSRect) -> Bool {
        frame.width.isFinite && frame.height.isFinite && frame.width > 0 && frame.height > 0
    }

    static func hasSubstantialOverlap(
        panelFrame: NSRect,
        visibleFrames: [NSRect],
        threshold: CGFloat = substantialOverlapThreshold
    ) -> Bool {
        guard panelFrame.width > 0, panelFrame.height > 0 else { return false }
        let panelArea = panelFrame.width * panelFrame.height
        let bottomCenter = NSPoint(x: panelFrame.midX, y: panelFrame.minY)
        return visibleFrames.contains { visibleFrame in
            guard isUsableScreenFrame(visibleFrame) else { return false }
            let intersection = panelFrame.intersection(visibleFrame)
            let overlapArea = intersection.isNull ? 0 : intersection.width * intersection.height
            return overlapArea / panelArea >= threshold
                || visibleFrame.contains(bottomCenter)
        }
    }

    static func healedFrame(
        panelFrame: NSRect,
        visibleFrames: [NSRect],
        preferredVisibleFrame: NSRect,
        defaultPositionIndex: Int
    ) -> NSRect {
        guard !hasSubstantialOverlap(panelFrame: panelFrame, visibleFrames: visibleFrames) else {
            return panelFrame
        }
        return NSRect(
            origin: defaultOrigin(
                visibleFrame: preferredVisibleFrame,
                displaySize: panelFrame.size,
                defaultPositionIndex: defaultPositionIndex
            ),
            size: panelFrame.size
        )
    }

    static func defaultOrigin(
        visibleFrame: NSRect,
        displaySize: NSSize,
        defaultPositionIndex: Int
    ) -> NSPoint {
        let groundLine = visibleFrame.minY + 24
        let scaledGroundMargin = CGFloat(SpriteSheet.contentMargin)
            * displaySize.height / CGFloat(SpriteSheet.cellHeight)
        let intendedOrigin = NSPoint(
            x: visibleFrame.maxX - displaySize.width - 24
                - CGFloat(defaultPositionIndex) * displaySize.width * 1.5,
            y: groundLine - scaledGroundMargin
        )
        return clampedOrigin(intendedOrigin, displaySize: displaySize, visibleFrame: visibleFrame)
    }

    static func clampedOrigin(
        _ origin: NSPoint,
        displaySize: NSSize,
        visibleFrame: NSRect
    ) -> NSPoint {
        let maximumX = max(visibleFrame.minX, visibleFrame.maxX - displaySize.width)
        let maximumY = max(visibleFrame.minY, visibleFrame.maxY - displaySize.height)
        return NSPoint(
            x: min(max(origin.x, visibleFrame.minX), maximumX),
            y: min(max(origin.y, visibleFrame.minY), maximumY)
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
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
            self.screenParametersObserver = nil
        }
        orderOut(nil)
        close()
    }

    deinit {
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
    }
}
