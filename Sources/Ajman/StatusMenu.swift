import AppKit

@MainActor
final class StatusMenu: NSObject {
    private let animator: Animator
    private weak var panel: OverlayPanel?
    private let registry: SessionRegistry
    private let statusItem: NSStatusItem
    /// When true, the live Claude/Codex driver is paused so the Debug menu selection sticks.
    private(set) var manualMode = false
    private let activityItem = NSMenuItem(title: "Claude: Idle — 0 sessions", action: nil, keyEquivalent: "")
    private let cycleItem = NSMenuItem(title: "Cycle All States", action: #selector(toggleCycle(_:)), keyEquivalent: "")
    private var stateItems: [AnimationState: NSMenuItem] = [:]
    private var cycleTimer: Timer?

    init(animator: Animator, panel: OverlayPanel, registry: SessionRegistry) {
        self.animator = animator
        self.panel = panel
        self.registry = registry
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusItem.button?.title = "🐈‍⬛"
        let menu = NSMenu()
        activityItem.isEnabled = false
        menu.addItem(activityItem)
        menu.addItem(.separator())
        let connect = NSMenuItem(title: "Connect to Claude Code", action: #selector(connectToClaude), keyEquivalent: "")
        connect.target = self; menu.addItem(connect)
        let disconnect = NSMenuItem(title: "Disconnect from Claude Code", action: #selector(disconnectFromClaude), keyEquivalent: "")
        disconnect.target = self; menu.addItem(disconnect)
        menu.addItem(.separator())

        let debugMenu = NSMenu(title: "Debug")
        for state in animator.availableStates {
            let item = NSMenuItem(title: state.title, action: #selector(selectState(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = state.rawValue
            debugMenu.addItem(item); stateItems[state] = item
        }
        debugMenu.addItem(.separator()); cycleItem.target = self; debugMenu.addItem(cycleItem)
        let resumeLive = NSMenuItem(title: "Resume Live Reactions", action: #selector(resumeLiveReactions), keyEquivalent: "")
        resumeLive.target = self; debugMenu.addItem(resumeLive)
        let debugItem = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        debugItem.submenu = debugMenu; menu.addItem(debugItem)

        let reset = NSMenuItem(title: "Reset Position", action: #selector(resetPosition), keyEquivalent: "")
        reset.target = self; menu.addItem(reset); menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Ajman", action: #selector(quit), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit); statusItem.menu = menu
        animator.stateDidChange = { [weak self] state in self?.updateChecks(for: state) }
        updateChecks(for: animator.currentState)
    }

    func updateActivity(state: AnimationState, sessionCount: Int) {
        guard !manualMode else { return }
        activityItem.title = "Claude: \(state.title) — \(sessionCount) session\(sessionCount == 1 ? "" : "s")"
    }

    private func refreshManualIndicator() {
        if manualMode {
            activityItem.title = "Manual: \(animator.currentState.title) — live paused"
        } else {
            updateActivity(state: registry.currentState, sessionCount: registry.sessions.count)
        }
    }

    @objc private func resumeLiveReactions() {
        stopCycling()
        manualMode = false
        animator.play(registry.currentState)
        refreshManualIndicator()
    }

    @objc private func connectToClaude() {
        do {
            let binary = try ClaudeHookInstaller.installHookBinary()
            // This is the sole live-settings install path, reached only by an explicit menu click.
            let settings = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
            let summary = try ClaudeHookInstaller.install(settingsPath: settings, hookBinaryPath: binary.path)
            showAlert(title: "Claude Code connected", text: "Added \(summary.eventsAdded.count) event hooks.\nBackup: \(summary.backupPath ?? "new settings file; no original to back up")")
        } catch { showAlert(title: "Could not connect", text: error.localizedDescription) }
    }

    @objc private func disconnectFromClaude() {
        do {
            // This is the sole live-settings uninstall path, reached only by an explicit menu click.
            let settings = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
            let summary = try ClaudeHookInstaller.uninstall(settingsPath: settings)
            showAlert(title: "Claude Code disconnected", text: "Removed \(summary.commandsRemoved) Ajman hook commands.\nBackup: \(summary.backupPath)")
        } catch { showAlert(title: "Could not disconnect", text: error.localizedDescription) }
    }

    private func showAlert(title: String, text: String) { let alert = NSAlert(); alert.messageText = title; alert.informativeText = text; alert.runModal() }
    @objc private func selectState(_ sender: NSMenuItem) { stopCycling(); guard let raw = sender.representedObject as? String, let state = AnimationState(rawValue: raw) else { return }; manualMode = true; animator.play(state); refreshManualIndicator() }
    @objc private func toggleCycle(_ sender: NSMenuItem) { cycleTimer == nil ? startCycling() : stopCycling() }
    private func startCycling() { manualMode = true; cycleItem.state = .on; refreshManualIndicator(); cycleTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in Task { @MainActor in guard let self, let index = self.animator.availableStates.firstIndex(of: self.animator.currentState) else { return }; let states = self.animator.availableStates; self.animator.play(states[(index + 1) % states.count]); self.refreshManualIndicator() } } }
    private func stopCycling() { cycleTimer?.invalidate(); cycleTimer = nil; cycleItem.state = .off }
    private func updateChecks(for state: AnimationState) { for (candidate, item) in stateItems { item.state = candidate == state ? .on : .off } }
    @objc private func resetPosition() { panel?.resetPosition() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
