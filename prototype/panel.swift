// Look-and-feel prototype for the beckon panel. Not product code: no IPC; a menu bar item fakes arrivals.
// Sample data mirrors real Claude Code hook payloads: PermissionRequest (tool_input.description,
// permission_suggestions), AskUserQuestion (1–4 questions, header, options with description/preview,
// multiSelect), ExitPlanMode (plan markdown), Stop / StopFailure, plus skill-sent "action needed" items.
// Build: swiftc -O prototype/panel.swift -o prototype/proto && prototype/proto
// Env: BECKON_FPS=1 runs a scripted sequence, prints frame stats, exits.
//      BECKON_IDLE=1 (with FPS) measures the machine's noise floor with nothing animating.
//      BECKON_STATIC=1 shows all samples at once; BECKON_EXPAND=<id> picks the open card.
// Performance rule: smoothness at the display's refresh rate comes first. No effect stays in if it drops
// frames above the idle noise floor (shadows were removed for that reason).
import AppKit
import Observation
import SwiftUI

// MARK: - Model

struct PermOption: Identifiable {
    enum Action { case allow, always, deny }
    let id: Int
    let label: String
    let detail: String
    let action: Action
}

struct Permission { let headline: String; let body: String; let diff: [String]; let options: [PermOption] }
struct QOption: Identifiable { let id: Int; let label: String; let description: String; let preview: String? }
struct Question: Identifiable { let id: Int; let header: String; let question: String; let multiSelect: Bool; let options: [QOption] }
struct Plan { let title: String; let markdown: String }
struct Action { let title: String; let steps: [String]; let targetApp: String; let targetBundle: String; let target: String }
struct Done { let headline: String; let summary: String }
struct Failure { let headline: String; let error: String }

enum Kind {
    case permission(Permission), questions([Question]), plan(Plan), action(Action), done(Done), failed(Failure)

    // Items that block Claude sort above updates and get the accent colour.
    var needsYou: Bool {
        switch self {
        case .permission, .questions, .plan, .action: return true
        case .done, .failed: return false
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

struct Item: Identifiable {
    var id: String
    let sessionID: String
    let bundleID: String
    let app: String
    let project: String
    let session: String
    var waiting: String
    let context: String
    let kind: Kind

    var summary: String {
        switch kind {
        case .permission(let p): return p.headline
        case .questions(let qs): return qs.count == 1 ? qs[0].question : "\(qs.count) questions"
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
}

let sampleItems: [Item] = [
    Item(id: "ask", sessionID: "s-beckon", bundleID: "com.mitchellh.ghostty", app: "Ghostty", project: "beckon",
         session: "Scaffold the beckon app", waiting: "now",
         context: "The signing spike is done: a stable self-signed identity unlocks notifications, ad-hoc builds are refused. Before I scaffold the app and CLI I need three decisions. My recommendation is first in each list.",
         kind: .questions([
            Question(id: 0, header: "Language", question: "Which language should the CLI use?", multiSelect: false, options: [
                QOption(id: 0, label: "Swift", description: "One toolchain with the app; 3.1 ms cold start", preview: nil),
                QOption(id: 1, label: "Rust", description: "2.5 ms cold start; second toolchain", preview: nil),
                QOption(id: 2, label: "Go", description: "Fast builds; larger binary", preview: nil)]),
            Question(id: 1, header: "Targets", question: "Which terminals should the MVP focus?", multiSelect: true, options: [
                QOption(id: 0, label: "VS Code", description: "Exact terminal across windows", preview: nil),
                QOption(id: 1, label: "Ghostty", description: "AppleScript by tty", preview: nil),
                QOption(id: 2, label: "Terminal.app", description: "AppleScript by tty", preview: nil),
                QOption(id: 3, label: "iTerm2", description: "Not installed here", preview: nil)]),
            Question(id: 2, header: "Install", question: "How should other people install it?", multiSelect: false, options: [
                QOption(id: 0, label: "Homebrew cask", description: "Own tap", preview: "brew install --cask wickes1/tap/beckon\nbeckon doctor"),
                QOption(id: 1, label: "Claude Code plugin", description: "Hooks wired automatically", preview: "/plugin install beckon\n# app still installed via cask"),
                QOption(id: 2, label: "Manual download", description: "DMG from GitHub releases", preview: nil)]),
         ])),
    Item(id: "login", sessionID: "s-bank", bundleID: "com.brave.Browser", app: "Brave", project: "household",
         session: "Pay the card bill", waiting: "waiting 1m",
         context: "Opened Example Bank in Brave to pay the card statement. I'll carry on by myself as soon as the page leaves the login screen.",
         kind: .action(Action(title: "Log in to Example Bank",
                              steps: ["Sign in with your password", "Tick “Remember this device”", "Leave the tab open — Claude continues on its own"],
                              targetApp: "Brave", targetBundle: "com.brave.Browser", target: "bank.example.com/login"))),
    Item(id: "perm", sessionID: "s-notify", bundleID: "com.microsoft.VSCode", app: "VS Code", project: "beckon",
         session: "Claude Code notification opens wrong app", waiting: "waiting 3m",
         context: "Committed the panel prototype. Pushing so the review agent can read it from GitHub.",
         kind: .permission(Permission(
            headline: "Push main to GitHub", body: "git push origin main", diff: [],
            options: [
                PermOption(id: 0, label: "Yes", detail: "", action: .allow),
                PermOption(id: 1, label: "Yes, and don't ask again", detail: "Bash(git push:*) in this project", action: .always),
                PermOption(id: 2, label: "No, and tell Claude what to do instead", detail: "", action: .deny)]))),
    Item(id: "plan", sessionID: "s-scraper", bundleID: "com.microsoft.VSCode", app: "VS Code", project: "listings",
         session: "Refresh listing scraper", waiting: "waiting 8m",
         context: "I've read the scraper and the failing runs. Here is the plan; nothing has been changed yet.",
         kind: .plan(Plan(title: "Fix the API token refresh", markdown: """
            1. Move token fetch into `auth.py` with a 50-minute cache
            2. Retry once on 401, then fail loud with the response body
            3. Add a test that replays a recorded 401 → 200 sequence
            4. Run the nightly refresh by hand and compare counts
            5. Update docs/README.md with the new failure mode
            6. Remove the old `token.txt` fallback once the test passes
            """))),
    Item(id: "done", sessionID: "s-docs", bundleID: "com.mitchellh.ghostty", app: "Ghostty", project: "docs",
         session: "VLAN explainer", waiting: "done 20m", context: "",
         kind: .done(Done(headline: "VLAN explainer is ready to read",
                          summary: "Wrote the VLAN explainer with an interactive switch simulator: drag a port between VLAN 10 and 20 and watch which frames reach which device. Added the router config as a code + log pair, a trunk vs access comparison table, and a Feynman-style summary at the end. Built dist/ and checked it renders in Brave at 3 widths. Not published yet — say the word and I'll push it."))),
    Item(id: "fail", sessionID: "s-stickers", bundleID: "com.microsoft.VSCode", app: "VS Code", project: "stickers",
         session: "Sticker export", waiting: "6m ago", context: "",
         kind: .failed(Failure(headline: "Claude stopped: API overloaded", error: "API Error 529 · overloaded_error — the request was not completed. Nothing was half-written."))),
]

// MARK: - Store: what is shown, in which order, and what happens when something new arrives

@Observable
final class Store {
    var items: [Item] = []
    var expanded: String?
    var drafts: [String: Draft] = [:]
    var sent: [String: String] = [:]       // id → confirmation text, shown briefly before the card leaves
    var unseen: Set<String> = []           // arrived while the user was busy with another card
    var showAll = false
    var pointerInside = false              // set by the window's click-through tracker
    private var serial = 0

    static let visibleRows = 4

    // Expanded card first (it never moves while you use it), then anything that blocks Claude
    // newest first, then updates newest first.
    var ordered: [Item] {
        let rest = items.filter { $0.id != expanded }
        let head = items.filter { $0.id == expanded }
        return head + rest.filter { $0.kind.needsYou } + rest.filter { !$0.kind.needsYou }
    }

    // The user is "engaged" with the open card if the pointer is on the panel or they have started answering.
    var engaged: Bool { pointerInside || (expanded.flatMap { drafts[$0]?.hasInput } ?? false) }

    func draft(_ id: String) -> Draft { drafts[id] ?? Draft() }
    func update(_ id: String, _ change: (inout Draft) -> Void) {
        var d = drafts[id] ?? Draft()
        change(&d)
        drafts[id] = d
    }

    // Arrival rules:
    // 1. A new update (Done / Stopped) from a session replaces that session's previous update.
    // 2. Nothing open → the new item opens.
    // 3. Open card is an update and the new item blocks Claude → the new item opens, unless the user is engaged.
    // 4. Otherwise the new item joins the list collapsed and marked unseen; the open card never moves or closes under you.
    func arrive(_ template: Item) {
        serial += 1
        var item = template
        item.id = "\(template.id)-\(serial)"
        item.waiting = "now"
        withAnimation(spring) {
            if !item.kind.needsYou {
                items.removeAll { $0.sessionID == item.sessionID && !$0.kind.needsYou && $0.id != expanded }
            }
            items.insert(item, at: 0)
            let open = items.first { $0.id == expanded }
            if open == nil {
                expanded = item.id
            } else if let open, !open.kind.needsYou, item.kind.needsYou, !engaged {
                expanded = item.id
            } else {
                unseen.insert(item.id)
            }
        }
    }

    // Answered in the panel: show the confirmation, then leave.
    func answer(_ id: String, _ text: String) {
        withAnimation(spring) { sent[id] = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { self.remove(id) }
    }

    // Answered in the terminal (real app: PostToolUse / UserPromptSubmit for that session): just leave.
    func resolvedElsewhere(_ id: String) { remove(id) }

    func remove(_ id: String) {
        withAnimation(spring) {
            items.removeAll { $0.id == id }
            drafts[id] = nil
            sent[id] = nil
            unseen.remove(id)
            if expanded == id { expanded = ordered.first?.id }
        }
    }

    func expand(_ id: String) {
        withAnimation(spring) {
            expanded = id
            unseen.remove(id)
        }
    }
}

let store = Store()

// MARK: - Look

let accent = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)  // Claude terracotta, the only accent
let spring = Animation.spring(response: 0.32, dampingFraction: 0.86)

// Cached: SwiftUI re-evaluates bodies on every animation frame, and a LaunchServices lookup per frame stutters.
var iconCache: [String: NSImage] = [:]
func appIcon(_ bundleID: String) -> NSImage {
    if let hit = iconCache[bundleID] { return hit }
    let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage()
    iconCache[bundleID] = icon
    return icon
}

// Parsed once per plan: re-parsing Markdown on every frame cost ~30 ms on first show.
var planCache: [String: AttributedString] = [:]
func planText(_ md: String) -> AttributedString {
    if let hit = planCache[md] { return hit }
    let parsed = (try? AttributedString(markdown: md, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(md)
    planCache[md] = parsed
    return parsed
}

func kindColor(_ k: Kind) -> Color {
    switch k {
    case .done: return Color.green.opacity(0.85)
    case .failed: return Color.orange.opacity(0.9)
    default: return accent
    }
}

extension View {
    // No shadow: a SwiftUI shadow over blurred material re-renders the card offscreen every frame
    // and was the largest single source of dropped frames.
    func glassCard(radius: CGFloat = 18) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(.white.opacity(0.14)))
    }
}

struct BarButtonStyle: ButtonStyle {
    let primary: Bool
    let enabled: Bool
    let wide: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: primary ? .semibold : .medium))
            .foregroundStyle(primary && enabled ? Color.white : (enabled ? Color.primary : Color.secondary))
            .padding(.horizontal, 14).padding(.vertical, 6)
            .frame(maxWidth: wide ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: 8).fill(
                primary && enabled ? AnyShapeStyle(accent.opacity(configuration.isPressed ? 0.8 : 1))
                                   : AnyShapeStyle(Color.white.opacity(configuration.isPressed ? 0.12 : (primary ? 0.06 : 0.08)))))
    }
}

struct RowBackground: ViewModifier {
    let selected: Bool
    let hovered: Bool
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(selected ? 0.12 : (hovered ? 0.06 : 0))))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(accent.opacity(selected ? 0.55 : 0), lineWidth: 1))
            .contentShape(Rectangle())
    }
}

struct Radio: View {
    let on: Bool
    let square: Bool
    var body: some View {
        ZStack {
            if square {
                RoundedRectangle(cornerRadius: 4).strokeBorder(on ? accent : Color.secondary.opacity(0.6), lineWidth: 1.5)
                if on { Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(accent) }
            } else {
                Circle().strokeBorder(on ? accent : Color.secondary.opacity(0.6), lineWidth: 1.5)
                if on { Circle().fill(accent).padding(4) }
            }
        }
        .frame(width: 15, height: 15)
    }
}

// Long text scrolls at a fixed height. Whether it needs to is estimated from the string, not measured:
// measuring with GeometryReader re-ran layout on every animation frame.
func estimatedLines(_ text: String, charsPerLine: Int = 56) -> Int {
    text.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { $0 + max(1, ($1.count + charsPerLine - 1) / charsPerLine) }
}

struct Capped<Content: View>: View {
    let lines: Int
    let maxLines: Int
    let lineHeight: CGFloat
    @ViewBuilder let content: Content
    var body: some View {
        if lines > maxLines {
            ScrollView(.vertical) { content.frame(maxWidth: .infinity, alignment: .leading) }
                .frame(height: CGFloat(maxLines) * lineHeight)
        } else {
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - The card skeleton. Every kind fills the same slots in the same order:
// Header · Title · Context · Detail · Options · Action bar. A kind may leave a slot out; none adds its own.

struct Header: View {
    let item: Item
    @State private var hover = false
    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: appIcon(item.bundleID)).resizable().frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text("\u{2733}").font(.system(size: 11, weight: .bold)).foregroundStyle(accent)
                    Text(item.session).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                }
                Text("\(item.project) · \(item.app)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if hover {
                Image(systemName: "arrow.up.forward").font(.system(size: 11, weight: .semibold)).foregroundStyle(accent)
            } else {
                Text(item.waiting).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(hover ? 0.08 : 0)))
        .padding(-6)
        .contentShape(Rectangle())
        .help("Go to \(item.app): \(item.session)")
        .onHover { h in
            hover = h
            if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onTapGesture { }
    }
}

struct TitleRow: View {
    let kind: Kind
    let title: String
    var trailing: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: kind.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(kindColor(kind))
                .help(kind.label)
            Text(title).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let trailing { Text(trailing).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
    }
}

struct ContextLine: View {
    let text: String
    @State private var open = false
    var body: some View {
        Group {
            if open {
                Capped(lines: estimatedLines(text, charsPerLine: 60), maxLines: 7, lineHeight: 15.5) {
                    Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(spring) { open.toggle() } }
        .help(open ? "Show less" : "Show more")
    }
}

struct DetailBox<Content: View>: View {
    let lines: Int
    var maxLines = 7
    var lineHeight: CGFloat = 16
    @ViewBuilder let content: Content
    var body: some View {
        Capped(lines: lines, maxLines: maxLines, lineHeight: lineHeight) { content }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.25)))
    }
}

struct Mono: View {
    let text: String
    var color: Color = .primary
    var body: some View { Text(text).font(.system(size: 12, design: .monospaced)).foregroundStyle(color) }
}

struct OptionRow<Lead: View, Trail: View>: View {
    let label: String
    var detail: String = ""
    var selected = false
    let action: () -> Void
    @ViewBuilder let lead: Lead
    @ViewBuilder let trail: Trail
    @State private var hover = false
    var body: some View {
        HStack(spacing: 10) {
            lead.frame(width: 15)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 13, weight: .medium))
                if !detail.isEmpty { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            Spacer()
            trail
        }
        .modifier(RowBackground(selected: selected, hovered: hover))
        .onHover { hover = $0 }
        .onTapGesture(perform: action)
    }
}

extension OptionRow where Trail == EmptyView {
    init(label: String, detail: String = "", selected: Bool = false, action: @escaping () -> Void, @ViewBuilder lead: () -> Lead) {
        self.init(label: label, detail: detail, selected: selected, action: action, lead: lead, trail: { EmptyView() })
    }
}

struct IconMark: View {
    let symbol: String
    var body: some View { Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary) }
}

struct BarButton: Identifiable {
    let id: String
    var icon: NSImage? = nil
    var primary = false
    var enabled = true
    let action: () -> Void
    init(_ label: String, icon: NSImage? = nil, primary: Bool = false, enabled: Bool = true, action: @escaping () -> Void) {
        self.id = label; self.icon = icon; self.primary = primary; self.enabled = enabled; self.action = action
    }
}

// The last row of every card. With a text field: field + its button. Without: buttons share the row evenly.
struct ActionBar: View {
    var placeholder: String? = nil
    var text: Binding<String>? = nil
    var focused: FocusState<Bool>.Binding? = nil
    let buttons: [BarButton]
    var body: some View {
        HStack(spacing: 6) {
            if let placeholder, let text {
                Group {
                    if let focused { TextField(placeholder, text: text).focused(focused) } else { TextField(placeholder, text: text) }
                }
                .textFieldStyle(.plain).font(.system(size: 13))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06)))
                .onSubmit { if let b = buttons.last, b.enabled { b.action() } }
            }
            ForEach(buttons) { b in
                Button(action: b.action) {
                    HStack(spacing: 6) {
                        if let icon = b.icon { Image(nsImage: icon).resizable().frame(width: 15, height: 15) }
                        Text(b.id)
                    }
                }
                .buttonStyle(BarButtonStyle(primary: b.primary, enabled: b.enabled, wide: placeholder == nil))
                .disabled(!b.enabled)
            }
        }
    }
}

struct CloseButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(.regularMaterial))
                .overlay(Circle().strokeBorder(.white.opacity(0.15)))
        }
        .buttonStyle(.plain).help("Close")
        .offset(x: -7, y: -7)
    }
}

struct Sent: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(accent)
            Text(text).font(.system(size: 13, weight: .medium))
            Spacer()
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Kind contents (each one only fills skeleton slots)

struct PermissionContent: View {
    let item: Item
    let p: Permission
    @FocusState private var replyFocused: Bool
    var body: some View {
        let id = item.id
        TitleRow(kind: item.kind, title: p.headline)
        if !item.context.isEmpty { ContextLine(text: item.context) }
        DetailBox(lines: estimatedLines(p.body, charsPerLine: 48) + p.diff.count) {
            VStack(alignment: .leading, spacing: 2) {
                Mono(text: p.body)
                ForEach(p.diff, id: \.self) { Mono(text: $0, color: $0.hasPrefix("+") ? .green.opacity(0.9) : .red.opacity(0.85)) }
            }
        }
        VStack(spacing: 4) {
            ForEach(p.options) { o in
                OptionRow(label: o.label, detail: o.detail, action: {
                    switch o.action {
                    case .allow: store.answer(id, "Allowed")
                    case .always: store.answer(id, "Allowed — won't ask again")
                    case .deny: replyFocused = true
                    }
                }) { IconMark(symbol: o.action == .deny ? "xmark" : (o.action == .always ? "checkmark.seal" : "checkmark")) }
            }
        }
        ActionBar(placeholder: "Tell Claude what to do instead…",
                  text: Binding(get: { store.draft(id).reply }, set: { v in store.update(id) { $0.reply = v } }),
                  focused: $replyFocused,
                  buttons: [BarButton("Deny", primary: true, enabled: !store.draft(id).reply.isEmpty) { store.answer(id, "Denied — told Claude") }])
    }
}

struct QuestionsContent: View {
    let item: Item
    let qs: [Question]

    var body: some View {
        let id = item.id
        let d = store.draft(id)
        let current = min(d.current, qs.count - 1)
        let q = qs[current]
        let isLast = current == qs.count - 1
        let answered: (Int) -> Bool = { i in !(d.picks[i] ?? []).isEmpty || !(d.other[i] ?? "").isEmpty }
        let all = qs.indices.allSatisfy(answered)

        TitleRow(kind: item.kind, title: q.question, trailing: qs.count > 1 ? "\(current + 1) of \(qs.count)" : nil)
        if !item.context.isEmpty { ContextLine(text: item.context) }
        if qs.count > 1 {
            HStack(spacing: 6) {
                ForEach(qs) { qq in
                    let on = qq.id == current
                    HStack(spacing: 4) {
                        if answered(qq.id) { Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(accent) }
                        Text(qq.header).font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(.white.opacity(on ? 0.14 : 0.05)))
                    .overlay(Capsule().strokeBorder(.white.opacity(on ? 0.2 : 0)))
                    .foregroundStyle(on ? .primary : .secondary)
                    .contentShape(Capsule())
                    .onTapGesture { go(id, qq.id) }
                }
                Spacer()
                if q.multiSelect { Text("Select all that apply").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
        }
        VStack(spacing: 4) {
            ForEach(q.options) { o in
                let on = d.picks[q.id]?.contains(o.id) ?? false
                VStack(spacing: 6) {
                    OptionRow(label: o.label, detail: o.description, selected: on, action: { pick(id, o, q, isLast: isLast) }) {
                        Radio(on: on, square: q.multiSelect)
                    } trail: {
                        if o.preview != nil {
                            Image(systemName: d.previewOpen == o.id ? "eye.fill" : "eye")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .frame(width: 22, height: 22).contentShape(Rectangle())
                                .onTapGesture { withAnimation(spring) { store.update(id) { $0.previewOpen = $0.previewOpen == o.id ? nil : o.id } } }
                                .help("Preview")
                        }
                    }
                    if let pv = o.preview, d.previewOpen == o.id {
                        DetailBox(lines: estimatedLines(pv, charsPerLine: 44)) { Mono(text: pv) }.padding(.leading, 35)
                    }
                }
            }
        }
        .id("options\(current)")
        .transition(.opacity)
        ActionBar(placeholder: q.multiSelect ? "Something else…" : "Other…",
                  text: Binding(get: { store.draft(id).other[current] ?? "" },
                                set: { v in store.update(id) { $0.other[current] = v; if !v.isEmpty && !q.multiSelect { $0.picks[current] = [] } } }),
                  buttons: [BarButton(isLast ? "Send" : "Next", primary: true, enabled: isLast ? all : answered(current)) {
                      if isLast { store.answer(id, qs.count == 1 ? "Answered — sent to Claude" : "All \(qs.count) answered — sent to Claude") } else { go(id, current + 1) }
                  }])
    }

    func go(_ id: String, _ i: Int) { withAnimation(spring) { store.update(id) { $0.current = i; $0.previewOpen = nil } } }

    func pick(_ id: String, _ o: QOption, _ q: Question, isLast: Bool) {
        store.update(id) { d in
            var set = d.picks[q.id] ?? []
            if q.multiSelect {
                if set.contains(o.id) { set.remove(o.id) } else { set.insert(o.id) }
                d.picks[q.id] = set
            } else {
                d.picks[q.id] = [o.id]
                d.other[q.id] = ""
            }
        }
        // Short pause so the pick registers before the next question replaces it.
        if !q.multiSelect && !isLast { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { go(id, q.id + 1) } }
    }
}

struct PlanContent: View {
    let item: Item
    let p: Plan
    @FocusState private var replyFocused: Bool
    var body: some View {
        let id = item.id
        TitleRow(kind: item.kind, title: p.title)
        if !item.context.isEmpty { ContextLine(text: item.context) }
        DetailBox(lines: estimatedLines(p.markdown, charsPerLine: 58), maxLines: 8, lineHeight: 18) {
            Text(planText(p.markdown)).font(.system(size: 12)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
        VStack(spacing: 4) {
            OptionRow(label: "Approve", detail: "Auto-accept edits", action: { store.answer(id, "Plan approved") }) { IconMark(symbol: "checkmark.seal") }
            OptionRow(label: "Approve", detail: "Review each edit", action: { store.answer(id, "Plan approved") }) { IconMark(symbol: "checkmark") }
            OptionRow(label: "Keep planning", detail: "Tell Claude what to change below", action: { replyFocused = true }) { IconMark(symbol: "arrow.uturn.backward") }
        }
        ActionBar(placeholder: "What should change in the plan…",
                  text: Binding(get: { store.draft(id).reply }, set: { v in store.update(id) { $0.reply = v } }),
                  focused: $replyFocused,
                  buttons: [BarButton("Send", primary: true, enabled: !store.draft(id).reply.isEmpty) { store.answer(id, "Sent back to planning") }])
    }
}

struct ActionContent: View {
    let item: Item
    let a: Action
    var body: some View {
        TitleRow(kind: item.kind, title: a.title)
        if !item.context.isEmpty { ContextLine(text: item.context) }
        DetailBox(lines: a.steps.count + 1) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(a.steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(i + 1)").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
                            .frame(width: 16, height: 16).background(Circle().fill(.white.opacity(0.1)))
                        Text(step).font(.system(size: 12.5))
                    }
                }
                Mono(text: a.target, color: .secondary).padding(.top, 2)
            }
        }
        ActionBar(buttons: [
            BarButton("I've done it") { store.answer(item.id, "Told Claude you're done") },
            BarButton("Open in \(a.targetApp)", icon: appIcon(a.targetBundle), primary: true) { },
        ])
    }
}

struct DoneContent: View {
    let item: Item
    let d: Done
    var body: some View {
        TitleRow(kind: item.kind, title: d.headline)
        ContextLine(text: d.summary)
        ActionBar(buttons: [
            BarButton("Dismiss") { store.remove(item.id) },
            BarButton("Open in \(item.app)", icon: appIcon(item.bundleID), primary: true) { },
        ])
    }
}

struct FailedContent: View {
    let item: Item
    let f: Failure
    var body: some View {
        TitleRow(kind: item.kind, title: f.headline)
        if !item.context.isEmpty { ContextLine(text: item.context) }
        DetailBox(lines: estimatedLines(f.error, charsPerLine: 48)) { Mono(text: f.error, color: .secondary) }
        ActionBar(buttons: [
            BarButton("Open in \(item.app)", icon: appIcon(item.bundleID)) { },
            BarButton("Retry", primary: true) { store.answer(item.id, "Asked Claude to retry") },
        ])
    }
}

// MARK: - Cards

struct ExpandedCard: View {
    let item: Item
    @State private var hover = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Header(item: item)
            if let sent = store.sent[item.id] {
                Sent(text: sent).transition(.opacity)
            } else {
                switch item.kind {
                case .permission(let p): PermissionContent(item: item, p: p)
                case .questions(let qs): QuestionsContent(item: item, qs: qs)
                case .plan(let p): PlanContent(item: item, p: p)
                case .action(let a): ActionContent(item: item, a: a)
                case .done(let d): DoneContent(item: item, d: d)
                case .failed(let f): FailedContent(item: item, f: f)
                }
            }
        }
        .padding(16)
        .overlay(alignment: .topLeading) { if hover { CloseButton { store.remove(item.id) } } }
        .onHover { hover = $0 }
    }
}

struct CollapsedCard: View {
    let item: Item
    @State private var hover = false
    var body: some View {
        let isNew = store.unseen.contains(item.id)
        HStack(spacing: 8) {
            Image(nsImage: appIcon(item.bundleID)).resizable().frame(width: 18, height: 18)
            Image(systemName: item.kind.symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(kindColor(item.kind))
            Text(item.summary).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Text(item.session).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 6)
            if isNew { Circle().fill(accent).frame(width: 6, height: 6).help("New") }
            Text(item.waiting).font(.system(size: 11)).foregroundStyle(isNew ? accent : .secondary).fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(hover ? 0.05 : 0)))
        .opacity(item.kind.needsYou ? 1 : 0.85)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { store.expand(item.id) }
        .help("\(item.kind.label): \(item.summary)")
    }
}

// One shell per item for its whole life: collapsing / expanding swaps only the content, so the blurred
// material view underneath is kept instead of being torn down and rebuilt (a frame drop per switch).
struct CardShell: View {
    let item: Item
    let open: Bool
    var body: some View {
        Group {
            if open { ExpandedCard(item: item) } else { CollapsedCard(item: item) }
        }
        .frame(width: 400, alignment: .topLeading)
        .glassCard(radius: open ? 18 : 14)
    }
}

// MARK: - Stack

struct CardFrames: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

func reportFrame() -> some View {
    GeometryReader { g in Color.clear.preference(key: CardFrames.self, value: [g.frame(in: .global)]) }
}

struct StackView: View {
    let onFrames: ([CGRect]) -> Void
    var body: some View {
        let list = store.ordered
        let shown = store.showAll ? list : Array(list.prefix(Store.visibleRows + 1))  // open card + 4 rows
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(shown) { item in
                CardShell(item: item, open: item.id == store.expanded)
                .background(reportFrame())
                .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
            }
            if list.count > shown.count || store.showAll && list.count > Store.visibleRows + 1 {
                Text(store.showAll ? "Show less" : "+\(list.count - shown.count) more")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
                    .contentShape(Capsule())
                    .onTapGesture { withAnimation(spring) { store.showAll.toggle() } }
                    .background(reportFrame())
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .environment(\.colorScheme, .dark)
        .onPreferenceChange(CardFrames.self, perform: onFrames)
    }
}

// MARK: - Demo driver: menu bar item to fake arrivals, plus the scripted FPS run

final class Demo: NSObject {
    var statusItem: NSStatusItem!

    func install() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "\u{2733}"
        let menu = NSMenu()
        for t in sampleItems {
            let mi = NSMenuItem(title: "New \(t.kind.label.lowercased()) · \(t.session)", action: #selector(newItem(_:)), keyEquivalent: "")
            mi.target = self; mi.representedObject = t.id
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        for (title, sel) in [("Answer open card in the terminal", #selector(resolveOpen)), ("Clear all", #selector(clearAll))] {
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: ""); mi.target = self; menu.addItem(mi)
        }
        statusItem.menu = menu
    }

    @objc func newItem(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String, let t = sampleItems.first(where: { $0.id == id }) { store.arrive(t) }
    }
    @objc func resolveOpen() { if let id = store.expanded { store.resolvedElsewhere(id) } }
    @objc func clearAll() { for i in store.items { store.remove(i.id) } }

    func startupArrivals(staticAll: Bool, expand: String?) {
        if staticAll {
            for t in sampleItems.reversed() { store.arrive(t) }
            if let expand, let hit = store.items.first(where: { $0.id.hasPrefix(expand + "-") }) { store.expand(hit.id) }
            return
        }
        for (i, t) in sampleItems.reversed().enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 + Double(i) * 0.18) { store.arrive(t) }
        }
    }

    // Scripted: arrivals, then expand switches, then a new arrival while engaged, then a terminal answer.
    func scripted() {
        startupArrivals(staticAll: false, expand: nil)
        for (i, prefix) in ["perm", "plan", "login", "ask"].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0 + Double(i) * 0.6) {
                if let hit = store.items.first(where: { $0.id.hasPrefix(prefix + "-") }) { store.expand(hit.id) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.4) { store.pointerInside = true; store.arrive(sampleItems[2]) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.9) { store.pointerInside = false; if let id = store.expanded { store.resolvedElsewhere(id) } }
    }
}

// BECKON_FPS=1: records frame intervals, prints a summary, exits. A main-thread hitch shows up as a long gap
// between display-link callbacks.
final class FrameProbe: NSObject {
    var stamps: [CFTimeInterval] = []
    var link: CADisplayLink?
    func start(on view: NSView, seconds: Double) {
        link = view.displayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { self.report() }
    }
    @objc func tick(_ l: CADisplayLink) { stamps.append(l.timestamp) }
    func report() {
        link?.invalidate()
        let pairs = zip(stamps.dropFirst(), stamps).map { ($1, ($0 - $1) * 1000) }
        let d = pairs.map(\.1).sorted()
        guard !d.isEmpty, let t0 = stamps.first else { print("no frames"); exit(1) }
        let median = d[d.count / 2]
        let slow = pairs.filter { $0.1 > median * 1.5 }
        print("slow at: " + slow.map { String(format: "%.2fs(%.0fms)", $0.0 - t0, $0.1) }.joined(separator: " "))
        print(String(format: "frames=%d median=%.1fms p95=%.1fms max=%.1fms dropped(>1.5x)=%d (%.1f%%)",
                     d.count, median, d[Int(Double(d.count) * 0.95)], d.last!, slow.count, 100 * Double(slow.count) / Double(d.count)))
        exit(0)
    }
}

// MARK: - Window

// The panel must never take keystrokes the user is typing elsewhere: it may become key only
// after a click inside it, and gives that up as soon as focus moves to another window.
final class KeyPanel: NSPanel {
    private var clickedIn = false
    override var canBecomeKey: Bool { clickedIn }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown && !clickedIn {
            clickedIn = true
            makeKey()
        }
        super.sendEvent(event)
    }
    override func resignKey() {
        super.resignKey()
        clickedIn = false
    }
}

let demo = Demo()
let probe = FrameProbe()

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: KeyPanel!
    var cardFrames: [CGRect] = []

    // A tall fixed transparent column, so cards animate without window resizes.
    // Clicks pass through everywhere except over a card.
    func updateClickThrough() {
        guard let content = panel.contentView else { return }
        let p = panel.mouseLocationOutsideOfEventStream
        let flipped = CGPoint(x: p.x, y: content.bounds.height - p.y)
        let over = cardFrames.contains { $0.insetBy(dx: -10, dy: -10).contains(flipped) }
        if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }
        if store.pointerInside != over && ProcessInfo.processInfo.environment["BECKON_FPS"] != "1" { store.pointerInside = over }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        let env = ProcessInfo.processInfo.environment
        let screen = NSScreen.main!.visibleFrame
        let width: CGFloat = 424
        panel = KeyPanel(contentRect: NSRect(x: screen.maxX - width, y: screen.minY, width: width, height: screen.height),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = NSHostingView(rootView: StackView { [weak self] frames in
            self?.cardFrames = frames
            self?.updateClickThrough()
        })
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in self?.updateClickThrough() }
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] e in self?.updateClickThrough(); return e }
        demo.install()

        if env["BECKON_FPS"] == "1", let v = panel.contentView {
            if env["BECKON_IDLE"] == "1" { demo.startupArrivals(staticAll: true, expand: nil) } else { demo.scripted() }
            probe.start(on: v, seconds: 5.6)
        } else {
            demo.startupArrivals(staticAll: env["BECKON_STATIC"] == "1", expand: env["BECKON_EXPAND"])
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
