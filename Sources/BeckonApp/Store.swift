import AppKit
import Foundation
import Observation
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
    case closed      // the user closed the card; Claude keeps waiting in the terminal
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
    var pointerInside = false
    var replyable: Set<String> = []    // Done cards whose Stop hook is still listening for a reply

    @ObservationIgnored private var shownAt: [String: Date] = [:]
    @ObservationIgnored private var connections: [String: Connection] = [:]
    @ObservationIgnored private var watchers: [String: DispatchSourceProcess] = [:]
    @ObservationIgnored var onChange: (() -> Void)?

    static let visibleRows = 4

    // Open card first (it never moves while you use it), then blocking items newest first, then updates.
    var ordered: [Item] {
        let shown = items.filter { $0.visibility == .shown }
        let head = shown.filter { $0.id == expanded }
        let rest = shown.filter { $0.id != expanded }
        return head + rest.filter { $0.kind.needsYou } + rest.filter { !$0.kind.needsYou }
    }

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
        AuditLog.write(item: items.first { $0.id == id }, decision: decision, accepted: ok,
                       shownFor: now.timeIntervalSince(shownAt[id] ?? now), pointerFor: pointerEnteredAt.map { now.timeIntervalSince($0) })
        guard ok else { return }
        connections.removeValue(forKey: id)?.reply(decision)
        withAnimation(spring) { sent[id] = confirmation }
        onChange?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { self.remove(id) }
    }

    /// The × button. A prompt Claude Code is also showing in the terminal stays pending in the menu bar;
    /// anything else has no other home, so closing it ends it.
    func close(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[i].kind.hasTerminalDialog else { remove(id); return }
        withAnimation(spring) {
            items[i].visibility = .closed
            unseen.remove(id)
            if expanded == id { expanded = ordered.first?.id }
        }
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
    func remove(_ id: String) {
        connections.removeValue(forKey: id)?.reply("")
        watchers.removeValue(forKey: id)?.cancel()
        shownAt[id] = nil
        guard items.contains(where: { $0.id == id }) else { return }
        withAnimation(spring) {
            items.removeAll { $0.id == id }
            drafts[id] = nil
            sent[id] = nil
            unseen.remove(id)
            replyable.remove(id)
            if expanded == id { expanded = ordered.first?.id }
        }
        onChange?()
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

    func expand(_ id: String) {
        withAnimation(spring) { expanded = id; unseen.remove(id) }
    }
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
    private static func append(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        let line = text.replacingOccurrences(of: "\n", with: " ") + "\n"
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { FileManager.default.createFile(atPath: path, contents: Data(line.utf8)) }
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
        guard !muted else { return }
        preview(sound(kind.needsYou ? .waiting : .ended))
    }

    static func preview(_ name: String) {
        guard !name.isEmpty else { return }
        NSSound(named: name)?.play()
    }
}
