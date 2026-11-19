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
