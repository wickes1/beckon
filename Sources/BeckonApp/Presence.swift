import AppKit
import BeckonCore
import Foundation

/// Two questions about the user: are they at the Mac at all, and are they looking at a given session.
enum Presence {
    // MARK: At the Mac — the presence file

    /// Claude Code skips Remote Control phone pushes while the file named by CLAUDE_CLIENT_PRESENCE_FILE exists.
    /// beckon keeps it there while the screen is unlocked and removes it on lock, so the phone only buzzes
    /// when the panel can't be seen. Only existence matters.
    private(set) static var locked = false
    private static var observers: [NSObjectProtocol] = []

    static func start() {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        locked = (session?["CGSSessionScreenIsLocked"] as? Bool) ?? false
        writeFile()
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in locked = true; writeFile() })
        observers.append(center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in locked = false; writeFile() })
    }

    /// Without beckon running nothing keeps the file honest, so it goes away and pushes are sent as normal.
    static func stop() { unlink(BeckonPaths.presenceFile) }

    private static func writeFile() {
        if locked { unlink(BeckonPaths.presenceFile) }
        else { FileManager.default.createFile(atPath: BeckonPaths.presenceFile, contents: nil) }
    }

    // MARK: Looking at a session

    /// True when the session's own terminal is what the user has in front of them, so Claude Code's dialog is
    /// already visible and a card would only be in the way. Exact where beckon can ask (Ghostty and
    /// Terminal.app by tty, VS Code through its extension); otherwise it falls back to "that app is frontmost".
    /// Always answers within `patience`: an app too busy to say counts as the fallback.
    static func looking(at location: Location, patience: TimeInterval = 0.35, then: @escaping (Bool) -> Void) {
        guard !locked, let app = location.bundleID, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == app else { then(false); return }
        var answered = false
        let finish: (Bool) -> Void = { value in
            guard !answered else { return }
            answered = true
            then(value)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + patience) { finish(true) }

        if Apps.vscodeFamily.contains(app) {
            VSCode.ask("state", pids: location.pids) { reply in
                guard let reply else { finish(true); return }  // no extension in that window: app-level answer
                let focused = reply["focused"] as? Bool ?? false
                // A session in the Claude Code side panel has no terminal to compare; its window being focused is the test.
                let onIt = (reply["match"] as? String) == "host" || (reply["activeTerminal"] as? Bool ?? false)
                finish(focused && onIt)
            }
        } else if let tty = location.tty, let script = Focus.terminalScript(app: app, tty: tty, action: .isFront) {
            Script.run(script, app: app, prompt: false) { result in finish(result.map { $0 == "yes" } ?? true) }
        } else {
            finish(true)
        }
    }

    // MARK: Suppressed cards come back when the user looks away

    private static var timer: Timer?

    /// Runs only while something is suppressed, so an idle beckon stays at zero wakeups.
    static func watchSuppressed() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            let hidden = store.items.filter { $0.visibility == .suppressed }
            if hidden.isEmpty { timer?.invalidate(); timer = nil; return }
            for item in hidden {
                looking(at: item.location) { looking in if !looking { store.reveal(item.id) } }
            }
        }
    }
}
