import AppKit
import Foundation

/// What beckon remembers about a Claude Code session between hook events.
struct Session {
    var location = Location()
    var surface = Surface(env: [:])
    var cwd = ""
    var transcript: String?
    var title: String?
    /// Set when the user sends a prompt, cleared when the turn ends: only those turns get a Done card.
    /// Turns Claude starts by itself (a background task finishing, a scheduled wake-up) would be noise.
    var userStarted = false
}

/// One envelope from the CLI: a Claude Code hook event, or a `beckon notify` / `dismiss` / `doctor` call.
enum Intake {
    static var sessions: [String: Session] = [:]

    static func handle(_ data: Data, _ conn: Connection) {
        guard let env = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = env["event"] as? String else { conn.reply(""); return }
        conn.expectsReply = env["wait"] as? Bool ?? false
        if event == "Doctor" { Doctor.report { conn.reply($0) }; return }
        guard let payload = env["payload"] as? [String: Any] else { conn.reply(""); return }
        let fromHook = event != "Notify" && event != "Dismiss"
        guard let session = payload["session_id"] as? String ?? (fromHook ? nil : "") else { conn.reply(""); return }

        let vars = env["env"] as? [String: String] ?? [:]
        let hookPID = (env["pid"] as? NSNumber)?.int32Value
        var s = sessions[session] ?? Session()
        s.location = Location(env: vars, ancestry: env["ancestry"] as? [[String: Any]] ?? [])
        s.surface = Surface(env: vars)
        // A skill's `beckon notify` runs wherever its shell happens to be; only hooks report the project directory.
        if let cwd = payload["cwd"] as? String, !cwd.isEmpty, fromHook || s.cwd.isEmpty { s.cwd = cwd }
        if let t = payload["transcript_path"] as? String, !t.isEmpty { s.transcript = t }
        if let t = payload["session_title"] as? String, !t.isEmpty { s.title = t }
        defer { if event != "SessionEnd" { sessions[session] = s } }

        let agent = payload["agent_id"] as? String
        let tool = payload["tool_name"] as? String ?? ""
        func item(_ kind: Kind, key: String, context: String = "") -> Item {
            let project = (s.cwd as NSString).lastPathComponent
            return Item(id: UUID().uuidString, sessionID: session, agentID: agent, callKey: key, arrived: Date(),
                        project: project, appName: s.surface.appName, bundleID: s.surface.bundleID,
                        title: s.title ?? (project.isEmpty ? "Claude Code" : project), context: context, kind: kind, location: s.location)
        }

        switch event {
        case "PermissionRequest":
            let input = payload["tool_input"] as? [String: Any] ?? [:]
            let kind: Kind
            switch tool {
            case "AskUserQuestion":
                guard let view = QuestionFormat.view(input: input) else { conn.reply(""); return }
                kind = .questions(view)
            case "ExitPlanMode":
                guard let view = PlanFormat.view(input: input) else { conn.reply(""); return }
                kind = .plan(view)
            default:
                kind = .permission(PermissionFormat.view(toolName: tool, input: input, suggestions: payload["permission_suggestions"] as? [[String: Any]] ?? []))
            }
            let key = PermissionFormat.callKey(session: session, agent: agent, tool: tool, input: input)
            deliver(item(kind, key: key), conn, hookPID: hookPID, transcript: s.transcript, wantsContext: true)

        // The call went ahead or failed after the user answered in the terminal: that card is done.
        case "PostToolUse", "PostToolUseFailure":
            conn.reply("")
            let key = PermissionFormat.callKey(session: session, agent: agent, tool: tool, input: payload["tool_input"])
            store.remove { $0.callKey == key }

        // The user is back in that session, so every prompt it had open was answered or dropped there.
        // This is also the only signal for a denial made in the terminal: no event fires for it.
        // An "Action needed" card stays: the skill that raised it is still waiting on the same thing.
        case "UserPromptSubmit":
            conn.reply("")
            s.userStarted = true
            store.remove { $0.sessionID == session && !$0.isAction }

        case "Stop":
            store.remove { $0.sessionID == session }
            let started = s.userStarted
            s.userStarted = false
            guard started else { conn.reply(""); return }
            let message = (payload["last_assistant_message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            deliver(item(.done(Updates.done(message)), key: "stop|\(session)"), conn, hookPID: hookPID, transcript: s.transcript, wantsContext: false)

        case "StopFailure":
            store.remove { $0.sessionID == session }
            s.userStarted = false
            let view = Updates.failure(error: payload["error"] as? String, details: payload["error_details"] as? String,
                                       message: payload["last_assistant_message"] as? String)
            deliver(item(.failed(view), key: "stop|\(session)"), conn, hookPID: nil, transcript: s.transcript, wantsContext: false)

        case "SubagentStop":
            conn.reply("")
            store.remove { $0.sessionID == session && $0.agentID == agent }

        case "SessionEnd":
            conn.reply("")
            store.remove { $0.sessionID == session }
            sessions[session] = nil

        case "Notify":
            guard let title = payload["title"] as? String, !title.isEmpty else { conn.reply(""); return }
            var target: Target?
            if let tab = (payload["brave_tab"] as? NSNumber)?.intValue { target = .braveTab(tab) }
            else if let url = payload["url"] as? String, !url.isEmpty { target = .url(url) }
            let key = notifyKey(session, payload["key"] as? String ?? title)
            store.remove { $0.callKey == key }  // the same notice again replaces the old card
            let view = ActionView(title: title, steps: payload["steps"] as? [String] ?? [], target: target)
            deliver(item(.action(view), key: key, context: payload["message"] as? String ?? ""), conn, hookPID: nil, transcript: s.transcript, wantsContext: false)

        case "Dismiss":
            conn.reply("")
            let key = notifyKey(session, payload["key"] as? String ?? "")
            store.remove { $0.callKey == key }

        default:
            conn.reply("")
        }
    }

    private static func notifyKey(_ session: String, _ key: String) -> String { "notify|\(session)|\(key)" }

    /// Puts an item on the panel, unless the user is looking at that very session: then a prompt Claude Code
    /// is also showing waits out of sight until they look away, and plain news is dropped.
    /// A skill's "Action needed" always shows — it sends the user somewhere else.
    private static func deliver(_ item: Item, _ conn: Connection, hookPID: Int32?, transcript: String?, wantsContext: Bool) {
        let show: (Item) -> Void = { item in
            // The looking check takes a moment; a hook that died meanwhile has nobody left to answer.
            if conn.expectsReply, let pid = hookPID, kill(pid, 0) != 0 { conn.reply(""); return }
            if !conn.expectsReply { conn.reply("") }
            store.arrive(item, connection: conn, hookPID: conn.expectsReply ? hookPID : nil)
            if item.visibility == .suppressed { Presence.watchSuppressed() }
            guard let transcript else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let info = Transcript.read(transcript)
                DispatchQueue.main.async {
                    store.setSessionInfo(id: item.id, title: info.title, context: wantsContext ? info.lastAssistantText : nil)
                    if let title = info.title, !title.isEmpty { sessions[item.sessionID]?.title = title }
                }
            }
        }
        if item.isAction { show(item); return }
        Presence.looking(at: item.location) { looking in
            var item = item
            if looking {
                guard item.kind.hasTerminalDialog else { conn.reply(""); return }
                item.visibility = .suppressed
            }
            show(item)
        }
    }

    /// A reply typed on a Done card starts a turn the same way a prompt in the terminal does.
    static func userReplied(session: String) { sessions[session]?.userStarted = true }
}

extension Item {
    var isAction: Bool { if case .action = kind { return true }; return false }
}

/// Done and Stopped cards: news about a turn that ended.
enum Updates {
    /// The first line of Claude's last message is the headline and the rest is the body. A first line too long
    /// for a headline is clipped there and kept whole in the body.
    static func done(_ message: String) -> DoneView {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = String(text.prefix { $0 != "\n" })
        let headline = Words.plain(String(first.drop { "#>-* ".contains($0) }))
        guard !headline.isEmpty else { return DoneView(headline: "Claude finished", summary: text) }
        let rest = String(text.dropFirst(first.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return DoneView(headline: Words.clip(headline, 90), summary: Words.width(headline) > 90 ? text : rest)
    }

    static func failure(error: String?, details: String?, message: String?) -> FailureView {
        let name = (error ?? "unknown").replacingOccurrences(of: "_", with: " ")
        let body = [message, details].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return FailureView(headline: "Claude stopped: \(name)", error: body.isEmpty ? "The turn ended on an API error." : body.joined(separator: "\n"))
    }

    /// How a Done-card reply reads to Claude: it arrives as a hook's system reminder, not as a user turn,
    /// so it has to say whose words these are.
    static func reply(_ text: String) -> String {
        "The user replied from the beckon panel while this session was idle. Treat this as their next message:\n\n\(text)"
    }
}

/// Which app the session's terminal lives in.
struct Surface {
    let bundleID: String?
    let appName: String

    static func bundleID(env: [String: String]) -> String? {
        if let id = env["__CFBundleIdentifier"] { return id }
        switch env["TERM_PROGRAM"] {
        case "vscode": return "com.microsoft.VSCode"
        case "ghostty": return Apps.ghostty
        case "Apple_Terminal": return Apps.terminal
        case "iTerm.app": return "com.googlecode.iterm2"
        default: return nil
        }
    }

    init(env: [String: String]) {
        let id = Surface.bundleID(env: env)
        bundleID = id
        if id == "com.microsoft.VSCode" {
            appName = "VS Code"
        } else if let id, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            appName = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        } else {
            appName = env["TERM_PROGRAM"] ?? "Terminal"
        }
    }
}
