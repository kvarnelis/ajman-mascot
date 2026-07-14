import AppKit
import Foundation

struct UpdatePreferences {
    static let promptsDisabledKey = "AjmanUpdatePromptsDisabled"
    static let skippedVersionKey = "AjmanSkippedUpdateVersion"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var promptsEnabled: Bool {
        get { !defaults.bool(forKey: Self.promptsDisabledKey) }
        nonmutating set { defaults.set(!newValue, forKey: Self.promptsDisabledKey) }
    }

    var skippedVersion: String? {
        get { defaults.string(forKey: Self.skippedVersionKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.skippedVersionKey) }
    }

    func shouldPrompt(for tag: String, runningVersion: AppVersion = AjmanApp.version) -> Bool {
        promptsEnabled && skippedVersion != tag && (AppVersion(tag).map { $0 > runningVersion } ?? false)
    }
}

struct GitHubRelease: Decodable {
    struct Asset: Decodable { let name: String }
    let tagName: String
    let assets: [Asset]

    var preferredAppAsset: String? {
        assets.map(\.name).first {
            $0.localizedCaseInsensitiveContains("ajman") && $0.lowercased().hasSuffix(".zip")
        } ?? assets.map(\.name).first { $0.lowercased().hasSuffix(".zip") }
    }
}

enum QuietProcess {
    static func run(_ executable: URL, arguments: [String], currentDirectory: URL? = nil) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.commandFailed }
        return data
    }
}

enum GitHubReleaseChecker {
    static func latest() -> GitHubRelease? {
        do {
            let data = try QuietProcess.run(
                URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["gh", "release", "view", "--repo", AjmanApp.repository, "--json", "tagName,assets"]
            )
            return try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            return nil
        }
    }
}

enum UpdateError: LocalizedError {
    case commandFailed
    case noAppAsset
    case invalidArchive
    case invalidApp
    case wrongVersion
    case notRunningFromApp
    case helperCouldNotStart

    var errorDescription: String? {
        switch self {
        case .commandFailed: return "the release download could not be completed"
        case .noAppAsset: return "the release has no Ajman app zip"
        case .invalidArchive: return "the downloaded archive is invalid"
        case .invalidApp: return "the downloaded app did not pass verification"
        case .wrongVersion: return "the downloaded app version does not match the release"
        case .notRunningFromApp: return "this copy is not running from Ajman.app"
        case .helperCouldNotStart: return "the installer helper could not start"
        }
    }
}

struct PreparedUpdate {
    let helper: URL
    let arguments: [String]
}

enum UpdateInstaller {
    static func prepare(release: GitHubRelease) throws -> PreparedUpdate {
        guard let asset = release.preferredAppAsset else { throw UpdateError.noAppAsset }
        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory.appendingPathComponent("ajman-update-\(UUID().uuidString)", isDirectory: true)
        let download = work.appendingPathComponent("download", isDirectory: true)
        let expanded = work.appendingPathComponent("expanded", isDirectory: true)
        try fileManager.createDirectory(at: download, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: expanded, withIntermediateDirectories: true)

        _ = try QuietProcess.run(
            URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [
                "gh", "release", "download", release.tagName,
                "--repo", AjmanApp.repository, "--pattern", asset, "--dir", download.path,
            ]
        )
        let archive = download.appendingPathComponent(asset)
        guard fileManager.fileExists(atPath: archive.path),
              (try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0 else {
            throw UpdateError.invalidArchive
        }
        _ = try QuietProcess.run(
            URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", archive.path, expanded.path]
        )

        guard let app = findAjmanApp(in: expanded), verify(app: app, releaseTag: release.tagName) else {
            throw UpdateError.invalidApp
        }
        let current = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard current.pathExtension == "app", current.lastPathComponent == "Ajman.app" else {
            throw UpdateError.notRunningFromApp
        }

        let support = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("Ajman", isDirectory: true)
        try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        let marker = support.appendingPathComponent("update-failure.txt")
        let helper = work.appendingPathComponent("install-update.sh")
        try helperScript.write(to: helper, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)

        let parent = current.deletingLastPathComponent()
        let rootLink = parent.lastPathComponent == "build"
            ? parent.deletingLastPathComponent().appendingPathComponent("Ajman.app").path
            : ""
        return PreparedUpdate(
            helper: helper,
            arguments: [current.path, app.path, rootLink, String(ProcessInfo.processInfo.processIdentifier), marker.path, work.path]
        )
    }

    static func launch(_ prepared: PreparedUpdate) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [prepared.helper.path] + prepared.arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw UpdateError.helperCouldNotStart }
    }

    private static func findAjmanApp(in directory: URL) -> URL? {
        let direct = directory.appendingPathComponent("Ajman.app", isDirectory: true)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == "Ajman.app" && url.pathExtension == "app" {
            return url
        }
        return nil
    }

    private static func verify(app: URL, releaseTag: String) -> Bool {
        guard let bundle = Bundle(url: app),
              bundle.bundleIdentifier == "net.varnelis.Ajman",
              let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path),
              let bundleVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let expected = AppVersion(releaseTag), let actual = AppVersion(bundleVersion),
              expected == actual else { return false }
        return (try? QuietProcess.run(
            URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--verify", "--deep", "--strict", app.path]
        )) != nil
    }

    private static let helperScript = #"""
#!/bin/bash
set -u
CURRENT="$1"
NEW_APP="$2"
ROOT_LINK="$3"
OLD_PID="$4"
MARKER="$5"
WORK="$6"
BACKUP="${CURRENT}.backup-$(date +%Y%m%d-%H%M%S)"

write_failure() {
  mkdir -p "$(dirname "$MARKER")"
  printf '%s\n' "$1" > "$MARKER"
}

restore_old() {
  if [ -d "$BACKUP" ]; then
    if [ -d "$CURRENT" ]; then mv "$CURRENT" "${CURRENT}.failed-$(date +%Y%m%d-%H%M%S)"; fi
    mv "$BACKUP" "$CURRENT" || true
  fi
  write_failure "$1"
  /usr/bin/open "$CURRENT" >/dev/null 2>&1 || true
  exit 1
}

while /bin/kill -0 "$OLD_PID" >/dev/null 2>&1; do /bin/sleep 0.2; done
[ -d "$CURRENT" ] || { write_failure "the current app disappeared before installation"; exit 1; }
[ -d "$NEW_APP" ] || { write_failure "the verified update disappeared before installation"; /usr/bin/open "$CURRENT" >/dev/null 2>&1; exit 1; }
/bin/mv "$CURRENT" "$BACKUP" || { write_failure "the current app could not be backed up"; /usr/bin/open "$CURRENT" >/dev/null 2>&1; exit 1; }
/bin/mv "$NEW_APP" "$CURRENT" || restore_old "the new app could not replace the current app"
if [ -n "$ROOT_LINK" ]; then
  /bin/ln -sfn "build/Ajman.app" "$ROOT_LINK" || restore_old "the root app link could not be refreshed"
fi
/usr/bin/open "$CURRENT" >/dev/null 2>&1 || restore_old "the updated app could not be relaunched"
/bin/rm -f "$MARKER"
exit 0
"""#
}

@MainActor
final class UpdateManager {
    static let checkInterval: TimeInterval = 24 * 60 * 60

    private let bubble = UpdateBubbleController()
    private let defaults: UserDefaults
    private let anchorProvider: () -> NSWindow?
    private var preferences: UpdatePreferences
    private var latestRelease: GitHubRelease?
    private var timer: Timer?
    private var isChecking = false
    var promptsChanged: ((Bool) -> Void)?

    init(defaults: UserDefaults = .standard, anchorProvider: @escaping () -> NSWindow?) {
        self.defaults = defaults
        preferences = UpdatePreferences(defaults: defaults)
        self.anchorProvider = anchorProvider
        bubble.updateHandler = { [weak self] in self?.updatePressed() }
        bubble.laterHandler = { [weak self] in self?.bubble.dismiss() }
        bubble.disableHandler = { [weak self] in self?.disablePrompts() }
    }

    var promptsEnabled: Bool { preferences.promptsEnabled }

    func start() {
        showDeferredFailureIfNeeded()
        checkNow()
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkNow() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        bubble.dismiss()
    }

    func setPromptsEnabled(_ enabled: Bool) {
        preferences.promptsEnabled = enabled
        promptsChanged?(enabled)
        if enabled { checkNow() } else { bubble.dismiss() }
    }

    func preview() {
        latestRelease = nil
        bubble.showPreview(anchoredTo: anchorProvider())
    }

    func checkNow() {
        guard preferences.promptsEnabled, !isChecking else { return }
        isChecking = true
        Task { @MainActor [weak self] in
            let release = await Task.detached { GitHubReleaseChecker.latest() }.value
            self?.finishedChecking(release)
        }
    }

    private func finishedChecking(_ release: GitHubRelease?) {
        isChecking = false
        guard let release, preferences.shouldPrompt(for: release.tagName) else { return }
        latestRelease = release
        bubble.showRelease(tag: release.tagName, anchoredTo: anchorProvider())
    }

    private func updatePressed() {
        guard let release = latestRelease else {
            bubble.showPreviewNoOp()
            return
        }
        bubble.showProgress("Downloading and verifying…")
        Task { @MainActor [weak self] in
            let result = await Task.detached { () -> Result<PreparedUpdate, Error> in
                do { return .success(try UpdateInstaller.prepare(release: release)) }
                catch { return .failure(error) }
            }.value
            self?.finishPreparation(result)
        }
    }

    private func finishPreparation(_ result: Result<PreparedUpdate, Error>) {
        switch result {
        case .success(let prepared):
            do {
                try UpdateInstaller.launch(prepared)
                NSApplication.shared.terminate(nil)
            } catch {
                bubble.showFailure(error.localizedDescription, anchoredTo: anchorProvider())
            }
        case .failure(let error):
            bubble.showFailure(error.localizedDescription, anchoredTo: anchorProvider())
        }
    }

    private func disablePrompts() {
        preferences.promptsEnabled = false
        promptsChanged?(false)
        bubble.dismiss()
    }

    private func showDeferredFailureIfNeeded() {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("Ajman/update-failure.txt"),
              let message = try? String(contentsOf: support, encoding: .utf8), !message.isEmpty else { return }
        try? FileManager.default.removeItem(at: support)
        bubble.showFailure(message.trimmingCharacters(in: .whitespacesAndNewlines), anchoredTo: anchorProvider())
    }

    deinit { timer?.invalidate() }
}
