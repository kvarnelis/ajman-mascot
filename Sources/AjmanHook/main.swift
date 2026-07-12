import Darwin
import Foundation

private let maximumInput = 64 * 1_024

private func finish() -> Never { exit(EXIT_SUCCESS) }

var input = Data()
while input.count <= maximumInput {
    let chunk = FileHandle.standardInput.readData(ofLength: min(8_192, maximumInput + 1 - input.count))
    if chunk.isEmpty { break }
    input.append(chunk)
}
guard input.count <= maximumInput, !input.isEmpty else { finish() }

if let eventIndex = CommandLine.arguments.firstIndex(of: "--event"),
   CommandLine.arguments.indices.contains(eventIndex + 1),
   var object = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
   object["hook_event_name"] == nil,
   let encoded = try? JSONSerialization.data(withJSONObject: {
       object["hook_event_name"] = CommandLine.arguments[eventIndex + 1]
       return object
   }()) {
    input = encoded
}

input.append(0x0a)
let socketPath = ProcessInfo.processInfo.environment["AJMAN_SOCKET_PATH"]
    ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".ajman/run/ajman.sock").path
guard socketPath.utf8.count < MemoryLayout<sockaddr_un>.size - 2 else { finish() }

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { finish() }
defer { close(fd) }
_ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
withUnsafeMutablePointer(to: &address.sun_path) { pointer in
    pointer.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { destination in
        _ = socketPath.withCString { source in strncpy(destination, source, pathCapacity - 1) }
    }
}
let connected = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
if connected != 0 {
    guard errno == EINPROGRESS else { finish() }
    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    guard poll(&descriptor, 1, 100) == 1 else { finish() }
    var error: Int32 = 0
    var length = socklen_t(MemoryLayout<Int32>.size)
    guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { finish() }
}

let deadline = DispatchTime.now().uptimeNanoseconds + 100_000_000
input.withUnsafeBytes { bytes in
    guard let base = bytes.baseAddress else { return }
    var sent = 0
    while sent < bytes.count, DispatchTime.now().uptimeNanoseconds < deadline {
        let result = Darwin.write(fd, base.advanced(by: sent), bytes.count - sent)
        if result > 0 { sent += result; continue }
        if errno != EAGAIN && errno != EWOULDBLOCK { break }
        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        _ = poll(&descriptor, 1, 10)
    }
}
finish()
