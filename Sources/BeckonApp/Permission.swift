import Foundation

// Pure translation between Claude Code's PermissionRequest hook payload and what the card shows,
// and back from the user's choice to the hook's decision JSON. No UI, no I/O: unit-tested.

struct PermOption: Identifiable, Equatable {
    enum Action: Equatable {
        case allow
        case allowAndApply(String)  // the permission_suggestions array as JSON, echoed back as updatedPermissions
        case deny
    }
    let id: Int
    let label: String
    let detail: String
    let action: Action
}

struct PermissionView: Equatable {
    let headline: String
    let body: String
    let diff: [String]
    let options: [PermOption]
}

enum PermissionFormat {
    static func view(toolName: String, input: [String: Any], suggestions: [[String: Any]]) -> PermissionView {
        let (headline, body, diff) = describe(toolName: toolName, input: input)
        var options = [PermOption(id: 0, label: "Yes", detail: "", action: .allow)]
        // The terminal folds every suggestion into one "Yes, and …" option that applies them all; do the same.
        // A suggestion we can't put into words drops the option entirely rather than applying something unseen.
        let described = suggestions.map { describe(suggestion: $0) }
        if !suggestions.isEmpty, described.allSatisfy({ $0 != nil }) {
            let parts = described.compactMap { $0 }
            let label = parts.count == 1 ? parts[0].0 : "Yes, and don't ask again for this"
            let detail = parts.map { parts.count == 1 ? $0.1 : [$0.0.replacingOccurrences(of: "Yes, and ", with: "").replacingOccurrences(of: "Yes, ", with: ""), $0.1].filter { !$0.isEmpty }.joined(separator: " ") }
                .joined(separator: " · ")
            options.append(PermOption(id: 1, label: label, detail: detail, action: .allowAndApply(compactJSON(suggestions, limit: .max))))
        }
        options.append(PermOption(id: options.count, label: "No, and tell Claude what to do instead", detail: "", action: .deny))
        return PermissionView(headline: headline, body: body, diff: diff, options: options)
    }

    static func describe(toolName: String, input: [String: Any]) -> (String, String, [String]) {
        func str(_ k: String) -> String? { (input[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let (headline, body, diff) = describeRaw(toolName: toolName, input: input, str: str)
        return (headline, tildePath(body), diff)
    }

    /// Paths read better with the home directory as ~.
    static func tildePath(_ s: String) -> String {
        let home = NSHomeDirectory()
        return s.hasPrefix(home + "/") ? "~" + s.dropFirst(home.count) : s
    }

    private static func describeRaw(toolName: String, input: [String: Any], str: (String) -> String?) -> (String, String, [String]) {
        let file = str("file_path") ?? str("notebook_path") ?? str("path")
        let name = file.map { ($0 as NSString).lastPathComponent }
        switch toolName {
        case "Bash", "PowerShell", "Monitor":
            return (str("description") ?? "Run a command", str("command") ?? "", [])
        case "Edit", "MultiEdit":
            var diff: [String] = []
            if let old = str("old_string") { diff += lines(old, max: 6).map { "- " + $0 } }
            if let new = str("new_string") { diff += lines(new, max: 6).map { "+ " + $0 } }
            return ("Edit \(name ?? "a file")", file ?? "", diff)
        case "Write":
            return ("Write \(name ?? "a file")", file ?? "", lines(str("content") ?? "", max: 8).map { "+ " + $0 })
        case "NotebookEdit":
            return ("Edit \(name ?? "a notebook")", file ?? "", lines(str("new_source") ?? "", max: 8).map { "+ " + $0 })
        case "WebFetch":
            return ("Fetch a web page", str("url") ?? "", [])
        case "WebSearch":
            return ("Search the web", str("query") ?? "", [])
        default:
            let title: String
            if toolName.hasPrefix("mcp__") {
                let parts = toolName.split(separator: "_", omittingEmptySubsequences: true)
                title = parts.count >= 3 ? "\(parts.dropFirst(2).joined(separator: "_")) (\(parts[1]))" : toolName
            } else {
                title = file.map { "\(toolName) \(($0 as NSString).lastPathComponent)" } ?? "Use \(toolName)"
            }
            return (title, compactJSON(input, limit: 400), [])
        }
    }

    /// Words for one permission_suggestions entry, mirroring the terminal dialog's "Yes, and …" options.
    static func describe(suggestion s: [String: Any]) -> (String, String)? {
        let destination: String
        switch s["destination"] as? String {
        case "session": destination = "for this session"
        case "localSettings": destination = "in this project, just for you"
        case "projectSettings": destination = "in this project"
        case "userSettings": destination = "in all projects"
        default: destination = ""
        }
        switch s["type"] as? String {
        case "addRules":
            guard (s["behavior"] as? String) == "allow", let rules = s["rules"] as? [[String: Any]], !rules.isEmpty else { return nil }
            let text = rules.map { r -> String in
                let tool = r["toolName"] as? String ?? "?"
                if let c = r["ruleContent"] as? String, !c.isEmpty { return "\(tool)(\(c))" }
                return tool
            }.joined(separator: ", ")
            return ("Yes, and don't ask again", [text, destination].filter { !$0.isEmpty }.joined(separator: " "))
        case "setMode":
            guard let mode = s["mode"] as? String else { return nil }
            if mode == "acceptEdits" { return ("Yes, allow all edits", destination) }
            return ("Yes, and switch to \(mode) mode", destination)
        case "addDirectories":
            // The path goes in the detail line (middle-truncated in the card), not the label.
            let dirs = (s["directories"] as? [String] ?? []).map(tildePath)
            return (dirs.count == 1 ? "Yes, and allow access to this folder" : "Yes, and allow access to these folders",
                    [dirs.joined(separator: ", "), destination].filter { !$0.isEmpty }.joined(separator: " "))
        default:
            return nil
        }
    }

    /// The exact stdout the hook prints for a choice.
    static func decision(_ action: PermOption.Action, message: String = "") -> String {
        var d: [String: Any]
        switch action {
        case .allow: d = ["behavior": "allow"]
        case .allowAndApply(let json):
            let entries = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [Any] ?? []
            d = ["behavior": "allow", "updatedPermissions": entries]
        case .deny: d = ["behavior": "deny", "message": message.isEmpty ? "The user denied this in beckon." : message]
        }
        return encode(d)
    }

    /// Wraps a decision in the envelope Claude Code reads from a PermissionRequest hook's stdout.
    static func encode(_ decision: [String: Any]) -> String {
        let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        let data = (try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Identity of a tool call across PermissionRequest and PostToolUse, which carry the same tool_input
    /// but (for PermissionRequest) no tool_use_id.
    static func callKey(session: String, agent: String?, tool: String, input: Any?) -> String {
        "\(session)|\(agent ?? "main")|\(tool)|\(compactJSON(input ?? [:], limit: .max))"
    }

    static func compactJSON(_ v: Any, limit: Int) -> String {
        guard JSONSerialization.isValidJSONObject(v),
              let data = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "\(v)" }
        let s = String(decoding: data, as: UTF8.self)
        return s.count > limit ? String(s.prefix(limit)) + "…" : s
    }

    static func lines(_ text: String, max: Int) -> [String] {
        let all = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return all.count > max ? Array(all.prefix(max)) + ["… \(all.count - max) more lines"] : all
    }
}
