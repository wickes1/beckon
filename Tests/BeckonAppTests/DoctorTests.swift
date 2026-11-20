import Foundation
import Testing
@testable import BeckonApp

@Suite struct HookCommands {
    // doctor is what a user runs when no card comes. A hook entry that names beckon but points at an app that
    // was moved or deleted is exactly that case, and reporting it as wired sends them looking everywhere else.
    @Test func aHookCommandCountsOnlyIfItIsAnExecutableFile() throws {
        let dir = NSTemporaryDirectory() + "beckon-doctor-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir + "/Beckon.app/Contents/MacOS", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let cli = dir + "/Beckon.app/Contents/MacOS/beckon"
        #expect(!Doctor.runnable(cli))  // nothing there
        FileManager.default.createFile(atPath: cli, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o644])
        #expect(!Doctor.runnable(cli))  // a file, but not one that can be run
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli)
        #expect(Doctor.runnable(cli))
        #expect(!Doctor.runnable(dir + "/Beckon.app"))  // a directory passes an "executable" check by itself

        // The plugin's form: a bare name, found on PATH.
        #expect(Doctor.runnable("beckon", path: ["/nonexistent", dir + "/Beckon.app/Contents/MacOS"]))
        #expect(!Doctor.runnable("beckon", path: ["/nonexistent", dir]))
    }
}

@Suite struct SettingsChecks {
    /// A settings file in a directory of its own, wiring every event to `command`.
    private func settings(_ text: String) throws -> String {
        let dir = NSTemporaryDirectory() + "beckon-doctor-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let file = dir + "/settings.json"
        try text.write(toFile: file, atomically: true, encoding: .utf8)
        return file
    }
    private func wired(to command: String) throws -> String {
        var hooks: [String: Any] = [:]
        for event in Doctor.events { hooks[event] = [["hooks": [["type": "command", "command": command, "args": ["hook", event]]]]] }
        return String(decoding: try JSONSerialization.data(withJSONObject: ["hooks": hooks]), as: UTF8.self)
    }
    private func bad(_ checks: [Doctor.Check]) -> [String] { checks.compactMap { if case .bad(let s) = $0 { return s }; return nil } }

    // Every event wired, to an app that has since been moved or deleted: the very setup in which no card comes, so
    // doctor must fail it, and say what to do for the way beckon was installed.
    @Test func hooksPointingAtAMissingAppFail() throws {
        let file = try settings(try wired(to: "/nonexistent/Beckon.app/Contents/MacOS/beckon"))
        defer { try? FileManager.default.removeItem(atPath: (file as NSString).deletingLastPathComponent) }

        let homebrew = bad(Doctor.settingsChecks(file: file, fromSource: false, pluginInstalled: { true }))
        #expect(homebrew.count == 1)
        #expect(homebrew.first?.contains("there is no executable file there") == true)
        #expect(homebrew.first?.contains("scripts/hooks.sh") == false)  // a Homebrew install has no checkout to run it from
        let source = bad(Doctor.settingsChecks(file: file, fromSource: true, pluginInstalled: { false }))
        #expect(source.first?.contains("run scripts/hooks.sh install") == true)

        let live = try settings("{}")
        let cli = (live as NSString).deletingLastPathComponent + "/beckon"
        defer { try? FileManager.default.removeItem(atPath: (live as NSString).deletingLastPathComponent) }
        FileManager.default.createFile(atPath: cli, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        try wired(to: cli).write(toFile: live, atomically: true, encoding: .utf8)
        let checks = Doctor.settingsChecks(file: live, fromSource: false, pluginInstalled: { false })
        #expect(checks.contains(.ok("hooks: all \(Doctor.events.count) events in ~/.claude/settings.json")))
    }

    // A settings file with a comma missing is not one without hooks. Read as empty, doctor reported "no hooks" and
    // "presence file not wired" and sent the user to edit a file it had not managed to read.
    @Test func aSettingsFileThatCantBeReadIsSaidToBeUnreadable() throws {
        for text in [#"{"hooks": {} "env": {}}"#, "[]"] {
            let file = try settings(text)
            defer { try? FileManager.default.removeItem(atPath: (file as NSString).deletingLastPathComponent) }
            let checks = Doctor.settingsChecks(file: file, fromSource: false, pluginInstalled: { false })
            #expect(checks.count == 1, "\(text)")
            #expect(bad(checks).first?.hasPrefix("~/.claude/settings.json can't be read") == true, "\(text)")
        }
        // No file at all is a setup not done yet, not an error in the file.
        let none = Doctor.settingsChecks(file: NSTemporaryDirectory() + "beckon-doctor-\(UUID().uuidString)/settings.json", fromSource: false, pluginInstalled: { true })
        #expect(none.first == .ok("hooks: from the beckon Claude Code plugin"))
    }
}
