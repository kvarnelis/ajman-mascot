import AppKit

@MainActor
final class UpdateBubbleController {
    private final class BubblePanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private final class BubbleBackgroundView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            let body = NSRect(x: 2, y: 16, width: bounds.width - 4, height: bounds.height - 18)
            NSColor.windowBackgroundColor.withAlphaComponent(0.97).setFill()
            NSColor.labelColor.withAlphaComponent(0.8).setStroke()
            let outline = NSBezierPath(roundedRect: body, xRadius: 17, yRadius: 17)
            outline.lineWidth = 2
            outline.fill()
            outline.stroke()

            let tail = NSBezierPath()
            tail.move(to: NSPoint(x: bounds.width - 54, y: 17))
            tail.line(to: NSPoint(x: bounds.width - 30, y: 2))
            tail.line(to: NSPoint(x: bounds.width - 34, y: 18))
            tail.close()
            tail.fill()
            tail.stroke()
        }
    }

    private let panel: NSPanel
    private let titleLabel = NSTextField(labelWithString: "New tricks — update?")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let updateButton = NSButton(title: "Update", target: nil, action: nil)
    private let laterButton = NSButton(title: "Later", target: nil, action: nil)
    private let disableButton = NSButton(title: "Don’t ask again", target: nil, action: nil)
    private var observerTokens: [NSObjectProtocol] = []
    private weak var anchorWindow: NSWindow?
    private var fallbackAnchor: NSRect?

    var updateHandler: (() -> Void)?
    var laterHandler: (() -> Void)?
    var disableHandler: (() -> Void)?

    var isVisible: Bool { panel.isVisible }
    var controlCount: Int { 3 }

    init() {
        panel = BubblePanel(
            contentRect: NSRect(x: 0, y: 0, width: 310, height: 142),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false

        let background = BubbleBackgroundView(frame: panel.contentView?.bounds ?? .zero)
        background.autoresizingMask = [.width, .height]
        panel.contentView = background

        titleLabel.font = .systemFont(ofSize: 16, weight: .bold)
        detailLabel.font = .systemFont(ofSize: 11.5, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2
        detailLabel.lineBreakMode = .byWordWrapping

        for button in [updateButton, laterButton, disableButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
        }
        updateButton.action = #selector(updatePressed)
        laterButton.action = #selector(laterPressed)
        disableButton.action = #selector(disablePressed)

        let buttons = NSStackView(views: [updateButton, laterButton, disableButton])
        buttons.orientation = .horizontal
        buttons.spacing = 6
        buttons.distribution = .fillProportionally

        let stack = NSStackView(views: [titleLabel, detailLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 15),
            buttons.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])
    }

    deinit { observerTokens.forEach(NotificationCenter.default.removeObserver) }

    func showRelease(tag: String, anchoredTo window: NSWindow?) {
        show(detail: "Version \(tag) is ready.", anchoredTo: window, fallbackAnchor: nil)
    }

    func showPreview(anchoredTo window: NSWindow?, fallbackAnchor: NSRect? = nil) {
        show(detail: "Preview only — no release will be installed.", anchoredTo: window, fallbackAnchor: fallbackAnchor)
    }

    func showFailure(_ message: String, anchoredTo window: NSWindow?) {
        show(detail: "Update failed — \(message)", anchoredTo: window, fallbackAnchor: nil)
    }

    func showProgress(_ message: String) {
        detailLabel.stringValue = message
        updateButton.isEnabled = false
        laterButton.isEnabled = false
        disableButton.isEnabled = false
    }

    func showPreviewNoOp() {
        detailLabel.stringValue = "Preview only — nothing was downloaded."
        updateButton.isEnabled = true
        laterButton.isEnabled = true
        disableButton.isEnabled = true
    }

    func dismiss() {
        clearObservers()
        panel.orderOut(nil)
    }

    private func show(detail: String, anchoredTo window: NSWindow?, fallbackAnchor: NSRect?) {
        clearObservers()
        anchorWindow = window
        self.fallbackAnchor = fallbackAnchor
        detailLabel.stringValue = detail
        updateButton.isEnabled = true
        laterButton.isEnabled = true
        disableButton.isEnabled = true
        if let window {
            let center = NotificationCenter.default
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification] {
                observerTokens.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.anchor() }
                })
            }
        }
        anchor()
        panel.orderFrontRegardless()
    }

    private func anchor() {
        let anchor = anchorWindow?.frame ?? fallbackAnchor
        let screen = anchorWindow?.screen ?? anchor.flatMap { rect in
            NSScreen.screens.first(where: { $0.frame.intersects(rect) })
        } ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let target = anchor ?? NSRect(x: visible.maxX - 100, y: visible.minY + 30, width: 70, height: 70)
        var origin = NSPoint(x: target.midX - size.width + 38, y: target.maxY + 2)
        if origin.y + size.height > visible.maxY {
            origin.y = target.minY - size.height - 2
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        panel.setFrameOrigin(origin)
    }

    private func clearObservers() {
        observerTokens.forEach(NotificationCenter.default.removeObserver)
        observerTokens.removeAll()
        anchorWindow = nil
    }

    @objc private func updatePressed() { updateHandler?() }
    @objc private func laterPressed() { laterHandler?() }
    @objc private func disablePressed() { disableHandler?() }
}
