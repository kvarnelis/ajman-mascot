import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var pets: [PetInstance] = []
    private var statusMenu: StatusMenu?
    private var registry: SessionRegistry?
    private var server: UDSServer?
    private var codexMonitor: CodexMonitor?
    private var catalog: PetCatalog?
    private var configuration: MenagerieConfiguration?
    private var discoveredPets: [PetDescriptor] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let catalog = PetCatalog()
            let configuration = MenagerieConfiguration()
            let registry = SessionRegistry()
            let server = UDSServer()
            let codexMonitor = CodexMonitor()
            let descriptors = catalog.discover()

            self.catalog = catalog
            self.configuration = configuration
            self.registry = registry
            self.server = server
            self.codexMonitor = codexMonitor
            discoveredPets = descriptors

            let shown = configuration.shownPetIDs
            let ordered = orderedShownPets(from: descriptors, shownIDs: shown)
            for descriptor in ordered {
                do {
                    let instance = try makePet(
                        id: descriptor.id,
                        simultaneousCount: ordered.count
                    )
                    pets.append(instance)
                    instance.show(useLegacyPositionFallback: ordered.count == 1)
                } catch {
                    log("could not show pet '\(descriptor.id)': \(error.localizedDescription)")
                }
            }

            let menu = StatusMenu(
                registry: registry,
                pets: descriptors,
                shownPetIDs: shown,
                bindings: bindingMap(),
                relativeScales: relativeScaleMap(),
                debugStates: commonDebugStates(),
                playfulIdleEnabled: UserDefaults.standard.object(forKey: PetMode.defaultsKey) as? Bool ?? true
            )
            statusMenu = menu
            wireMenu(menu)

            registry.didChange = { [weak self] state, count in
                guard let self else { return }
                self.statusMenu?.updateActivity(state: state, sessionCount: count)
                for pet in self.pets {
                    pet.applyState(registry.currentState(for: pet.binding))
                }
            }
            registry.notificationDidChange = { [weak self] change in
                self?.pets.forEach { $0.apply(notificationChange: change) }
            }
            server.eventHandler = { event in
                Task { @MainActor in registry.apply(event) }
            }
            try server.start()
            codexMonitor.eventHandler = { event in
                Task { @MainActor in registry.apply(event) }
            }
            codexMonitor.start()
        } catch {
            pets.forEach { $0.teardown() }
            pets.removeAll()
            let alert = NSAlert()
            alert.messageText = "Ajman could not start."
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.runModal()
            NSApplication.shared.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        codexMonitor?.stop()
        server?.stop()
        pets.forEach { $0.teardown() }
        pets.removeAll()
    }

    private func wireMenu(_ menu: StatusMenu) {
        menu.showPetHandler = { [weak self] id, shown in self?.setPet(id: id, shown: shown) }
        menu.bindingHandler = { [weak self] id, provider in self?.setBinding(provider, for: id) }
        menu.scaleHandler = { [weak self] scale in
            scale.save()
            self?.pets.forEach { $0.setScale(scale) }
        }
        menu.relativeScaleHandler = { [weak self] id, scale in
            self?.catalog?.saveRelativeScale(scale, for: id)
            self?.pets.first(where: { $0.petID == id })?.setRelativeScale(scale)
        }
        menu.steadySizeHandler = { [weak self] enabled in
            self?.pets.forEach { pet in
                do { try pet.setSteadySize(enabled) }
                catch { self?.log("could not re-prepare pet '\(pet.petID)': \(error.localizedDescription)") }
            }
        }
        menu.playfulIdleHandler = { [weak self] enabled in
            self?.pets.forEach { $0.setPlayfulIdle(enabled) }
        }
        menu.debugStateHandler = { [weak self] state in
            self?.pets.forEach { $0.setDebugState(state) }
        }
        menu.resumeLiveHandler = { [weak self] in
            guard let self, let registry = self.registry else { return }
            for pet in self.pets {
                pet.applyState(registry.currentState(for: pet.binding))
                pet.resumeLiveReactions()
            }
        }
        menu.resetPositionsHandler = { [weak self] in
            self?.pets.forEach { $0.resetPosition() }
        }
    }

    private func setPet(id: String, shown: Bool) {
        guard let configuration else { return }
        if shown {
            guard !pets.contains(where: { $0.petID == id }) else { return }
            do {
                let targetCount = pets.count + 1
                let instance = try makePet(id: id, simultaneousCount: targetCount)
                pets.append(instance)
                updateDefaultPositionSlots()
                configuration.setShown(true, petID: id)
                instance.show(useLegacyPositionFallback: targetCount == 1)
                applyCurrentStateAndNotifications(to: instance)
                if let state = statusMenu?.debugState { instance.setDebugState(state) }
            } catch {
                log("could not show pet '\(id)': \(error.localizedDescription)")
            }
        } else {
            configuration.setShown(false, petID: id)
            if let index = pets.firstIndex(where: { $0.petID == id }) {
                pets.remove(at: index).teardown()
            }
            updateDefaultPositionSlots()
        }
        refreshMenu()
    }

    private func setBinding(_ provider: AgentEvent.Provider?, for id: String) {
        guard let configuration else { return }
        configuration.setBinding(provider, for: id)
        if let pet = pets.first(where: { $0.petID == id }) {
            pet.setBinding(provider)
            applyCurrentStateAndNotifications(to: pet)
        }
        refreshMenu()
    }

    private func makePet(id: String, simultaneousCount: Int) throws -> PetInstance {
        guard let catalog, let configuration, let registry else {
            throw StartupError.notReady
        }
        return try PetInstance(
            petID: id,
            binding: configuration.binding(for: id),
            catalog: catalog,
            scale: PetScale.load(),
            defaultPositionIndex: simultaneousCount == 1 ? 0 : defaultPositionIndex(for: id),
            isManualMode: { [weak self] in self?.statusMenu?.manualMode ?? false },
            dismissNotification: { [weak registry] id in registry?.dismissNotification(id: id) }
        )
    }

    private func applyCurrentStateAndNotifications(to pet: PetInstance) {
        guard let registry else { return }
        pet.applyState(registry.currentState(for: pet.binding))
        for notification in registry.currentNotifications(for: pet.binding) {
            pet.apply(notificationChange: .upsert(notification))
        }
    }

    private func refreshMenu() {
        guard let configuration else { return }
        statusMenu?.refreshMenagerie(
            pets: discoveredPets,
            shownPetIDs: configuration.shownPetIDs,
            bindings: bindingMap(),
            relativeScales: relativeScaleMap(),
            debugStates: commonDebugStates()
        )
    }

    private func bindingMap() -> [String: AgentEvent.Provider?] {
        guard let configuration else { return [:] }
        var result: [String: AgentEvent.Provider?] = [:]
        for descriptor in discoveredPets {
            result.updateValue(configuration.binding(for: descriptor.id), forKey: descriptor.id)
        }
        return result
    }

    private func relativeScaleMap() -> [String: Double] {
        guard let catalog else { return [:] }
        return Dictionary(uniqueKeysWithValues: discoveredPets.map { ($0.id, catalog.relativeScale(for: $0.id)) })
    }

    private func commonDebugStates() -> [AnimationState] {
        guard !pets.isEmpty else { return AnimationState.allCases }
        return AnimationState.allCases.filter { state in
            pets.allSatisfy { $0.availableStates.contains(state) }
        }
    }

    private func updateDefaultPositionSlots() {
        for pet in pets {
            pet.setDefaultPositionIndex(pets.count == 1 ? 0 : defaultPositionIndex(for: pet.petID))
        }
    }

    private func orderedShownPets(from descriptors: [PetDescriptor], shownIDs: Set<String>) -> [PetDescriptor] {
        descriptors.filter { shownIDs.contains($0.id) }.sorted {
            let left = defaultPositionIndex(for: $0.id)
            let right = defaultPositionIndex(for: $1.id)
            return left == right ? $0.displayName < $1.displayName : left < right
        }
    }

    private func defaultPositionIndex(for id: String) -> Int {
        switch id {
        case "ajman": return 0
        case "winnie": return 1
        default:
            let others = discoveredPets.filter { $0.id != "ajman" && $0.id != "winnie" }
            return 2 + (others.firstIndex(where: { $0.id == id }) ?? others.count)
        }
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("Ajman: \(message)\n".utf8))
    }

    private enum StartupError: LocalizedError {
        case notReady
        var errorDescription: String? { "The menagerie was not ready to build a pet." }
    }
}
