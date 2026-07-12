import Foundation

/// Observe-only tailer for Codex CLI and Desktop rollout logs.
final class CodexMonitor {
    private struct FileState {
        var offset: UInt64
        var partialLine = Data()
        var sessionID: String?
        var cwd: String?
        var originator: String?
    }

    private static let pollInterval: TimeInterval = 1
    private static let recentFileAge: TimeInterval = 24 * 60 * 60
    private static let maximumReadSize = 256 * 1_024
    private static let maximumLineSize = 64 * 1_024

    private let sessionsURL: URL
    private let queue = DispatchQueue(label: "net.varnelis.ajman.codex-monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var files: [String: FileState] = [:]
    var eventHandler: ((AgentEvent) -> Void)?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let home: URL
        if let override = environment["CODEX_HOME"], !override.isEmpty {
            home = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        }
        sessionsURL = home.appendingPathComponent("sessions", isDirectory: true)
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            self.poll()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
            self?.files.removeAll()
        }
    }

    deinit { timer?.cancel() }

    private func poll() {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: sessionsURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-Self.recentFileAge)
        var discovered = Set<String>()
        for case let url as URL in enumerator where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  (values.contentModificationDate ?? .distantPast) >= cutoff else { continue }
            discovered.insert(url.path)
            if files[url.path] == nil {
                bootstrap(url, size: UInt64(values.fileSize ?? 0))
            }
            readAppends(url)
        }
        files = files.filter { discovered.contains($0.key) }
    }

    private func bootstrap(_ url: URL, size: UInt64) {
        var state = FileState(offset: size)

        // Metadata lives at the head of a rollout. Read only a small bounded
        // prefix so an already-running session has an identity, but do not
        // replay its historical activity. Actual tailing begins at EOF.
        if size > 0,
           let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            let prefix = (try? handle.read(upToCount: min(Self.maximumLineSize, Int(size)))) ?? Data()
            if let newline = prefix.firstIndex(of: 0x0a) {
                consumeLine(Data(prefix[..<newline]), state: &state, metadataOnly: true)
            } else if size <= UInt64(Self.maximumLineSize) {
                consumeLine(prefix, state: &state, metadataOnly: true)
            }
        }
        files[url.path] = state
    }

    private func readAppends(_ url: URL) {
        guard var state = files[url.path],
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attributes[.size] as? NSNumber else { return }
        let size = number.uint64Value
        if size < state.offset {
            state.offset = 0
            state.partialLine.removeAll(keepingCapacity: true)
        }
        guard size > state.offset,
              let handle = try? FileHandle(forReadingFrom: url) else {
            files[url.path] = state
            return
        }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: state.offset)
            let amount = min(Self.maximumReadSize, Int(size - state.offset))
            let chunk = try handle.read(upToCount: amount) ?? Data()
            state.offset += UInt64(chunk.count)
            state.partialLine.append(chunk)
            consumeCompleteLines(state: &state)
            if state.partialLine.count > Self.maximumLineSize {
                state.partialLine.removeAll(keepingCapacity: true)
            }
        } catch {
            // The next poll retries; rollout files are an explicitly unstable surface.
        }
        files[url.path] = state
    }

    private func consumeCompleteLines(state: inout FileState) {
        while let newline = state.partialLine.firstIndex(of: 0x0a) {
            let line = Data(state.partialLine[..<newline])
            state.partialLine.removeSubrange(...newline)
            consumeLine(line, state: &state, metadataOnly: false)
        }
    }

    private func consumeLine(_ line: Data, state: inout FileState, metadataOnly: Bool) {
        guard !line.isEmpty, line.count <= Self.maximumLineSize,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let tag = object["type"] as? String,
              let payload = object["payload"] as? [String: Any] else { return }

        if normalized(tag) == "sessionmeta" {
            state.sessionID = string(in: payload, keys: ["id", "session_id", "thread_id"]) ?? state.sessionID
            state.cwd = string(in: payload, keys: ["cwd"]) ?? state.cwd
            state.originator = string(in: payload, keys: ["originator"]) ?? state.originator
            emit("SessionStart", payload: payload, state: state)
            return
        }
        guard !metadataOnly, normalized(tag) == "eventmsg",
              let eventType = string(in: payload, keys: ["type", "event", "name"]),
              let mapped = mappedEvent(eventType) else { return }
        emit(mapped, payload: payload, state: state)
    }

    private func emit(_ event: String, payload: [String: Any], state: FileState) {
        let sessionID = string(in: payload, keys: ["session_id", "thread_id", "id"]) ?? state.sessionID
        let cwd = string(in: payload, keys: ["cwd"]) ?? state.cwd
        var raw = payload.mapValues(JSONValue.init)
        if let originator = state.originator { raw["originator"] = .string(originator) }
        eventHandler?(AgentEvent(
            provider: .codex,
            event: event,
            sessionId: sessionID,
            cwd: cwd,
            toolName: string(in: payload, keys: ["tool_name", "name", "command"]),
            transcriptPath: nil,
            timestamp: Date(),
            raw: raw
        ))
    }

    private func mappedEvent(_ value: String) -> String? {
        let event = normalized(value)
        switch event {
        case "taskstarted", "turnstarted": return "UserPromptSubmit"
        case "taskcomplete", "turncomplete": return "Stop"
        case "turnaborted", "error", "streamerror": return "CodexFailure"
        case "shutdowncomplete": return "SessionEnd"
        case "requestpermissions", "execapprovalrequest", "applypatchapprovalrequest",
             "requestuserinput", "elicitationrequest": return "Notification"
        case "execcommandbegin", "mcptoolcallbegin", "websearchbegin", "imagegenerationbegin", "patchapplybegin":
            return "PreToolUse"
        case "execcommandend", "mcptoolcallend", "websearchend", "imagegenerationend", "patchapplyend":
            return "PostToolUse"
        default:
            if event.hasSuffix("begin") && (event.contains("tool") || event.contains("command")) { return "PreToolUse" }
            if event.hasSuffix("end") && (event.contains("tool") || event.contains("command")) { return "PostToolUse" }
            return nil
        }
    }

    private func normalized(_ value: String) -> String {
        value.unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(String.init).joined().lowercased()
    }

    private func string(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }
}
