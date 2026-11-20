import AppKit
import BeckonCore
import Foundation
import Security
import ServiceManagement

/// `beckon doctor`: the app describes its own state, since everything worth checking lives on this side of
/// the socket. First line is the verdict ("ok" / "fail"), the rest is the report the CLI prints.
enum Doctor {
    /// Every event beckon listens to. Without the first one nothing reaches the panel at all.
    static let events = ["PermissionRequest", "PostToolUse", "PostToolUseFailure", "UserPromptSubmit", "Stop", "StopFailure", "SubagentStop", "SessionEnd"]

    static func report(then: @escaping (String) -> Void) {
        // Each Automation probe waits up to a second for its app; keep that off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let automation = [("Ghostty", Apps.ghostty), ("Terminal", Apps.terminal), ("Brave", Target.brave)].map { name, id in
                "\(name): \(Script.permission(id).rawValue)"
            }
            let windows = VSCode.windows().count
            DispatchQueue.main.async { then(build(automation: automation, vscodeWindows: windows)) }
        }
    }

    private static func build(automation: [String], vscodeWindows: Int) -> String {
        var failed = false
        var lines: [String] = []
        func ok(_ s: String) { lines.append("✓ " + s) }
        func bad(_ s: String) { lines.append("✗ " + s); failed = true }
        func note(_ s: String) { lines.append("· " + s) }

        ok("app \(beckonVersion) running (pid \(getpid())), socket \(BeckonPaths.socket)")
        switch signing() {
        case .adhoc: bad("ad-hoc signed: permission grants won't survive a rebuild — sign with a stable identity (scripts/make-signing-cert.sh)")
        case .identity(let name): ok("signed by \"\(name)\"")
        case .unknown: note("signature could not be read")
        }

        for check in settingsChecks(file: NSHomeDirectory() + "/.claude/settings.json", fromSource: fromSource, pluginInstalled: pluginInstalled) {
            switch check {
            case .ok(let s): ok(s)
            case .bad(let s): bad(s)
            case .note(let s): note(s)
            }
        }

        if vscodeWindows > 0 {
            note("VS Code extension: \(vscodeWindows) window(s) connected")
        } else if let vsix = Bundle.main.path(forResource: "beckon", ofType: "vsix") {
            // The bundled copy is the only one a Homebrew install has.
            note("VS Code extension: no window connected — clicks only bring VS Code forward. Install it once per VS Code profile: code --install-extension \"\(vsix)\"")
        } else {
            note("VS Code extension: no window connected — clicks only bring VS Code forward (scripts/build-vscode.sh --install)")
        }
        note("Automation — " + automation.joined(separator: " · ") + " (\"not asked yet\" is granted the first time you click through to that app)")
        note("open at login: \(SMAppService.mainApp.status == .enabled ? "on" : "off") (menu bar icon → Open at Login)")
        note("\(store.pending.count) waiting, \(Intake.sessions.count) session(s) seen since launch")
        return (failed ? "fail" : "ok") + "\n" + lines.joined(separator: "\n") + "\n"
    }

    enum Check: Equatable { case ok(String), bad(String), note(String) }

    /// The part of the report read from ~/.claude/settings.json: the hooks and the presence file. The file and the
    /// install come in as arguments so a test can hand it any of them.
    static func settingsChecks(file: String, fromSource: Bool, pluginInstalled: () -> Bool) -> [Check] {
        var checks: [Check] = []
        func ok(_ s: String) { checks.append(.ok(s)) }
        func bad(_ s: String) { checks.append(.bad(s)) }
        func note(_ s: String) { checks.append(.note(s)) }

        let settings: [String: Any]
        do {
            settings = try readSettings(file)
        } catch {
            // Read as empty, a file with one comma missing had doctor report no hooks and no presence file, and send
            // the user off to fix things in a file beckon never managed to read.
            bad("~/.claude/settings.json can't be read (\(error.localizedDescription)), so its hooks and env weren't checked: fix the file")
            return checks
        }
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        // What to tell the user to run depends on how they installed: only a checkout has scripts/hooks.sh.
        let plugin = "claude plugin marketplace add wickes1/beckon, then claude plugin install beckon@beckon"
        let repair = fromSource ? "run scripts/hooks.sh install"
                                : "take beckon's hooks out of ~/.claude/settings.json and install the plugin instead (\(plugin))"
        let wired = events.filter { ours(hooks[$0]) != nil }
        let dead = Set(events.compactMap { ours(hooks[$0])?["command"] as? String }).filter { !runnable($0) }.sorted()
        if !dead.isEmpty {
            // A hook that is merely named beckon proves nothing: the app it pointed at may have moved or gone.
            bad("hooks: ~/.claude/settings.json runs \(dead.joined(separator: ", ")), and there is no executable file there — \(repair)")
        } else if wired.count == events.count {
            ok("hooks: all \(events.count) events in ~/.claude/settings.json")
        } else if wired.isEmpty {
            if pluginInstalled() { ok("hooks: from the beckon Claude Code plugin") }
            else { bad("hooks: none found — " + (fromSource ? "run scripts/hooks.sh install, or install the beckon plugin" : "install the plugin: \(plugin)")) }
        } else {
            bad("hooks: missing \(events.filter { !wired.contains($0) }.joined(separator: ", ")) — \(repair)")
        }
        if let stop = ours(hooks["Stop"]) {
            let waits = (stop["args"] as? [String] ?? []).contains("--rewake")
            let background = stop["asyncRewake"] as? Bool == true
            if waits && !background { bad("the Stop hook waits (--rewake) without asyncRewake: it holds up the end of every turn — \(repair)") }
            else if !waits || !background { note("the Stop hook isn't the asyncRewake form: Done cards have no reply field — \(repair)") }
        }

        let env = settings["env"] as? [String: Any] ?? [:]
        if env["CLAUDE_CLIENT_PRESENCE_FILE"] as? String == BeckonPaths.presenceFile {
            ok("presence file wired: phone pushes only while the screen is locked (\(Presence.locked ? "locked now" : "unlocked now"))")
        } else {
            note("presence file not wired: Claude Code doesn't know when you're at the Mac — add \"CLAUDE_CLIENT_PRESENCE_FILE\": \"\(BeckonPaths.presenceFile)\" to the env block of ~/.claude/settings.json" + (fromSource ? " (scripts/hooks.sh install does it)" : ""))
        }
        return checks
    }

    /// No file is a setup with nothing in it yet. A file that is there has to be a JSON object.
    private static func readSettings(_ file: String) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: file) else { return [:] }
        guard let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: file))) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return settings
    }

    /// beckon's own hook entry for an event, recognised by the binary's name.
    private static func ours(_ entries: Any?) -> [String: Any]? {
        for entry in entries as? [[String: Any]] ?? [] {
            for hook in entry["hooks"] as? [[String: Any]] ?? [] {
                let command = hook["command"] as? String ?? ""
                if (command as NSString).lastPathComponent == "beckon", (hook["args"] as? [String])?.first == "hook" { return hook }
            }
        }
        return nil
    }

    /// A source install is the copy scripts/build-app.sh puts in ~/Applications, the only place scripts/hooks.sh
    /// wires. Any other copy (Homebrew's, in /Applications) came without the scripts and gets its hooks from the plugin.
    private static var fromSource: Bool { Bundle.main.bundlePath == NSHomeDirectory() + "/Applications/Beckon.app" }

    /// Where a hook command given as a bare name may be found. Claude Code looks on its own PATH, which the app
    /// can't see (an app started from Finder has only the system directories), so this adds the places the two
    /// install routes link the CLI: Homebrew's bin on either architecture, and ~/.local/bin.
    static var searchPath: [String] {
        (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"]
    }

    /// Whether a hook's command is something Claude Code can start: an executable file, at that path or, for a
    /// bare name, in one of `path`.
    static func runnable(_ command: String, path: [String] = searchPath) -> Bool {
        func executable(_ file: String) -> Bool {
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: file, isDirectory: &directory) && !directory.boolValue
                && FileManager.default.isExecutableFile(atPath: file)
        }
        return command.contains("/") ? executable(command) : path.contains { executable($0 + "/" + command) }
    }

    private static func pluginInstalled() -> Bool {
        let path = NSHomeDirectory() + "/.claude/plugins/installed_plugins.json"
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))) as? [String: Any] else { return false }
        return (obj["plugins"] as? [String: Any] ?? obj).keys.contains { $0.hasPrefix("beckon@") }
    }

    private enum Signing { case adhoc, identity(String), unknown }

    private static func signing() -> Signing {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return .unknown }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return .unknown }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return .unknown }
        if let flags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value, flags & 0x2 != 0 { return .adhoc }  // kSecCodeSignatureAdhoc
        guard let cert = (dict[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first else { return .unknown }
        var name: CFString?
        SecCertificateCopyCommonName(cert, &name)
        return .identity((name as String?) ?? "?")
    }
}
