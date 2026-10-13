import Darwin
import Foundation

public final class LocalEventServer: @unchecked Sendable {
    private let lock = NSLock()
    private var thread: Thread?
    private var socketFD: Int32 = -1
    private var running = false
    public var onPayload: (@Sendable (Data) -> Void)?

    public init() {}

    public func start(socketPath: String) throws {
        lock.lock()
        if running {
            lock.unlock()
            return
        }
        running = true
        lock.unlock()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        unlink(socketPath)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: pathBytes.count + 1) { raw in
                for (index, byte) in pathBytes.enumerated() { raw[index] = byte }
                raw[pathBytes.count] = 0
            }
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        guard bound == 0 else {
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        chmod(socketPath, 0o600)
        guard listen(fd, 16) == 0 else {
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        lock.lock()
        socketFD = fd
        lock.unlock()
        let thread = Thread { [weak self] in
            self?.acceptLoop()
        }
        thread.name = "MochAI Event Server"
        thread.start()
        self.thread = thread
        MochaiLog.hooks.info("Local event socket is listening")
    }

    public func stop() {
        lock.lock()
        running = false
        let fd = socketFD
        socketFD = -1
        lock.unlock()
        if fd >= 0 { close(fd) }
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running && socketFD >= 0
    }

    private func acceptLoop() {
        while true {
            lock.lock()
            let listening = running
            let fd = socketFD
            lock.unlock()
            if !listening || fd < 0 { break }
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                break
            }
            var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var buffer = [UInt8](repeating: 0, count: 65_536)
            let count = read(client, &buffer, buffer.count)
            close(client)
            guard count > 0 else { continue }
            let data = Data(buffer.prefix(count))
            onPayload?(data)
        }
    }

    public static func drainFallbackDirectory(_ directory: URL, handler: (Data) -> Void) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let sorted = files.filter { $0.pathExtension == "json" }.sorted { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left < right
        }
        for file in sorted.prefix(100) {
            if let data = try? Data(contentsOf: file) {
                handler(data)
            }
            try? fm.removeItem(at: file)
        }
    }
}
