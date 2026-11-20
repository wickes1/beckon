import BeckonCore
import Foundation
import Testing
@testable import BeckonApp

// The CLI checks `notify --url` with webURLProblem and exits; the app checks Target.web after the CLI has gone.
// Any URL the CLI lets through and the app refuses is a card that silently never appears.
@Suite struct WebURLRule {
    @Test func whatTheCLIAcceptsTheAppOpens() {
        let ordinary = ["https://example.com/login?next=/a#top", "HTTP://example.com", "https://user:pw@example.com:8443/a?b#c",
                        "http://[::1]:8080/", "http://127.0.0.1:8080", "https://example.com/über", "https://example.com/a b", "https://exa_mple.com"]
        for url in ordinary {
            #expect(webURLProblem(url) == nil, "\(url)")
            #expect(Target.web(url) == .url(url), "\(url)")
        }
        // Each one passed the CLI's old prefix check and was refused by the app.
        for url in ["https://", "http://", "https:///login", "http://:8080/x", "https://@/x", "https://exa mple.com", "https://example.com:abc/", "https://[::1"] {
            #expect(webURLProblem(url) != nil, "\(url)")
            #expect(Target.web(url) == nil, "\(url)")
        }
        // Hosts Foundation reads but this rule doesn't: refused on both sides, and out loud in the CLI.
        for url in ["https://bücher.de", "https://a!b.com", "https://[v1.fe]/"] {
            #expect(webURLProblem(url) != nil, "\(url)")
            #expect(URL(string: url)?.isWeb == true, "\(url)")
        }
        #expect(webURLProblem("https:///login") == "has no host")
        #expect(webURLProblem("file:///etc/hosts") == "has the scheme \"file\", not http or https")
        #expect(webURLProblem("example.com") == "is not a URL")
    }
}

private func envelope(_ event: String, _ payload: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: ["v": 1, "event": event, "wait": false, "payload": payload])
}

// These go through Intake.handle, which works on the app's one store: one suite, so that they run one at a time,
// each cleaning up after itself.
@Suite(.serialized) struct IntakeEvents {
    init() { AuditLog.path = NSTemporaryDirectory() + "beckon-test-audit.log" }

    // The button says "Open in Browser" and hands the URL to macOS, which opens a file or starts another app's
    // URL handler just as readily. Whoever can run `beckon notify` must not get that behind a browser label.
    @Test func onlyWebPagesAreTargets() {
        #expect(Target.web("https://example.com/login?next=/a") == .url("https://example.com/login?next=/a"))
        #expect(Target.web("HTTP://example.com") != nil)
        for refused in ["file:///Applications/Calculator.app", "file:///etc/passwd", "ssh://host", "x-apple.systempreferences:com.apple.preference.security",
                        "javascript:alert(1)", "example.com", "/usr/bin/true", "https://", "http:example.com"] {
            #expect(Target.web(refused) == nil, "\(refused)")
        }
    }

    // A refused notify shows no card at all (a card without its button would send the user nowhere), and leaves
    // a line in the log, since the CLI has already gone and nothing else says why no card came.
    @Test func notifyWithAnotherSchemeShowsNoCard() throws {
        let scheme = "beckontest-\(UUID().uuidString.prefix(8).lowercased())"  // the log is shared: a line only this run writes
        Intake.handle(envelope("Notify", ["title": scheme, "url": "\(scheme)://x"]), Connection(fd: -1))
        #expect(!store.items.contains { $0.summary == scheme })
        let log = try String(contentsOfFile: AuditLog.path, encoding: .utf8)
        #expect(log.contains("NOTIFY refused: --url has the scheme \"\(scheme)\""))
    }

    // The line has to say what was wrong. "https:///login" (a skill's empty $HOST) was logged as a scheme that
    // "is not http or https", which sends whoever reads it after the wrong thing.
    @Test func aRefusedNotifyLogsTheRealReason() throws {
        let before = (try? Data(contentsOf: URL(fileURLWithPath: AuditLog.path)))?.count ?? 0
        let title = "no-host-\(UUID().uuidString)"
        Intake.handle(envelope("Notify", ["title": title, "url": "https:///login"]), Connection(fd: -1))
        #expect(!store.items.contains { $0.summary == title })
        let added = try Data(contentsOf: URL(fileURLWithPath: AuditLog.path)).dropFirst(before)
        #expect(String(decoding: added, as: UTF8.self).contains("NOTIFY refused: --url has no host"))
    }

    @Test func notifyWithAWebPageShowsItsCard() {
        let title = "accepted-\(UUID().uuidString)"
        Intake.handle(envelope("Notify", ["title": title, "url": "https://example.com/login"]), Connection(fd: -1))
        let card = store.items.first { $0.summary == title }
        defer { if let card { store.remove(card.id) } }
        guard case .action(let view) = card?.kind else { Issue.record("an http(s) notify should arrive as an Action needed card"); return }
        #expect(view.target == .url("https://example.com/login"))
    }

    private func prompt(_ id: String, session: String, agent: String?) -> Item {
        Item(id: id, sessionID: session, agentID: agent, callKey: id, arrived: Date(), project: "p", appName: "VS Code", bundleID: nil,
             title: "t", context: "", kind: .permission(PermissionFormat.view(toolName: "Bash", input: [:], suggestions: [])))
    }

    // A subagent finishing says nothing about what the main agent is waiting on. The main agent's prompts have
    // no agent id, so a SubagentStop that also has none must not be read as "the agent with no id stopped":
    // that took every approval of the session off the panel while Claude was still waiting on them.
    @Test func aSubagentStopClearsOnlyThatSubagentsCards() {
        let session = "session-\(UUID().uuidString)"
        let (main, sub) = ("main-\(session)", "sub-\(session)")
        store.arrive(prompt(main, session: session, agent: nil), connection: Connection(fd: -1), hookPID: nil)
        store.arrive(prompt(sub, session: session, agent: "a1"), connection: Connection(fd: -1), hookPID: nil)
        defer { store.remove(main); store.remove(sub) }

        Intake.handle(envelope("SubagentStop", ["session_id": session]), Connection(fd: -1))
        #expect(store.items.contains { $0.id == main })
        #expect(store.items.contains { $0.id == sub })

        Intake.handle(envelope("SubagentStop", ["session_id": session, "agent_id": "a1"]), Connection(fd: -1))
        #expect(store.items.contains { $0.id == main })
        #expect(!store.items.contains { $0.id == sub })
    }
}
