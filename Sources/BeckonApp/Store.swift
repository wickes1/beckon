import AppKit
import Foundation
import Observation
import os
import SwiftUI

struct ActionView: Equatable {
    let title: String
    let steps: [String]
    let target: Target?
}

struct DoneView: Equatable {
    let headline: String
    let summary: String
}

struct FailureView: Equatable {
    let headline: String
    let error: String
}

enum Kind {
    case permission(PermissionView), questions(QuestionsView), plan(PlanView), action(ActionView), done(DoneView), failed(FailureView)

    // Items that block Claude sort above updates and get the accent colour.
    var needsYou: Bool {
        switch self {
        case .permission, .questions, .plan, .action: return true
        case .done, .failed: return false
        }
    }
    /// Claude Code is showing its own dialog for these in the terminal, so closing the card doesn't end the request.
    var hasTerminalDialog: Bool {
        switch self {
        case .permission, .questions, .plan: return true
        case .action, .done, .failed: return false
        }
    }
    var label: String {
        switch self {
        case .permission: return "Approval"
        case .questions: return "Question"
        case .plan: return "Plan review"
        case .action: return "Action needed"
        case .done: return "Done"
        case .failed: return "Stopped"
        }
    }
    var symbol: String {
        switch self {
        case .permission: return "hand.raised.fill"
        case .questions: return "questionmark.bubble.fill"
        case .plan: return "list.bullet.clipboard.fill"
        case .action: return "cursorarrow.click.2"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
}

/// Where an item is right now. Anything not `.shown` is still pending and still listed in the menu bar.
enum Visibility {
    case shown
    case closed      // closed with ×, or its time on the panel ran out; Claude keeps waiting
    case suppressed  // the user is looking at that session, so its own dialog is in front of them
}

struct Item: Identifiable {
    let id: String
    let sessionID: String
    let agentID: String?
    let callKey: String
    let arrived: Date
    let project: String
    let appName: String
    let bundleID: String?
    var title: String      // session title from the transcript, else the project name
    var context: String    // Claude's last words before the prompt, from the transcript
    let kind: Kind
    var location = Location()
    var visibility = Visibility.shown

    var summary: String {
        switch kind {
        case .permission(let p): return p.headline
        case .questions(let q): return q.questions.count == 1 ? q.questions[0].question : "\(q.questions.count) questions"
        case .plan(let p): return p.title
        case .action(let a): return a.title
        case .done(let d): return d.headline
        case .failed(let f): return f.headline
        }
    }
}

// Per-item answer-in-progress, kept outside the views so collapsing a card never loses what was typed or picked.
struct Draft {
    var reply = ""
    var picks: [Int: Set<Int>] = [:]
    var other: [Int: String] = [:]
    var current = 0
    var previewOpen: Int?
    var hasInput: Bool { !reply.isEmpty || !picks.values.allSatisfy(\.isEmpty) || !other.values.allSatisfy(\.isEmpty) }
    func answered(_ q: Int) -> Bool { !(picks[q] ?? []).isEmpty || !(other[q] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    func complete(_ count: Int) -> Bool { (0..<count).allSatisfy(answered) }
}

@Observable
final class Store {
    var items: [Item] = []
    var expanded: String?
    var drafts: [String: Draft] = [:]
    var sent: [String: String] = [:]   // id → confirmation shown briefly before the card leaves
    var unseen: Set<String> = []
    var showAll = false
    var pointerInside = false {
        // A card whose time ran out while the pointer was on the panel can go now.
        didSet { if oldValue && !pointerInside { sweep() } }
    }
    var replyable: Set<String> = []    // Done cards whose Stop hook is still listening for a reply
    var countdowns: [String: Date] = [:]  // id → since when the card has been in view, while it is counting down to leaving by itself

    @ObservationIgnored private var shownAt: [String: Date] = [:]
    @ObservationIgnored private var connections: [String: Connection] = [:]
    @ObservationIgnored private var watchers: [String: DispatchSourceProcess] = [:]
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var kept: Set<String> = []  // cards whose countdown was called off for good
    @ObservationIgnored private var sweepAgain = false  // a sweep is due in a moment, see sweep()

    static let visibleRows = 4

    // Open card first (it never moves while you use it), then blocking items newest first, then updates.
    var ordered: [Item] {
        let shown = items.filter { $0.visibility == .shown }
        let head = shown.filter { $0.id == expanded }
        let rest = shown.filter { $0.id != expanded }
        return head + rest.filter { $0.kind.needsYou } + rest.filter { !$0.kind.needsYou }
    }

    /// The cards actually drawn: the rest of `ordered` is folded under "+N more" until the user unfolds it.
    var onScreen: [Item] { showAll ? ordered : Array(ordered.prefix(Self.visibleRows + 1)) }

    /// What the menu bar counts and lists: everything still waiting on the user, on screen or not.
    var pending: [Item] { items.filter { $0.kind.needsYou } }

    var engaged: Bool { pointerInside || (expanded.flatMap { drafts[$0]?.hasInput } ?? false) }

    func draft(_ id: String) -> Draft { drafts[id] ?? Draft() }
    func update(_ id: String, _ change: (inout Draft) -> Void) {
        var d = drafts[id] ?? Draft()
        change(&d)
        drafts[id] = d
    }

    // MARK: Arrival

    /// Arrival rules:
    /// 1. A new update (Done / Stopped) from a session replaces that session's previous update.
    /// 2. Nothing open → the new item opens.
    /// 3. Open card is an update and the new item blocks Claude → it opens, unless the user is engaged.
    /// 4. Otherwise it joins the list collapsed and marked unseen; the open card never moves or closes under the user.
    /// An item that arrives suppressed is only stored (and counted) until `reveal`.
    func arrive(_ item: Item, connection: Connection, hookPID: Int32?) {
        if !item.kind.needsYou {
            for old in items where old.sessionID == item.sessionID && !old.kind.needsYou && old.id != expanded { remove(old.id) }
        }
        connections[item.id] = connection
        if let pid = hookPID { watch(pid: pid, for: item.id) }
        withAnimation(spring) {
            if case .done = item.kind, connection.expectsReply { replyable.insert(item.id) }
            items.insert(item, at: 0)
            if item.visibility == .shown { place(item) }
        }
        if item.visibility == .shown { Chime.play(for: item.kind) }
        syncCountdowns()
        onChange?()
    }

    private func place(_ item: Item) {
        if let open = items.first(where: { $0.id == expanded }) {
            if !open.kind.needsYou && item.kind.needsYou && !engaged { expanded = item.id } else { unseen.insert(item.id) }
        } else {
            expanded = item.id
        }
    }

    /// A closed or suppressed item comes onto the panel. From the menu bar (`open`) it also becomes the open card.
    func reveal(_ id: String, open: Bool = false) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(spring) {
            if items[i].visibility != .shown {
                items[i].visibility = .shown
                place(items[i])
                // Held back while the user looked at its session, it shows now they looked away: that is its
                // arrival. Opened from the menu bar, the user asked for it and needs no sound.
                if !open { Chime.play(for: items[i].kind) }
            }
            if open { expanded = id; unseen.remove(id) }
        }
        // Picked from the menu bar: the user asked for this card, which is as good as pointing at it.
        if open { kept.insert(id) }
        syncCountdowns()
        onChange?()
    }

    func setSessionInfo(id: String, title: String?, context: String?) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if let title, !title.isEmpty { items[i].title = title }
        if let context { items[i].context = context }
    }

    // If the hook process goes away (Claude's hook timeout, session killed), a prompt card is stale.
    // A Done card is still news; it only loses its reply field.
    private func watch(pid: Int32, for id: String) {
        let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            if self.replyable.contains(id) { withAnimation(spring) { _ = self.replyable.remove(id) } } else { self.remove(id) }
        }
        src.resume()
        watchers[id] = src
    }

    // MARK: Leaving

    /// Answered in the panel: reply to the waiting hook now, show the confirmation, then leave.
    /// `typed` answers carry text the user wrote, which no stray click can produce, so they skip the pointer
    /// half of the click guard (the pointer may have left the panel while typing).
    func answer(_ id: String, decision: String, confirmation: String, typed: Bool = false) {
        let now = Date()
        let ok = (typed ? shownLongEnough(id, now: now) : armed(id, now: now)) && sent[id] == nil
        log(id, decision: decision, accepted: ok, now: now)
        guard ok else { return }
        connections.removeValue(forKey: id)?.reply(decision)
        withAnimation(spring) { sent[id] = confirmation }
        onChange?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { self.remove(id) }
    }

    /// The × button. A prompt Claude Code is also showing in the terminal stays pending in the menu bar;
    /// anything else has no other home, so closing it ends it.
    func close(_ id: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        guard item.kind.hasTerminalDialog else { remove(id); return }
        hide(id)
    }

    /// Off the panel but still pending: the menu bar lists it, a waiting hook keeps waiting, `reveal` brings it back.
    private func hide(_ id: String, animation: Animation = spring) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(animation) {
            items[i].visibility = .closed
            unseen.remove(id)
            if expanded == id { expanded = ordered.first?.id }
        }
        syncCountdowns()
        onChange?()
    }

    /// The user went to this session from a card: none of its cards stay on the panel. Each leaves the way × would
    /// (a prompt stays pending in the menu bar, its terminal dialog now in front of them; news ends). Another
    /// "Action needed" from the session stays: it points somewhere else, which this click didn't visit.
    func wentTo(_ clicked: Item) {
        for item in items where item.sessionID == clicked.sessionID && item.visibility == .shown && sent[item.id] == nil
            && (item.id == clicked.id || !item.isAction) { close(item.id) }
    }

    /// Leaves without a decision; a still-waiting hook gets an empty reply so it exits and Claude carries on.
    func remove(_ id: String, animation: Animation = spring) {
        connections.removeValue(forKey: id)?.reply("")
        watchers.removeValue(forKey: id)?.cancel()
        shownAt[id] = nil
        kept.remove(id)
        guard items.contains(where: { $0.id == id }) else { return }
        withAnimation(animation) {
            items.removeAll { $0.id == id }
            drafts[id] = nil
            sent[id] = nil
            unseen.remove(id)
            replyable.remove(id)
            if expanded == id { expanded = ordered.first?.id }
        }
        syncCountdowns()
        onChange?()
        sweep()  // the card that left may be what kept an overdue one waiting (its draft made the panel engaged)
    }

    func remove(where match: (Item) -> Bool) {
        for item in items where match(item) && sent[item.id] == nil { remove(item.id) }
    }

    // A card that just appeared or opened under the pointer must not take the click meant for the window
    // behind it: answers are ignored for a moment after a card is shown.
    // Two conditions, because a card can sit under a pointer that is busy in the window behind it (seen live:
    // the panel overlaps VS Code's Claude Code sidebar and a click there approved a prompt):
    // the card has been on screen for armDelay, and the pointer came onto the panel at least dwell ago.
    static let armDelay: TimeInterval = 0.5
    static let dwell: TimeInterval = 0.3
    @ObservationIgnored var pointerEnteredAt: Date?
    func cardShown(_ id: String) { shownAt[id] = Date() }
    private func shownLongEnough(_ id: String, now: Date) -> Bool {
        now.timeIntervalSince(shownAt[id] ?? .distantPast) >= Self.armDelay
    }
    func armed(_ id: String, now: Date = Date()) -> Bool {
        guard shownLongEnough(id, now: now), let entered = pointerEnteredAt else { return false }
        return now.timeIntervalSince(entered) >= Self.dwell
    }

    private func log(_ id: String, decision: String, accepted: Bool, now: Date) {
        AuditLog.write(item: items.first { $0.id == id }, decision: decision, accepted: accepted,
                       shownFor: now.timeIntervalSince(shownAt[id] ?? now), pointerFor: pointerEnteredAt.map { now.timeIntervalSince($0) })
    }

    enum AfterPick { case stay, next, send }

    /// A click on one of a question card's options: records the pick and says what follows. A single-select pick
    /// that leaves every question answered is the answer itself and sends, as an approval's Yes does; one that leaves
    /// questions open moves on. Multi-select and typed answers keep Send: only the user knows when those are done.
    /// The click guard is read here, at the click: the send runs a moment later, and answer's own check then would
    /// count that pause towards the time a card must have been up. A pick too early to count stays marked, so the
    /// next pick or Send sends it, and is logged as ignored, as answer logs one: "never clicked" would be wrong.
    func pick(_ option: Int, of q: Question, in view: QuestionsView, on id: String, now: Date = Date()) -> AfterPick {
        let armed = self.armed(id, now: now)
        update(id) { d in
            var set = d.picks[q.id] ?? []
            if q.multiSelect {
                if set.contains(option) { set.remove(option) } else { set.insert(option) }
                d.picks[q.id] = set
            } else {
                d.picks[q.id] = [option]
                d.other[q.id] = ""
            }
        }
        guard !q.multiSelect else { return .stay }
        guard draft(id).complete(view.questions.count) else { return q.id < view.questions.count - 1 ? .next : .stay }
        guard armed else {
            log(id, decision: QuestionFormat.decision(view, answers: QuestionFormat.answers(view, draft(id))), accepted: false, now: now)
            return .stay
        }
        return .send
    }

    func expand(_ id: String) {
        withAnimation(spring) { expanded = id; unseen.remove(id) }
        syncCountdowns()
    }

    func toggleShowAll() {
        withAnimation(spring) { showAll.toggle() }
        syncCountdowns()
    }

    // MARK: Leaving by itself

    /// How long a card stays in view before it leaves by itself; nil = it never does. The menu bar sets this.
    /// A change starts every card in view afresh: a card that has sat there for minutes must not vanish the
    /// moment a short time is picked.
    @ObservationIgnored var stay: TimeInterval? = AutoDismiss.after {
        didSet {
            countdowns = [:]
            syncCountdowns()
        }
    }

    /// Brings the countdowns in line with what is in view. A card's time starts when it is drawn, not when it
    /// arrived: one held back while its session is in front, closed, or folded under "+N more" has no countdown,
    /// and gets a full one when it comes into view.
    private func syncCountdowns(now: Date = Date()) {
        guard let stay else {
            if !countdowns.isEmpty { countdowns = [:] }
            return
        }
        let counting = Set(onScreen.map(\.id)).subtracting(kept)
        for id in countdowns.keys where !counting.contains(id) { countdowns[id] = nil }
        for id in counting where countdowns[id] == nil {
            countdowns[id] = now
            // Wall clock, like the bar: a deadline in uptime stands still while the Mac sleeps, and the card
            // would sit there after waking with its bar already empty.
            DispatchQueue.main.asyncAfter(wallDeadline: .now() + stay) { [weak self] in self?.sweep() }
        }
    }

    /// The pointer came onto this card: its countdown is off for good, and it stays until dismissed by hand.
    func hovered(_ id: String) {
        guard countdowns[id] != nil else { return }
        kept.insert(id)
        withAnimation(spring) { countdowns[id] = nil }
    }

    /// Lets go of every card whose time is up. Called by each card's timer, and again when whatever held an
    /// overdue card back has ended (the pointer left the panel, a card was removed, or a second has passed).
    /// Nothing leaves while the user is engaged with the panel: a card vanishing would move the others under
    /// the pointer or the text being typed. A card holding an unsent answer, or showing its "Sent" line, is the
    /// user's own doing and keeps its place for good.
    func sweep(now: Date = Date()) {
        guard let stay else { return }
        guard !engaged else {
            // Not every end of being engaged calls back here: an answer typed and deleted again, or the open card
            // swapped from the menu bar, leaves no event behind. While an overdue card waits, look again shortly.
            if !sweepAgain, countdowns.values.contains(where: { now.timeIntervalSince($0) >= stay }) {
                sweepAgain = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.sweepAgain = false
                    self?.sweep()
                }
            }
            return
        }
        for (id, since) in countdowns where now.timeIntervalSince(since) >= stay {
            guard countdowns[id] != nil, let item = items.first(where: { $0.id == id }) else { continue }
            if sent[id] != nil || draft(id).hasInput {
                kept.insert(id)
                countdowns[id] = nil
                continue
            }
            let how = AutoDismiss.whenTimeIsUp(item.kind)
            // Nothing else records it: "where did that approval go" is answered from the log or not at all.
            AuditLog.note("AUTO \(how == .hide ? "hidden" : "dismissed") after \(Int(stay)) s: \(item.kind.label) session=\(item.sessionID) card=\(item.summary)")
            switch how {
            case .dismiss: remove(id, animation: AutoDismiss.fade)
            case .hide: hide(id, animation: AutoDismiss.fade)
            }
        }
    }
}

/// Cards that leave by themselves after a while. Off unless the user picks a time in the menu bar.
enum AutoDismiss {
    static let choices: [TimeInterval] = [10, 30, 60, 300]

    private static let key = "cards.dismissAfter"
    /// The chosen time in seconds; nil = Never, which is also what an unset or unknown value means.
    static var after: TimeInterval? {
        get {
            let seconds = UserDefaults.standard.double(forKey: key)
            return choices.contains(seconds) ? seconds : nil
        }
        set { UserDefaults.standard.set(newValue ?? 0, forKey: key) }
    }

    static func title(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "Never" }
        return seconds < 120 ? "After \(Int(seconds)) Seconds" : "After \(Int(seconds / 60)) Minutes"
    }

    enum TimeUp { case dismiss, hide }

    /// What a card does when its time is up. News (Done, Stopped) goes the way its Dismiss button sends it.
    /// Anything still waiting on the user is only hidden, as × hides a prompt: a prompt Claude is blocked on, and
    /// a skill's "Action needed" (the skill is watching for the user to do it). The hook keeps waiting and the
    /// item stays in the menu bar, because a timer must never answer for the user or drop something they
    /// haven't seen. This is the one place that rule lives.
    static func whenTimeIsUp(_ kind: Kind) -> TimeUp { kind.needsYou ? .hide : .dismiss }

    /// Slower than every other change on the panel, so a card leaving by itself is seen to leave.
    static let fade = Animation.easeOut(duration: 1.2)
}

let store = Store()
let spring = Animation.spring(response: 0.32, dampingFraction: 0.86)

/// Every answer given in the panel, accepted or ignored by the click guard, one line each. An approval tool
/// needs a trail: this is how a surprise "Allowed by PermissionRequest hook" gets explained.
enum AuditLog {
    static var path = NSHomeDirectory() + "/Library/Logs/beckon.log"  // tests point this at a temp file
    private static let formatter: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()

    static func write(item: Item?, decision: String, accepted: Bool, shownFor: TimeInterval, pointerFor: TimeInterval?) {
        let behavior = (try? JSONSerialization.jsonObject(with: Data(decision.utf8)) as? [String: Any])
            .flatMap { ($0["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any] }
        let applies = (behavior?["updatedPermissions"] as? [Any])?.count ?? 0
        // A reply to an idle session is free text, not a decision: log that it happened, not what was said.
        let what = behavior.map { "behavior=\($0["behavior"] as? String ?? "?")" + (applies > 0 ? "+\(applies) permission update(s)" : "") }
            ?? "reply(\(decision.count) chars)"
        let fields: [String] = [
            formatter.string(from: Date()),
            accepted ? "ACCEPTED" : "IGNORED(click guard)",
            what,
            "shown=\(Int(shownFor * 1000))ms",
            "pointer=" + (pointerFor.map { "\(Int($0 * 1000))ms" } ?? "never-entered"),
            "session=\(item?.sessionID ?? "?")",
            "card=\(item?.summary ?? "?")",
        ]
        append(fields.joined(separator: " "))
    }

    /// Anything else worth finding later in the same file, e.g. a tab script that failed.
    static func note(_ text: String) { append(formatter.string(from: Date()) + " " + text) }

    private static let lock = NSLock()
    /// The system log, for a line the file can't take: it needs no new descriptor, and the file can't be opened
    /// exactly when the descriptor table is full, which is what "SERVER accept failed" reports.
    private static let fallback = Logger(subsystem: "dev.wickend.beckon", category: "audit")

    /// One open, append, close per line. Only ever appends: falling back to createFile when the open failed replaced
    /// the whole trail with one line whenever the second try got a descriptor the first didn't. And write(2) returns
    /// an error where FileHandle.write raises an Objective-C exception, which a full disk turned into a crash.
    static func append(_ text: String, to file: String = path) {
        lock.lock(); defer { lock.unlock() }
        let line = text.replacingOccurrences(of: "\n", with: " ") + "\n"
        let fd = open(file, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            let code = errno
            fallback.error("beckon.log can't be opened (errno \(code)): \(line, privacy: .public)")
            return
        }
        defer { close(fd) }
        let bytes = Array(line.utf8)
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        if written != bytes.count {
            let code = errno
            fallback.error("beckon.log write failed (errno \(code)): \(line, privacy: .public)")
        }
    }
}

/// The sound a card makes when it comes onto the panel. Two slots, chosen in the menu bar's Sounds submenu: one
/// for cards that hold Claude up, one for a finished or failed turn (each may be None). Mute silences both
/// without forgetting the choices. All three survive a restart.
enum Chime {
    enum Slot: String, CaseIterable {
        case waiting, ended
        var title: String { self == .waiting ? "When Claude Waits for You" : "When a Turn Ends" }
        var fallback: String { self == .waiting ? "Glass" : "Tink" }
    }

    private static let mutedKey = "sounds.muted"
    static var muted: Bool {
        get { UserDefaults.standard.bool(forKey: mutedKey) }
        set { UserDefaults.standard.set(newValue, forKey: mutedKey) }
    }

    /// The sound's name, or "" for None.
    static func sound(_ slot: Slot) -> String {
        UserDefaults.standard.string(forKey: "sounds." + slot.rawValue) ?? slot.fallback
    }
    static func set(_ slot: Slot, to name: String) { UserDefaults.standard.set(name, forKey: "sounds." + slot.rawValue) }

    /// The sounds macOS ships, read from disk so the list matches this Mac's version of the OS.
    static let available: [String] = {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? []
        return files.filter { $0.hasSuffix(".aiff") }.map { String($0.dropLast(5)) }.sorted()
    }()

    static func play(for kind: Kind) {
        // The unit tests drive `arrive` dozens of times and would ring the real system sounds;
        // scripts/test.sh sets this so a test run is silent without muting the whole Mac.
        guard !muted, ProcessInfo.processInfo.environment["BECKON_SILENT"] == nil else { return }
        preview(sound(kind.needsYou ? .waiting : .ended))
    }

    static func preview(_ name: String) {
        guard !name.isEmpty else { return }
        NSSound(named: name)?.play()
    }
}
