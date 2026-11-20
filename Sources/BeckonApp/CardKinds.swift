import AppKit
import SwiftUI

// What each kind puts into the card skeleton (Header · Title · Context · Detail · Options · Action bar).
// A kind may leave a slot out; none adds its own. Permission is in Cards.swift.

struct QuestionsContent: View {
    let item: Item
    let view: QuestionsView

    var body: some View {
        let id = item.id
        let qs = view.questions
        let d = store.draft(id)
        let current = min(d.current, qs.count - 1)
        let q = qs[current]
        let isLast = current == qs.count - 1
        let answered: (Int) -> Bool = d.answered
        let all = d.complete(qs.count)

        GoArea(item: item) { TitleRow(kind: item.kind, title: q.question, trailing: qs.count > 1 ? "\(current + 1) of \(qs.count)" : nil) }
        if !item.context.isEmpty { ContextLine(text: item.context) }
        if qs.count > 1 || q.multiSelect {
            HStack(spacing: 6) {
                if qs.count > 1 {
                    ForEach(qs) { qq in
                        let on = qq.id == current
                        HStack(spacing: 4) {
                            if answered(qq.id) { Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(accent) }
                            Text(qq.header).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(.white.opacity(on ? 0.14 : 0.05)))
                        .outline(Capsule(), .white.opacity(on ? 0.2 : 0))
                        .foregroundStyle(on ? .primary : .secondary)
                        .contentShape(Capsule())
                        .onTapGesture { go(qq.id) }
                    }
                }
                Spacer()
                if q.multiSelect { Text("Select all that apply").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
        }
        VStack(spacing: 4) {
            ForEach(q.options) { o in
                let on = d.picks[q.id]?.contains(o.id) ?? false
                VStack(spacing: 6) {
                    OptionRow(label: o.label, detail: o.description, selected: on, action: { pick(o, q) }) {
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
                      if isLast { send() } else { go(current + 1) }
                  }])
    }

    func go(_ i: Int) { withAnimation(spring) { store.update(item.id) { $0.current = i; $0.previewOpen = nil } } }

    func pick(_ o: QOption, _ q: Question) {
        // Short pause either way so the pick registers before the card moves on.
        switch store.pick(o.id, of: q, in: view, on: item.id) {
        case .send: DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { send() }
        case .next: DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { go(q.id + 1) }
        case .stay: break
        }
    }

    func send() {
        let d = store.draft(item.id)
        let n = view.questions.count
        store.answer(item.id, decision: QuestionFormat.decision(view, answers: QuestionFormat.answers(view, d)),
                     confirmation: n == 1 ? "Answered — sent to Claude" : "All \(n) answered — sent to Claude",
                     typed: !d.other.values.allSatisfy(\.isEmpty))
    }
}

struct PlanContent: View {
    let item: Item
    let p: PlanView
    @FocusState private var replyFocused: Bool
    var body: some View {
        let id = item.id
        GoArea(item: item) { TitleRow(kind: item.kind, title: p.title) }
        if !item.context.isEmpty { ContextLine(text: item.context) }
        DetailBox(lines: estimatedLines(p.markdown, charsPerLine: 58), maxLines: 8, lineHeight: 18) {
            Text(planText(p.markdown)).font(.system(size: 12)).lineSpacing(3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        VStack(spacing: 4) {
            OptionRow(label: "Approve", detail: "Auto-accept edits", action: {
                store.answer(id, decision: PlanFormat.decision(p, .approveAcceptEdits), confirmation: "Plan approved — auto-accepting edits")
            }) { IconMark(symbol: "checkmark.seal") }
            OptionRow(label: "Approve", detail: "Review each edit", action: {
                store.answer(id, decision: PlanFormat.decision(p, .approve), confirmation: "Plan approved")
            }) { IconMark(symbol: "checkmark") }
            OptionRow(label: "Keep planning", detail: "Tell Claude what to change below", action: { keyPanel?.takeKey(); replyFocused = true }) { IconMark(symbol: "arrow.uturn.backward") }
        }
        ActionBar(placeholder: "What should change in the plan…", text: replyBinding(id), focused: $replyFocused,
                  buttons: [BarButton("Send", primary: true, enabled: !store.draft(id).reply.isEmpty) {
                      store.answer(id, decision: PlanFormat.decision(p, .revise(store.draft(id).reply)), confirmation: "Sent back to planning", typed: true)
                  }])
    }
}

struct ActionContent: View {
    let item: Item
    let a: ActionView
    var body: some View {
        GoArea(item: item) { TitleRow(kind: item.kind, title: a.title) }
        if !item.context.isEmpty { ContextLine(text: item.context) }
        if !a.steps.isEmpty || a.target != nil {
            DetailBox(lines: a.steps.count + 1) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(a.steps.enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(i + 1)").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
                                .frame(width: 16, height: 16).background(Circle().fill(.white.opacity(0.1)))
                            Text(step).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let target = a.target { Mono(text: target.text, color: .secondary).padding(.top, 2) }
                }
            }
        }
        // Nothing is sent to Claude here: the skill that raised the card watches for the result itself.
        ActionBar(buttons: [
            BarButton("I've done it") { store.remove(item.id) },
            a.target.map { t in BarButton("Open in \(t.appName)", icon: t.bundleID.map(appIcon), primary: true) { Focus.open(t) } }
                ?? BarButton("Open in \(item.appName)", icon: appIcon(item.bundleID), primary: true) { goAndDismiss(item) },
        ])
    }
}

struct DoneContent: View {
    let item: Item
    let d: DoneView
    var body: some View {
        let id = item.id
        GoArea(item: item) {
            TitleRow(kind: item.kind, title: d.headline)
            if !d.summary.isEmpty {
                Text(d.summary).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        if store.replyable.contains(id) {
            // The session is idle with its Stop hook still listening: a reply here wakes it.
            // Dismiss sits beside Send so leaving without replying never depends on hitting the × in the corner.
            // Send stays last: Return in the field presses the last button.
            ActionBar(placeholder: "Reply to Claude…", text: replyBinding(id),
                      buttons: [BarButton("Dismiss") { store.remove(id) },
                                BarButton("Send", primary: true, enabled: !store.draft(id).reply.trimmingCharacters(in: .whitespaces).isEmpty) {
                          Intake.userReplied(session: item.sessionID)
                          store.answer(id, decision: Updates.reply(store.draft(id).reply), confirmation: "Sent to Claude", typed: true)
                      }])
        } else {
            ActionBar(buttons: [
                BarButton("Dismiss") { store.remove(id) },
                BarButton("Open in \(item.appName)", icon: appIcon(item.bundleID), primary: true) { goAndDismiss(item) },
            ])
        }
    }
}

struct FailedContent: View {
    let item: Item
    let f: FailureView
    var body: some View {
        GoArea(item: item) { TitleRow(kind: item.kind, title: f.headline) }
        // Outside the click target: the error text stays selectable for copying.
        DetailBox(lines: estimatedLines(f.error, charsPerLine: 48)) { Mono(text: f.error, color: .secondary) }
        // No Retry: Claude Code ignores whatever a StopFailure hook returns, so the retry happens in the session.
        ActionBar(buttons: [
            BarButton("Dismiss") { store.remove(item.id) },
            BarButton("Open in \(item.appName)", icon: appIcon(item.bundleID), primary: true) { goAndDismiss(item) },
        ])
    }
}
