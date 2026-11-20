import Foundation
import enum SwiftUI.TimelineScheduleMode  // only this: SwiftUI's own Visibility would clash with the app's
import Testing
@testable import BeckonApp

private let approval = Kind.permission(PermissionFormat.view(toolName: "Bash", input: [:], suggestions: []))
private let done = Kind.done(DoneView(headline: "Finished", summary: ""))

private func item(_ id: String, kind: Kind = approval, visibility: Visibility = .shown, arrived: Date = Date()) -> Item {
    // A session each: a second Done from the same session would replace the first.
    Item(id: id, sessionID: "session-" + id, agentID: nil, callKey: id, arrived: arrived, project: "p", appName: "VS Code",
         bundleID: nil, title: "t", context: "", kind: kind, visibility: visibility)
}

/// A store where cards stay 30 s, whatever this Mac's own setting is.
private func store(stay: TimeInterval? = 30) -> Store {
    let s = Store()
    s.stay = stay
    return s
}

private func arrive(_ s: Store, _ items: Item...) {
    for item in items { s.arrive(item, connection: Connection(fd: -1), hookPID: nil) }
}

/// A moment by which a card that came into view just now has used up its 30 s.
private var later: Date { Date().addingTimeInterval(31) }

/// Gives the main queue, where the store's timers run, up to `seconds` to bring about `done`.
@MainActor private func wait(upTo seconds: TimeInterval, until done: () -> Bool) async throws {
    let end = Date().addingTimeInterval(seconds)
    while !done(), Date() < end { try await Task.sleep(for: .milliseconds(20)) }
}

/// A hook waiting on a card, seen from the hook's end: what, if anything, the app has sent it.
private struct WaitingHook {
    let connection: Connection
    private let fd: Int32

    init() {
        var fds: [Int32] = [0, 0]
        socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        _ = fcntl(fds[0], F_SETFL, O_NONBLOCK)
        fd = fds[0]
        connection = Connection(fd: fds[1])
        connection.expectsReply = true
    }

    /// nil while the app is still holding the hook; otherwise its reply ("\n" is the empty reply that lets the
    /// hook go without a decision).
    func reply() -> String? {
        var buf = [UInt8](repeating: 0, count: 256)
        let n = read(fd, &buf, buf.count)
        return n < 0 ? nil : String(decoding: buf[0..<n], as: UTF8.self)
    }
}

@Suite struct CardsLeavingByThemselves {
    init() { AuditLog.path = NSTemporaryDirectory() + "beckon-test-audit.log" }  // cards leaving are logged: keep them out of the real trail

    // The default. Someone who never touched the setting must see the panel behave exactly as it always has:
    // no bar, and a card that stays until they deal with it.
    @Test func neverMeansNoCountdownAndNothingLeaves() {
        let s = store(stay: nil)
        arrive(s, item("a"), item("d", kind: done))
        #expect(s.countdowns.isEmpty)
        s.sweep(now: Date().addingTimeInterval(86_400))
        #expect(s.ordered.count == 2)
    }

    // The time is for reading the card, so it runs from when the card can be read. A prompt held back while its
    // session was in front, for an hour, must get its full time once it shows — not be gone before it appeared.
    @Test func timeRunsFromWhenTheCardCameIntoViewNotFromWhenItArrived() throws {
        let s = store()
        arrive(s, item("a", visibility: .suppressed, arrived: Date().addingTimeInterval(-3600)))
        #expect(s.countdowns["a"] == nil)
        s.sweep(now: later)
        #expect(s.items.first?.visibility == .suppressed)

        let before = Date()
        s.reveal("a")
        #expect(try #require(s.countdowns["a"]) >= before)
        s.sweep(now: Date().addingTimeInterval(29))
        #expect(s.ordered.map(\.id) == ["a"])
        s.sweep(now: later)
        #expect(s.ordered.isEmpty)
    }

    // A card folded under "+N more" isn't drawn either. Its time starts when it moves up into view.
    @Test func aCardFoldedAwayStartsItsTimeWhenItIsDrawn() {
        let s = store()
        for i in 1...7 { arrive(s, item("d\(i)", kind: done)) }
        let drawn = Set(s.onScreen.map(\.id))
        #expect(drawn.count == Store.visibleRows + 1)
        #expect(Set(s.countdowns.keys) == drawn)

        s.remove(s.onScreen.last!.id)
        #expect(Set(s.countdowns.keys) == Set(s.onScreen.map(\.id)))
        #expect(s.countdowns.count == Store.visibleRows + 1)
        s.toggleShowAll()
        #expect(s.countdowns.count == 6)
    }

    // Pointing at a card says "I'm reading this". From then on it must never leave by itself, however long the
    // pointer has been gone: the owner's rule, in his words.
    @Test func pointingAtACardCallsItsCountdownOffForGood() {
        let s = store()
        arrive(s, item("a", kind: done))
        s.hovered("a")
        #expect(s.countdowns["a"] == nil)
        arrive(s, item("b", kind: done))  // other cards coming and going must not start it again
        #expect(s.countdowns["a"] == nil)
        s.sweep(now: later)
        #expect(s.ordered.map(\.id) == ["a"])
    }

    // While the pointer is on the panel, or an answer is being typed in the open card, a card vanishing would
    // shift the others under the user's hands. An overdue card waits, and goes once they are done.
    @Test func nothingLeavesWhileTheUserIsOnThePanel() {
        let s = store()
        arrive(s, item("d", kind: done))
        s.pointerInside = true
        s.countdowns["d"] = Date().addingTimeInterval(-31)  // its time ran out while the pointer was on the panel
        s.sweep()
        #expect(s.ordered.map(\.id) == ["d"])
        s.pointerInside = false  // and nothing else comes along to sweep it: the pointer leaving has to
        #expect(s.ordered.isEmpty)

        arrive(s, item("a"), item("e", kind: done))
        s.update("a") { $0.reply = "use the staging remo" }  // "a" is the open card
        s.sweep(now: later)
        #expect(Set(s.ordered.map(\.id)) == ["a", "e"])
    }

    // The card's own timer is what makes it leave. Every other test here moves the clock by hand with sweep(now:),
    // so with the timer gone they all stay green while no card ever leaves by itself.
    @Test @MainActor func aCardLeavesOnItsOwnTimer() async throws {
        let s = store(stay: 0.2)
        arrive(s, item("d", kind: done))
        try await wait(upTo: 3) { s.ordered.isEmpty }
        #expect(s.ordered.isEmpty)
    }

    // A card's timer fires once. If an answer was being typed then, the card waits; when the text is deleted again
    // nothing else happens on the panel, and the card must still go rather than sit there with an empty bar.
    @Test @MainActor func anOverdueCardGoesOnceTheAnswerThatHeldItIsDeleted() async throws {
        let s = store(stay: 0.2)
        arrive(s, item("a"), item("e", kind: done))  // "a" is the open card
        s.update("a") { $0.reply = "use the staging remo" }
        try await Task.sleep(for: .milliseconds(400))  // both timers have fired and found the user typing
        #expect(Set(s.ordered.map(\.id)) == ["a", "e"])
        s.update("a") { $0.reply = "" }
        try await wait(upTo: 3) { !s.ordered.contains { $0.id == "e" } }
        #expect(!s.ordered.contains { $0.id == "e" })
    }

    // The other way an overdue card is let go: the open card whose draft held it leaves.
    @Test func anOverdueCardGoesWhenTheCardThatHeldItBackLeaves() {
        let s = store()
        arrive(s, item("a"), item("e", kind: done))
        s.update("a") { $0.reply = "typing" }
        s.countdowns["e"] = Date().addingTimeInterval(-31)
        s.sweep()
        #expect(s.ordered.map(\.id).contains("e"))
        s.remove("a")
        #expect(s.ordered.isEmpty)
    }

    // Opening a card can push another under "+N more". The countdowns follow what is drawn: the card folded away
    // stops, the one that came up starts.
    @Test func expandingACardKeepsCountdownsOnWhatIsDrawn() {
        let s = store()
        arrive(s, item("d", kind: done))
        s.pointerInside = true  // so the prompts below join collapsed instead of taking the open slot
        for i in 1...5 { arrive(s, item("p\(i)")) }
        #expect(s.expanded == "d")
        s.expand("p5")
        #expect(!s.onScreen.map(\.id).contains("d"))
        #expect(Set(s.countdowns.keys) == Set(s.onScreen.map(\.id)))
    }

    // A card kept past its time keeps an empty bar, and that bar must stop redrawing: the endless schedule it had
    // redrew it every frame for a 10 s stay, for as long as the card stayed.
    @Test func theBarStopsTickingOnceItIsEmpty() {
        let since = Date()
        let ticks = CountdownTicks(since: since, stay: 10)
        let all = ticks.entries(from: since, mode: .normal)
        #expect(all.first == since)
        #expect(all.last == since.addingTimeInterval(10))
        #expect(zip(all, all.dropFirst()).allSatisfy { $0 < $1 })
        #expect(ticks.entries(from: since.addingTimeInterval(4), mode: .normal).first == since.addingTimeInterval(4))  // drawn at once, mid-way
        #expect(ticks.entries(from: since.addingTimeInterval(11), mode: .normal) == [since.addingTimeInterval(11)])  // drawn empty once, then nothing
    }

    // An answer half given, or just sent and showing its confirmation, is the user's own work on that card:
    // a timer must not take it away, then or later.
    @Test func aCardHoldingAnAnswerKeepsItsPlace() {
        let s = store()
        arrive(s, item("open"), item("picked"), item("sent"))  // the first one is the open card; the others wait collapsed
        s.update("picked") { $0.picks[0] = [1] }
        s.sent["sent"] = "Allowed"
        s.sweep(now: later)
        #expect(Set(s.ordered.map(\.id)) == ["picked", "sent"])
        #expect(s.countdowns["picked"] == nil)
        #expect(s.countdowns["sent"] == nil)
    }

    // The rule that matters most. News has nowhere else to live, so its time being up ends it, as Dismiss does
    // (a Done card's listening hook is let go). Anything still waiting on the user must outlive its time on the
    // panel. A prompt is a question Claude is blocked on: a timer must neither answer it nor drop it. An "Action
    // needed" card is a skill waiting for the user to do something elsewhere; dropping it would leave nothing to
    // say what. Both only leave the panel: a held hook is still held, the menu bar still lists them, and they
    // can be brought back. The skill's own `beckon dismiss` still takes its card down.
    @Test func whenTimeIsUpNewsIsDismissedButWhatWaitsOnTheUserIsOnlyHidden() {
        let action = Kind.action(ActionView(title: "Log in", steps: [], target: nil))
        #expect(AutoDismiss.whenTimeIsUp(approval) == .hide)
        #expect(AutoDismiss.whenTimeIsUp(.questions(QuestionsView(questions: [], inputJSON: "{}"))) == .hide)
        #expect(AutoDismiss.whenTimeIsUp(.plan(PlanView(title: "", markdown: "", inputJSON: "{}"))) == .hide)
        #expect(AutoDismiss.whenTimeIsUp(action) == .hide)
        #expect(AutoDismiss.whenTimeIsUp(done) == .dismiss)
        #expect(AutoDismiss.whenTimeIsUp(.failed(FailureView(headline: "", error: ""))) == .dismiss)

        let s = store()
        let (stopHook, permissionHook) = (WaitingHook(), WaitingHook())
        s.arrive(item("news", kind: done), connection: stopHook.connection, hookPID: nil)
        s.arrive(item("prompt"), connection: permissionHook.connection, hookPID: nil)
        arrive(s, item("action", kind: action))
        s.sweep(now: later)

        #expect(!s.items.contains { $0.id == "news" })
        #expect(stopHook.reply() == "\n")

        #expect(s.ordered.isEmpty)
        #expect(s.items.first { $0.id == "prompt" }?.visibility == .closed)
        #expect(s.items.first { $0.id == "action" }?.visibility == .closed)
        #expect(Set(s.pending.map(\.id)) == ["prompt", "action"])
        #expect(permissionHook.reply() == nil)
        s.reveal("prompt", open: true)
        #expect(s.expanded == "prompt")

        s.remove { $0.callKey == "action" }  // what the skill's `beckon dismiss` does
        #expect(s.pending.map(\.id) == ["prompt"])
    }

    // A prompt the timer hid, or news it dismissed, leaves the panel without anyone seeing it go. The log is the
    // one place that can say what happened to it.
    @Test func whatTheTimerTakesAwayIsLogged() throws {
        let before = (try? Data(contentsOf: URL(fileURLWithPath: AuditLog.path)))?.count ?? 0
        let s = store()
        let tag = UUID().uuidString
        arrive(s, item("prompt-" + tag), item("news-" + tag, kind: done))
        s.sweep(now: later)
        let added = String(decoding: try Data(contentsOf: URL(fileURLWithPath: AuditLog.path)).dropFirst(before), as: UTF8.self)
        #expect(added.contains("AUTO hidden after 30 s: Approval session=session-prompt-\(tag)"))
        #expect(added.contains("AUTO dismissed after 30 s: Done session=session-news-\(tag)"))
    }

    // The × on an "Action needed" card is the user saying they are done with it: that still ends it. Only the
    // timer hides one.
    @Test func closingAnActionCardByHandStillEndsIt() {
        let s = store()
        arrive(s, item("action", kind: .action(ActionView(title: "Log in", steps: [], target: nil))))
        s.close("action")
        #expect(s.items.isEmpty)
    }

    // Picked from the menu bar, a card is there because the user asked for it. Closing it again under them a few
    // seconds later would make a timed-out prompt impossible to answer at leisure.
    @Test func aCardBroughtBackFromTheMenuBarStays() {
        let s = store()
        arrive(s, item("a"))
        s.sweep(now: later)
        s.reveal("a", open: true)
        #expect(s.countdowns["a"] == nil)
        s.sweep(now: Date().addingTimeInterval(3600))
        #expect(s.ordered.map(\.id) == ["a"])
    }

    // The setting comes back from defaults, where anything can be. Only a time the menu offers counts; anything else
    // is Never, or cards would leave after a time the menu shows no tick against.
    @Test func onlyATimeTheMenuOffersIsUsed() {
        for seconds in AutoDismiss.choices { #expect(AutoDismiss.offered(seconds) == seconds) }
        for seconds in [0.0, 15, -1, 86_400] { #expect(AutoDismiss.offered(seconds) == nil, "\(seconds)") }
    }

    // The menu names the choices as the README does: 10 s, 30 s, 60 s or 5 min, and Never.
    @Test func theMenuNamesEachChoice() {
        #expect(AutoDismiss.choices.map(AutoDismiss.title) == ["After 10 Seconds", "After 30 Seconds", "After 60 Seconds", "After 5 Minutes"])
        #expect(AutoDismiss.title(nil) == "Never")
    }

    // Changing the setting applies to the cards already there, from that moment: a card that has sat on the
    // panel for minutes must not vanish the instant "10 seconds" is picked, and Never must stop every bar.
    @Test func pickingATimeStartsTheCardsInViewAfresh() throws {
        let s = store(stay: 300)
        arrive(s, item("d", kind: done))
        s.countdowns["d"] = Date().addingTimeInterval(-200)  // it has been in view for a while
        let before = Date()
        s.stay = 10
        #expect(try #require(s.countdowns["d"]) >= before)
        s.sweep(now: Date().addingTimeInterval(9))
        #expect(s.ordered.map(\.id) == ["d"])

        s.stay = nil
        #expect(s.countdowns.isEmpty)
        s.sweep(now: later)
        #expect(s.ordered.map(\.id) == ["d"])
        s.stay = 30
        #expect(s.countdowns["d"] != nil)
    }
}
