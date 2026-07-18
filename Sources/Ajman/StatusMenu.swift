import AppKit

@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private final class PetActionSelection: NSObject {
        let petID: String
        let action: PetCycleAction

        init(petID: String, action: PetCycleAction) {
            self.petID = petID
            self.action = action
        }
    }

    private let registry: SessionRegistry
    private let statusItem: NSStatusItem
    private let launchAtLogin = LaunchAtLogin()
    private let activityItem = NSMenuItem(title: "Agents: Idle — 0 sessions", action: nil, keyEquivalent: "")
    private let cycleItem = NSMenuItem(title: "Cycle All States", action: #selector(toggleCycle(_:)), keyEquivalent: "")
    private let agentNotificationsItem = NSMenuItem(
        title: "Show agent notifications", action: #selector(toggleAgentNotifications(_:)), keyEquivalent: ""
    )
    private let claudeConnectionItem = NSMenuItem(
        title: "Hear Claude Code", action: #selector(toggleClaudeConnection(_:)), keyEquivalent: ""
    )
    private let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
    private let updateChecksItem = NSMenuItem(title: "Check for updates", action: #selector(toggleUpdateChecks(_:)), keyEquivalent: "")
    private let petMenu = NSMenu(title: "Pets")
    private let debugMenu = NSMenu(title: "Actions")
    private var scaleItems: [PetScale: NSMenuItem] = [:]
    private var relativeScaleItems: [String: [Double: NSMenuItem]] = [:]
    private var temperamentItems: [String: [Temperament: NSMenuItem]] = [:]
    private var pets: [PetDescriptor]
    private var shownPetIDs: Set<String>
    private var directActionsByPetID: [String: [PetCycleAction]]
    private var temperaments: [String: Temperament]
    private var debugStates: [AnimationState]
    private var cycleTimer: Timer?
    private var cycleState: AnimationState?
    private var manualAction: PetCycleAction?
    private let claudeSettingsPath: URL

    private(set) var manualMode = false

    var showPetHandler: ((String, Bool) -> Void)?
    var bindingHandler: ((String, AgentEvent.Provider?) -> Void)?
    var scaleHandler: ((PetScale) -> Void)?
    var relativeScaleHandler: ((String, Double) -> Void)?
    var temperamentHandler: ((String, Temperament) -> Void)?
    var agentNotificationsHandler: ((Bool) -> Void)?
    var petActionHandler: ((String, PetCycleAction) -> Void)?
    var debugStateHandler: ((AnimationState) -> Void)?
    var resumeLiveHandler: (() -> Void)?
    var resetPositionsHandler: (() -> Void)?
    var previewUpdateHandler: (() -> Void)?
    var updateChecksHandler: ((Bool) -> Void)?

    init(
        registry: SessionRegistry,
        pets: [PetDescriptor],
        shownPetIDs: Set<String>,
        bindings: [String: AgentEvent.Provider?],
        relativeScales: [String: Double],
        temperaments: [String: Temperament],
        debugStates: [AnimationState],
        directActionsByPetID: [String: [PetCycleAction]],
        agentNotificationsEnabled: Bool,
        claudeSettingsPath: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    ) {
        self.registry = registry
        self.pets = pets
        self.shownPetIDs = shownPetIDs
        self.directActionsByPetID = directActionsByPetID
        self.temperaments = temperaments
        self.debugStates = debugStates
        self.claudeSettingsPath = claudeSettingsPath
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.title = ""
            button.image = Self.makeStatusIcon()
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = "Ajman"
        }
        let menu = NSMenu()
        menu.delegate = self
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

        agentNotificationsItem.target = self
        agentNotificationsItem.state = agentNotificationsEnabled ? .on : .off
        menu.addItem(agentNotificationsItem)
        claudeConnectionItem.target = self
        updateClaudeConnectionCheck()
        menu.addItem(claudeConnectionItem)
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
        if LaunchAtLogin.isSupported {
            launchAtLoginItem.target = self
            launchAtLoginItem.state = launchAtLogin.isEnabled ? .on : .off
            menu.addItem(launchAtLoginItem)
        }
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
        temperaments: [String: Temperament],
        debugStates: [AnimationState],
        directActionsByPetID: [String: [PetCycleAction]]
    ) {
        rebuildPetMenu(
            pets: pets,
            shownPetIDs: shownPetIDs,
            bindings: bindings,
            relativeScales: relativeScales
        )
        self.pets = pets
        self.shownPetIDs = shownPetIDs
        self.directActionsByPetID = directActionsByPetID
        self.temperaments = temperaments
        if self.debugStates != debugStates {
            self.debugStates = debugStates
            stopCycling()
            if manualMode, cycleState.map({ !debugStates.contains($0) }) ?? true {
                cycleState = debugStates.first
                if let cycleState { debugStateHandler?(cycleState) }
            }
        }
        rebuildDebugMenu()
        refreshActivityIndicator()
    }

    func updateActivity(state: AnimationState, sessionCount: Int) {
        guard !manualMode else { return }
        activityItem.title = "Agents: \(state.title) — \(sessionCount) session\(sessionCount == 1 ? "" : "s")"
    }

    /// Opens the existing status-item menu for Finder/Dock reopen requests.
    func presentForApplicationReopen() {
        statusItem.button?.performClick(nil)
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
        temperamentItems.removeAll()
        for pet in pets where shownPetIDs.contains(pet.id) {
            let actionsMenu = NSMenu(title: pet.displayName)
            for action in directActionsByPetID[pet.id] ?? [] {
                let item = NSMenuItem(
                    title: action.menuTitle,
                    action: #selector(selectPetAction(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = PetActionSelection(petID: pet.id, action: action)
                actionsMenu.addItem(item)
            }
            let petItem = NSMenuItem(title: pet.displayName, action: nil, keyEquivalent: "")
            petItem.submenu = actionsMenu
            debugMenu.addItem(petItem)
        }
        debugMenu.addItem(.separator())
        for pet in pets {
            let temperamentMenu = NSMenu(title: "\(pet.displayName) Temperament")
            let current = temperaments[pet.id] ?? Temperament.defaultValue(for: pet.id)
            var items: [Temperament: NSMenuItem] = [:]
            for temperament in Temperament.allCases {
                let item = NSMenuItem(
                    title: temperament.title,
                    action: #selector(selectTemperament(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = [pet.id, temperament.rawValue]
                item.state = temperament == current ? .on : .off
                temperamentMenu.addItem(item)
                items[temperament] = item
            }
            temperamentItems[pet.id] = items
            let temperamentItem = NSMenuItem(title: "\(pet.displayName) Temperament", action: nil, keyEquivalent: "")
            temperamentItem.submenu = temperamentMenu
            debugMenu.addItem(temperamentItem)
        }
        debugMenu.addItem(.separator())
        cycleItem.target = self
        debugMenu.addItem(cycleItem)
        let resume = NSMenuItem(title: "Resume Live Reactions", action: #selector(resumeLiveReactions), keyEquivalent: "")
        resume.target = self
        debugMenu.addItem(resume)
        debugMenu.addItem(.separator())
        let previewUpdate = NSMenuItem(
            title: "Preview update bubble", action: #selector(previewUpdateBubble), keyEquivalent: ""
        )
        previewUpdate.target = self
        debugMenu.addItem(previewUpdate)
        updateChecksItem.target = self
        updateChecksItem.state = UpdatePreferences().promptsEnabled ? .on : .off
        debugMenu.addItem(updateChecksItem)
        updateDebugChecks()
    }

    private func refreshActivityIndicator() {
        if manualMode {
            let title = manualAction?.menuTitle ?? cycleState?.title ?? "Actions"
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

    @objc private func selectTemperament(_ sender: NSMenuItem) {
        guard let values = sender.representedObject as? [String], values.count == 2,
              let temperament = Temperament(rawValue: values[1]) else { return }
        temperaments[values[0]] = temperament
        temperamentHandler?(values[0], temperament)
        for (candidate, item) in temperamentItems[values[0]] ?? [:] {
            item.state = candidate == temperament ? .on : .off
        }
    }

    @objc private func toggleAgentNotifications(_ sender: NSMenuItem) {
        let enabled = sender.state != .on
        sender.state = enabled ? .on : .off
        agentNotificationsHandler?(enabled)
    }

    @objc private func selectPetAction(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? PetActionSelection else { return }
        stopCycling()
        manualMode = true
        manualAction = selection.action
        cycleState = nil
        petActionHandler?(selection.petID, selection.action)
        refreshActivityIndicator()
    }

    @objc private func toggleCycle(_ sender: NSMenuItem) {
        cycleTimer == nil ? startCycling() : stopCycling()
    }

    private func startCycling() {
        guard !debugStates.isEmpty else { return }
        manualMode = true
        manualAction = nil
        cycleItem.state = .on
        playNextDebugState()
        cycleTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.playNextDebugState() }
        }
        refreshActivityIndicator()
    }

    private func playNextDebugState() {
        guard let state = PetActionCycle.next(after: cycleState, availableStates: debugStates) else { return }
        cycleState = state
        debugStateHandler?(state)
        updateDebugChecks()
    }

    private func stopCycling() {
        cycleTimer?.invalidate()
        cycleTimer = nil
        cycleItem.state = .off
    }

    @objc private func resumeLiveReactions() {
        stopCycling()
        manualMode = false
        manualAction = nil
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
        cycleItem.state = cycleTimer == nil ? .off : .on
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

    func updateChecksEnabled(_ enabled: Bool) {
        updateChecksItem.state = enabled ? .on : .off
    }

    func refreshLaunchAtLoginState() {
        launchAtLoginItem.state = launchAtLogin.isEnabled ? .on : .off
    }

    @objc private func previewUpdateBubble() { previewUpdateHandler?() }

    @objc private func toggleUpdateChecks(_ sender: NSMenuItem) {
        let enabled = sender.state != .on
        sender.state = enabled ? .on : .off
        updateChecksHandler?(enabled)
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            try launchAtLogin.setEnabled(!launchAtLogin.isEnabled)
        } catch {
            showAlert(title: "Could not update Launch at Login", text: error.localizedDescription)
        }
        sender.state = launchAtLogin.isEnabled ? .on : .off
    }

    @objc private func toggleClaudeConnection(_ sender: NSMenuItem) {
        if ClaudeHookInstaller.isInstalled(settingsPath: claudeSettingsPath) {
            disconnectFromClaude()
        } else {
            connectToClaude()
        }
        updateClaudeConnectionCheck()
    }

    private func connectToClaude() {
        do {
            let binary = try ClaudeHookInstaller.installHookBinary()
            let summary = try ClaudeHookInstaller.install(settingsPath: claudeSettingsPath, hookBinaryPath: binary.path)
            showAlert(title: "Claude Code connected", text: "Added \(summary.eventsAdded.count) event hooks.\nBackup: \(summary.backupPath ?? "new settings file; no original to back up")")
        } catch { showAlert(title: "Could not connect", text: error.localizedDescription) }
    }

    private func disconnectFromClaude() {
        do {
            let summary = try ClaudeHookInstaller.uninstall(settingsPath: claudeSettingsPath)
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

    func menuWillOpen(_ menu: NSMenu) {
        updateClaudeConnectionCheck()
    }

    private func updateClaudeConnectionCheck() {
        claudeConnectionItem.state = ClaudeHookInstaller.isInstalled(settingsPath: claudeSettingsPath) ? .on : .off
    }

    private static func makeStatusIcon() -> NSImage {
        let pointSize = NSSize(width: 18, height: 18)
        let scale = 2
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pointSize.width) * scale,
            pixelsHigh: Int(pointSize.height) * scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            let image = NSImage(size: pointSize)
            image.isTemplate = true
            return image
        }

        bitmap.size = pointSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        NSColor.black.setFill()
        NSColor.black.setStroke()

        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: 12.5, y: 5))
        tail.curve(
            to: NSPoint(x: 16.2, y: 10.4),
            controlPoint1: NSPoint(x: 16.4, y: 4.2),
            controlPoint2: NSPoint(x: 17.4, y: 7.7)
        )
        tail.lineWidth = 2.2
        tail.lineCapStyle = .round
        tail.stroke()

        NSBezierPath(ovalIn: NSRect(x: 4.2, y: 2.1, width: 10.2, height: 10.6)).fill()
        NSBezierPath(ovalIn: NSRect(x: 3.8, y: 8.2, width: 10.4, height: 7.5)).fill()

        let leftEar = NSBezierPath()
        leftEar.move(to: NSPoint(x: 4.6, y: 12.7))
        leftEar.line(to: NSPoint(x: 5.3, y: 17))
        leftEar.line(to: NSPoint(x: 8.1, y: 14.6))
        leftEar.close()
        leftEar.fill()

        let rightEar = NSBezierPath()
        rightEar.move(to: NSPoint(x: 10, y: 14.7))
        rightEar.line(to: NSPoint(x: 12.8, y: 17))
        rightEar.line(to: NSPoint(x: 13.5, y: 12.7))
        rightEar.close()
        rightEar.fill()
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: pointSize)
        image.addRepresentation(bitmap)
        image.isTemplate = true
        return image
    }

    var topLevelMenuTitlesForTesting: [String] { statusItem.menu?.items.map(\.title) ?? [] }
    var actionsTopLevelTitlesForTesting: [String] { debugMenu.items.map(\.title) }
    var actionsMenuTreeForTesting: [String: [String]] {
        Dictionary(uniqueKeysWithValues: debugMenu.items.compactMap { item in
            item.submenu.map { (item.title, $0.items.map(\.title)) }
        })
    }
    var statusIconProofForTesting: (isTemplate: Bool, pointSize: NSSize, pixelSize: NSSize?) {
        let image = statusItem.button?.image
        let bitmap = image?.representations.compactMap { $0 as? NSBitmapImageRep }.first
        let pixels = bitmap.map { NSSize(width: $0.pixelsWide, height: $0.pixelsHigh) }
        return (image?.isTemplate == true, image?.size ?? .zero, pixels)
    }
    func performPetActionForTesting(petID: String, action: PetCycleAction) {
        for petItem in debugMenu.items {
            guard let submenu = petItem.submenu else { continue }
            for item in submenu.items {
                guard let selection = item.representedObject as? PetActionSelection,
                      selection.petID == petID, selection.action == action else { continue }
                selectPetAction(item)
                return
            }
        }
    }
    var claudeConnectionStateForTesting: NSControl.StateValue { claudeConnectionItem.state }
    var agentNotificationsStateForTesting: NSControl.StateValue { agentNotificationsItem.state }
    func refreshClaudeConnectionStateForTesting() { updateClaudeConnectionCheck() }

    deinit { cycleTimer?.invalidate() }
}
