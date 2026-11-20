import Foundation
import Testing
@testable import BeckonApp

// The hook CLI is top-level code, so these run the built binary. Always with an empty environment and a HOME of
// its own: the CLI finds the app's socket under HOME, and a test must never reach the real app, nor be taken for
// a headless Claude Code run (which the CLI skips) because the tests themselves were started from one.
private final class Here {}

struct CLIResult {
    let status: Int32
    let out: String
    let err: String
}

/// A throwaway HOME. Under /tmp, not the per-user temp directory: a socket path has to fit in 104 bytes.
final class TestHome {
    let path: String
    var directory: String { path + "/Library/Application Support/beckon" }

    init() throws {
        var template = Array("/tmp/beckon-test.XXXXXX".utf8CString)
        guard mkdtemp(&template) != nil else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        path = String(cString: template)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: path) }
}

func beckon(_ args: [String], stdin: String = "", home: TestHome) throws -> CLIResult {
    let process = Process()
    process.executableURL = Bundle(for: Here.self).bundleURL.deletingLastPathComponent().appendingPathComponent("beckon")
    process.arguments = args
    process.environment = ["HOME": home.path]
    let input = Pipe(), out = Pipe(), err = Pipe()
    // Into the pipe before the CLI starts. Written after, it raced a CLI that exits without reading stdin (every
    // command line it can't read): writing to a pipe nobody holds open raises SIGPIPE, which killed the whole test
    // run about once in 80, and every test home still in use was left in /tmp. The pipe holds this much unread.
    precondition(stdin.utf8.count <= 16_384, "more stdin than a pipe holds before the CLI reads it")
    input.fileHandleForWriting.write(Data(stdin.utf8))
    try input.fileHandleForWriting.close()
    process.standardInput = input
    process.standardOutput = out
    process.standardError = err
    try process.run()
    let stdout = out.fileHandleForReading.readDataToEndOfFile()
    let stderr = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return CLIResult(status: process.terminationStatus, out: String(decoding: stdout, as: UTF8.self), err: String(decoding: stderr, as: UTF8.self))
}

/// A listening Unix socket at `path`. Open, it stands in for the running app (the kernel completes a connection
/// without anyone accepting it); closed, it leaves its file behind the way an app that died does.
func listeningSocket(at path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    precondition(bytes.count < MemoryLayout.size(ofValue: addr.sun_path), "socket path too long: \(path)")
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in raw.copyBytes(from: bytes); raw[bytes.count] = 0 }
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard fd >= 0, bound == 0, listen(fd, 4) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    return fd
}

@Suite struct PresenceFileAfterACrash {
    // The app removes its presence file when it quits, but a crash or force-quit leaves it, and from then on
    // Claude Code believes the user is at the Mac and sends no phone push. The hook is the only beckon code
    // still running at that point, so it has to be the one that clears the file.
    @Test func hookRemovesThePresenceFileWhenNobodyAnswersTheSocket() throws {
        let home = try TestHome()
        let present = home.directory + "/present"
        FileManager.default.createFile(atPath: present, contents: nil)
        close(try listeningSocket(at: home.directory + "/beckon.sock"))
        let result = try beckon(["hook", "Stop"], stdin: #"{"session_id":"s"}"#, home: home)
        #expect(result.status == 0)  // still failing open
        #expect(!FileManager.default.fileExists(atPath: present))
    }

    // While the app is up the file is the app's to keep: a hook that reaches it must leave the file alone.
    @Test func hookLeavesThePresenceFileWhileTheAppIsUp() throws {
        let home = try TestHome()
        let present = home.directory + "/present"
        FileManager.default.createFile(atPath: present, contents: nil)
        let app = try listeningSocket(at: home.directory + "/beckon.sock")
        defer { close(app) }
        let result = try beckon(["hook", "PostToolUse"], stdin: #"{"session_id":"s"}"#, home: home)
        #expect(result.status == 0)
        #expect(FileManager.default.fileExists(atPath: present))
    }
}

@Suite struct NotifyCommand {
    // The app drops a notify whose URL isn't a web page without a word, because notify doesn't wait for a reply.
    // The caller has to hear it from the CLI, or its card silently never appears.
    @Test func urlMustBeAWebPage() throws {
        let home = try TestHome()
        let result = try beckon(["notify", "--title", "Log in", "--url", "file:///Applications/Calculator.app"], home: home)
        #expect(result.status == 1)
        #expect(result.err.contains("--url takes an http or https URL"))
    }

    // The same with the app up, which is when it matters: a skill building "https://$HOST/login" with $HOST empty
    // must hear from the CLI, not get exit 0 and wait for a login the user was never asked for.
    @Test(arguments: ["https://", "http://", "https:///login", "http://:8080/x", "https://exa mple.com"])
    func aURLTheAppWouldRefuseFailsInTheCLI(url: String) throws {
        let home = try TestHome()
        let app = try listeningSocket(at: home.directory + "/beckon.sock")
        defer { close(app) }
        #expect(Target.web(url) == nil)
        let result = try beckon(["notify", "--title", "Log in", "--url", url], home: home)
        #expect(result.status == 1)
        #expect(result.err.contains("--url takes an http or https URL with a host"))
    }

    // The app reads the link from "url". Under any other key the card still comes, without its Open in Browser button.
    @Test func theURLReachesTheAppUnderTheKeyItReads() throws {
        let home = try TestHome()
        let app = try listeningSocket(at: home.directory + "/beckon.sock")
        defer { close(app) }
        final class Received: @unchecked Sendable { var data = Data() }
        let received = Received()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            let c = accept(app, nil, nil)
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(c, &buf, buf.count)
                if n <= 0 { break }
                received.data.append(buf, count: n)
            }
            close(c)
            done.signal()
        }
        let result = try beckon(["notify", "--title", "Log in", "--url", "https://example.com/login"], home: home)
        #expect(result.status == 0)
        done.wait()
        let envelope = try #require(try JSONSerialization.jsonObject(with: received.data) as? [String: Any])
        let payload = try #require(envelope["payload"] as? [String: Any])
        #expect(payload["url"] as? String == "https://example.com/login")
    }
}

@Suite struct ExitCodes {
    // Claude Code reads exit 2 from a hook as "block this": a UserPromptSubmit hook that exits 2 refuses the
    // prompt and a Stop hook keeps the turn from ending. A plugin newer than the CLI, or a Claude Code that drops
    // the hook's arguments, hands beckon a command line it can't read on every event; if that exits 2, installing
    // beckon has locked the user out of Claude Code. It is an error, and it must be a non-blocking one.
    @Test(arguments: [[], ["hook"], ["hook", "Stop", "--later"], ["hook", "Stop", "--rewake", "extra"], ["hook", "UserPromptSubmit", "--rewake"],
                      ["frobnicate"], ["notify", "--title"], ["notify", "--colour", "red"], ["test", "extra"]])
    func aCommandLineItCannotReadIsAnErrorButNeverExitTwo(arguments: [String]) throws {
        let result = try beckon(arguments, stdin: #"{"session_id":"s"}"#, home: try TestHome())
        #expect(result.status == 1)
        #expect(!result.err.isEmpty)
        #expect(result.out.isEmpty)  // a hook's stdout is read as its decision
    }

    // The one exit 2 beckon means: run as the asyncRewake Stop hook, a reply typed on the Done card comes back
    // from the app, and exit 2 with the reply on stderr is how Claude Code hands it to the idle session.
    @Test func aReplyFromTheDoneCardWakesTheSessionWithExitTwo() throws {
        let home = try TestHome()
        let app = try listeningSocket(at: home.directory + "/beckon.sock")
        defer { close(app) }
        Thread.detachNewThread {
            let hook = accept(app, nil, nil)
            var on: Int32 = 1
            setsockopt(hook, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))  // a CLI gone early fails this test, not the run
            var buf = [UInt8](repeating: 0, count: 4096)
            while read(hook, &buf, buf.count) > 0 {}
            _ = Array("also run the tests\n".utf8).withUnsafeBytes { write(hook, $0.baseAddress, $0.count) }
            close(hook)
        }
        let result = try beckon(["hook", "Stop", "--rewake"], stdin: #"{"session_id":"s"}"#, home: home)
        #expect(result.status == 2)
        #expect(result.err == "also run the tests\n")
    }
}
