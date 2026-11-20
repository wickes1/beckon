import Foundation
import Testing
@testable import BeckonApp

/// Two connected sockets: the test writes into the first as a client would, the server code reads the second.
private func pair() -> (client: Int32, server: Int32) {
    var fds: [Int32] = [0, 0]
    socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
    var on: Int32 = 1
    setsockopt(fds[0], SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))  // a cut-off client must not kill the tests
    return (fds[0], fds[1])
}

@Suite struct RequestLimits {
    init() { AuditLog.path = NSTemporaryDirectory() + "beckon-test-audit.log" }

    // Every local process of the user can connect. One that sends without end must not be able to make the app
    // buffer it all: past the limit the request is dropped whole, never handed on cut short.
    @Test func aRequestOverTheSizeLimitIsDropped() {
        for (bytes, kept) in [(1000, 1000), (1001, 0)] {
            let (client, server) = pair()
            defer { close(client); close(server) }
            _ = [UInt8](repeating: 0x20, count: bytes).withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
            shutdown(client, SHUT_WR)
            #expect(Server.readToEOF(server, limit: 1000).count == kept)
        }
    }

    // The idle timeout alone lets a client that keeps a trickle going hold a reader thread for good; each such
    // connection is one more thread that never comes back. The whole request has a deadline too.
    @Test func aClientThatNeverStopsSendingIsCutOff() {
        let (client, server) = pair()
        defer { close(server) }
        Thread.detachNewThread {
            var byte: UInt8 = 0x20
            for _ in 0..<150 where write(client, &byte, 1) == 1 { usleep(20_000) }  // 3 s, well inside the idle timeout each time
            close(client)
        }
        let started = Date()
        let data = Server.readToEOF(server, idle: 1, total: 0.3)
        #expect(data.isEmpty)
        #expect(Date().timeIntervalSince(started) < 1.5)
    }

    // A client that stalls part way is handled with what it sent. That half envelope can't be read, and without a
    // line saying the request went quiet nothing would tell why its card never came.
    @Test func aRequestThatGoesQuietIsHandledAsItStandsAndLogged() throws {
        let (client, server) = pair()
        defer { close(client); close(server) }
        let before = (try? Data(contentsOf: URL(fileURLWithPath: AuditLog.path)))?.count ?? 0
        _ = Array(#"{"v":1"#.utf8).withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
        #expect(Server.readToEOF(server, idle: 0.2, total: 2).count == 6)
        let added = String(decoding: try Data(contentsOf: URL(fileURLWithPath: AuditLog.path)).dropFirst(before), as: UTF8.self)
        #expect(added.contains("SERVER request went quiet for 0 s after 6 bytes"))
    }
}

@Suite struct AcceptErrors {
    // A full descriptor table or a moment's memory pressure passes; the socket dying doesn't. Taking a passing error
    // for a dead socket ends the server, and with it every card until beckon is restarted. Taking a dead socket for a
    // passing error would spin on it for good.
    @Test func onlyErrorsThatPassAreRetried() {
        for code in [EMFILE, ENFILE, ENOMEM, ENOBUFS, ECONNABORTED] { #expect(Server.acceptErrorPasses(code), "errno \(code)") }
        for code in [EBADF, EINVAL, ENOTSOCK, EOPNOTSUPP] { #expect(!Server.acceptErrorPasses(code), "errno \(code)") }
    }
}
