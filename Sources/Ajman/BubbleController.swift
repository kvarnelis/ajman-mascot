import AppKit

@MainActor
final class BubbleController {
    private final class BubblePanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private let petPanel: OverlayPanel
    private let panel: NSPanel
    private let stack = NSStackView()
    private var notifications: [String: PetNotification] = [:]
    private var expiryTimers: [String: Timer] = [:]
    private var observerTokens: [NSObjectProtocol] = []
    var dismissHandler: ((String) -> Void)?
    private let maximumVisible = 4
    private let cardWidth: CGFloat = 260

    init(petPanel: OverlayPanel) {
        self.petPanel = petPanel
        panel = BubblePanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        panel.contentView = content
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 7),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -7),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -7),
        ])

        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification] {
            observerTokens.append(center.addObserver(forName: name, object: petPanel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.anchor() }
            })
        }
    }

    deinit {
        observerTokens.forEach(NotificationCenter.default.removeObserver)
        expiryTimers.values.forEach { $0.invalidate() }
    }

    func apply(_ change: PetNotificationChange) {
        switch change {
        case .upsert(let notification):
            notifications[notification.id] = notification
            scheduleExpiry(for: notification)
        case .dismiss(let id):
            notifications.removeValue(forKey: id)
            expiryTimers.removeValue(forKey: id)?.invalidate()
        }
        render()
    }

    private func scheduleExpiry(for notification: PetNotification) {
        expiryTimers.removeValue(forKey: notification.id)?.invalidate()
        guard notification.kind != .waiting else { return }
        expiryTimers[notification.id] = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dismissHandler?(notification.id)
            }
        }
    }

    private func render() {
        stack.arrangedSubviews.forEach { view in stack.removeArrangedSubview(view); view.removeFromSuperview() }
        let ordered = notifications.values.sorted { $0.timestamp > $1.timestamp }
        for notification in ordered.prefix(maximumVisible) {
            let card = BubbleCardView(notification: notification)
            card.widthAnchor.constraint(equalToConstant: cardWidth).isActive = true
            card.onDismiss = { [weak self] in self?.dismissHandler?(notification.id) }
            card.onOpen = { [weak self] in
                self?.activateOwner(for: notification.provider)
                self?.dismissHandler?(notification.id)
            }
            card.onHeightChange = { [weak self] in
                self?.resizeAndAnchor()
            }
            stack.addArrangedSubview(card)
        }
        if ordered.count > maximumVisible {
            let more = NSTextField(labelWithString: "+\(ordered.count - maximumVisible) more")
            more.font = .systemFont(ofSize: 10, weight: .medium)
            more.textColor = .secondaryLabelColor
            stack.addArrangedSubview(more)
        }

        guard !ordered.isEmpty else {
            panel.orderOut(nil)
            panel.setFrame(.zero, display: false)
            return
        }
        resizeAndAnchor()
        panel.orderFrontRegardless()
    }

    private func resizeAndAnchor() {
        stack.layoutSubtreeIfNeeded()
        let fitting = stack.fittingSize
        panel.setContentSize(NSSize(width: cardWidth + 14, height: fitting.height + 14))
        anchor()
    }

    private func anchor() {
        guard panel.isVisible || !notifications.isEmpty else { return }
        let pet = petPanel.frame
        let screen = petPanel.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        var origin = NSPoint(x: pet.maxX - size.width, y: pet.maxY + 8)
        if origin.y + size.height > visible.maxY {
            origin = NSPoint(x: pet.minX - size.width - 8, y: pet.maxY - size.height)
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        panel.setFrameOrigin(origin)
    }

    private func activateOwner(for provider: AgentEvent.Provider) {
        let needle = provider == .claude ? "claude" : "codex"
        let app = NSWorkspace.shared.runningApplications.first { application in
            application.localizedName?.localizedCaseInsensitiveContains(needle) == true ||
                application.bundleIdentifier?.localizedCaseInsensitiveContains(needle) == true
        }
        app?.activate(options: [])
    }
}
