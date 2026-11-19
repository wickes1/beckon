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
