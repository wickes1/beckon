import AppKit
import BeckonCore
import Foundation

/// Where a session lives: which app, which tty, and the hook's parent chain (nearest first).
/// The tty picks the tab in Ghostty / Terminal.app; the pids pick the window and terminal in VS Code.
struct Location: Equatable {
    var bundleID: String?
    var tty: String?
    var pids: [Int32] = []

    init() {}
    init(env: [String: String], ancestry: [[String: Any]]) {
        bundleID = Surface.bundleID(env: env)
        pids = ancestry.compactMap { ($0["pid"] as? NSNumber)?.int32Value }
        tty = ancestry.compactMap { $0["tty"] as? String }.first { !$0.isEmpty }.map { "/dev/" + $0 }
    }
}

/// Somewhere other than the session that an "Action needed" card sends the user.
enum Target: Equatable {
    case braveTab(Int)  // Chromium tab id, the number the claude-in-chrome tools report
    case url(String)

    static let brave = "com.brave.Browser"
    var bundleID: String? { if case .braveTab = self { return Target.brave }; return nil }
    var appName: String { if case .braveTab = self { return "Brave" }; return "Browser" }
    var text: String {
        switch self {
        case .braveTab(let id): return "Brave tab \(id)"
        case .url(let u): return u
        }
    }
}

enum Apps {
    static let ghostty = "com.mitchellh.ghostty"
    static let terminal = "com.apple.Terminal"
    /// VS Code and the forks that run the same extension API.
    static let vscodeFamily: Set<String> = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium", "com.todesktop.230313mzl4w4u92"]

    static func running(_ bundleID: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }
    static func activate(_ bundleID: String?) {
        guard let bundleID, let app = running(bundleID) else { return }
        app.activate()
    }
}

/// AppleScript against another app. Every call is bounded: an app that doesn't answer Apple events (seen live
/// with Ghostty while the screen was locked) must never hang beckon, only cost it the exact tab.
enum Script {
    enum Permission: String { case granted, denied, notAsked = "not asked yet", notRunning = "app not running", noAnswer = "no answer", unknown }

    private static let lock = NSLock()
    private static var probing: Set<String> = []

    /// Whether beckon may send Apple events to that app. Never prompts. Blocks for at most `timeout`:
    /// the system call behind it can wait on the target app indefinitely, so it runs on its own thread, and
    /// while one probe of an app is still out no second one is started.
    static func permission(_ bundleID: String, timeout: TimeInterval = 1) -> Permission {
        guard Apps.running(bundleID) != nil else { return .notRunning }
        lock.lock()
        let busy = probing.contains(bundleID)
        if !busy { probing.insert(bundleID) }
        lock.unlock()
        guard !busy else { return .noAnswer }

        var result = Permission.noAnswer
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
            let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false)
            lock.lock()
            switch status {
            case noErr: result = .granted
            case OSStatus(errAEEventNotPermitted): result = .denied
            case -1744: result = .notAsked  // errAEEventWouldRequireUserConsent
            case OSStatus(procNotFound): result = .notRunning
            default: result = .unknown
            }
            probing.remove(bundleID)
            lock.unlock()
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
        lock.lock(); defer { lock.unlock() }
        return result
    }

    /// Runs the script in an `osascript` child, which can be killed when it overruns. `prompt: false` runs only
    /// if the user already allowed beckon to control that app, so a background check never throws a permission
    /// dialog on screen; `prompt: true` is for a click, where the dialog is the expected next step and gets two
    /// minutes to be answered. The result is nil on any failure.
    static func run(_ source: String, app bundleID: String, prompt: Bool, then: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var result: String?
            let allowed = permission(bundleID)
            if allowed == .granted || (prompt && allowed != .notRunning && allowed != .denied) {
                result = osascript(source, app: bundleID, timeout: allowed == .granted ? 3 : 120)
            }
            DispatchQueue.main.async { then(result) }
        }
    }

    /// A script that fails leaves a line in beckon.log: otherwise a click that only brings the app forward
    /// looks the same as one that worked.
    private static func osascript(_ source: String, app: String, timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch {
            AuditLog.note("SCRIPT \(app) could not start osascript: \(error.localizedDescription)")
            return nil
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            AuditLog.note("SCRIPT \(app) no answer within \(Int(timeout)) s")
            return nil
        }
        guard process.terminationStatus == 0 else {
            let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            AuditLog.note("SCRIPT \(app) failed: \(message)")
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// The beckon VS Code extension, one instance per window. Each registers `<extension-host pid>.json` holding
/// its socket path; beckon asks every live window which one owns the session.
enum VSCode {
    static var directory: String { BeckonPaths.directory + "/vscode" }

    struct Window { let pid: Int32; let socket: String }

    static func windows() -> [Window] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            let path = directory + "/" + name
            guard let data = FileManager.default.contents(atPath: path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = (obj["pid"] as? NSNumber)?.int32Value, let socket = obj["socket"] as? String else { return nil }
            // A window that crashed leaves its entry behind.
            guard kill(pid, 0) == 0 else { try? FileManager.default.removeItem(atPath: path); return nil }
            return Window(pid: pid, socket: socket)
        }
    }

    /// Sends one command to every window in turn and returns the first reply that claims the session
    /// (`match` is "terminal" or "host"). Blocking; `ask` wraps it for the main thread.
    static func askSync(_ command: String, pids: [Int32]) -> [String: Any]? {
        for w in windows() {
            if let reply = request(w.socket, ["cmd": command, "pids": pids]), reply["match"] is String { return reply }
        }
        return nil
    }

    static func ask(_ command: String, pids: [Int32], then: @escaping ([String: Any]?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let reply = askSync(command, pids: pids)
            DispatchQueue.main.async { then(reply) }
        }
    }

    private static func request(_ socketPath: String, _ message: [String: Any]) -> [String: Any]? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        // A window busy in a long extension-host task must not hold up the others.
        var timeout = timeval(tv_sec: 0, tv_usec: 400_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in raw.copyBytes(from: bytes); raw[bytes.count] = 0 }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0, var out = try? JSONSerialization.data(withJSONObject: message) else { return nil }
        out.append(0x0A)
        guard out.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == out.count else { return nil }
        var reply = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while !reply.contains(0x0A) {
            let n = read(fd, &buf, buf.count)
            if n > 0 { reply.append(buf, count: n) } else { break }
        }
        return (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
    }
}

/// Going to the exact place Claude is waiting.
enum Focus {
    /// The session's own terminal: the Ghostty or Terminal.app tab by tty, the VS Code window and terminal
    /// through the extension; any other app is just brought forward.
    static func go(to location: Location) {
        guard let app = location.bundleID else { return }
        if Apps.vscodeFamily.contains(app) {
            VSCode.ask("focus", pids: location.pids) { reply in
                // Opening the folder a window already has open is how VS Code raises that window;
                // an extension has no call for it.
                if let workspace = reply?["workspace"] as? String, !workspace.isEmpty {
                    let open = Process()
                    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                    open.arguments = ["-b", app, workspace]
                    do { try open.run() } catch { Apps.activate(app) }
                } else {
                    Apps.activate(app)
                }
            }
            return
        }
        // The app comes forward at once; the exact tab follows when the script has run.
        Apps.activate(app)
        guard let tty = location.tty, let script = terminalScript(app: app, tty: tty, action: .focus) else { return }
        Script.run(script, app: app, prompt: true) { _ in }
    }

    static func open(_ target: Target) {
        switch target {
        case .url(let u):
            if let url = URL(string: u) { NSWorkspace.shared.open(url) }
        case .braveTab(let id):
            // The scripting `id` of a Chromium tab is the same number extensions see, so the tab is found
            // by id: its URL changes as a login redirects.
            let script = """
            tell application id "\(Target.brave)"
              repeat with w in windows
                set i to 0
                repeat with t in tabs of w
                  set i to i + 1
                  if (id of t as text) is "\(id)" then
                    set active tab index of w to i
                    set index of w to 1
                    activate
                    return "ok"
                  end if
                end repeat
              end repeat
              return "missing"
            end tell
            """
            Apps.activate(Target.brave)
            Script.run(script, app: Target.brave, prompt: true) { _ in }
        }
    }

    enum TerminalAction { case focus, isFront }

    /// nil for apps beckon has no tab-level script for.
    static func terminalScript(app: String, tty: String, action: TerminalAction) -> String? {
        let t = Script.quote(tty)
        switch (app, action) {
        case (Apps.ghostty, .focus):
            return """
            tell application id "\(Apps.ghostty)"
              repeat with term in terminals
                if tty of term is \(t) then
                  focus term
                  return "ok"
                end if
              end repeat
              return "missing"
            end tell
            """
        case (Apps.ghostty, .isFront):
            return """
            tell application id "\(Apps.ghostty)"
              if tty of focused terminal of selected tab of front window is \(t) then return "yes"
              return "no"
            end tell
            """
        case (Apps.terminal, .focus):
            return """
            tell application id "\(Apps.terminal)"
              repeat with w in windows
                repeat with tb in tabs of w
                  if tty of tb is \(t) then
                    set selected of tb to true
                    set index of w to 1
                    activate
                    return "ok"
                  end if
                end repeat
              end repeat
              return "missing"
            end tell
            """
        case (Apps.terminal, .isFront):
            return """
            tell application id "\(Apps.terminal)"
              if tty of selected tab of front window is \(t) then return "yes"
              return "no"
            end tell
            """
        default:
            return nil
        }
    }
}
