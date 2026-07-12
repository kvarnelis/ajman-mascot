import AppKit

@MainActor
private func runSelfTest() -> Int32 {
    let fileManager = FileManager.default
    let registry = SessionRegistry(startTimer: false)
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

        try invokeHook(event: "PreToolUse", tool: "Bash")
        guard pump(until: { registry.currentState == .running }) else { throw SelfTestError("PreToolUse did not produce running") }
        print("UDS transport: PreToolUse(Bash) -> running")
        try invokeHook(event: "Notification")
        guard pump(until: { registry.currentState == .waiting }) else { throw SelfTestError("Notification did not produce waiting") }
        print("UDS transport: Notification -> waiting")

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
        let sheet = try SpriteSheet.load()
        let table = sheet.animationTable
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
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
