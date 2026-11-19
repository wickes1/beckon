import Foundation
import Testing
@testable import BeckonApp

private func envelope(_ event: String, _ payload: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: ["v": 1, "event": event, "wait": false, "payload": payload])
}

// These go through Intake.handle, which works on the app's one store: one at a time, each cleaning up after itself.
@Suite(.serialized) struct NotifyTargets {
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
        #expect(log.contains("NOTIFY refused: --url scheme \"\(scheme)\""))
    }

    @Test func notifyWithAWebPageShowsItsCard() {
        let title = "accepted-\(UUID().uuidString)"
        Intake.handle(envelope("Notify", ["title": title, "url": "https://example.com/login"]), Connection(fd: -1))
        let card = store.items.first { $0.summary == title }
        defer { if let card { store.remove(card.id) } }
        guard case .action(let view) = card?.kind else { Issue.record("an http(s) notify should arrive as an Action needed card"); return }
        #expect(view.target == .url("https://example.com/login"))
    }
}
