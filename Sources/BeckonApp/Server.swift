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
                // Out of descriptors, or a client that hung up before it was accepted: both pass by themselves.
                // The pause keeps a full table from spinning this thread until a descriptor frees up.
                if code == EMFILE || code == ENFILE || code == ECONNABORTED { usleep(100_000); continue }
                // Anything else means the listening socket is gone, and with this thread goes every card.
                AuditLog.note("SERVER stopped accepting: hooks fall back to the terminal until beckon is restarted")
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

    private static func readToEOF(_ fd: Int32) -> Data {
        // A hook payload is small; cap reads so a misbehaving client can't hold a thread forever.
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &buf, buf.count)
            if n > 0 { out.append(buf, count: n) } else if n < 0 && errno == EINTR { continue } else { break }
        }
        return out
    }

    private func posix(_ what: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "\(what): \(String(cString: strerror(errno)))"])
    }
}
