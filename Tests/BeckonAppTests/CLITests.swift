import Foundation
import Testing

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
    process.standardInput = input
    process.standardOutput = out
    process.standardError = err
    try process.run()
    input.fileHandleForWriting.write(Data(stdin.utf8))
    try input.fileHandleForWriting.close()
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
}
