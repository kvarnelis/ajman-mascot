import AppKit

@MainActor
final class StatusMenu: NSObject {
    private let animator: Animator
    private weak var panel: OverlayPanel?
    private let registry: SessionRegistry
    private let petMode: PetMode
    private let statusItem: NSStatusItem
    private let launchAtLogin = LaunchAtLogin()
    /// When true, the live Claude/Codex driver is paused so the Debug menu selection sticks.
    private(set) var manualMode = false
    private let activityItem = NSMenuItem(title: "Claude: Idle — 0 sessions", action: nil, keyEquivalent: "")
    private let cycleItem = NSMenuItem(title: "Cycle All States", action: #selector(toggleCycle(_:)), keyEquivalent: "")
    private var stateItems: [AnimationState: NSMenuItem] = [:]
    private var scaleItems: [PetScale: NSMenuItem] = [:]
    private var cycleTimer: Timer?
    private let playfulIdleItem = NSMenuItem(title: "Playful Idle", action: #selector(togglePlayfulIdle(_:)), keyEquivalent: "")
    private let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
    private let petMenu = NSMenu(title: "Pet")
    private let debugMenu = NSMenu(title: "Debug")
    private var petItems: [String: NSMenuItem] = [:]
    var petSelectionHandler: ((String) -> Void)?

    init(animator: Animator, panel: OverlayPanel, registry: SessionRegistry, petMode: PetMode, pets: [PetDescriptor], activePetID: String) {
        self.animator = animator
        self.panel = panel
        self.registry = registry
        self.petMode = petMode
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusItem.button?.title = "🐈‍⬛"
        let menu = NSMenu()
        activityItem.isEnabled = false
        menu.addItem(activityItem)
        rebuildPetMenu(pets: pets, activePetID: activePetID)
        let petItem = NSMenuItem(title: "Pet", action: nil, keyEquivalent: "")
        petItem.submenu = petMenu
        menu.addItem(petItem)
        playfulIdleItem.target = self
        playfulIdleItem.state = petMode.isEnabled ? .on : .off
        menu.addItem(playfulIdleItem)
        menu.addItem(.separator())
        let connect = NSMenuItem(title: "Connect to Claude Code", action: #selector(connectToClaude), keyEquivalent: "")
        connect.target = self; menu.addItem(connect)
        let disconnect = NSMenuItem(title: "Disconnect from Claude Code", action: #selector(disconnectFromClaude), keyEquivalent: "")
        disconnect.target = self; menu.addItem(disconnect)
        menu.addItem(.separator())

        let sizeMenu = NSMenu(title: "Size")
        for scale in PetScale.allCases {
            let item = NSMenuItem(title: scale.menuTitle, action: #selector(selectScale(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = scale.rawValue
            sizeMenu.addItem(item)
            scaleItems[scale] = item
        }
        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        rebuildDebugMenu()
        let debugItem = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        debugItem.submenu = debugMenu; menu.addItem(debugItem)

        let reset = NSMenuItem(title: "Reset Position", action: #selector(resetPosition), keyEquivalent: "")
        reset.target = self; menu.addItem(reset)
        launchAtLoginItem.target = self
        launchAtLoginItem.state = launchAtLogin.isEnabled ? .on : .off
        menu.addItem(launchAtLoginItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Ajman", action: #selector(quit), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit); statusItem.menu = menu
        animator.stateDidChange = { [weak self] state in self?.updateChecks(for: state) }
        updateChecks(for: animator.currentState)
        updateScaleChecks(for: panel.petScale)
        panel.petWasClicked = { [weak petMode] in petMode?.wake() }
    }

    func refreshForPet(pets: [PetDescriptor], activePetID: String) {
        rebuildPetMenu(pets: pets, activePetID: activePetID)
        rebuildDebugMenu()
        updateChecks(for: animator.currentState)
        refreshManualIndicator()
    }

    private func rebuildPetMenu(pets: [PetDescriptor], activePetID: String) {
        petMenu.removeAllItems()
        petItems.removeAll()
        for pet in pets {
            let item = NSMenuItem(title: pet.displayName, action: #selector(selectPet(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = pet.id
            item.state = pet.id == activePetID ? .on : .off
            petMenu.addItem(item)
            petItems[pet.id] = item
        }
    }

    private func rebuildDebugMenu() {
        debugMenu.removeAllItems()
        stateItems.removeAll()
        for state in animator.availableStates {
            let item = NSMenuItem(title: state.title, action: #selector(selectState(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = state.rawValue
            debugMenu.addItem(item)
            stateItems[state] = item
        }
        debugMenu.addItem(.separator())
        cycleItem.target = self
        debugMenu.addItem(cycleItem)
        let resumeLive = NSMenuItem(title: "Resume Live Reactions", action: #selector(resumeLiveReactions), keyEquivalent: "")
        resumeLive.target = self
        debugMenu.addItem(resumeLive)
    }

    @objc private func selectPet(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        petSelectionHandler?(id)
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
        if registry.currentState == .idle {
            petMode.resumeAtRest()
        } else {
            petMode.yieldToHigherPriorityDriver()
            animator.play(registry.currentState)
        }
        refreshManualIndicator()
    }

    @objc private func togglePlayfulIdle(_ sender: NSMenuItem) {
        petMode.setEnabled(!petMode.isEnabled)
        sender.state = petMode.isEnabled ? .on : .off
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let current = launchAtLogin.isEnabled
        do {
            try launchAtLogin.setEnabled(!current)
        } catch {
            showAlert(title: "Could not update Launch at Login", text: error.localizedDescription)
        }
        sender.state = launchAtLogin.isEnabled ? .on : .off
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
    @objc private func selectState(_ sender: NSMenuItem) { stopCycling(); guard let raw = sender.representedObject as? String, let state = AnimationState(rawValue: raw) else { return }; manualMode = true; petMode.yieldToHigherPriorityDriver(); animator.play(state); refreshManualIndicator() }
    @objc private func toggleCycle(_ sender: NSMenuItem) { cycleTimer == nil ? startCycling() : stopCycling() }
    private func startCycling() { manualMode = true; petMode.yieldToHigherPriorityDriver(); cycleItem.state = .on; refreshManualIndicator(); cycleTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in Task { @MainActor in guard let self, let index = self.animator.availableStates.firstIndex(of: self.animator.currentState) else { return }; let states = self.animator.availableStates; self.animator.play(states[(index + 1) % states.count]); self.refreshManualIndicator() } } }
    private func stopCycling() { cycleTimer?.invalidate(); cycleTimer = nil; cycleItem.state = .off }
    private func updateChecks(for state: AnimationState) { for (candidate, item) in stateItems { item.state = candidate == state ? .on : .off } }
    @objc private func selectScale(_ sender: NSMenuItem) {
        guard let factor = sender.representedObject as? Double,
              let scale = PetScale(rawValue: factor) else { return }
        panel?.apply(scale: scale)
        updateScaleChecks(for: scale)
    }
    private func updateScaleChecks(for scale: PetScale) { for (candidate, item) in scaleItems { item.state = candidate == scale ? .on : .off } }
    @objc private func resetPosition() { panel?.resetPosition() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
