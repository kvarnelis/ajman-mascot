import AppKit

@MainActor
private func runSelfTest() -> Int32 {
    let fileManager = FileManager.default
    let registry = SessionRegistry(startTimer: false)
    var notificationChanges: [PetNotificationChange] = []
    registry.notificationDidChange = { notificationChanges.append($0) }
    let selfTestSocket = URL(fileURLWithPath: "/tmp/ajman-selftest-\(UUID().uuidString.prefix(8)).sock")
    let server = UDSServer(socketURL: selfTestSocket)
    server.eventHandler = { event in Task { @MainActor in registry.apply(event) } }
    do { try server.start() } catch {
        print("SELFTEST FAIL: UDS start: \(error.localizedDescription)")
        return 1
    }
    defer { server.stop() }

    func pump(until predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline, !predicate() { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return predicate()
    }
    func invokeHook(event: String, tool: String? = nil) throws {
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("ajman-hook")
        let process = Process(); process.executableURL = binary
        process.environment = ProcessInfo.processInfo.environment.merging(["AJMAN_SOCKET_PATH": selfTestSocket.path]) { _, testValue in testValue }
        let pipe = Pipe(); process.standardInput = pipe; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        var json: [String: Any] = ["hook_event_name": event, "session_id": "selftest", "cwd": "/tmp"]
        if let tool { json["tool_name"] = tool }
        try process.run(); pipe.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: json)); try pipe.fileHandleForWriting.close(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.executableRuntimeMismatch) }
    }

    do {
        let suiteName = "AjmanSelfTest.PetScale.\(UUID().uuidString)"
        guard let scaleDefaults = UserDefaults(suiteName: suiteName) else { throw SelfTestError("could not create scale defaults") }
        defer { scaleDefaults.removePersistentDomain(forName: suiteName) }
        guard PetScale.load(from: scaleDefaults) == .small else { throw SelfTestError("scale default was not 0.5") }
        for scale in PetScale.allCases {
            scale.save(to: scaleDefaults)
            guard PetScale.load(from: scaleDefaults) == scale else { throw SelfTestError("scale did not round-trip: \(scale.rawValue)") }
        }
        print("Pet scale: default 0.5; all 6 options round-trip")

        let steadySuiteName = "AjmanSelfTest.SteadySize.\(UUID().uuidString)"
        guard let steadyDefaults = UserDefaults(suiteName: steadySuiteName) else { throw SelfTestError("could not create steady-size defaults") }
        defer { steadyDefaults.removePersistentDomain(forName: steadySuiteName) }
        guard SteadySize.load(from: steadyDefaults) else { throw SelfTestError("steady size was not on by default") }
        SteadySize.save(false, to: steadyDefaults)
        guard !SteadySize.load(from: steadyDefaults) else { throw SelfTestError("steady size did not persist off") }
        SteadySize.save(true, to: steadyDefaults)
        guard SteadySize.load(from: steadyDefaults) else { throw SelfTestError("steady size did not persist on") }
        print("Steady size: default on; off/on round-trip")

        let selectionSuiteName = "AjmanSelfTest.PetSelection.\(UUID().uuidString)"
        guard let selectionDefaults = UserDefaults(suiteName: selectionSuiteName) else { throw SelfTestError("could not create selection defaults") }
        defer { selectionDefaults.removePersistentDomain(forName: selectionSuiteName) }
        let catalog = PetCatalog(defaults: selectionDefaults)
        guard !catalog.discover().isEmpty else { throw SelfTestError("pet discovery found no readable packages") }
        guard catalog.selectedPetID == "ajman" else { throw SelfTestError("selected pet default was not ajman") }
        catalog.saveSelection("winnie")
        guard catalog.selectedPetID == "winnie" else { throw SelfTestError("selected pet did not round-trip") }
        guard catalog.relativeScale(for: "ajman") == 1.0, catalog.relativeScale(for: "winnie") == 0.8 else {
            throw SelfTestError("built-in relative pet scales were incorrect")
        }
        selectionDefaults.set(0.7, forKey: "AjmanPetScale.winnie")
        guard catalog.relativeScale(for: "winnie") == 0.7 else { throw SelfTestError("relative pet scale override did not persist") }
        print("Pet catalog: discovered \(catalog.discover().count); selection and relative scale override round-trip")

        let normalizationPetIDs = ["ajman", "winnie"].filter { id in
            catalog.discover().contains { $0.id == id }
        }
        for id in normalizationPetIDs {
            let steadySheet = try catalog.load(id: id, steadySize: true).sheet
            guard let idle = steadySheet.animationTable.definition(for: .idle) else { throw SelfTestError("\(id) idle definition missing") }
            let idleBounds = steadySheet.contentBounds(for: idle).compactMap { $0 }
            let idleHeights = idleBounds.map(\.height)
            guard idleBounds.count == idle.frameCount,
                  (idleHeights.max() ?? 0) - (idleHeights.min() ?? 0) <= 2,
                  idleBounds.allSatisfy({ abs($0.minY - CGFloat(SpriteSheet.contentMargin)) <= 1 }) else {
                throw SelfTestError("\(id) normalized idle frames did not share height/ground line: \(idleBounds)")
            }
            var checkedFrameCount = 0
            for definition in steadySheet.animationTable.definitions {
                let bounds = steadySheet.contentBounds(for: definition)
                guard bounds.count == definition.frameCount else {
                    throw SelfTestError("\(id) \(definition.state.rawValue) returned \(bounds.count)/\(definition.frameCount) normalized bounds")
                }
                for (column, frameBounds) in bounds.enumerated() {
                    guard let frameBounds else {
                        throw SelfTestError("\(id) \(definition.state.rawValue)[\(column)] has no normalized content")
                    }
                    guard frameBounds.minX >= 0, frameBounds.minY >= 0,
                          frameBounds.maxX <= CGFloat(SpriteSheet.cellWidth),
                          frameBounds.maxY <= CGFloat(SpriteSheet.cellHeight),
                          abs(frameBounds.minY - CGFloat(SpriteSheet.contentMargin)) <= 1 else {
                        throw SelfTestError("\(id) \(definition.state.rawValue)[\(column)] normalized content clips or missed ground line: \(frameBounds)")
                    }
                    checkedFrameCount += 1
                }
            }
            guard checkedFrameCount == steadySheet.animationTable.usedFrameCount else {
                throw SelfTestError("\(id) checked \(checkedFrameCount)/\(steadySheet.animationTable.usedFrameCount) used frames for clipping")
            }
            print("Sprite normalization \(id): all \(checkedFrameCount) used frames inside 192x208; ground line within 1 px")
        }
        print("Sprite normalization (\(normalizationPetIDs.joined(separator: ", "))): idle heights within 2 px; no clipping")

        try invokeHook(event: "PreToolUse", tool: "Bash")
        guard pump(until: { registry.currentState == .running }) else { throw SelfTestError("PreToolUse did not produce running") }
        print("UDS transport: PreToolUse(Bash) -> running")
        try invokeHook(event: "Notification")
        guard pump(until: { registry.currentState == .waiting }) else { throw SelfTestError("Notification did not produce waiting") }
        print("UDS transport: Notification -> waiting")
        guard case .upsert(let waiting)? = notificationChanges.last, waiting.kind == .waiting else {
            throw SelfTestError("Notification did not raise a waiting card")
        }
        try invokeHook(event: "PostToolUse", tool: "Bash")
        guard pump(until: {
            notificationChanges.contains { change in
                if case .dismiss(let id) = change { return id == waiting.id }
                return false
            }
        }) else { throw SelfTestError("follow-up event did not dismiss waiting card") }
        print("Bubble lifecycle: waiting card raised; PostToolUse dismissed it")

        let temp = fileManager.temporaryDirectory.appendingPathComponent("ajman-selftest-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temp) }
        try fileManager.createDirectory(at: temp, withIntermediateDirectories: true)
        let settings = temp.appendingPathComponent("settings.json")
        let userCommand = "/tmp/user-hook"
        let fixture: [String: Any] = ["theme": "dark", "hooks": ["PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": userCommand]]]]]]
        try JSONSerialization.data(withJSONObject: fixture, options: .prettyPrinted).write(to: settings)
        let hookPath = temp.appendingPathComponent("bin/ajman-hook").path
        let installed = try ClaudeHookInstaller.install(settingsPath: settings, hookBinaryPath: hookPath)
        let afterInstall = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        func containsCommand(_ value: Any, command: String) -> Bool {
            if let dictionary = value as? [String: Any] {
                if dictionary["command"] as? String == command { return true }
                return dictionary.values.contains { containsCommand($0, command: command) }
            }
            if let array = value as? [Any] { return array.contains { containsCommand($0, command: command) } }
            return false
        }
        let userSurvivedInstall = containsCommand(afterInstall, command: userCommand)
        let allEventsAdded = installed.eventsAdded.count == ClaudeHookInstaller.events.count
        let backupExists = installed.backupPath.map { fileManager.fileExists(atPath: $0) } == true
        guard userSurvivedInstall, allEventsAdded, backupExists else {
            throw SelfTestError("installer fixture assertions failed (user=\(userSurvivedInstall), events=\(installed.eventsAdded.count), backup=\(backupExists))")
        }
        print("Installer fixture: user hook preserved; 10 Ajman event groups added; backup exists")
        let uninstalled = try ClaudeHookInstaller.uninstall(settingsPath: settings)
        let afterUninstall = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        guard containsCommand(afterUninstall, command: userCommand), !containsCommand(afterUninstall, command: hookPath), uninstalled.commandsRemoved == 10 else { throw SelfTestError("uninstaller fixture assertions failed") }
        print("Uninstaller fixture: 10 Ajman commands removed; user hook preserved")
        print("SELFTEST OK")
        return 0
    } catch {
        print("SELFTEST FAIL: \(error.localizedDescription)")
        return 1
    }
}

private struct SelfTestError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

if CommandLine.arguments.contains("--selftest") { exit(MainActor.assumeIsolated { runSelfTest() }) }

if CommandLine.arguments.contains("--validate") {
    do {
        let loadedPet = try PetCatalog().loadSelected()
        let sheet = loadedPet.sheet
        let table = sheet.animationTable
        print("pet=\(loadedPet.descriptor.id)")
        print("source=\(sheet.sourceURL.path)")
        print("spriteVersionNumber=\(table.spriteVersionNumber)")
        print("usedFrames=\(table.usedFrameCount)")
        for definition in table.definitions {
            let milliseconds = definition.durations.map { String(Int(($0 * 1_000).rounded())) }.joined(separator: ",")
            print("row=\(definition.row) state=\(definition.state.rawValue) frames=\(definition.frameCount) ms=\(milliseconds)")
        }
        exit(EXIT_SUCCESS)
    } catch {
        FileHandle.standardError.write(Data("Ajman validation failed: \(error.localizedDescription)\n".utf8))
        exit(EXIT_FAILURE)
    }
}

if CommandLine.arguments.contains("--connect") {
    do {
        let hook = try ClaudeHookInstaller.installHookBinary()
        let settings = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        let summary = try ClaudeHookInstaller.install(settingsPath: settings, hookBinaryPath: hook.path)
        print("connected: hook=\(hook.path)")
        print("events added: \(summary.eventsAdded.isEmpty ? "(none — already present)" : summary.eventsAdded.joined(separator: ", "))")
        print("backup: \(summary.backupPath ?? "(none)")")
        exit(EXIT_SUCCESS)
    } catch {
        FileHandle.standardError.write(Data("connect failed: \(error.localizedDescription)\n".utf8))
        exit(EXIT_FAILURE)
    }
}

if CommandLine.arguments.contains("--disconnect") {
    do {
        let settings = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        let summary = try ClaudeHookInstaller.uninstall(settingsPath: settings)
        print("disconnected: removed \(summary.commandsRemoved) Ajman command(s); backup: \(summary.backupPath)")
        exit(EXIT_SUCCESS)
    } catch {
        FileHandle.standardError.write(Data("disconnect failed: \(error.localizedDescription)\n".utf8))
        exit(EXIT_FAILURE)
    }
}

let application = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
