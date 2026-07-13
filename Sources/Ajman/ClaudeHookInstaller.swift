import Foundation

enum ClaudeHookInstaller {
    static let events = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse",
        "PostToolUseFailure", "Notification", "SubagentStart", "SubagentStop", "Stop", "SessionEnd",
    ]

    struct InstallSummary { let eventsAdded: [String]; let backupPath: String? }
    struct UninstallSummary { let commandsRemoved: Int; let backupPath: String }

    enum InstallerError: LocalizedError {
        case invalidRoot, invalidJSON, hookBinaryMissing
        var errorDescription: String? {
            switch self {
            case .invalidRoot: "The settings file must contain a JSON object."
            case .invalidJSON: "The settings file is not valid JSON and was left unchanged."
            case .hookBinaryMissing: "The bundled ajman-hook binary could not be found."
            }
        }
    }

    static func canonicalHookBinaryURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ajman/bin/ajman-hook")
    }

    static func installHookBinary(sourceURL: URL? = nil) throws -> URL {
        let source = sourceURL ?? Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("ajman-hook")
        guard let source, FileManager.default.fileExists(atPath: source.path) else { throw InstallerError.hookBinaryMissing }
        let destination = canonicalHookBinaryURL()
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        return destination
    }

    static func install(settingsPath: URL, hookBinaryPath: String) throws -> InstallSummary {
        let existed = FileManager.default.fileExists(atPath: settingsPath.path)
        var root = try readRoot(at: settingsPath, missingAllowed: true)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var added: [String] = []
        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            let alreadyInstalled = groups.contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(hookBinaryPath) == true }
            }
            if !alreadyInstalled {
                groups.append(["matcher": "", "hooks": [["type": "command", "command": hookBinaryPath]]])
                hooks[event] = groups
                added.append(event)
            }
        }
        root["hooks"] = hooks
        let backup = existed ? try backupFile(settingsPath) : nil
        try write(root, to: settingsPath)
        return InstallSummary(eventsAdded: added, backupPath: backup?.path)
    }

    static func uninstall(settingsPath: URL) throws -> UninstallSummary {
        var root = try readRoot(at: settingsPath, missingAllowed: false)
        let backup = try backupFile(settingsPath)
        var removed = 0
        if var hooks = root["hooks"] as? [String: Any] {
            for event in Array(hooks.keys) {
                guard let groups = hooks[event] as? [[String: Any]] else { continue }
                var survivingGroups: [[String: Any]] = []
                for var group in groups {
                    guard let commands = group["hooks"] as? [[String: Any]] else { survivingGroups.append(group); continue }
                    let survivors = commands.filter { command in
                        let isAjman = (command["command"] as? String).map { $0.contains("/ajman-hook") } ?? false
                        if isAjman { removed += 1 }
                        return !isAjman
                    }
                    if !survivors.isEmpty { group["hooks"] = survivors; survivingGroups.append(group) }
                }
                if survivingGroups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = survivingGroups }
            }
            if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        }
        try write(root, to: settingsPath)
        return UninstallSummary(commandsRemoved: removed, backupPath: backup.path)
    }

    private static func readRoot(at url: URL, missingAllowed: Bool) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            if missingAllowed { return [:] }
            throw CocoaError(.fileNoSuchFile)
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) else { throw InstallerError.invalidJSON }
        guard let root = object as? [String: Any] else { throw InstallerError.invalidRoot }
        return root
    }

    private static func backupFile(_ url: URL) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        var backup = URL(fileURLWithPath: url.path + ".ajman-backup-" + formatter.string(from: Date()))
        var suffix = 1
        while FileManager.default.fileExists(atPath: backup.path) {
            backup = URL(fileURLWithPath: url.path + ".ajman-backup-" + formatter.string(from: Date()) + "-\(suffix)")
            suffix += 1
        }
        try FileManager.default.copyItem(at: url, to: backup)
        return backup
    }

    private static func write(_ root: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data([0x0a])).write(to: url, options: .atomic)
    }
}
