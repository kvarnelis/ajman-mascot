import AppKit

@MainActor
final class BubbleCardView: NSView {
    private let notification: PetNotification
    private let titleLabel = NSTextField(labelWithString: "")
    private let previewLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let expandButton = NSButton(title: "⌄", target: nil, action: nil)
    private let closeButton = NSButton(title: "×", target: nil, action: nil)
    private var expanded = false
    var onDismiss: (() -> Void)?
    var onOpen: (() -> Void)?
    var onHeightChange: (() -> Void)?

    init(notification: PetNotification) {
        self.notification = notification
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        layer?.borderWidth = 0.5
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.14
        layer?.shadowRadius = 5
        layer?.shadowOffset = NSSize(width: 0, height: -1)

        titleLabel.stringValue = notification.title
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        previewLabel.font = .systemFont(ofSize: 11)
        previewLabel.textColor = .secondaryLabelColor
        previewLabel.maximumNumberOfLines = 2
        previewLabel.stringValue = Self.collapsed(notification.preview)

        let status = Self.status(for: notification.kind)
        statusLabel.stringValue = status.text
        statusLabel.textColor = status.color
        statusLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        statusLabel.alignment = .center
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        if notification.kind == .running { progressIndicator.startAnimation(nil) }

        for button in [expandButton, closeButton] {
            button.isBordered = false
            button.font = .systemFont(ofSize: 13, weight: .medium)
            button.contentTintColor = .secondaryLabelColor
        }
        expandButton.target = self
        expandButton.action = #selector(toggleExpanded)
        closeButton.target = self
        closeButton.action = #selector(closeCard)

        [titleLabel, previewLabel, statusLabel, progressIndicator, expandButton, closeButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 68),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            statusLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            statusLabel.widthAnchor.constraint(equalToConstant: 17),
            progressIndicator.centerXAnchor.constraint(equalTo: statusLabel.centerXAnchor),
            progressIndicator.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            progressIndicator.widthAnchor.constraint(equalToConstant: 14),
            progressIndicator.heightAnchor.constraint(equalToConstant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: statusLabel.trailingAnchor, constant: 5),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: expandButton.leadingAnchor, constant: -4),
            expandButton.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            expandButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -1),
            expandButton.widthAnchor.constraint(equalToConstant: 24),
            expandButton.heightAnchor.constraint(equalToConstant: 25),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 25),
            previewLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            previewLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            previewLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            previewLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard !expandButton.frame.contains(point), !closeButton.frame.contains(point) else { return }
        onOpen?()
    }

    @objc private func closeCard() { onDismiss?() }

    @objc private func toggleExpanded() {
        expanded.toggle()
        previewLabel.maximumNumberOfLines = expanded ? 0 : 2
        previewLabel.stringValue = expanded ? notification.fullText : Self.collapsed(notification.preview)
        expandButton.title = expanded ? "⌃" : "⌄"
        onHeightChange?()
    }

    private static func collapsed(_ value: String) -> String {
        guard value.count > 120 else { return value }
        return String(value.prefix(120)) + "…"
    }

    private static func status(for kind: PetNotification.Kind) -> (text: String, color: NSColor) {
        switch kind {
        case .waiting: return ("●", .systemOrange)
        case .done: return ("✓", .systemGreen)
        case .failed: return ("●", .systemRed)
        case .running: return ("", .controlAccentColor)
        }
    }
}
