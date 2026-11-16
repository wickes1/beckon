import Foundation
import Testing
@testable import BeckonApp

private func json(_ s: String) -> [String: Any] {
    try! JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: Any]
}

@Suite struct DecisionJSON {
    // If the shape is off, Claude Code ignores the hook output and the user's click silently does nothing.
    @Test func allowHasTheShapeClaudeCodeReads() {
        let out = json(PermissionFormat.decision(.allow))
        let hso = out["hookSpecificOutput"] as! [String: Any]
        #expect(hso["hookEventName"] as? String == "PermissionRequest")
        #expect((hso["decision"] as! [String: Any])["behavior"] as? String == "allow")
    }

    // "Don't ask again" must save exactly the rule Claude Code offered; rebuilding it could save a broader rule.
    @Test func alwaysEchoesTheSuggestionVerbatim() {
        let suggestion = #"{"behavior":"allow","destination":"localSettings","rules":[{"ruleContent":"git push:*","toolName":"Bash"}],"type":"addRules"}"#
        let view = PermissionFormat.view(toolName: "Bash", input: ["command": "git push"], suggestions: [json(suggestion)])
        guard case .allowAndApply(let entry) = view.options[1].action else { Issue.record("second option should apply the suggestion"); return }
        let decision = (json(PermissionFormat.decision(.allowAndApply(entry)))["hookSpecificOutput"] as! [String: Any])["decision"] as! [String: Any]
        let applied = decision["updatedPermissions"] as! [[String: Any]]
        #expect(applied.count == 1)
        #expect(NSDictionary(dictionary: applied[0]).isEqual(to: json(suggestion)))
    }

    // The terminal offers one "Yes, and …" that applies every suggestion together (seen live with Write:
    // accept-edits + directory access). Splitting them would let the panel save a different set than the terminal.
    @Test func severalSuggestionsAreOneOptionApplyingAll() {
        let a = json(#"{"type":"setMode","mode":"acceptEdits","destination":"session"}"#)
        let b = json(#"{"type":"addDirectories","directories":["/tmp/x"],"destination":"session"}"#)
        let view = PermissionFormat.view(toolName: "Write", input: ["file_path": "/tmp/x/f"], suggestions: [a, b])
        #expect(view.options.count == 3)
        guard case .allowAndApply(let entries) = view.options[1].action else { Issue.record("expected combined option"); return }
        let decision = (json(PermissionFormat.decision(.allowAndApply(entries)))["hookSpecificOutput"] as! [String: Any])["decision"] as! [String: Any]
        #expect((decision["updatedPermissions"] as! [Any]).count == 2)
    }

    // A denial without a reason leaves Claude guessing; the user's words must reach it, and an empty field still says why.
    @Test func denyCarriesTheUsersWords() {
        let d = (json(PermissionFormat.decision(.deny, message: "use the staging remote"))["hookSpecificOutput"] as! [String: Any])["decision"] as! [String: Any]
        #expect(d["behavior"] as? String == "deny")
        #expect(d["message"] as? String == "use the staging remote")
        let empty = (json(PermissionFormat.decision(.deny))["hookSpecificOutput"] as! [String: Any])["decision"] as! [String: Any]
        #expect(!(empty["message"] as? String ?? "").isEmpty)
    }
}

@Suite struct Options {
    // Mirrors the terminal dialog, so the panel never offers a choice the terminal wouldn't.
    @Test func yesFirstSuggestionsThenNo() {
        let s = json(#"{"type":"setMode","mode":"acceptEdits","destination":"session"}"#)
        let view = PermissionFormat.view(toolName: "Edit", input: ["file_path": "/a/b.md"], suggestions: [s])
        #expect(view.options.map(\.label) == ["Yes", "Yes, allow all edits", "No, and tell Claude what to do instead"])
        #expect(view.options[1].detail == "for this session")
    }

    // An option we can't describe would be a button with unknown consequences: skip it.
    @Test func unknownSuggestionTypesAreNotOffered() {
        let view = PermissionFormat.view(toolName: "Bash", input: [:], suggestions: [json(#"{"type":"somethingNew","destination":"session"}"#)])
        #expect(view.options.count == 2)
        // One unknown entry poisons the combined option: applying it would change settings the user never saw.
        let mixed = PermissionFormat.view(toolName: "Bash", input: [:], suggestions: [
            json(#"{"type":"setMode","mode":"acceptEdits","destination":"session"}"#), json(#"{"type":"somethingNew"}"#)])
        #expect(mixed.options.map(\.label) == ["Yes", "No, and tell Claude what to do instead"])
    }

    @Test func ruleTextNamesToolAndScope() {
        let s = json(#"{"type":"addRules","behavior":"allow","destination":"projectSettings","rules":[{"toolName":"Bash","ruleContent":"npm test"}]}"#)
        #expect(PermissionFormat.describe(suggestion: s)?.1 == "Bash(npm test) in this project")
    }
}

@Suite struct CardText {
    // The headline is what the user decides on at a glance: Claude's own one-line description beats the raw command.
    @Test func bashUsesClaudesDescription() {
        let (headline, body, _) = PermissionFormat.describe(toolName: "Bash", input: ["command": "git push origin main", "description": "Push main to GitHub"])
        #expect(headline == "Push main to GitHub")
        #expect(body == "git push origin main")
    }

    @Test func editShowsFileAndDiff() {
        let (headline, body, diff) = PermissionFormat.describe(toolName: "Edit", input: ["file_path": "/x/notes.md", "old_string": "a", "new_string": "b"])
        #expect(headline == "Edit notes.md")
        #expect(body == "/x/notes.md")
        #expect(diff == ["- a", "+ b"])
    }
}

@Suite struct StaleCards {
    // PostToolUse is how a card answered in the terminal gets cleared. If the keys differ for the same call,
    // the card stays on screen after the user already answered.
    @Test func sameCallSameKeyRegardlessOfKeyOrder() {
        let a = json(#"{"command":"ls","description":"List"}"#)
        let b = json(#"{"description":"List","command":"ls"}"#)
        #expect(PermissionFormat.callKey(session: "s", agent: nil, tool: "Bash", input: a) == PermissionFormat.callKey(session: "s", agent: nil, tool: "Bash", input: b))
    }

    // A subagent's identical call is a different prompt; clearing one must not clear the other.
    @Test func subagentCallsAreDistinct() {
        let i = json(#"{"command":"ls"}"#)
        #expect(PermissionFormat.callKey(session: "s", agent: nil, tool: "Bash", input: i) != PermissionFormat.callKey(session: "s", agent: "a1", tool: "Bash", input: i))
    }
}
