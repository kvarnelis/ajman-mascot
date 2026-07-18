import AppKit

@MainActor
private func runSelfTest() -> Int32 {
    _ = NSApplication.shared
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
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let contentsURL = executableURL.deletingLastPathComponent().deletingLastPathComponent()
        if contentsURL.lastPathComponent == "Contents" {
            let iconURL = contentsURL.appendingPathComponent("Resources/Ajman.icns")
            let plistURL = contentsURL.appendingPathComponent("Info.plist")
            guard fileManager.fileExists(atPath: iconURL.path),
                  (try iconURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0,
                  let plist = NSDictionary(contentsOf: plistURL),
                  plist["CFBundleIconFile"] as? String == "Ajman.icns" else {
                throw SelfTestError("bundled app icon or CFBundleIconFile is missing")
            }
            print("App icon: bundled Resources/Ajman.icns exists and CFBundleIconFile is Ajman.icns")
        }

        var reopenShowCount = 0
        var reopenMenuCount = 0
        ApplicationReopenAction.perform(
            showPetsIfNeeded: { reopenShowCount += 1 },
            openMenu: { reopenMenuCount += 1 }
        )
        guard reopenShowCount == 1, reopenMenuCount == 1 else {
            throw SelfTestError("application reopen did not reveal pets and present the menu exactly once")
        }
        print("Application reopen: reveals hidden pets and triggers the status-item menu")

        let launchPromptSuiteName = "AjmanSelfTest.FirstRunLaunchPrompt.\(UUID().uuidString)"
        guard let launchPromptDefaults = UserDefaults(suiteName: launchPromptSuiteName) else {
            throw SelfTestError("could not create first-run launch prompt defaults")
        }
        defer { launchPromptDefaults.removePersistentDomain(forName: launchPromptSuiteName) }
        var promptCount = 0
        var enableCount = 0
        let firstRunPrompt = FirstRunLaunchPrompt(defaults: launchPromptDefaults)
        let firstPromptShown = try firstRunPrompt.performIfNeeded(
            prompt: {
                promptCount += 1
                return true
            },
            enableLaunchAtLogin: { enableCount += 1 }
        )
        let repeatedPromptShown = try FirstRunLaunchPrompt(defaults: launchPromptDefaults).performIfNeeded(
            prompt: {
                promptCount += 1
                return true
            },
            enableLaunchAtLogin: { enableCount += 1 }
        )
        guard firstPromptShown, !repeatedPromptShown,
              promptCount == 1, enableCount == 1,
              launchPromptDefaults.bool(forKey: FirstRunLaunchPrompt.didAskKey) else {
            throw SelfTestError("first-run launch prompt did not show once and enable Launch at Login on Yes")
        }

        let notNowSuiteName = "AjmanSelfTest.FirstRunLaunchPrompt.NotNow.\(UUID().uuidString)"
        guard let notNowDefaults = UserDefaults(suiteName: notNowSuiteName) else {
            throw SelfTestError("could not create Not now launch prompt defaults")
        }
        defer { notNowDefaults.removePersistentDomain(forName: notNowSuiteName) }
        var notNowEnableCount = 0
        _ = try FirstRunLaunchPrompt(defaults: notNowDefaults).performIfNeeded(
            prompt: { false },
            enableLaunchAtLogin: { notNowEnableCount += 1 }
        )
        guard notNowEnableCount == 0,
              notNowDefaults.bool(forKey: FirstRunLaunchPrompt.didAskKey) else {
            throw SelfTestError("Not now did not persist the one-time prompt without enabling Launch at Login")
        }
        print("First-run launch prompt: shows once; Yes enables; Not now stays off; both persist \(FirstRunLaunchPrompt.didAskKey)")

        guard AjmanApp.version == AppVersion("v0.1.2"),
              AppVersion("1.2.4")! > AppVersion("1.2.3")!,
              AppVersion("1.2")! == AppVersion("1.2.0")!,
              AppVersion("1.2.3-beta.2")! < AppVersion("1.2.3")!,
              AppVersion("1.2.3")! < AppVersion("2.0.0")! else {
            throw SelfTestError("update version comparison failed for newer/older/equal tags")
        }
        print("Updates: semver-ish newer/older/equal comparison passes; running version \(AjmanApp.version)")

        let releaseFixture = #"""
        {
          "tag_name": "v0.1.2",
          "assets": [
            {"name": "Ajman-0.1.2.dmg", "browser_download_url": "https://example.invalid/Ajman-0.1.2.dmg"},
            {"name": "Ajman-0.1.2.zip", "browser_download_url": "https://example.invalid/Ajman-0.1.2.zip"},
            {"name": "other.zip", "browser_download_url": "https://example.invalid/other.zip"}
          ]
        }
        """#
        let dmgOnlyFixture = #"""
        {
          "tag_name": "v0.1.1",
          "assets": [
            {"name": "Ajman-0.1.1.dmg", "browser_download_url": "https://example.invalid/Ajman-0.1.1.dmg"}
          ]
        }
        """#
        let fixtureRelease = try JSONDecoder().decode(GitHubRelease.self, from: Data(releaseFixture.utf8))
        let dmgOnlyRelease = try JSONDecoder().decode(GitHubRelease.self, from: Data(dmgOnlyFixture.utf8))
        guard fixtureRelease.tagName == "v0.1.2",
              fixtureRelease.preferredAppAsset?.name == "Ajman-0.1.2.zip",
              dmgOnlyRelease.preferredAppAsset?.name == nil,
              GitHubReleaseChecker.latestReleaseURL()?.absoluteString
                == "https://api.github.com/repos/kvarnelis/ajman-mascot/releases/latest" else {
            throw SelfTestError("GitHub release fixture decoding, zip selection, or feed URL construction failed")
        }
        print("Updates: fixture tag=v0.1.2 asset=Ajman-0.1.2.zip; DMG-only asset=nil; feed URL=\(GitHubReleaseChecker.latestReleaseURL()!.absoluteString)")

        let bubbleVisibleFrame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let bubbleSize = NSSize(width: 310, height: 158)
        let roomyAnchor = NSRect(x: 450, y: 300, width: 80, height: 80)
        let roomyPlacement = UpdateBubbleController.bubblePlacement(
            anchorFrame: roomyAnchor, visible: bubbleVisibleFrame, bubbleSize: bubbleSize
        )
        guard !roomyPlacement.tailOnTop,
              abs(roomyPlacement.origin.y - 382) < 0.000_001,
              abs(roomyPlacement.origin.x + roomyPlacement.tailTipX - roomyAnchor.midX) < 0.000_001 else {
            throw SelfTestError("roomy update bubble did not sit above or point at its anchor")
        }

        let topAnchor = NSRect(x: 450, y: 740, width: 80, height: 50)
        let topPlacement = UpdateBubbleController.bubblePlacement(
            anchorFrame: topAnchor, visible: bubbleVisibleFrame, bubbleSize: bubbleSize
        )
        guard topPlacement.tailOnTop,
              abs(topPlacement.origin.y - 580) < 0.000_001,
              abs(topPlacement.origin.x + topPlacement.tailTipX - topAnchor.midX) < 0.000_001 else {
            throw SelfTestError("top-edge update bubble did not flip below or point up at its anchor")
        }

        let rightAnchor = NSRect(x: 950, y: 300, width: 40, height: 80)
        let rightPlacement = UpdateBubbleController.bubblePlacement(
            anchorFrame: rightAnchor, visible: bubbleVisibleFrame, bubbleSize: bubbleSize
        )
        guard abs(rightPlacement.origin.x - 690) < 0.000_001,
              abs(rightPlacement.tailTipX - 280) < 0.000_001,
              abs(rightPlacement.origin.x + rightPlacement.tailTipX - rightAnchor.midX) < 0.000_001 else {
            throw SelfTestError("right-edge update bubble tail did not compensate for the x clamp")
        }

        let extremeAnchors = [
            NSRect(x: -30, y: 300, width: 10, height: 80),
            NSRect(x: 995, y: 300, width: 5, height: 80),
        ]
        let extremeTips = extremeAnchors.map {
            UpdateBubbleController.bubblePlacement(
                anchorFrame: $0, visible: bubbleVisibleFrame, bubbleSize: bubbleSize
            ).tailTipX
        }
        guard extremeTips.allSatisfy({
            $0 >= UpdateBubbleController.tailTipInset
                && $0 <= bubbleSize.width - UpdateBubbleController.tailTipInset
        }) else {
            throw SelfTestError("update bubble tail escaped the rounded-body inset")
        }
        print(
            "Update bubble placement: roomy origin=\(roomyPlacement.origin) tailOnTop=\(roomyPlacement.tailOnTop) tipX=\(roomyPlacement.tailTipX); "
                + "top origin=\(topPlacement.origin) tailOnTop=\(topPlacement.tailOnTop) tipX=\(topPlacement.tailTipX); "
                + "right origin=\(rightPlacement.origin) tailOnTop=\(rightPlacement.tailOnTop) tipX=\(rightPlacement.tailTipX); "
                + "extreme tips=\(extremeTips)"
        )

        let updateSuiteName = "AjmanSelfTest.Updates.\(UUID().uuidString)"
        guard let updateDefaults = UserDefaults(suiteName: updateSuiteName) else {
            throw SelfTestError("could not create update defaults")
        }
        defer { updateDefaults.removePersistentDomain(forName: updateSuiteName) }
        let updatePreferences = UpdatePreferences(defaults: updateDefaults)
        guard updatePreferences.shouldPrompt(for: "0.1.3") else {
            throw SelfTestError("an enabled newer update did not prompt")
        }
        updatePreferences.promptsEnabled = false
        guard !updatePreferences.shouldPrompt(for: "9.0.0"),
              updateDefaults.bool(forKey: UpdatePreferences.promptsDisabledKey) else {
            throw SelfTestError("don't-ask-again did not persistently disable prompts")
        }
        updatePreferences.promptsEnabled = true
        updatePreferences.skippedVersion = "0.2.0"
        guard !updatePreferences.shouldPrompt(for: "0.2.0"), updatePreferences.shouldPrompt(for: "0.2.1") else {
            throw SelfTestError("skipped update version was not isolated")
        }
        let previewBubble = UpdateBubbleController()
        previewBubble.showPreview(
            anchoredTo: nil,
            fallbackAnchor: NSRect(x: 100, y: 100, width: 80, height: 80)
        )
        guard previewBubble.isVisible, previewBubble.controlCount == 3 else {
            throw SelfTestError("preview update bubble did not construct/show with three controls")
        }
        previewBubble.dismiss()
        print("Updates: don't-ask-again persists/re-enables; preview bubble shows Update/Later/Don't ask again")

        let suiteName = "AjmanSelfTest.PetScale.\(UUID().uuidString)"
        guard let scaleDefaults = UserDefaults(suiteName: suiteName) else { throw SelfTestError("could not create scale defaults") }
        defer { scaleDefaults.removePersistentDomain(forName: suiteName) }
        guard PetScale.load(from: scaleDefaults) == .twoThirds else { throw SelfTestError("scale default was not 0.6667") }
        for scale in PetScale.allCases {
            scale.save(to: scaleDefaults)
            guard PetScale.load(from: scaleDefaults) == scale else { throw SelfTestError("scale did not round-trip: \(scale.rawValue)") }
        }
        print("Pet scale: default 0.6667; all \(PetScale.allCases.count) options round-trip")

        let steadySuiteName = "AjmanSelfTest.SteadySize.\(UUID().uuidString)"
        guard let steadyDefaults = UserDefaults(suiteName: steadySuiteName) else { throw SelfTestError("could not create steady-size defaults") }
        defer { steadyDefaults.removePersistentDomain(forName: steadySuiteName) }
        guard !SteadySize.load(from: steadyDefaults) else { throw SelfTestError("steady size was not off by default") }
        SteadySize.save(false, to: steadyDefaults)
        guard !SteadySize.load(from: steadyDefaults) else { throw SelfTestError("steady size did not persist off") }
        SteadySize.save(true, to: steadyDefaults)
        guard SteadySize.load(from: steadyDefaults) else { throw SelfTestError("steady size did not persist on") }
        print("Steady size: default off; off/on round-trip")

        let notificationSuiteName = "AjmanSelfTest.AgentNotifications.\(UUID().uuidString)"
        guard let notificationDefaults = UserDefaults(suiteName: notificationSuiteName) else {
            throw SelfTestError("could not create agent-notification defaults")
        }
        defer { notificationDefaults.removePersistentDomain(forName: notificationSuiteName) }
        let notificationPreferences = AgentNotificationPreferences(defaults: notificationDefaults)
        guard !notificationPreferences.isEnabled else {
            throw SelfTestError("agent notifications were not off by default")
        }
        notificationPreferences.isEnabled = true
        guard notificationPreferences.isEnabled else {
            throw SelfTestError("agent notifications did not persist on")
        }
        notificationPreferences.isEnabled = false
        guard !notificationPreferences.isEnabled else {
            throw SelfTestError("agent notifications did not persist off")
        }
        print("Agent notifications: default off; shared Claude/Codex preference round-trips")

        let selectionSuiteName = "AjmanSelfTest.PetSelection.\(UUID().uuidString)"
        guard let selectionDefaults = UserDefaults(suiteName: selectionSuiteName) else { throw SelfTestError("could not create selection defaults") }
        defer { selectionDefaults.removePersistentDomain(forName: selectionSuiteName) }
        let catalog = PetCatalog(defaults: selectionDefaults)
        guard !catalog.discover().isEmpty else { throw SelfTestError("pet discovery found no readable packages") }
        guard catalog.selectedPetID == "ajman" else { throw SelfTestError("selected pet default was not ajman") }
        catalog.saveSelection("winnie")
        guard catalog.selectedPetID == "winnie" else { throw SelfTestError("selected pet did not round-trip") }
        guard catalog.relativeScale(for: "ajman") == 1.0, catalog.relativeScale(for: "winnie") == 0.67 else {
            throw SelfTestError("built-in relative pet scales were incorrect")
        }
        let defaultAjmanEffectiveScale = PetScale.defaultValue.rawValue * catalog.relativeScale(for: "ajman")
        let defaultWinnieEffectiveScale = PetScale.defaultValue.rawValue * catalog.relativeScale(for: "winnie")
        guard abs(defaultAjmanEffectiveScale - 0.6667) < 0.000_001,
              abs(defaultWinnieEffectiveScale - 0.446689) < 0.000_001 else {
            throw SelfTestError("fresh-install overall/per-pet default sizes did not combine correctly")
        }
        print("Pet catalog defaults: overall 0.6667; ajman 1.0; winnie 0.67")
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
        let testVisibleFrame = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let defaultAjmanSize = NSSize(
            width: (CGFloat(SpriteSheet.cellWidth) * CGFloat(PetScale.defaultValue.rawValue)).rounded(),
            height: (CGFloat(SpriteSheet.cellHeight) * CGFloat(PetScale.defaultValue.rawValue)).rounded()
        )
        let defaultWinnieSize = NSSize(
            width: (CGFloat(SpriteSheet.cellWidth) * CGFloat(PetScale.defaultValue.rawValue) * 0.67).rounded(),
            height: (CGFloat(SpriteSheet.cellHeight) * CGFloat(PetScale.defaultValue.rawValue) * 0.67).rounded()
        )
        let ajmanResetOrigin = OverlayPanel.defaultOrigin(
            visibleFrame: testVisibleFrame, displaySize: defaultAjmanSize, defaultPositionIndex: 0
        )
        let winnieResetOrigin = OverlayPanel.defaultOrigin(
            visibleFrame: testVisibleFrame, displaySize: defaultWinnieSize, defaultPositionIndex: 1
        )
        let ajmanGroundLine = OverlayPanel.renderedGroundLine(
            originY: ajmanResetOrigin.y, displayHeight: defaultAjmanSize.height
        )
        let winnieGroundLine = OverlayPanel.renderedGroundLine(
            originY: winnieResetOrigin.y, displayHeight: defaultWinnieSize.height
        )
        guard abs(ajmanGroundLine - winnieGroundLine) < 0.000_001 else {
            throw SelfTestError("reset positions did not share a rendered ground line")
        }
        print("Pet instances: both packages load; distinct position keys; reset feet share one scaled ground line")

        func isFullyContained(_ panelFrame: NSRect, in visibleFrame: NSRect) -> Bool {
            visibleFrame.contains(panelFrame)
        }
        let largeDisplayFrames = [
            NSRect(x: 0, y: 0, width: 5_120, height: 2_880),
            NSRect(x: 0, y: 0, width: 2_560, height: 1_440),
        ]
        for visibleFrame in largeDisplayFrames {
            for (index, size) in [defaultAjmanSize, defaultWinnieSize].enumerated() {
                let origin = OverlayPanel.defaultOrigin(
                    visibleFrame: visibleFrame,
                    displaySize: size,
                    defaultPositionIndex: index
                )
                guard isFullyContained(NSRect(origin: origin, size: size), in: visibleFrame) else {
                    throw SelfTestError("default pet position escaped a large single display")
                }
            }
        }

        let offscreen = NSRect(x: 8_000, y: 8_000, width: defaultAjmanSize.width, height: defaultAjmanSize.height)
        let healedOffscreen = OverlayPanel.healedFrame(
            panelFrame: offscreen,
            visibleFrames: [testVisibleFrame],
            preferredVisibleFrame: testVisibleFrame,
            defaultPositionIndex: 0
        )
        guard isFullyContained(healedOffscreen, in: testVisibleFrame) else {
            throw SelfTestError("fully off-screen saved origin was not healed")
        }

        let onePixelIntersection = NSRect(
            x: testVisibleFrame.maxX - 1,
            y: testVisibleFrame.maxY - 1,
            width: defaultAjmanSize.width,
            height: defaultAjmanSize.height
        )
        guard !OverlayPanel.hasSubstantialOverlap(
            panelFrame: onePixelIntersection,
            visibleFrames: [testVisibleFrame]
        ) else {
            throw SelfTestError("one-pixel screen intersection counted as substantially visible")
        }
        let healedOnePixel = OverlayPanel.healedFrame(
            panelFrame: onePixelIntersection,
            visibleFrames: [testVisibleFrame],
            preferredVisibleFrame: testVisibleFrame,
            defaultPositionIndex: 0
        )
        guard isFullyContained(healedOnePixel, in: testVisibleFrame) else {
            throw SelfTestError("one-pixel saved-origin intersection was not healed")
        }

        let negativeSecondary = NSRect(x: -1_920, y: -240, width: 1_920, height: 1_080)
        let multiDisplayFrames = [testVisibleFrame, negativeSecondary]
        let secondaryPet = NSRect(
            origin: OverlayPanel.defaultOrigin(
                visibleFrame: negativeSecondary,
                displaySize: defaultWinnieSize,
                defaultPositionIndex: 1
            ),
            size: defaultWinnieSize
        )
        guard isFullyContained(secondaryPet, in: negativeSecondary),
              OverlayPanel.hasSubstantialOverlap(panelFrame: secondaryPet, visibleFrames: multiDisplayFrames) else {
            throw SelfTestError("negative-origin secondary display did not keep a pet fully visible")
        }
        print("Panel visibility: 55%/bottom-center rule; off-screen and 1px origins heal; large and negative-origin displays contain all pets")

        let cycleOrder: [AnimationState] = [
            .idle, .runningRight, .runningLeft, .waving, .jumping, .failed,
            .waiting, .running, .review, .lookDirectionsA, .lookDirectionsB,
        ]
        guard PetActionCycle.order == cycleOrder,
              PetClickDisposition.classify(buttonNumber: 0, modifiers: []) == .normal,
              PetClickDisposition.classify(buttonNumber: 0, modifiers: [.control]) == .advanceAction,
              PetClickDisposition.classify(buttonNumber: 1, modifiers: []) == .advanceAction else {
            throw SelfTestError("pet click classification or shared action-cycle order was incorrect")
        }
        let fullActionCycle = PetActionCycle.availableActions(
            availableStates: cycleOrder,
            hasLoaf: true,
            hasSleep: true,
            hasStretch: true,
            hasScratch: true,
            hasGroom: true
        )
        let expectedAfterIdle: [PetCycleAction] = [
            .animation(.runningRight), .animation(.runningLeft), .animation(.waving),
            .animation(.jumping), .animation(.failed), .animation(.waiting),
            .animation(.running), .animation(.review), .animation(.lookDirectionsA),
            .animation(.lookDirectionsB), .loaf, .sleep, .stretch, .scratch, .groom,
            .animation(.idle),
        ]
        guard fullActionCycle == PetActionCycle.directOrder,
              fullActionCycle.suffix(5) == [.loaf, .sleep, .stretch, .scratch, .groom] else {
            throw SelfTestError("per-pet action cycle did not include ordered loaf, sleep, stretch, scratch, and groom")
        }

        var ajmanCursor = PetActionCycle.Cursor()
        var observed: [PetCycleAction] = []
        for _ in expectedAfterIdle.indices {
            // Simulate one-shot animations having reverted to idle before every click.
            if let action = ajmanCursor.next(
                availableActions: fullActionCycle,
                startingAfter: .animation(.idle)
            ) {
                observed.append(action)
            }
        }
        guard observed == expectedAfterIdle,
              ajmanCursor.next(
                  availableActions: fullActionCycle,
                  startingAfter: .animation(.idle)
              ) == .animation(.runningRight) else {
            throw SelfTestError("repeated control-click did not traverse the full cycle in order and wrap")
        }

        let ajmanPositionAfterWrap = ajmanCursor.position
        var winnieCursor = PetActionCycle.Cursor()
        guard winnieCursor.position == nil,
              winnieCursor.next(
                  availableActions: fullActionCycle,
                  startingAfter: .animation(.idle)
              ) == .animation(.runningRight),
              winnieCursor.position == 1,
              ajmanCursor.position == ajmanPositionAfterWrap else {
            throw SelfTestError("per-pet action-cycle positions were not isolated")
        }
        let noScratchCycle = PetActionCycle.availableActions(
            availableStates: cycleOrder,
            hasLoaf: true,
            hasSleep: true,
            hasStretch: true,
            hasScratch: false,
            hasGroom: true
        )
        let noStretchCycle = PetActionCycle.availableActions(
            availableStates: cycleOrder,
            hasLoaf: true,
            hasSleep: true,
            hasStretch: false,
            hasScratch: true,
            hasGroom: true
        )
        var resyncCursor = PetActionCycle.Cursor()
        for _ in 0..<fullActionCycle.count {
            _ = resyncCursor.next(availableActions: fullActionCycle)
        }
        guard !noScratchCycle.contains(.scratch),
              noScratchCycle.suffix(4) == [.loaf, .sleep, .stretch, .groom],
              !noStretchCycle.contains(.stretch),
              noStretchCycle.suffix(4) == [.loaf, .sleep, .scratch, .groom],
              resyncCursor.next(availableActions: noScratchCycle) == .animation(.idle),
              PetActionCycle.next(after: .lookDirectionsB, availableStates: cycleOrder) == .idle else {
            throw SelfTestError("per-pet action cycle did not skip unavailable behavior assets")
        }
        print("Pet action clicks: per-pet cursor traverses 11 states plus loaf/sleep/stretch/scratch/groom despite idle resets; missing stretch/scratch assets skip; order wraps")

        let temperamentSuiteName = "AjmanSelfTest.Temperament.\(UUID().uuidString)"
        guard let temperamentDefaults = UserDefaults(suiteName: temperamentSuiteName) else {
            throw SelfTestError("could not create temperament defaults")
        }
        defer { temperamentDefaults.removePersistentDomain(forName: temperamentSuiteName) }
        let expectedTemperaments: [Temperament] = [.catatonic, .calm, .normal, .frisky, .insane]
        guard Temperament.allCases == expectedTemperaments,
              Temperament.load(for: "ajman", from: temperamentDefaults) == .calm,
              Temperament.load(for: "winnie", from: temperamentDefaults) == .frisky,
              Temperament.load(for: "other", from: temperamentDefaults) == .normal else {
            throw SelfTestError("temperament levels or per-pet defaults were incorrect")
        }
        Temperament.frisky.save(for: "ajman", to: temperamentDefaults)
        Temperament.calm.save(for: "winnie", to: temperamentDefaults)
        let ajmanTemperament = Temperament.load(for: "ajman", from: temperamentDefaults)
        let winnieTemperament = Temperament.load(for: "winnie", from: temperamentDefaults)
        guard ajmanTemperament == .frisky,
              winnieTemperament == .calm,
              temperamentDefaults.string(forKey: "AjmanTemperament.ajman") == Temperament.frisky.rawValue,
              temperamentDefaults.string(forKey: "AjmanTemperament.winnie") == Temperament.calm.rawValue,
              ajmanTemperament.scaledIdleFrameDuration(1) < winnieTemperament.scaledIdleFrameDuration(1) else {
            throw SelfTestError("Ajman/Winnie temperament identity or per-pet idle liveliness was swapped")
        }
        for temperament in Temperament.allCases {
            temperament.save(for: "ajman", to: temperamentDefaults)
            guard Temperament.load(for: "ajman", from: temperamentDefaults) == temperament else {
                throw SelfTestError("temperament did not persist: \(temperament.rawValue)")
            }
        }
        let frequencies = Temperament.allCases.map(\.frequencyMultiplier)
        let fidgetFrequencies = Temperament.allCases.map(\.idleFidgetFrequencyMultiplier)
        let fidgetAmplitudes = Temperament.allCases.map(\.idleFidgetAmplitudeMultiplier)
        let fidgetWaits = Temperament.allCases.map { $0.scaledFidget(interval: PetMode.randomIntervalRange.lowerBound) }
        let scratchProbabilities = Temperament.allCases.map { $0.scaledFidget(probability: ScratchBehavior.triggerProbability) }
        let scratchSpacing = Temperament.allCases.map { $0.scaledFidget(interval: ScratchBehavior.minimumSpacing) }
        let groomProbabilities = Temperament.allCases.map {
            $0.scaledFidget(probability: GroomingSequence.triggerProbability)
        }
        let groomSpacing = Temperament.allCases.map {
            $0.scaledFidget(interval: GroomingSequence.minimumSpacing)
        }
        let idleLiveliness = Temperament.allCases.map(\.idleLivelinessMultiplier)
        let idleFrameWaits = Temperament.allCases.map { $0.scaledIdleFrameDuration(1) }
        let calmPoseWaits = Temperament.allCases.map { $0.scaledCalmPose(interval: Animator.sleepPoseHoldRange.lowerBound) }
        let breathingScales = Temperament.allCases.map { $0.scaledBreathingScale(PetView.sleepBreathingScale) }
        let restMultipliers = Temperament.allCases.map(\.automaticRestIntervalMultiplier)
        let loafOnsets = Temperament.allCases.map { $0.scaledAutomaticRest(interval: PetMode.defaultLoafInterval) }
        let sleepOnsets = Temperament.allCases.map { $0.scaledAutomaticRest(interval: PetMode.defaultDozeInterval) }
        guard zip(frequencies, frequencies.dropFirst()).allSatisfy({ $0 < $1 }),
              zip(fidgetFrequencies, fidgetFrequencies.dropFirst()).allSatisfy({ $0 < $1 }),
              zip(fidgetAmplitudes, fidgetAmplitudes.dropFirst()).allSatisfy({ $0 <= $1 }),
              zip(fidgetWaits, fidgetWaits.dropFirst()).allSatisfy({ $0 > $1 }),
              zip(scratchProbabilities, scratchProbabilities.dropFirst()).allSatisfy({ $0 < $1 }),
              zip(scratchSpacing, scratchSpacing.dropFirst()).allSatisfy({ $0 > $1 }),
              zip(groomProbabilities, groomProbabilities.dropFirst()).allSatisfy({ $0 < $1 }),
              zip(groomSpacing, groomSpacing.dropFirst()).allSatisfy({ $0 > $1 }),
              zip(idleLiveliness, idleLiveliness.dropFirst()).allSatisfy({ $0 < $1 }),
              zip(idleFrameWaits, idleFrameWaits.dropFirst()).allSatisfy({ $0 > $1 }),
              calmPoseWaits[0] > calmPoseWaits[1], calmPoseWaits[1] > calmPoseWaits[2],
              calmPoseWaits[2] == calmPoseWaits[3], calmPoseWaits[3] == calmPoseWaits[4],
              breathingScales[0] < breathingScales[1], breathingScales[1] < breathingScales[2],
              breathingScales[2] == breathingScales[3], breathingScales[3] == breathingScales[4],
              zip(restMultipliers, restMultipliers.dropFirst()).allSatisfy({ $0 < $1 }),
              zip(loafOnsets, loafOnsets.dropFirst()).allSatisfy({ $0 < $1 }),
              zip(sleepOnsets, sleepOnsets.dropFirst()).allSatisfy({ $0 < $1 }),
              restMultipliers == [0.1, 0.5, 1, 20, .infinity],
              loafOnsets == [4.5, 22.5, 45, 900, .infinity],
              sleepOnsets == [12, 60, 120, 2_400, .infinity],
              !Temperament.insane.allowsAutomaticRest,
              Temperament.catatonic.allowsAutomaticRest,
              ajmanTemperament.scaledAutomaticRest(interval: PetMode.defaultDozeInterval)
                > winnieTemperament.scaledAutomaticRest(interval: PetMode.defaultDozeInterval),
              idleLiveliness == [0.05, 0.3, 1, 2, 4],
              fidgetFrequencies == [0.01, 0.15, 1, 2, 4],
              fidgetAmplitudes == [0.02, 0.25, 1, 1, 1],
              fidgetAmplitudes[0] < 0.05,
              fidgetAmplitudes[1] >= 0.05 && fidgetAmplitudes[1] < 1,
              fidgetAmplitudes[2...].allSatisfy({ $0 == 1 }) else {
            throw SelfTestError("temperament did not monotonically govern idle cadence, fidget rate/amplitude, calm poses, and breathing")
        }
        print("Temperament: idle 0.05/0.3/1/2/4x; auto-rest 0.1/0.5/1/20x/disabled (loaf 4.5/22.5/45/900s/never; sleep 12/60/120/2400s/never); low-end beats/breathing scaled")

        let expectedLivelyStates: Set<AnimationState> = [
            .jumping, .waving, .runningRight, .runningLeft, .running,
        ]
        guard Set(AnimationState.allCases.filter(\.isLively)) == expectedLivelyStates else {
            throw SelfTestError("inter-cat lively trigger set was incorrect")
        }

        func glanceEligibility(
            liveState: AnimationState = .idle,
            displayedState: AnimationState = .idle,
            isManual: Bool = false,
            isSleeping: Bool = false,
            isAlreadyGlancing: Bool = false,
            supportsLookDirections: Bool = true
        ) -> InterCatGlanceEligibility {
            InterCatGlanceEligibility(
                isShown: true,
                supportsLookDirections: supportsLookDirections,
                liveState: liveState,
                displayedState: displayedState,
                isManual: isManual,
                isSleeping: isSleeping,
                isAlreadyGlancing: isAlreadyGlancing
            )
        }

        let calmStatus = glanceEligibility()
        let agentBusyStatus = glanceEligibility(liveState: .running)
        let sleepingStatus = glanceEligibility(isSleeping: true)
        let manualStatus = glanceEligibility(isManual: true)
        guard calmStatus.canReact,
              !agentBusyStatus.canReact,
              !sleepingStatus.canReact,
              !manualStatus.canReact,
              !glanceEligibility(displayedState: .jumping).canReact,
              !glanceEligibility(isAlreadyGlancing: true).canReact,
              !glanceEligibility(supportsLookDirections: false).canReact else {
            throw SelfTestError("inter-cat rest/manual/sleep/look-row eligibility guards were incorrect")
        }

        let calmCenter = NSPoint(x: 0, y: 0)
        var glanceClock = Date(timeIntervalSince1970: 1_000)
        var randomDraw = 0.0
        var requestedDirections: [LookDirection] = []
        var unexpectedReactors: [String] = []
        let glanceCoordinator = InterCatGlanceCoordinator(
            probability: 0.6,
            cooldown: 8,
            now: { glanceClock },
            randomUnit: { randomDraw }
        )
        let glanceCandidates = [
            InterCatGlanceCandidate(
                petID: "active",
                isEligible: { true },
                requestGlance: { _ in unexpectedReactors.append("source"); return true }
            ),
            InterCatGlanceCandidate(
                petID: "calm",
                isEligible: { calmStatus.canReact },
                requestGlance: { target in
                    guard let direction = LookDirection.toward(source: calmCenter, target: target) else { return false }
                    requestedDirections.append(direction)
                    return true
                }
            ),
            InterCatGlanceCandidate(
                petID: "agent-busy",
                isEligible: { agentBusyStatus.canReact },
                requestGlance: { _ in unexpectedReactors.append("agent-busy"); return true }
            ),
            InterCatGlanceCandidate(
                petID: "sleeping",
                isEligible: { sleepingStatus.canReact },
                requestGlance: { _ in unexpectedReactors.append("sleeping"); return true }
            ),
            InterCatGlanceCandidate(
                petID: "manual",
                isEligible: { manualStatus.canReact },
                requestGlance: { _ in unexpectedReactors.append("manual"); return true }
            ),
        ]

        glanceCoordinator.livelyAnimationBegan(
            sourcePetID: "active",
            sourceCenter: NSPoint(x: 100, y: 0),
            candidates: glanceCandidates
        )
        guard requestedDirections == [LookDirection(headingIndex: 4)], unexpectedReactors.isEmpty else {
            throw SelfTestError("calm sibling did not glance right toward lively sibling, or an ineligible pet reacted")
        }

        glanceCoordinator.livelyAnimationBegan(
            sourcePetID: "active",
            sourceCenter: NSPoint(x: -100, y: 0),
            candidates: glanceCandidates
        )
        guard requestedDirections.count == 1 else {
            throw SelfTestError("per-pet inter-cat cooldown did not suppress an immediate second glance")
        }

        glanceClock = glanceClock.addingTimeInterval(9)
        randomDraw = 0.9
        glanceCoordinator.livelyAnimationBegan(
            sourcePetID: "active",
            sourceCenter: NSPoint(x: -100, y: 0),
            candidates: glanceCandidates
        )
        guard requestedDirections.count == 1 else {
            throw SelfTestError("forced inter-cat probability rejection still requested a glance")
        }

        randomDraw = 0
        glanceCoordinator.livelyAnimationBegan(
            sourcePetID: "active",
            sourceCenter: NSPoint(x: -100, y: 0),
            candidates: glanceCandidates
        )
        guard requestedDirections == [LookDirection(headingIndex: 4), LookDirection(headingIndex: 12)],
              LookDirection.toward(source: calmCenter, target: NSPoint(x: 0, y: 100)) == LookDirection(headingIndex: 0),
              LookDirection.toward(source: calmCenter, target: NSPoint(x: 0, y: -100)) == LookDirection(headingIndex: 8) else {
            throw SelfTestError("inter-cat look direction mapping did not select right/left/up/down frames")
        }
        print("Inter-cat glances: lively set exact; calm faces right/left; busy/sleep/manual excluded; forced 60% gate and 8s cooldown pass")

        guard let bundledPets = Bundle.main.resourceURL?.appendingPathComponent("pets", isDirectory: true) else {
            throw SelfTestError("bundle resource root was unavailable for calm-behavior tests")
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
        let sleepingAjman = try sleepCatalog.load(id: "ajman")
        let temperamentAnimator = Animator(sheet: sleepingAjman.sheet, view: nil)
        guard let normalIdleDurations = temperamentAnimator.playbackDurations(of: .idle) else {
            throw SelfTestError("idle animation durations were unavailable")
        }
        temperamentAnimator.setTemperament(.catatonic)
        let catatonicIdleDurations = temperamentAnimator.playbackDurations(of: .idle)
        temperamentAnimator.setTemperament(.insane)
        let insaneIdleDurations = temperamentAnimator.playbackDurations(of: .idle)
        guard catatonicIdleDurations == normalIdleDurations.map({ $0 / Temperament.catatonic.idleLivelinessMultiplier }),
              insaneIdleDurations == normalIdleDurations.map({ $0 / Temperament.insane.idleLivelinessMultiplier }) else {
            throw SelfTestError("Animator did not apply temperament to the visible idle frame cadence")
        }
        temperamentAnimator.stop()
        guard let winnieSleep = sleepingWinnie.sleepAnimation,
              winnieSleep.frameCount == 8,
              winnieSleep.poseWeights.count == 8,
              winnieSleep.poseWeights[6] == winnieSleep.poseWeights[0] else {
            throw SelfTestError("Winnie's bundled sleep strip did not load eight poses with an equal roly-poly weight")
        }
        guard let ajmanSleep = sleepingAjman.sleepAnimation,
              ajmanSleep.frameCount == 8,
              ajmanSleep.poseWeights.count == 8,
              ajmanSleep.poseWeights[6] == ajmanSleep.poseWeights[0] else {
            throw SelfTestError("Ajman's bundled sleep strip did not load eight poses with an equal roly-poly weight")
        }
        guard let ajmanLoaf = sleepingAjman.loafAnimation, ajmanLoaf.frameCount == 8 else {
            throw SelfTestError("Ajman's bundled loaf strip did not load eight ordered poses")
        }
        guard let ajmanWake = sleepingAjman.wakeAnimation, ajmanWake.frameCount == 5 else {
            throw SelfTestError("Ajman's bundled stretch/yawn strip did not load five ordered poses")
        }
        guard let ajmanScratch = sleepingAjman.scratchAnimation,
              ajmanScratch.frameCount == 2,
              ScratchSide.left.poseIndex == 0,
              ScratchSide.right.poseIndex == 1 else {
            throw SelfTestError("Ajman's bundled scratch strip did not map left/right paws to left/right edges")
        }
        guard let winnieWake = sleepingWinnie.wakeAnimation,
              winnieWake.frameCount == 5,
              let winnieScratch = sleepingWinnie.scratchAnimation,
              winnieScratch.frameCount == 2 else {
            throw SelfTestError("Winnie's bundled stretch/scratch strips did not load 5/2 poses")
        }
        guard let winnieGroom = sleepingWinnie.groomAnimation,
              winnieGroom.frameCount == 6,
              GroomingSequence.frameDurations.count == 6,
              GroomingSequence.frameDurations.reduce(0, +) >= 4,
              GroomingSequence.frameDurations.reduce(0, +) <= 8,
              sleepingAjman.groomAnimation == nil else {
            throw SelfTestError("Winnie's six-frame grooming ritual or Ajman isolation was incorrect")
        }
        guard let winnieRunLeft = sleepingWinnie.travelAnimation(for: .left),
              let winnieRunRight = sleepingWinnie.travelAnimation(for: .right),
              winnieRunLeft.frameCount == 8,
              winnieRunRight.frameCount == 8,
              winnieRunLeft.sourceURL.lastPathComponent == "run-left.webp",
              winnieRunRight.sourceURL.lastPathComponent == "run-right.webp",
              sleepingAjman.travelAnimation(for: .left) == nil,
              sleepingAjman.travelAnimation(for: .right) == nil else {
            throw SelfTestError("Winnie's 8+8 directional travel gait or Ajman isolation was incorrect")
        }
        let winnieGroomBounds = winnieGroom.frames.compactMap(SpriteSheet.contentBounds)
        let winnieTravelFrames = winnieRunLeft.frames + winnieRunRight.frames
        let winnieTravelBounds = winnieTravelFrames.compactMap(SpriteSheet.contentBounds)
        guard winnieGroomBounds.count == 6,
              winnieTravelBounds.count == 16,
              winnieGroomBounds.allSatisfy({
                  $0.maxY >= 201 && $0.maxY <= 204
                      && $0.minX > 0
                      && $0.maxX < CGFloat(SpriteSheet.cellWidth)
                      && $0.maxY < CGFloat(SpriteSheet.cellHeight)
              }),
              winnieTravelBounds.allSatisfy({
                  $0.maxY == 203
                      && $0.minX > 0
                      && $0.maxX < CGFloat(SpriteSheet.cellWidth)
                      && $0.maxY < CGFloat(SpriteSheet.cellHeight)
              }) else {
            throw SelfTestError(
                "Winnie groom/run frames missed the ground line or touched a cell edge: groom=\(winnieGroomBounds), run=\(winnieTravelBounds)"
            )
        }
        let winnieCompanionFrames = winnieWake.frames + winnieScratch.frames
        let winnieCompanionBounds = winnieCompanionFrames.compactMap(SpriteSheet.contentBounds)
        guard winnieCompanionBounds.count == winnieCompanionFrames.count,
              winnieCompanionBounds.allSatisfy({
                  abs($0.maxY - CGFloat(SpriteSheet.cellHeight - SpriteSheet.contentMargin)) <= 1
                      && $0.minX > 0
                      && $0.maxX < CGFloat(SpriteSheet.cellWidth)
                      && $0.maxY < CGFloat(SpriteSheet.cellHeight)
              }) else {
            throw SelfTestError(
                "Winnie's stretch/scratch frames missed the ground line or touched a cell edge: \(winnieCompanionBounds)"
            )
        }
        guard let leftUpperImage = winnieScratch.frames[ScratchSide.left.poseIndex].cropping(
            to: CGRect(x: 0, y: 0, width: SpriteSheet.cellWidth, height: 80)
        ),
              let rightUpperImage = winnieScratch.frames[ScratchSide.right.poseIndex].cropping(
                to: CGRect(x: 0, y: 0, width: SpriteSheet.cellWidth, height: 80)
              ),
              let leftUpperBounds = SpriteSheet.contentBounds(leftUpperImage),
              let rightUpperBounds = SpriteSheet.contentBounds(rightUpperImage),
              leftUpperBounds.minX < CGFloat(SpriteSheet.cellWidth) / 2,
              leftUpperBounds.maxX < rightUpperBounds.maxX,
              rightUpperBounds.minX > leftUpperBounds.minX,
              rightUpperBounds.maxX > CGFloat(SpriteSheet.cellWidth) / 2 else {
            throw SelfTestError("Winnie's scratch pose indices did not map pixel reach left=0/right=1")
        }
        let winnieActions = PetActionCycle.availableActions(
            availableStates: sleepingWinnie.sheet.animationTable.states,
            hasLoaf: sleepingWinnie.loafAnimation != nil,
            hasSleep: sleepingWinnie.sleepAnimation != nil,
            hasStretch: sleepingWinnie.wakeAnimation != nil,
            hasScratch: sleepingWinnie.scratchAnimation != nil,
            hasGroom: sleepingWinnie.groomAnimation != nil
        )
        let ajmanActions = PetActionCycle.availableActions(
            availableStates: sleepingAjman.sheet.animationTable.states,
            hasLoaf: sleepingAjman.loafAnimation != nil,
            hasSleep: sleepingAjman.sleepAnimation != nil,
            hasStretch: sleepingAjman.wakeAnimation != nil,
            hasScratch: sleepingAjman.scratchAnimation != nil,
            hasGroom: sleepingAjman.groomAnimation != nil
        )
        guard let winnieSleepIndex = winnieActions.firstIndex(of: .sleep),
              let winnieStretchIndex = winnieActions.firstIndex(of: .stretch),
              let winnieScratchIndex = winnieActions.firstIndex(of: .scratch),
              let ajmanSleepIndex = ajmanActions.firstIndex(of: .sleep),
              let ajmanStretchIndex = ajmanActions.firstIndex(of: .stretch),
              let ajmanScratchIndex = ajmanActions.firstIndex(of: .scratch),
              winnieSleepIndex < winnieStretchIndex,
              winnieStretchIndex < winnieScratchIndex,
              ajmanSleepIndex < ajmanStretchIndex,
              ajmanStretchIndex < ajmanScratchIndex,
              winnieActions.contains(.scratch), winnieActions.contains(.groom),
              HeldSequenceEligibility(
                hasAsset: true, isShown: true, liveState: .idle,
                displayedState: .idle, isManual: false,
                isCalmPose: false, isGlancing: false
              ).canStart,
              !HeldSequenceEligibility(
                hasAsset: true, isShown: true, liveState: .running,
                displayedState: .idle, isManual: false,
                isCalmPose: false, isGlancing: false
              ).canStart,
              Temperament.defaultValue(for: "winnie").scaledFidget(
                probability: GroomingSequence.triggerProbability
              ) == 0.56,
              Temperament.catatonic.scaledFidget(
                probability: GroomingSequence.triggerProbability
              ) < 0.003,
              Temperament.defaultValue(for: "winnie").scaledFidget(
                probability: ScratchBehavior.triggerProbability
              ) > Temperament.defaultValue(for: "ajman").scaledFidget(
                probability: ScratchBehavior.triggerProbability
              ) else {
            throw SelfTestError("Winnie scratch/groom whim availability or default frequency was incorrect")
        }
        print("Winnie companions: groom 6 frames/5.05s and run 8+8 frames are grounded; Ajman and Winnie direct actions order Sleep/Stretch/Scratch; travel direction maps left/right assets")
        guard ScratchEdgeGeometry.leftPawX == 37,
              ScratchEdgeGeometry.rightPawX == 155,
              ScratchEdgeGeometry.targetOriginX(
                  side: .left, visibleMinX: 0, visibleMaxX: 1_000, scale: 0.75
              ) == -27.75,
              ScratchEdgeGeometry.targetOriginX(
                  side: .right, visibleMinX: 0, visibleMaxX: 1_000, scale: 0.75
              ) == 883.75,
              ScratchEdgeGeometry.travelState(fromOriginX: 500, toOriginX: 100) == .runningLeft,
              ScratchEdgeGeometry.travelState(fromOriginX: 100, toOriginX: 500) == .runningRight,
              ScratchEdgeGeometry.farSide(
                  currentOriginX: 850, visibleMinX: 0, visibleMaxX: 1_000, scale: 0.75
              ) == .left else {
            throw SelfTestError("scratch edge geometry did not align measured paws or choose the far edge")
        }
        var liveScratchOriginX: CGFloat = 850
        guard ScratchEdgeGeometry.autonomousSide(
            currentOriginX: liveScratchOriginX,
            visibleMinX: 0,
            visibleMaxX: 1_000,
            scale: 0.75,
            randomUnit: 0.99
        ) == .right else {
            throw SelfTestError("autonomous scratch did not choose the nearest edge from a live right-side position")
        }
        liveScratchOriginX = 100
        guard ScratchEdgeGeometry.autonomousSide(
            currentOriginX: liveScratchOriginX,
            visibleMinX: 0,
            visibleMaxX: 1_000,
            scale: 0.75,
            randomUnit: 0.99
        ) == .left,
              ScratchEdgeGeometry.autonomousSide(
                  currentOriginX: liveScratchOriginX,
                  visibleMinX: 0,
                  visibleMaxX: 1_000,
                  scale: 0.75,
                  randomUnit: 0
              ) == .right else {
            throw SelfTestError("autonomous scratch did not follow the live position or deterministically exercise the far-edge branch")
        }
        var movementOrigin: NSPoint? = NSPoint(x: 100, y: 100)
        let movementMover = ScratchPanelMover(
            currentOrigin: { movementOrigin },
            setOrigin: { movementOrigin = $0 }
        )
        let movementTarget = NSPoint(x: 500, y: 100)
        var movementCompleted = false
        movementMover.move(to: movementTarget, duration: 0.12) {
            movementCompleted = true
        }
        guard pump(until: {
            guard let x = movementOrigin?.x else { return false }
            return x > 100 && x < movementTarget.x
        }), !movementCompleted else {
            throw SelfTestError("scratch panel did not translate toward its edge before showing the pose")
        }
        guard pump(until: { movementCompleted }),
              abs((movementOrigin?.x ?? -.infinity) - movementTarget.x) < 0.5 else {
            throw SelfTestError("scratch panel did not reach its edge before completing")
        }
        let recordedStart = NSPoint(x: 100, y: 100)
        var returnCompleted = false
        movementMover.move(to: recordedStart, duration: 0.12) {
            returnCompleted = true
        }
        guard pump(until: {
            guard let x = movementOrigin?.x else { return false }
            return x < movementTarget.x && x > recordedStart.x
        }), !returnCompleted else {
            throw SelfTestError("scratch panel did not travel back toward its recorded start after the rake")
        }
        guard pump(until: { returnCompleted }),
              abs((movementOrigin?.x ?? .infinity) - recordedStart.x) < 0.5 else {
            throw SelfTestError("scratch panel did not return to its recorded start after the rake")
        }
        movementMover.cancel()
        let winnieSleepAnimator = Animator(
            sheet: sleepingWinnie.sheet,
            view: nil,
            sleepHoldRange: 0.03...0.03
        )
        winnieSleepAnimator.playSleep(winnieSleep)
        let firstWinnieSleepPose = winnieSleepAnimator.currentSleepPoseIndex
        guard firstWinnieSleepPose != nil,
              pump(until: {
                  winnieSleepAnimator.currentSleepPoseIndex != nil
                      && winnieSleepAnimator.currentSleepPoseIndex != firstWinnieSleepPose
              }) else {
            throw SelfTestError("Winnie's held sleep pose did not rotate to a different pose")
        }
        winnieSleepAnimator.stop()
        print("Calm assets: Winnie sleep/wake/scratch load 8/5/2 with y=203 grounding and pixel-mapped left=00/right=01; her Frisky scratch whim exceeds Ajman's Calm default; Ajman loaf/sleep/wake/scratch load 8/8/5/2; scratch travel returns home")

        var scratchEligibility = ScratchEligibility(
            hasAsset: true,
            isShown: true,
            liveState: .running,
            displayedState: .idle,
            isManual: false,
            isCalmPose: false,
            isGlancing: false
        )
        var scratchEvents: [String] = []
        let scratchBehavior = ScratchBehavior(
            animation: ajmanScratch,
            eligibility: { scratchEligibility },
            willStart: { scratchEvents.append("start") },
            moveToEdge: { side, completion in
                scratchEvents.append(side == .left ? "move-left" : "move-right")
                completion()
            },
            moveBackToStart: { completion in
                scratchEvents.append("move-home")
                completion()
            },
            showPose: { side in
                scratchEvents.append(side == .left ? "pose-left" : "pose-right")
                return true
            },
            setRaking: { enabled, amplitude in
                scratchEvents.append(enabled ? "rake-on-\(amplitude)" : "rake-off-\(amplitude)")
            },
            showIdle: { scratchEvents.append("idle") },
            didFinish: { scratchEvents.append("finish") },
            scheduler: { _, action in action() }
        )
        guard !scratchBehavior.startIfEligible(side: .left) else {
            throw SelfTestError("scratch started while the live state was active")
        }
        guard scratchBehavior.forceStart(side: .right),
              !scratchBehavior.isPerforming,
              scratchEvents == ["start", "move-right", "pose-right", "rake-on-5.0", "rake-off-5.0", "move-home", "idle", "finish"] else {
            throw SelfTestError("debug scratch did not bypass eligibility and finish: \(scratchEvents)")
        }
        scratchEvents.removeAll()
        scratchEligibility = ScratchEligibility(
            hasAsset: true,
            isShown: true,
            liveState: .idle,
            displayedState: .idle,
            isManual: false,
            isCalmPose: true,
            isGlancing: false
        )
        guard !scratchBehavior.startIfEligible(side: .left) else {
            throw SelfTestError("scratch started during loaf or sleep")
        }
        scratchEligibility = ScratchEligibility(
            hasAsset: true,
            isShown: true,
            liveState: .idle,
            displayedState: .idle,
            isManual: false,
            isCalmPose: false,
            isGlancing: false
        )
        guard scratchBehavior.startIfEligible(side: .left),
              !scratchBehavior.isPerforming,
              scratchEvents == ["start", "move-left", "pose-left", "rake-on-5.0", "rake-off-5.0", "move-home", "idle", "finish"] else {
            throw SelfTestError("idle scratch did not approach, rake, and return to idle: \(scratchEvents)")
        }
        scratchBehavior.teardown()
        print("Scratch behavior: no enable-flag gate; debug force bypasses eligibility; active/sleep gates reject; idle approaches, rakes, runs home, and returns")

        var sleepLiveState = AnimationState.idle
        let sleepAnimator = Animator(
            sheet: sleepingAjman.sheet,
            view: nil,
            sleepHoldRange: 0.03...0.03
        )
        let shortDoze = PetMode(
            animator: sleepAnimator,
            loafAnimation: ajmanLoaf,
            sleepAnimation: ajmanSleep,
            wakeAnimation: ajmanWake,
            currentLiveState: { sleepLiveState },
            isManualMode: { false },
            loafInterval: 0.04,
            dozeInterval: 0.14,
            wakeHoldRange: 0.05...0.05
        )
        guard shortDoze.forceLoaf(), shortDoze.isLoafing, sleepAnimator.isPlayingLoaf,
              shortDoze.forceSleep(), shortDoze.isSleeping, sleepAnimator.isPlayingSleep else {
            throw SelfTestError("forced per-pet loaf/sleep paths did not select their pose strips")
        }
        shortDoze.yieldToHigherPriorityDriver()
        shortDoze.resumeAtRest()
        guard pump(until: { shortDoze.isLoafing && sleepAnimator.isPlayingLoaf }) else {
            throw SelfTestError("moderate calm interval did not transition Ajman to loaf")
        }
        guard PetView.sleepBreathingScale == 1.02,
              PetView.sleepBreathingHalfPeriod == 5,
              PetView.sleepBreathingAnchorPoint == CGPoint(x: 0.5, y: 0) else {
            throw SelfTestError("Ajman's calm breathing geometry was not subtle and bottom-anchored")
        }
        let firstLoafPose = sleepAnimator.currentLoafPoseIndex
        guard pump(until: {
            sleepAnimator.currentLoafPoseIndex != nil
                && sleepAnimator.currentLoafPoseIndex != firstLoafPose
        }) else {
            throw SelfTestError("Ajman's held loaf pose did not rotate to a different pose")
        }
        guard pump(until: { shortDoze.isSleeping && sleepAnimator.isPlayingSleep }),
              !shortDoze.isLoafing, !sleepAnimator.isPlayingLoaf else {
            throw SelfTestError("longer calm interval did not progress loaf to sleep")
        }

        shortDoze.stir()
        guard shortDoze.isWaking, sleepAnimator.isPlayingWake,
              sleepAnimator.currentWakePoseIndex != nil else {
            throw SelfTestError("simulated bound-agent stir did not start a held stretch/yawn")
        }
        sleepLiveState = .running
        guard pump(until: { !shortDoze.isWaking && sleepAnimator.currentState == .running }),
              !sleepAnimator.isPlayingWake else {
            throw SelfTestError("agent wake did not finish its held pose before handing off to running")
        }

        sleepLiveState = .idle
        shortDoze.resumeAtRest()
        guard pump(until: { shortDoze.isLoafing && sleepAnimator.isPlayingLoaf }) else {
            throw SelfTestError("Ajman did not return to loaf for the click-wake test")
        }
        shortDoze.wake()
        let heldWakePose = sleepAnimator.currentWakePoseIndex
        guard shortDoze.isWaking, sleepAnimator.isPlayingWake, heldWakePose != nil else {
            throw SelfTestError("simulated click did not interrupt loaf with a stretch/yawn")
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        guard sleepAnimator.currentWakePoseIndex == heldWakePose else {
            throw SelfTestError("stretch/yawn changed frames during its static hold")
        }
        guard pump(until: {
            !shortDoze.isWaking && sleepAnimator.currentState == .idle && !sleepAnimator.isPlayingCalmPose
        }) else {
            throw SelfTestError("click wake did not return to idle after the held stretch/yawn")
        }
        guard shortDoze.forceStretch(), shortDoze.isWaking, sleepAnimator.isPlayingWake,
              sleepAnimator.currentWakePoseIndex != nil,
              pump(until: {
                  !shortDoze.isWaking && sleepAnimator.currentState == .idle
                      && !sleepAnimator.isPlayingCalmPose
              }) else {
            throw SelfTestError("direct stretch did not play once and settle back to idle")
        }
        shortDoze.teardown()
        sleepAnimator.stop()

        let catatonicAnimator = Animator(sheet: sleepingAjman.sheet, view: nil)
        let catatonicDoze = PetMode(
            animator: catatonicAnimator,
            loafAnimation: ajmanLoaf,
            sleepAnimation: ajmanSleep,
            wakeAnimation: ajmanWake,
            currentLiveState: { .idle },
            isManualMode: { false },
            loafInterval: 0.04,
            dozeInterval: 0.14
        )
        catatonicDoze.resumeAtRest()
        catatonicDoze.setTemperament(.catatonic)
        guard pump(until: { catatonicDoze.isSleeping && catatonicAnimator.isPlayingSleep }) else {
            throw SelfTestError("Catatonic did not auto-sleep on its near-immediate scaled threshold")
        }
        catatonicDoze.teardown()
        catatonicAnimator.stop()

        let insaneAnimator = Animator(sheet: sleepingAjman.sheet, view: nil)
        let insaneDoze = PetMode(
            animator: insaneAnimator,
            loafAnimation: ajmanLoaf,
            sleepAnimation: ajmanSleep,
            wakeAnimation: ajmanWake,
            currentLiveState: { .idle },
            isManualMode: { false },
            loafInterval: 0.03,
            dozeInterval: 0.05
        )
        insaneDoze.resumeAtRest()
        insaneDoze.setTemperament(.insane)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        guard !insaneDoze.isLoafing, !insaneDoze.isSleeping,
              !insaneAnimator.isPlayingLoaf, !insaneAnimator.isPlayingSleep else {
            throw SelfTestError("Insane entered automatic loaf or sleep")
        }
        guard insaneDoze.forceSleep(), insaneDoze.isSleeping, insaneAnimator.isPlayingSleep else {
            throw SelfTestError("Insane temperament blocked manual Actions -> Sleep")
        }
        insaneDoze.teardown()
        insaneAnimator.stop()

        let noSleepAnimator = Animator(sheet: sleepingAjman.sheet, view: nil)
        let noSleepMode = PetMode(
            animator: noSleepAnimator,
            loafAnimation: nil,
            sleepAnimation: nil,
            wakeAnimation: nil,
            currentLiveState: { sleepLiveState },
            isManualMode: { false },
            loafInterval: 0.03,
            dozeInterval: 0.05
        )
        noSleepMode.resumeAtRest()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        guard !noSleepMode.isLoafing, !noSleepMode.isSleeping,
              !noSleepAnimator.isPlayingLoaf, !noSleepAnimator.isPlayingSleep else {
            throw SelfTestError("a pet without calm art entered loaf or sleep")
        }
        noSleepMode.teardown()
        noSleepAnimator.stop()
        print("Calm behavior: Normal idle -> rotating loaf -> sleep unchanged; Catatonic auto-sleeps immediately; Insane never auto-rests but manual Sleep works; activity/click/no-asset guards pass")

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
        if normalizationPetIDs.contains("winnie") {
            let winnieSheet = try catalog.load(id: "winnie", steadySize: false).sheet
            guard let idle = winnieSheet.animationTable.definition(for: .idle),
                  let failed = winnieSheet.animationTable.definition(for: .failed),
                  let idleTarget = SteadySize.targetBox(
                    idleBounds: winnieSheet.contentBounds(for: idle).compactMap { $0 },
                    cellWidth: SpriteSheet.cellWidth,
                    cellHeight: SpriteSheet.cellHeight
                  ) else {
                throw SelfTestError("Winnie idle/failed definitions could not be measured")
            }
            let failedBounds = winnieSheet.contentBounds(for: failed).compactMap { $0 }
            guard idle.frameCount == 6,
                  failedBounds.count == failed.frameCount,
                  failedBounds.allSatisfy({
                    $0.width <= 130
                        && $0.height <= idleTarget.height + 2
                        && abs($0.minY - CGFloat(SpriteSheet.contentMargin)) <= 1
                  }),
                  failedBounds.contains(where: { $0.width >= 126 }) else {
                throw SelfTestError("Winnie idle was not six frames or failed frames lost their calibrated 128px fit: \(failedBounds)")
            }
            print("Winnie seated idle: 6 frames; failed row preserves its calibrated 128x198 fit with Steady Size off")
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
        let connectionMenu = StatusMenu(
            registry: registry,
            pets: [],
            shownPetIDs: [],
            bindings: [:],
            relativeScales: [:],
            temperaments: [:],
            debugStates: [],
            sleepAvailable: false,
            agentNotificationsEnabled: notificationPreferences.isEnabled,
            claudeSettingsPath: settings
        )
        let menuTitles = connectionMenu.topLevelMenuTitlesForTesting
        guard !menuTitles.contains("Playful Idle"),
              menuTitles.filter({ $0 == "Connect to Claude Code" }).count == 1,
              !menuTitles.contains("Disconnect from Claude Code"),
              connectionMenu.claudeConnectionStateForTesting == .on,
              connectionMenu.agentNotificationsStateForTesting == .off else {
            throw SelfTestError("cleaned menu items or initial checkbox states were incorrect")
        }
        print("Menu fixture: Playful Idle absent; one Claude checkbox reflects installed hooks; notifications off")
        let uninstalled = try ClaudeHookInstaller.uninstall(settingsPath: settings)
        connectionMenu.refreshClaudeConnectionStateForTesting()
        let afterUninstall = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        guard containsCommand(afterUninstall, command: userCommand),
              !containsCommand(afterUninstall, command: hookPath),
              uninstalled.commandsRemoved == ClaudeHookInstaller.events.count,
              connectionMenu.claudeConnectionStateForTesting == .off else {
            throw SelfTestError("uninstaller fixture assertions failed")
        }
        print("Claude checkbox fixture: uninstall removes \(ClaudeHookInstaller.events.count) Ajman commands, preserves user hook, and clears checkmark")
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

if CommandLine.arguments.contains("--update-feed-smoke") {
    Task {
        if let release = await GitHubReleaseChecker.latest() {
            print("UPDATE FEED tag=\(release.tagName) preferredAppAsset=\(release.preferredAppAsset?.name ?? "nil")")
            exit(0)
        }
        print("UPDATE FEED nil")
        exit(1)
    }
    dispatchMain()
}

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
