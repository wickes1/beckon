import BeckonCore
import Darwin
import Foundation

/// One hook invocation. Waiting connections stay open until `reply` (answer, or empty for "no decision").
final class Connection {
    private let fd: Int32
    private var closed = false
    private let lock = NSLock()

    init(fd: Int32) { self.fd = fd }

    /// Set from the envelope: only waiting hooks read a reply; fire-and-forget ones have already hung up.
    var expectsReply = false

    /// Writes the reply (may be empty) if the hook is waiting, then closes. Only the first call counts.
    func reply(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        if expectsReply {
            var bytes = Array(text.utf8)
            bytes.append(0x0A)
            bytes.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
        }
        close(fd)
    }
}

/// Unix-socket server in a 0700 per-user directory. Rejects peers from other uids.
final class Server {
    private var listenFD: Int32 = -1
    private let onRequest: (Data, Connection) -> Void
    /// Called on the main queue if the server stops for good, so the app can say so: from then on no card comes.
    var onStop: (() -> Void)?

    init(onRequest: @escaping (Data, Connection) -> Void) { self.onRequest = onRequest }

    func start() throws {
        let dir = BeckonPaths.directory
        mkdir(dir, 0o700)
        chmod(dir, 0o700)
        let path = BeckonPaths.socket
        unlink(path)  // stale socket from a previous run

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw posix("socket") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw posix("socket path too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in raw.copyBytes(from: bytes); raw[bytes.count] = 0 }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { throw posix("bind \(path)") }
        chmod(path, 0o600)
        guard listen(listenFD, 64) == 0 else { throw posix("listen") }

        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "beckon.accept"
        thread.start()
    }

    private func acceptLoop() {
        var lastError: Int32 = 0
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                let code = errno
                if code == EINTR { continue }
                // Logged once per run of the same error: with the descriptor table full it recurs ten times a second.
                if code != lastError { AuditLog.note("SERVER accept failed: \(String(cString: strerror(code))) (errno \(code))") }
                lastError = code
                // The pause keeps a full table from spinning this thread until a descriptor frees up.
                if Self.acceptErrorPasses(code) { usleep(100_000); continue }
                // Anything else means the listening socket is gone, and with this thread goes every card. Close and
                // remove it, so a hook fails to connect and falls back to the terminal at once, rather than waiting in
                // a backlog nobody reads until Claude Code's hook timeout.
                close(listenFD)
                unlink(BeckonPaths.socket)
                AuditLog.note("SERVER stopped accepting: hooks fall back to the terminal until beckon is restarted")
                DispatchQueue.main.async { [weak self] in self?.onStop?() }
                return
            }
            lastError = 0
            var nosigpipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); continue }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let data = Self.readToEOF(client)
                let conn = Connection(fd: client)
                DispatchQueue.main.async { self?.onRequest(data, conn) }
            }
        }
    }

    /// Errors accept(2) gets over by itself: out of descriptors, memory or buffers, or a client that hung up before
    /// it was accepted. Taken for a dead socket, any one of them ended the server for the rest of the run.
    static func acceptErrorPasses(_ code: Int32) -> Bool { [EMFILE, ENFILE, ENOMEM, ENOBUFS, ECONNABORTED].contains(code) }

    /// A hook writes one small envelope in one go and hangs up its sending side. A client that does otherwise
    /// must not hold a thread or grow a buffer for as long as it likes: a silence of `idle` ends the request
    /// where it stands, and one that is still coming in after `total`, or is larger than `limit`, is dropped
    /// (empty data, which Intake answers like any other request it can't read).
    static func readToEOF(_ fd: Int32, limit: Int = 16 << 20, idle: TimeInterval = 2, total: TimeInterval = 5) -> Data {
        let deadline = ProcessInfo.processInfo.systemUptime + total
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let left = min(idle, deadline - ProcessInfo.processInfo.systemUptime)
            guard left > 0 else { return dropped("still arriving after \(total) s") }
            // At least a millisecond: a zero timeval would mean no timeout at all.
            let micros = max(1000, Int(left * 1_000_000))
            var timeout = timeval(tv_sec: micros / 1_000_000, tv_usec: Int32(micros % 1_000_000))
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let n = read(fd, &buf, buf.count)
            if n > 0 { out.append(buf, count: n) } else if n < 0 && errno == EINTR { continue }
            else if n < 0 && errno == EAGAIN && left < idle { continue }  // the deadline cut this wait short, not a silence
            else { break }
            guard out.count <= limit else { return dropped("larger than \(limit) bytes") }
        }
        return out
    }

    private static func dropped(_ why: String) -> Data {
        AuditLog.note("SERVER dropped a request: \(why)")
        return Data()
    }

    private func posix(_ what: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "\(what): \(String(cString: strerror(errno)))"])
    }
}
