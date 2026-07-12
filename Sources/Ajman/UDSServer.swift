import Darwin
import Foundation

final class UDSServer {
    static let maximumFrameSize = 64 * 1_024
    let socketURL: URL
    private let queue = DispatchQueue(label: "net.varnelis.ajman.uds", qos: .utility)
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    var eventHandler: ((AgentEvent) -> Void)?

    init(socketURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ajman/run/ajman.sock")) {
        self.socketURL = socketURL
    }

    func start() throws {
        let directory = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        unlink(socketURL.path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.ENOTSOCK) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard socketURL.path.utf8.count < pathCapacity else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { destination in
                _ = socketURL.path.withCString { source in strncpy(destination, source, pathCapacity - 1) }
            }
        }
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bindResult == 0, listen(fd, 16) == 0 else {
            let code = errno; close(fd); listenFD = -1; throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        chmod(socketURL.path, 0o600)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnections() }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    func stop() {
        source?.cancel(); source = nil; listenFD = -1
        unlink(socketURL.path)
    }

    deinit { stop() }

    private func acceptConnections() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 { break }
            queue.async { [weak self] in self?.read(client) }
        }
    }

    private func read(_ fd: Int32) {
        defer { close(fd) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count <= 0 { break }
            buffer.append(chunk, count: count)
            while let newline = buffer.firstIndex(of: 0x0a) {
                let frame = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if let event = AgentEvent.decode(frame: frame) { eventHandler?(event) }
            }
            if buffer.count > Self.maximumFrameSize { return }
        }
        if !buffer.isEmpty, let event = AgentEvent.decode(frame: buffer) { eventHandler?(event) }
    }
}
