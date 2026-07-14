import AppKit

@MainActor
final class StatusMenu: NSObject {
    private let registry: SessionRegistry
    private let statusItem: NSStatusItem
    private let launchAtLogin = LaunchAtLogin()
    private let activityItem = NSMenuItem(title: "Agents: Idle — 0 sessions", action: nil, keyEquivalent: "")
    private let cycleItem = NSMenuItem(title: "Cycle All States", action: #selector(toggleCycle(_:)), keyEquivalent: "")
    private let sleepItem = NSMenuItem(title: "Sleep", action: #selector(selectSleep(_:)), keyEquivalent: "")
    private let scratchItem = NSMenuItem(title: "Scratch", action: #selector(selectScratch(_:)), keyEquivalent: "")
    private let playfulIdleItem = NSMenuItem(title: "Playful Idle", action: #selector(togglePlayfulIdle(_:)), keyEquivalent: "")
    private let steadySizeItem = NSMenuItem(title: "Steady Size", action: #selector(toggleSteadySize(_:)), keyEquivalent: "")
    private let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
    private let petMenu = NSMenu(title: "Pets")
    private let debugMenu = NSMenu(title: "Actions")
    private var scaleItems: [PetScale: NSMenuItem] = [:]
    private var relativeScaleItems: [String: [Double: NSMenuItem]] = [:]
    private var stateItems: [AnimationState: NSMenuItem] = [:]
    private var debugStates: [AnimationState]
    private var sleepAvailable: Bool
    private var cycleTimer: Timer?
    private var cycleState: AnimationState?
    private var playfulIdleEnabled: Bool

    private(set) var manualMode = false
    private(set) var manualSleep = false
    private(set) var manualScratch = false
    var debugState: AnimationState? { manualMode && !manualSleep && !manualScratch ? cycleState : nil }

    var showPetHandler: ((String, Bool) -> Void)?
    var bindingHandler: ((String, AgentEvent.Provider?) -> Void)?
    var scaleHandler: ((PetScale) -> Void)?
    var relativeScaleHandler: ((String, Double) -> Void)?
    var steadySizeHandler: ((Bool) -> Void)?
    var playfulIdleHandler: ((Bool) -> Void)?
    var debugStateHandler: ((AnimationState) -> Void)?
    var debugSleepHandler: (() -> Void)?
    var debugScratchHandler: (() -> Void)?
    var resumeLiveHandler: (() -> Void)?
    var resetPositionsHandler: (() -> Void)?

    init(
        registry: SessionRegistry,
        pets: [PetDescriptor],
        shownPetIDs: Set<String>,
        bindings: [String: AgentEvent.Provider?],
        relativeScales: [String: Double],
        debugStates: [AnimationState],
        sleepAvailable: Bool,
        playfulIdleEnabled: Bool
    ) {
        self.registry = registry
        self.debugStates = debugStates
        self.sleepAvailable = sleepAvailable
        self.playfulIdleEnabled = playfulIdleEnabled
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.title = "🐈‍⬛"
        let menu = NSMenu()
        activityItem.isEnabled = false
        menu.addItem(activityItem)

        rebuildPetMenu(
            pets: pets,
            shownPetIDs: shownPetIDs,
            bindings: bindings,
            relativeScales: relativeScales
        )
        let petsItem = NSMenuItem(title: "Pets", action: nil, keyEquivalent: "")
        petsItem.submenu = petMenu
        menu.addItem(petsItem)

        playfulIdleItem.target = self
        playfulIdleItem.state = playfulIdleEnabled ? .on : .off
        menu.addItem(playfulIdleItem)
        steadySizeItem.target = self
        steadySizeItem.state = SteadySize.load() ? .on : .off
        menu.addItem(steadySizeItem)
        menu.addItem(.separator())

        let connect = NSMenuItem(title: "Connect to Claude Code", action: #selector(connectToClaude), keyEquivalent: "")
        connect.target = self
        menu.addItem(connect)
        let disconnect = NSMenuItem(title: "Disconnect from Claude Code", action: #selector(disconnectFromClaude), keyEquivalent: "")
        disconnect.target = self
        menu.addItem(disconnect)
        menu.addItem(.separator())

        let sizeMenu = NSMenu(title: "Overall Size")
        for scale in PetScale.allCases {
            let item = NSMenuItem(title: scale.menuTitle, action: #selector(selectScale(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = scale.rawValue
            sizeMenu.addItem(item)
            scaleItems[scale] = item
        }
        let sizeItem = NSMenuItem(title: "Overall Size", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        rebuildDebugMenu()
        let debugItem = NSMenuItem(title: "Actions", action: nil, keyEquivalent: "")
        debugItem.submenu = debugMenu
        menu.addItem(debugItem)

        let reset = NSMenuItem(title: "Reset Position", action: #selector(resetPosition), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        launchAtLoginItem.target = self
        launchAtLoginItem.state = launchAtLogin.isEnabled ? .on : .off
        menu.addItem(launchAtLoginItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Ajman", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu

        updateScaleChecks(for: PetScale.load())
    }

    func refreshMenagerie(
        pets: [PetDescriptor],
        shownPetIDs: Set<String>,
        bindings: [String: AgentEvent.Provider?],
        relativeScales: [String: Double],
        debugStates: [AnimationState],
        sleepAvailable: Bool
    ) {
        rebuildPetMenu(
            pets: pets,
            shownPetIDs: shownPetIDs,
            bindings: bindings,
            relativeScales: relativeScales
        )
        if self.debugStates != debugStates || self.sleepAvailable != sleepAvailable {
            self.debugStates = debugStates
            self.sleepAvailable = sleepAvailable
            stopCycling()
            if manualMode, !manualSleep, !manualScratch,
               cycleState.map({ !debugStates.contains($0) }) ?? true {
                cycleState = debugStates.first
                if let cycleState { debugStateHandler?(cycleState) }
            }
            if manualSleep, !sleepAvailable {
                manualSleep = false
                manualMode = false
                cycleState = nil
                resumeLiveHandler?()
            }
            rebuildDebugMenu()
        }
        refreshActivityIndicator()
    }

    func updateActivity(state: AnimationState, sessionCount: Int) {
        guard !manualMode else { return }
        activityItem.title = "Agents: \(state.title) — \(sessionCount) session\(sessionCount == 1 ? "" : "s")"
    }

    private func rebuildPetMenu(
        pets: [PetDescriptor],
        shownPetIDs: Set<String>,
        bindings: [String: AgentEvent.Provider?],
        relativeScales: [String: Double]
    ) {
        petMenu.removeAllItems()
        relativeScaleItems.removeAll()
        for pet in pets {
            let submenu = NSMenu(title: pet.displayName)
            let show = NSMenuItem(title: "Show on desktop", action: #selector(togglePet(_:)), keyEquivalent: "")
            show.target = self
            show.representedObject = pet.id
            show.state = shownPetIDs.contains(pet.id) ? .on : .off
            submenu.addItem(show)

            let reactsMenu = NSMenu(title: "Reacts to")
            let currentBinding = bindings[pet.id] ?? nil
            for binding in PetBinding.allCases {
                let item = NSMenuItem(title: binding.menuTitle, action: #selector(selectBinding(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = [pet.id, binding.rawValue]
                item.state = binding.provider == currentBinding ? .on : .off
                reactsMenu.addItem(item)
            }
            let reacts = NSMenuItem(title: "Reacts to", action: nil, keyEquivalent: "")
            reacts.submenu = reactsMenu
            submenu.addItem(reacts)

            let currentRelativeScale = relativeScales[pet.id] ?? PetCatalog.builtInRelativeScale(for: pet.id)
            let sizeMenu = NSMenu(title: "Size")
            var items: [Double: NSMenuItem] = [:]
            for scale in relativeScaleOptions(for: pet.id, current: currentRelativeScale) {
                let item = NSMenuItem(
                    title: relativeScaleTitle(scale, for: pet.id, current: currentRelativeScale),
                    action: #selector(selectRelativeScale(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = [pet.id, String(scale)]
                item.state = scale == currentRelativeScale ? .on : .off
                sizeMenu.addItem(item)
                items[scale] = item
            }
            relativeScaleItems[pet.id] = items
            let size = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
            size.submenu = sizeMenu
            submenu.addItem(size)

            let item = NSMenuItem(title: pet.displayName, action: nil, keyEquivalent: "")
            item.submenu = submenu
            petMenu.addItem(item)
        }
    }

    private func rebuildDebugMenu() {
        debugMenu.removeAllItems()
        stateItems.removeAll()
        for state in debugStates {
            let item = NSMenuItem(title: state.title, action: #selector(selectState(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = state.rawValue
            debugMenu.addItem(item)
            stateItems[state] = item
        }
        if sleepAvailable {
            sleepItem.target = self
            debugMenu.addItem(sleepItem)
        }
        scratchItem.target = self
        debugMenu.addItem(scratchItem)
        debugMenu.addItem(.separator())
        cycleItem.target = self
        debugMenu.addItem(cycleItem)
        let resume = NSMenuItem(title: "Resume Live Reactions", action: #selector(resumeLiveReactions), keyEquivalent: "")
        resume.target = self
        debugMenu.addItem(resume)
        updateDebugChecks()
    }

    private func refreshActivityIndicator() {
        if manualMode {
            let title = manualSleep ? "Sleep" : manualScratch ? "Scratch" : cycleState?.title ?? "Actions"
            activityItem.title = "Manual: \(title) — live paused"
        } else {
            updateActivity(state: registry.currentState(for: nil), sessionCount: registry.sessionCount(for: nil))
        }
    }

    @objc private func togglePet(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        showPetHandler?(id, sender.state != .on)
    }

    @objc private func selectBinding(_ sender: NSMenuItem) {
        guard let values = sender.representedObject as? [String], values.count == 2,
              let binding = PetBinding(rawValue: values[1]) else { return }
        bindingHandler?(values[0], binding.provider)
    }

    @objc private func selectScale(_ sender: NSMenuItem) {
        guard let factor = sender.representedObject as? Double,
              let scale = PetScale(rawValue: factor) else { return }
        scaleHandler?(scale)
        updateScaleChecks(for: scale)
    }

    @objc private func selectRelativeScale(_ sender: NSMenuItem) {
        guard let values = sender.representedObject as? [String], values.count == 2,
              let scale = Double(values[1]) else { return }
        relativeScaleHandler?(values[0], scale)
        updateRelativeScaleChecks(for: values[0], scale: scale)
    }

    @objc private func toggleSteadySize(_ sender: NSMenuItem) {
        let enabled = sender.state != .on
        SteadySize.save(enabled)
        sender.state = enabled ? .on : .off
        steadySizeHandler?(enabled)
    }

    @objc private func togglePlayfulIdle(_ sender: NSMenuItem) {
        playfulIdleEnabled.toggle()
        UserDefaults.standard.set(playfulIdleEnabled, forKey: PetMode.defaultsKey)
        sender.state = playfulIdleEnabled ? .on : .off
        playfulIdleHandler?(playfulIdleEnabled)
    }

    @objc private func selectState(_ sender: NSMenuItem) {
        stopCycling()
        guard let raw = sender.representedObject as? String,
              let state = AnimationState(rawValue: raw) else { return }
        manualMode = true
        manualSleep = false
        manualScratch = false
        cycleState = state
        debugStateHandler?(state)
        updateDebugChecks()
        refreshActivityIndicator()
    }

    @objc private func toggleCycle(_ sender: NSMenuItem) {
        cycleTimer == nil ? startCycling() : stopCycling()
    }

    private func startCycling() {
        guard !debugStates.isEmpty else { return }
        manualMode = true
        manualSleep = false
        manualScratch = false
        cycleItem.state = .on
        playNextDebugState()
        cycleTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.playNextDebugState() }
        }
        refreshActivityIndicator()
    }

    private func playNextDebugState() {
        let currentIndex = cycleState.flatMap(debugStates.firstIndex(of:)) ?? -1
        let state = debugStates[(currentIndex + 1) % debugStates.count]
        cycleState = state
        debugStateHandler?(state)
        updateDebugChecks()
    }

    private func stopCycling() {
        cycleTimer?.invalidate()
        cycleTimer = nil
        cycleItem.state = .off
    }

    @objc private func selectSleep(_ sender: NSMenuItem) {
        guard sleepAvailable else { return }
        stopCycling()
        manualMode = true
        manualSleep = true
        manualScratch = false
        cycleState = nil
        debugSleepHandler?()
        updateDebugChecks()
        refreshActivityIndicator()
    }

    @objc private func selectScratch(_ sender: NSMenuItem) {
        stopCycling()
        manualMode = true
        manualSleep = false
        manualScratch = true
        cycleState = nil
        debugScratchHandler?()
        updateDebugChecks()
        refreshActivityIndicator()
    }

    @objc private func resumeLiveReactions() {
        stopCycling()
        manualMode = false
        manualSleep = false
        manualScratch = false
        cycleState = nil
        updateDebugChecks()
        resumeLiveHandler?()
        refreshActivityIndicator()
    }

    func resumeLiveReactionsIfManual() {
        guard manualMode else { return }
        resumeLiveReactions()
    }

    private func updateDebugChecks() {
        for (state, item) in stateItems { item.state = state == cycleState && manualMode ? .on : .off }
        sleepItem.state = manualMode && manualSleep ? .on : .off
        scratchItem.state = manualMode && manualScratch ? .on : .off
    }

    private func updateScaleChecks(for scale: PetScale) {
        for (candidate, item) in scaleItems { item.state = candidate == scale ? .on : .off }
    }

    private func updateRelativeScaleChecks(for id: String, scale: Double) {
        for (candidate, item) in relativeScaleItems[id] ?? [:] {
            item.state = candidate == scale ? .on : .off
        }
    }

    private func relativeScaleOptions(for id: String, current: Double) -> [Double] {
        let standard = [0.5, 0.67, 0.8, 1.0, 1.25, 1.5]
        return Array(Set(standard + [PetCatalog.builtInRelativeScale(for: id), current])).sorted()
    }

    private func relativeScaleTitle(_ scale: Double, for id: String, current: Double) -> String {
        let formatted = scale.formatted(.number.precision(.fractionLength(1...2))) + "×"
        if scale == PetCatalog.builtInRelativeScale(for: id) { return formatted + " (default)" }
        if scale == current, ![0.5, 0.67, 0.8, 1.0, 1.25, 1.5].contains(scale) {
            return formatted + " (current)"
        }
        return formatted
    }

    @objc private func resetPosition() {
        resetPositionsHandler?()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            try launchAtLogin.setEnabled(!launchAtLogin.isEnabled)
        } catch {
            showAlert(title: "Could not update Launch at Login", text: error.localizedDescription)
        }
        sender.state = launchAtLogin.isEnabled ? .on : .off
    }

    @objc private func connectToClaude() {
        do {
            let binary = try ClaudeHookInstaller.installHookBinary()
            let settings = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
            let summary = try ClaudeHookInstaller.install(settingsPath: settings, hookBinaryPath: binary.path)
            showAlert(title: "Claude Code connected", text: "Added \(summary.eventsAdded.count) event hooks.\nBackup: \(summary.backupPath ?? "new settings file; no original to back up")")
        } catch { showAlert(title: "Could not connect", text: error.localizedDescription) }
    }

    @objc private func disconnectFromClaude() {
        do {
            let settings = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
            let summary = try ClaudeHookInstaller.uninstall(settingsPath: settings)
            showAlert(title: "Claude Code disconnected", text: "Removed \(summary.commandsRemoved) Ajman hook commands.\nBackup: \(summary.backupPath)")
        } catch { showAlert(title: "Could not disconnect", text: error.localizedDescription) }
    }

    private func showAlert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }

    deinit { cycleTimer?.invalidate() }
}
