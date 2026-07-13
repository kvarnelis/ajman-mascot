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
    func invokeHook(event: String, tool: String? = nil, fields: [String: Any] = [:]) throws {
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("ajman-hook")
        let process = Process(); process.executableURL = binary
        process.environment = ProcessInfo.processInfo.environment.merging(["AJMAN_SOCKET_PATH": selfTestSocket.path]) { _, testValue in testValue }
        let pipe = Pipe(); process.standardInput = pipe; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        var json: [String: Any] = ["hook_event_name": event, "session_id": "selftest", "cwd": "/tmp"]
        if let tool { json["tool_name"] = tool }
        for (key, value) in fields { json[key] = value }
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
        print("Pet scale: default 0.5; all \(PetScale.allCases.count) options round-trip")

        let steadySuiteName = "AjmanSelfTest.SteadySize.\(UUID().uuidString)"
        guard let steadyDefaults = UserDefaults(suiteName: steadySuiteName) else { throw SelfTestError("could not create steady-size defaults") }
        defer { steadyDefaults.removePersistentDomain(forName: steadySuiteName) }
        guard !SteadySize.load(from: steadyDefaults) else { throw SelfTestError("steady size was not off by default") }
        SteadySize.save(false, to: steadyDefaults)
        guard !SteadySize.load(from: steadyDefaults) else { throw SelfTestError("steady size did not persist off") }
        SteadySize.save(true, to: steadyDefaults)
        guard SteadySize.load(from: steadyDefaults) else { throw SelfTestError("steady size did not persist on") }
        print("Steady size: default off; off/on round-trip")

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
        catalog.saveRelativeScale(0.7, for: "winnie")
        guard catalog.relativeScale(for: "winnie") == 0.7 else { throw SelfTestError("relative pet scale override did not persist") }
        guard selectionDefaults.double(forKey: PetCatalog.relativeScaleKey(for: "winnie")) == 0.7 else {
            throw SelfTestError("relative pet scale override did not round-trip through AjmanPetScale.winnie")
        }
        catalog.saveRelativeScale(0.8, for: "winnie")
        let defaultEffectiveScale = PetScale.threeQuarter.rawValue * catalog.relativeScale(for: "winnie")
        guard abs(defaultEffectiveScale - 0.6) < 0.000_001 else {
            throw SelfTestError("effective pet scale was not overall × per-cat: \(defaultEffectiveScale)")
        }
        let formattedEffectiveScale = defaultEffectiveScale.formatted(.number.precision(.fractionLength(1)))
        print("Pet catalog: discovered \(catalog.discover().count); per-pet override round-trip; effective 0.75 × 0.8 = \(formattedEffectiveScale)")

        let menagerieSuiteName = "AjmanSelfTest.Menagerie.\(UUID().uuidString)"
        guard let menagerieDefaults = UserDefaults(suiteName: menagerieSuiteName) else {
            throw SelfTestError("could not create menagerie defaults")
        }
        defer { menagerieDefaults.removePersistentDomain(forName: menagerieSuiteName) }
        var menagerie = MenagerieConfiguration(defaults: menagerieDefaults)
        guard menagerie.shownPetIDs == ["ajman", "winnie"],
              menagerie.binding(for: "ajman") == .claude,
              menagerie.binding(for: "winnie") == .codex else {
            throw SelfTestError("menagerie first-run defaults were incorrect")
        }
        menagerie.setShown(false, petID: "winnie")
        menagerie.setShown(true, petID: "test-pet")
        menagerie.setBinding(.codex, for: "ajman")
        menagerie.setBinding(nil, for: "test-pet")
        menagerie = MenagerieConfiguration(defaults: menagerieDefaults)
        guard menagerie.shownPetIDs == ["ajman", "test-pet"],
              menagerie.binding(for: "ajman") == .codex,
              menagerie.binding(for: "test-pet") == nil else {
            throw SelfTestError("shown pets and bindings did not round-trip")
        }
        print("Menagerie config: first-run pair and shown-pets/bindings round-trip")

        let providerRegistry = SessionRegistry(startTimer: false)
        let now = Date()
        let claudeFrame = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "Notification", "session_id": "claude-one",
        ])
        let codexFrame = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "PreToolUse", "session_id": "codex-one", "tool_name": "Bash",
        ])
        guard let claudeEvent = AgentEvent.decode(frame: claudeFrame, provider: .claude, now: now),
              let codexEvent = AgentEvent.decode(frame: codexFrame, provider: .codex, now: now) else {
            throw SelfTestError("could not construct provider-isolation events")
        }
        providerRegistry.apply(claudeEvent)
        providerRegistry.apply(codexEvent)
        guard providerRegistry.currentState(for: .claude) == .waiting,
              providerRegistry.currentState(for: .codex) == .running,
              providerRegistry.currentState(for: nil) == .waiting,
              providerRegistry.sessionCount(for: .claude) == 1,
              providerRegistry.sessionCount(for: .codex) == 1 else {
            throw SelfTestError("Claude and Codex provider states were not independent")
        }
        print("Provider reducer: Claude waiting; Codex running; global waiting")

        guard catalog.discover().contains(where: { $0.id == "ajman" }),
              catalog.discover().contains(where: { $0.id == "winnie" }),
              (try? catalog.load(id: "ajman")) != nil,
              (try? catalog.load(id: "winnie")) != nil else {
            throw SelfTestError("Ajman and Winnie packages are required for the two-instance test")
        }
        let ajmanPositionKey = OverlayPanel.positionPersistenceKey(for: "ajman")
        let winniePositionKey = OverlayPanel.positionPersistenceKey(for: "winnie")
        guard ajmanPositionKey == "AjmanPanelOrigin.ajman",
              winniePositionKey == "AjmanPanelOrigin.winnie",
              ajmanPositionKey != winniePositionKey else {
            throw SelfTestError("pet instances did not have distinct position keys")
        }
        print("Pet instances: both packages load; distinct per-pet position keys (headless)")

        guard let bundledPets = Bundle.main.resourceURL?.appendingPathComponent("pets", isDirectory: true) else {
            throw SelfTestError("bundle resource root was unavailable for sleep tests")
        }
        let noLivePets = fileManager.temporaryDirectory.appendingPathComponent(
            "ajman-selftest-no-live-\(UUID().uuidString)", isDirectory: true
        )
        let sleepCatalog = PetCatalog(
            defaults: selectionDefaults,
            liveRoot: noLivePets,
            bundledRoot: bundledPets
        )
        let sleepingWinnie = try sleepCatalog.load(id: "winnie")
        let wakefulAjman = try sleepCatalog.load(id: "ajman")
        guard sleepingWinnie.sleepAnimation?.frameCount == 6 else {
            throw SelfTestError("Winnie's bundled sleep strip did not load six ordered frames")
        }
        guard wakefulAjman.sleepAnimation == nil else {
            throw SelfTestError("Ajman unexpectedly reported a sleep animation")
        }
        print("Sleep assets: Winnie bundled strip loads 6 frames; Ajman reports none")

        let sleepSuiteName = "AjmanSelfTest.Sleep.\(UUID().uuidString)"
        guard let sleepDefaults = UserDefaults(suiteName: sleepSuiteName) else {
            throw SelfTestError("could not create sleep defaults")
        }
        defer { sleepDefaults.removePersistentDomain(forName: sleepSuiteName) }
        sleepDefaults.set(true, forKey: PetMode.defaultsKey)

        let sleepLiveState = AnimationState.idle
        let sleepAnimator = Animator(sheet: sleepingWinnie.sheet, view: nil)
        let shortDoze = PetMode(
            animator: sleepAnimator,
            sleepAnimation: sleepingWinnie.sleepAnimation,
            currentLiveState: { sleepLiveState },
            isManualMode: { false },
            dozeInterval: 0.05,
            defaults: sleepDefaults
        )
        shortDoze.resumeAtRest()
        guard pump(until: { shortDoze.isSleeping && sleepAnimator.isPlayingSleep }) else {
            throw SelfTestError("short calm interval did not transition Winnie to sleep")
        }
        shortDoze.stir()
        guard !shortDoze.isSleeping, !sleepAnimator.isPlayingSleep else {
            throw SelfTestError("simulated bound-agent stir did not wake Winnie")
        }
        guard shortDoze.forceSleep() else { throw SelfTestError("manual sleep could not restart Winnie") }
        shortDoze.wake()
        guard !shortDoze.isSleeping, !sleepAnimator.isPlayingSleep else {
            throw SelfTestError("simulated click/wake did not wake Winnie")
        }
        shortDoze.teardown()
        sleepAnimator.stop()

        let noSleepAnimator = Animator(sheet: wakefulAjman.sheet, view: nil)
        let noSleepMode = PetMode(
            animator: noSleepAnimator,
            sleepAnimation: nil,
            currentLiveState: { sleepLiveState },
            isManualMode: { false },
            dozeInterval: 0.05,
            defaults: sleepDefaults
        )
        noSleepMode.resumeAtRest()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        guard !noSleepMode.isSleeping, !noSleepAnimator.isPlayingSleep else {
            throw SelfTestError("a pet without sleep art entered sleep")
        }
        noSleepMode.teardown()
        noSleepAnimator.stop()
        print("Sleep behavior: short calm dozes; agent stir and click wake; no-asset pet stays idle")

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
        let notificationMessage = "Permission requested for the specific release step."
        try invokeHook(event: "Notification", fields: ["message": notificationMessage])
        guard pump(until: { registry.currentState == .waiting }) else { throw SelfTestError("Notification did not produce waiting") }
        guard case .upsert(let waiting)? = notificationChanges.last,
              waiting.kind == .waiting,
              waiting.preview.contains(notificationMessage),
              waiting.fullText.contains(notificationMessage) else {
            throw SelfTestError("Notification message did not reach the waiting card")
        }
        print("Bubble content: Claude Notification preview contains real message: \(waiting.preview)")

        try invokeHook(
            event: "PermissionRequest",
            tool: "Bash",
            fields: ["tool_input": ["command": "swift test"]]
        )
        guard pump(until: {
            if case .upsert(let notification)? = notificationChanges.last {
                return notification.title.contains("Claude · Run: swift test") && notification.preview == "swift test"
            }
            return false
        }) else {
            throw SelfTestError("Claude PermissionRequest command did not reach the waiting card")
        }
        print("Bubble content: Claude PermissionRequest -> Claude · Run: swift test")
        try invokeHook(event: "PostToolUse", tool: "Bash")
        guard pump(until: {
            notificationChanges.contains { change in
                if case .dismiss(let id, _) = change { return id == waiting.id }
                return false
            }
        }) else { throw SelfTestError("follow-up event did not dismiss waiting card") }
        print("Bubble lifecycle: waiting card raised; PostToolUse dismissed it")

        let completionMessage = "Implemented specific bubble content. All verification checks passed."
        try invokeHook(event: "Stop", fields: ["last_assistant_message": completionMessage])
        guard pump(until: {
            if case .upsert(let notification)? = notificationChanges.last {
                return notification.kind == .done && notification.fullText.contains(completionMessage)
            }
            return false
        }), case .upsert(let completed)? = notificationChanges.last,
           completed.preview.contains("All verification checks passed"),
           !completed.preview.contains("The turn is ready for review") else {
            throw SelfTestError("Stop last_assistant_message did not replace the generic completion card")
        }
        print("Bubble content: Claude Stop preview contains real assistant text: \(completed.preview)")

        let codexMonitor = CodexMonitor(environment: ["CODEX_HOME": "/tmp/ajman-selftest-codex"])
        var codexEvents: [AgentEvent] = []
        codexMonitor.eventHandler = { codexEvents.append($0) }
        func rolloutLine(_ type: String, payload: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["type": type, "payload": payload])
        }
        let earlierCodexMessage = "Codex is still working through the rollout."
        let codexMessage = "Real Codex answer reached the card. The latest assistant text stayed intact."
        let rawApprovalOutcome = "{\"outcome\":\"allow\"}"
        codexMonitor.consumeFixtureLines([
            try rolloutLine("session_meta", payload: ["id": "codex-selftest", "cwd": "/tmp", "originator": "Codex Desktop"]),
            try rolloutLine("event_msg", payload: ["type": "task_started"]),
            try rolloutLine("event_msg", payload: ["type": "agent_message", "message": earlierCodexMessage, "phase": "commentary"]),
            try rolloutLine("event_msg", payload: ["type": "token_count", "info": ["total_token_usage": 123]]),
            try rolloutLine("event_msg", payload: [
                "type": "exec_approval_request", "command": "swift test", "message": rawApprovalOutcome, "cwd": "/tmp",
            ]),
            try rolloutLine("event_msg", payload: ["type": "agent_message", "message": codexMessage, "phase": "final_answer"]),
        ])
        guard let codexStop = codexEvents.first(where: { $0.event == "Stop" }),
              codexStop.message == codexMessage,
              codexEvents.filter({ $0.event == "Stop" }).count == 1,
              let codexApproval = codexEvents.first(where: { $0.event == "Notification" }),
              codexApproval.detail == "swift test",
              codexApproval.message == earlierCodexMessage,
              codexApproval.message != rawApprovalOutcome else {
            throw SelfTestError("Codex rollout message/approval extraction failed")
        }
        let codexRegistry = SessionRegistry(startTimer: false)
        codexRegistry.apply(codexStop)
        guard let codexCard = codexRegistry.currentNotifications(for: .codex).first,
              codexCard.fullText.contains(codexMessage),
              codexCard.preview.contains(codexMessage),
              codexCard.title == "Codex · Real Codex answer reached the card." else {
            throw SelfTestError("Codex agent_message did not reach the completion card")
        }
        codexRegistry.apply(codexApproval)
        guard let approvalCard = codexRegistry.currentNotifications(for: .codex).first,
              approvalCard.title.contains("Run: swift test"),
              approvalCard.preview == "swift test" else {
            throw SelfTestError("Codex exec approval command did not reach the waiting card")
        }
        print("Codex rollout: event_msg/agent_message/message final_answer -> specific completion without task_complete")
        print("Codex card: title=\(codexCard.title); preview contains real message")
        print("Codex approval: exec approval -> Run: swift test")

        let rawDecisionEvent = AgentEvent(
            provider: .codex,
            event: "Notification",
            sessionId: "codex-decision-selftest",
            cwd: "/tmp",
            toolName: nil,
            transcriptPath: nil,
            title: rawApprovalOutcome,
            message: rawApprovalOutcome,
            detail: rawApprovalOutcome,
            timestamp: Date(),
            raw: ["type": .string("exec_approval_request"), "outcome": .string("allow")]
        )
        let rawDecisionRegistry = SessionRegistry(startTimer: false)
        rawDecisionRegistry.apply(rawDecisionEvent)
        guard let rawDecisionCard = rawDecisionRegistry.currentNotifications(for: .codex).first,
              !rawDecisionCard.title.contains("{\"outcome\""),
              !rawDecisionCard.preview.contains("{\"outcome\""),
              rawDecisionCard.title == "Codex needs you",
              rawDecisionCard.preview == "This session is waiting for your input." else {
            throw SelfTestError("Codex approval outcome JSON reached the card")
        }

        let decisionMonitor = CodexMonitor(environment: ["CODEX_HOME": "/tmp/ajman-selftest-codex-decision"])
        var decisionEvents: [AgentEvent] = []
        decisionMonitor.eventHandler = { decisionEvents.append($0) }
        decisionMonitor.consumeFixtureLines([
            try rolloutLine("session_meta", payload: ["id": "codex-guardian-selftest", "cwd": "/tmp", "originator": "Codex Desktop"]),
            try rolloutLine("event_msg", payload: ["type": "task_started"]),
            try rolloutLine("event_msg", payload: ["type": "agent_message", "message": rawApprovalOutcome, "phase": "final_answer"]),
        ])
        guard let decisionStop = decisionEvents.first(where: { $0.event == "Stop" }), decisionStop.message == nil else {
            throw SelfTestError("Codex monitor accepted approval outcome JSON as assistant prose")
        }
        let decisionCompletionRegistry = SessionRegistry(startTimer: false)
        decisionCompletionRegistry.apply(decisionStop)
        guard let decisionCompletionCard = decisionCompletionRegistry.currentNotifications(for: .codex).first,
              decisionCompletionCard.title == "Codex finished",
              decisionCompletionCard.preview == "The turn is ready for review.",
              !decisionCompletionCard.fullText.contains("{\"outcome\"") else {
            throw SelfTestError("Codex guardian outcome JSON reached the completion card")
        }
        guard AgentEvent.displayText(rawApprovalOutcome) == nil,
              AgentEvent.displayText(codexMessage) == codexMessage else {
            throw SelfTestError("Codex display-text guard rejected prose or accepted JSON")
        }
        print("Codex JSON regression: approval outcome rejected; command and real assistant prose preserved")

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
        print("Installer fixture: user hook preserved; \(ClaudeHookInstaller.events.count) Ajman event groups added; backup exists")
        let uninstalled = try ClaudeHookInstaller.uninstall(settingsPath: settings)
        let afterUninstall = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        guard containsCommand(afterUninstall, command: userCommand),
              !containsCommand(afterUninstall, command: hookPath),
              uninstalled.commandsRemoved == ClaudeHookInstaller.events.count else {
            throw SelfTestError("uninstaller fixture assertions failed")
        }
        print("Uninstaller fixture: \(ClaudeHookInstaller.events.count) Ajman commands removed; user hook preserved")
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
