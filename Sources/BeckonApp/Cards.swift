import AppKit
import SwiftUI

// The panel's look, ported from prototype/panel.swift (the design reference).
// Smoothness first: no shadows, cached icons, no per-frame measuring, one glass shell per card.

let accent = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)  // Claude terracotta, the only accent

// Cached: SwiftUI re-evaluates bodies on every animation frame, and a LaunchServices lookup per frame stutters.
private var iconCache: [String: NSImage] = [:]
func appIcon(_ bundleID: String?) -> NSImage {
    guard let bundleID else { return NSImage(systemSymbolName: "terminal", accessibilityDescription: nil) ?? NSImage() }
    if let hit = iconCache[bundleID] { return hit }
    let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage()
    iconCache[bundleID] = icon
    return icon
}

// Parsed once per plan: re-parsing Markdown on every frame cost ~30 ms on first show.
private var planCache: [String: AttributedString] = [:]
func planText(_ md: String) -> AttributedString {
    if let hit = planCache[md] { return hit }
    var parsed = (try? AttributedString(markdown: md, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(md)
    // A Markdown link shows its text, not its target, and a click on it opens whatever the plan's author put
    // there. Web links stay; any other target (a file, another app's URL scheme) is left as plain text.
    for range in parsed.runs.filter({ $0.link.map { !$0.isWeb } ?? false }).map(\.range) { parsed[range].link = nil }
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

// A prompt has been waiting that long; news simply happened that long ago.
func age(_ item: Item, _ now: Date) -> String {
    let s = Int(now.timeIntervalSince(item.arrived))
    if s < 60 { return "now" }
    let span = s < 3600 ? "\(s / 60)m" : "\(s / 3600)h"
    return item.kind.needsYou ? "waiting \(span)" : "\(span) ago"
}

extension View {
    /// A drawn outline that takes no clicks. A stroked border laid over a view is hit-tested as a shape, and on
    /// a shape whose corners nearly meet (a 36 pt card with 14 pt continuous corners, a capsule) it claimed the
    /// whole horizontal centre line: a click exactly there reached the border instead of the row under it.
    func outline<S: InsettableShape>(_ shape: S, _ color: Color, lineWidth: CGFloat = 1) -> some View {
        overlay(shape.strokeBorder(color, lineWidth: lineWidth).allowsHitTesting(false))
    }

    // No shadow: a SwiftUI shadow over blurred material re-renders offscreen every frame (measured: largest frame-drop source).
    func glassCard(radius: CGFloat = 18) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(.ultraThinMaterial, in: shape).outline(shape, .white.opacity(0.14))
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

struct RowBackground: ViewModifier {
    let selected: Bool
    let hovered: Bool
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(selected ? 0.12 : (hovered ? 0.06 : 0))))
            .outline(RoundedRectangle(cornerRadius: 9), accent.opacity(selected ? 0.55 : 0))
            .contentShape(Rectangle())
    }
}

// Whether long text needs to scroll is estimated from the string, not measured: measuring re-ran layout every frame.
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

// MARK: - Card skeleton: Header · Title · Context · Detail · Options · Action bar

struct Header: View {
    let item: Item
    /// On a news card the header is part of one larger click target (GoArea), which owns the hover and the click
    /// and passes its hover state in here. nil = the header is its own target.
    var areaHover: Bool? = nil
    @State private var hover = false
    var body: some View {
        if let areaHover {
            row(hot: areaHover)
        } else {
            row(hot: hover)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(hover ? 0.08 : 0)))
                .padding(-6)
                .contentShape(Rectangle())
                .help("Go to \(item.appName): \(item.title)")
                .pointingHand($hover)
                .onTapGesture { goAndDismiss(item) }
        }
    }

    func row(hot: Bool) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: appIcon(item.bundleID)).resizable().frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text("\u{2733}").font(.system(size: 11, weight: .bold)).foregroundStyle(accent)
                    Text(item.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                }
                // A `beckon notify` from outside any project has no directory to name.
                Text(item.project.isEmpty ? item.appName : "\(item.project) · \(item.appName)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if hot {
                Image(systemName: "arrow.up.forward").font(.system(size: 11, weight: .semibold)).foregroundStyle(accent)
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    Text(age(item, ctx.date)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Hover state plus the pointing-hand cursor for a click-through target. The cursor is a stack: a target that
/// leaves the screen while hovered (its card was just dismissed by that very click) gets no hover-ended call,
/// so it pops on disappear too, or the hand would stay.
struct PointingHand: ViewModifier {
    @Binding var hover: Bool
    func body(content: Content) -> some View {
        content
            .onHover { h in
                guard h != hover else { return }
                hover = h
                if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .onDisappear { if hover { NSCursor.pop() } }
    }
}

extension View {
    func pointingHand(_ hover: Binding<Bool>) -> some View { modifier(PointingHand(hover: hover)) }
}

/// Every card: the header and everything the kind puts in here are one click target that goes to the session
/// and takes its cards away — the user is on their way to it. The same area on every kind, so where to click
/// never depends on what the card is; options, fields and the context toggle stay outside it.
struct GoArea<Content: View>: View {
    let item: Item
    @ViewBuilder let content: Content
    @State private var hover = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Header(item: item, areaHover: hover)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(hover ? 0.07 : 0)))
        .padding(-8)
        .contentShape(Rectangle())
        .help("Go to \(item.appName) and dismiss")
        .pointingHand($hover)
        // Same guard as an answer: this click also throws the card away, and the panel sits over a busy work area.
        .onTapGesture { if store.armed(item.id) { goAndDismiss(item) } }
    }
}

func goAndDismiss(_ item: Item) {
    Focus.go(to: item.location)
    store.wentTo(item)
}

struct TitleRow: View {
    let kind: Kind
    let title: String
    var trailing: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: kind.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(kindColor(kind)).help(kind.label)
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
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
        .help(open ? "Show less" : "Show more")
        .onTapGesture { withAnimation(spring) { open.toggle() } }
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
    var body: some View { Text(text).font(.system(size: 12, design: .monospaced)).foregroundStyle(color).textSelection(.enabled) }
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
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).help(detail)
                }
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
                // Return sends, same as the button next to the field.
                let field = TextField(placeholder, text: text)
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .onSubmit { if let b = buttons.last, b.enabled { b.action() } }
                Group {
                    if let focused { field.focused(focused) } else { field }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06)))
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
    let help: String
    let action: () -> Void
    var body: some View {
        // The visible disc stays small so it doesn't cover the card; the click target around it is 36 pt,
        // because a 20 pt target on the card's corner was easy to miss. It reaches 8 pt past the card: the panel
        // lets clicks through from 10 pt out (AppDelegate.updateClickThrough), and at 10 the outermost point fell
        // through to the window behind (seen live).
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                .frame(width: 24, height: 24)
                .background(Circle().fill(.regularMaterial))
                .outline(Circle(), .white.opacity(0.15))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
        .offset(x: -8, y: -8)
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

func replyBinding(_ id: String) -> Binding<String> {
    Binding(get: { store.draft(id).reply }, set: { v in store.update(id) { $0.reply = v } })
}

// MARK: - Permission card content (the other kinds are in CardKinds.swift)

struct PermissionContent: View {
    let item: Item
    let p: PermissionView
    @FocusState private var replyFocused: Bool
    var body: some View {
        let id = item.id
        let reply = store.draft(id).reply
        GoArea(item: item) { TitleRow(kind: item.kind, title: p.headline) }
        if !item.context.isEmpty { ContextLine(text: item.context) }
        if !p.body.isEmpty || !p.diff.isEmpty {
            DetailBox(lines: estimatedLines(p.body, charsPerLine: 48) + p.diff.count) {
                VStack(alignment: .leading, spacing: 2) {
                    if !p.body.isEmpty { Mono(text: p.body) }
                    ForEach(Array(p.diff.enumerated()), id: \.offset) { _, line in
                        Mono(text: line, color: line.hasPrefix("+") ? .green.opacity(0.9) : (line.hasPrefix("-") ? .red.opacity(0.85) : .secondary))
                    }
                }
            }
        }
        VStack(spacing: 4) {
            ForEach(p.options) { o in
                OptionRow(label: o.label, detail: o.detail, action: { choose(o) }) {
                    switch o.action {
                    case .allow: IconMark(symbol: "checkmark")
                    case .allowAndApply: IconMark(symbol: "checkmark.seal")
                    case .deny: IconMark(symbol: "xmark")
                    }
                }
            }
        }
        // Deny works with the field empty too. Only words the user typed skip the pointer half of the click guard.
        ActionBar(placeholder: "Tell Claude what to do instead…", text: replyBinding(id), focused: $replyFocused,
                  buttons: [BarButton("Deny", primary: !reply.isEmpty) {
                      let words = store.draft(id).reply.trimmingCharacters(in: .whitespacesAndNewlines)
                      store.answer(id, decision: PermissionFormat.decision(.deny, message: words),
                                   confirmation: words.isEmpty ? "Denied" : "Denied — told Claude", typed: !words.isEmpty)
                  }])
    }

    func choose(_ o: PermOption) {
        switch o.action {
        case .allow: store.answer(item.id, decision: PermissionFormat.decision(.allow), confirmation: "Allowed")
        case .allowAndApply: store.answer(item.id, decision: PermissionFormat.decision(o.action), confirmation: "Allowed — won't ask again")
        case .deny:
            keyPanel?.takeKey()
            replyFocused = true
        }
    }
}

// MARK: - Cards and stack

struct ExpandedCard: View {
    let item: Item
    @State private var hover = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Every kind puts the header inside its own, larger click target (GoArea); only the brief
            // confirmation after an answer shows it on its own.
            if store.sent[item.id] != nil { Header(item: item) }
            if let sent = store.sent[item.id] {
                Sent(text: sent).transition(.opacity)
            } else {
                switch item.kind {
                case .permission(let p): PermissionContent(item: item, p: p)
                case .questions(let q): QuestionsContent(item: item, view: q)
                case .plan(let p): PlanContent(item: item, p: p)
                case .action(let a): ActionContent(item: item, a: a)
                case .done(let d): DoneContent(item: item, d: d)
                case .failed(let f): FailedContent(item: item, f: f)
                }
            }
        }
        .padding(16)
        .overlay(alignment: .topLeading) {
            if hover {
                CloseButton(help: item.kind.hasTerminalDialog ? "Close — Claude keeps waiting in the terminal; the item stays in the menu bar" : "Dismiss") { store.close(item.id) }
            }
        }
        .onHover { hover = $0 }
        .onAppear { store.cardShown(item.id) }
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
            Text(item.title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 6)
            if isNew { Circle().fill(accent).frame(width: 6, height: 6).help("New") }
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                Text(age(item, ctx.date)).font(.system(size: 11)).foregroundStyle(isNew ? accent : .secondary).fixedSize()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(hover ? 0.05 : 0)))
        .opacity(item.kind.needsYou ? 1 : 0.85)
        .contentShape(Rectangle())
        .help("\(item.kind.label): \(item.summary)")
        .onHover { hover = $0 }
        .onTapGesture { store.expand(item.id) }
    }
}

// One shell per item for its whole life: expand / collapse swaps only the content, so the blurred material
// underneath is kept instead of rebuilt (a frame drop per switch).
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

struct CardFrames: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

private func reportFrame() -> some View {
    GeometryReader { g in Color.clear.preference(key: CardFrames.self, value: [g.frame(in: .global)]) }
}

struct StackView: View {
    let onFrames: ([CGRect]) -> Void
    var body: some View {
        let list = store.ordered
        let shown = store.showAll ? list : Array(list.prefix(Store.visibleRows + 1))
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(shown) { item in
                CardShell(item: item, open: item.id == store.expanded)
                    .background(reportFrame())
                    .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
            }
            if list.count > Store.visibleRows + 1 {
                Text(store.showAll ? "Show less" : "+\(list.count - shown.count) more")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .outline(Capsule(), .white.opacity(0.12))
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
