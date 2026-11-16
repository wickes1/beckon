import Foundation
import Testing
@testable import BeckonApp

private let approval = Kind.permission(PermissionFormat.view(toolName: "Bash", input: [:], suggestions: []))
private let done = Kind.done(DoneView(headline: "Finished", summary: ""))

private func item(_ id: String, session: String = "s", kind: Kind = approval, visibility: Visibility = .shown) -> Item {
    Item(id: id, sessionID: session, agentID: nil, callKey: id, arrived: Date(), project: "p", appName: "VS Code",
         bundleID: nil, title: "t", context: "", kind: kind, visibility: visibility)
}

private func waiting() -> Connection {
    let c = Connection(fd: -1)
    c.expectsReply = true
    return c
}

@Suite struct ArrivalRules {
    init() { AuditLog.path = NSTemporaryDirectory() + "beckon-test-audit.log" }

    // The card being read must never be swapped out or pushed down by a newer one.
    @Test func newArrivalNeverReplacesTheOpenCard() {
        let s = Store()
        s.arrive(item("a"), connection: Connection(fd: -1), hookPID: nil)
        s.arrive(item("b"), connection: Connection(fd: -1), hookPID: nil)
        #expect(s.expanded == "a")
        #expect(s.ordered.first?.id == "a")
        #expect(s.unseen == ["b"])
    }

    // When the open card leaves, the user should land on the next thing that needs them, not on nothing.
    @Test func nextCardOpensWhenTheOpenOneLeaves() {
        let s = Store()
        s.arrive(item("a"), connection: Connection(fd: -1), hookPID: nil)
        s.arrive(item("b"), connection: Connection(fd: -1), hookPID: nil)
        s.remove("a")
        #expect(s.expanded == "b")
    }

    // A new prompt from the session means the old one was answered in the terminal; a turn moving on clears them all.
    @Test func sessionMovingOnClearsItsCards() {
        let s = Store()
        s.arrive(item("a", session: "x"), connection: Connection(fd: -1), hookPID: nil)
        s.arrive(item("b", session: "y"), connection: Connection(fd: -1), hookPID: nil)
        s.remove { $0.sessionID == "x" }
        #expect(s.items.map(\.id) == ["b"])
    }
}

@Suite struct ClickGuard {
    init() { AuditLog.path = NSTemporaryDirectory() + "beckon-test-audit.log" }  // keep test answers out of the real trail

    // A card that appears under the pointer must not catch a click aimed at the window behind it,
    // or a stray click becomes an approval.
    @Test func answersIgnoredRightAfterACardIsShown() async throws {
        let s = Store()
        s.arrive(item("a"), connection: Connection(fd: -1), hookPID: nil)
        s.cardShown("a")
        s.pointerEnteredAt = Date()
        s.answer("a", decision: PermissionFormat.decision(.allow), confirmation: "Allowed")
        #expect(s.sent["a"] == nil)
        try await Task.sleep(for: .milliseconds(Int(Store.armDelay * 1000) + 50))
        s.answer("a", decision: PermissionFormat.decision(.allow), confirmation: "Allowed")
        #expect(s.sent["a"] == "Allowed")
    }

    // The pointer has to come onto the panel on purpose: a card that has long been on screen still must not
    // accept a click from a pointer that just arrived (it was working in the window behind and slid over).
    @Test func pointerMustDwellBeforeAClickCounts() {
        let s = Store()
        s.arrive(item("a"), connection: Connection(fd: -1), hookPID: nil)
        s.cardShown("a")
        let later = Date().addingTimeInterval(10)
        #expect(!s.armed("a", now: later))  // pointer never entered
        s.pointerEnteredAt = later.addingTimeInterval(-0.1)
        #expect(!s.armed("a", now: later))  // entered 100 ms ago
        s.pointerEnteredAt = later.addingTimeInterval(-1)
        #expect(s.armed("a", now: later))
    }
}

@Suite struct UpdatesAndPrompts {
    init() { AuditLog.path = NSTemporaryDirectory() + "beckon-test-audit.log" }

    // Something that blocks Claude outranks news: it takes the open slot from a Done card the user isn't using.
    @Test func promptOpensOverAnUpdate() {
        let s = Store()
        s.arrive(item("d", kind: done), connection: Connection(fd: -1), hookPID: nil)
        s.arrive(item("a"), connection: Connection(fd: -1), hookPID: nil)
        #expect(s.expanded == "a")
        #expect(s.ordered.map(\.id) == ["a", "d"])
    }

    // ...but never while the user is reading or typing into that Done card.
    @Test func promptWaitsWhileTheUserIsOnTheOpenCard() {
        let s = Store()
        s.arrive(item("d", kind: done), connection: Connection(fd: -1), hookPID: nil)
        s.update("d") { $0.reply = "one more th" }
        s.arrive(item("a"), connection: Connection(fd: -1), hookPID: nil)
        #expect(s.expanded == "d")
        #expect(s.unseen == ["a"])
    }

    // One Done per session: five finished turns must not leave five cards.
    @Test func newUpdateReplacesTheSessionsPreviousOne() {
        let s = Store()
        s.arrive(item("other", session: "y", kind: done), connection: Connection(fd: -1), hookPID: nil)
        s.arrive(item("d1", session: "x", kind: done), connection: Connection(fd: -1), hookPID: nil)
        s.arrive(item("d2", session: "x", kind: done), connection: Connection(fd: -1), hookPID: nil)
        #expect(Set(s.items.map(\.id)) == ["other", "d2"])
    }

    // The reply field is a promise that Claude will get the text: it only exists while the Stop hook is listening.
    @Test func onlyAListeningStopHookGivesAReplyField() {
        let s = Store()
        s.arrive(item("live", session: "x", kind: done), connection: waiting(), hookPID: nil)
        s.arrive(item("dead", session: "y", kind: done), connection: Connection(fd: -1), hookPID: nil)
        #expect(s.replyable == ["live"])
    }
}

@Suite struct ClosedAndSuppressed {
    // Closing a prompt card must not answer it or lose it: Claude is still waiting in the terminal,
    // so it stays in the menu bar and can be brought back.
    @Test func closingAPromptKeepsItPending() {
        let s = Store()
        s.arrive(item("a"), connection: Connection(fd: -1), hookPID: nil)
        s.arrive(item("b"), connection: Connection(fd: -1), hookPID: nil)
        s.close("a")
        #expect(s.ordered.map(\.id) == ["b"])
        #expect(s.expanded == "b")
        #expect(s.pending.map(\.id).sorted() == ["a", "b"])
        s.reveal("a", open: true)
        #expect(s.expanded == "a")
        #expect(s.ordered.first?.id == "a")
    }

    // News has no terminal dialog behind it: closing it is the end of it.
    @Test func closingAnUpdateRemovesIt() {
        let s = Store()
        s.arrive(item("d", kind: done), connection: Connection(fd: -1), hookPID: nil)
        s.close("d")
        #expect(s.items.isEmpty)
    }

    // A prompt held back because its session is in front is still counted, takes no space on the panel,
    // and appears once the user looks away.
    @Test func suppressedPromptIsCountedButNotShownUntilRevealed() {
        let s = Store()
        s.arrive(item("a", visibility: .suppressed), connection: Connection(fd: -1), hookPID: nil)
        #expect(s.ordered.isEmpty)
        #expect(s.expanded == nil)
        #expect(s.pending.count == 1)
        s.reveal("a")
        #expect(s.expanded == "a")
    }

    // Going to a session from any of its cards means the user is now in front of it: nothing of that session may
    // stay on the panel. Prompts stay pending (Claude still waits in the terminal), news ends, other sessions and
    // a skill's "Action needed" pointing elsewhere are untouched.
    @Test func goingToASessionClearsItsCards() {
        let s = Store()
        let action = Kind.action(ActionView(title: "Log in", steps: [], target: nil))
        s.arrive(item("other", session: "y"), connection: Connection(fd: -1), hookPID: nil)
        s.arrive(item("news", session: "x", kind: done), connection: Connection(fd: -1), hookPID: nil)
        s.arrive(item("login", session: "x", kind: action), connection: Connection(fd: -1), hookPID: nil)
        s.arrive(item("prompt", session: "x"), connection: Connection(fd: -1), hookPID: nil)
        s.wentTo(s.items.first { $0.id == "prompt" }!)
        #expect(s.ordered.map(\.id).sorted() == ["login", "other"])
        #expect(s.pending.map(\.id).sorted() == ["login", "other", "prompt"])
        #expect(!s.items.contains { $0.id == "news" })
        s.wentTo(s.items.first { $0.id == "login" }!)
        #expect(s.ordered.map(\.id) == ["other"])
    }

    // Answered in the terminal while suppressed: it must go without ever having appeared.
    @Test func suppressedPromptClearsWithItsSession() {
        let s = Store()
        s.arrive(item("a", session: "x", visibility: .suppressed), connection: Connection(fd: -1), hookPID: nil)
        s.remove { $0.sessionID == "x" }
        #expect(s.items.isEmpty)
    }
}

@Suite struct TypedAnswers {
    init() { AuditLog.path = NSTemporaryDirectory() + "beckon-test-audit.log" }

    // Typing moves the pointer away as often as not. Text the user wrote can't come from a stray click,
    // so pressing Return must send it even with the pointer off the panel.
    @Test func typedAnswerDoesNotNeedThePointer() async throws {
        let s = Store()
        s.arrive(item("a"), connection: Connection(fd: -1), hookPID: nil)
        s.cardShown("a")
        try await Task.sleep(for: .milliseconds(Int(Store.armDelay * 1000) + 50))
        s.pointerEnteredAt = nil
        s.answer("a", decision: PermissionFormat.decision(.allow), confirmation: "Allowed")
        #expect(s.sent["a"] == nil)  // a click still needs the pointer
        s.answer("a", decision: PermissionFormat.decision(.deny, message: "no"), confirmation: "Denied", typed: true)
        #expect(s.sent["a"] == "Denied")
    }
}
