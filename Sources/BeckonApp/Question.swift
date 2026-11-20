import Foundation

// AskUserQuestion and ExitPlanMode arrive as PermissionRequest hooks like any other tool. This file is the pure
// translation between their tool_input and what the card shows, and back to the hook's decision JSON.
// No UI, no I/O: unit-tested.

struct QOption: Identifiable, Equatable {
    let id: Int
    let label: String
    let description: String
    let preview: String?
}

struct Question: Identifiable, Equatable {
    let id: Int
    let header: String
    let question: String
    let multiSelect: Bool
    let options: [QOption]
}

struct QuestionsView: Equatable {
    let questions: [Question]
    let inputJSON: String  // the original tool_input, echoed back with the answers added
}

enum QuestionFormat {
    /// nil when the payload has no usable question: the terminal dialog handles it instead of an empty card.
    static func view(input: [String: Any]) -> QuestionsView? {
        let raw = input["questions"] as? [[String: Any]] ?? []
        let questions = raw.enumerated().compactMap { i, q -> Question? in
            guard let text = q["question"] as? String, !text.isEmpty else { return nil }
            let options = (q["options"] as? [[String: Any]] ?? []).enumerated().compactMap { j, o -> QOption? in
                guard let label = o["label"] as? String, !label.isEmpty else { return nil }
                let preview = (o["preview"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return QOption(id: j, label: label, description: o["description"] as? String ?? "", preview: preview)
            }
            return Question(id: i, header: q["header"] as? String ?? "Q\(i + 1)", question: text,
                            multiSelect: q["multiSelect"] as? Bool ?? false, options: options)
        }
        guard !questions.isEmpty, questions.count == raw.count else { return nil }
        return QuestionsView(questions: questions, inputJSON: PermissionFormat.compactJSON(input, limit: .max))
    }

    /// One question's answer as Claude Code expects it: the picked label, several labels joined with ", ",
    /// or the typed text. Typed text on a multi-select question is one more entry in the list.
    static func answer(_ q: Question, picks: Set<Int>, other: String) -> String {
        let typed = other.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts = q.options.filter { picks.contains($0.id) }.map(\.label)
        if !typed.isEmpty { if q.multiSelect { parts.append(typed) } else { parts = [typed] } }
        return parts.joined(separator: ", ")
    }

    /// What the card holds, as each question's answer.
    static func answers(_ view: QuestionsView, _ d: Draft) -> [Int: String] {
        Dictionary(uniqueKeysWithValues: view.questions.map { ($0.id, answer($0, picks: d.picks[$0.id] ?? [], other: d.other[$0.id] ?? "")) })
    }

    /// The hook's stdout: allow, with the original input plus `answers` keyed by each question's text.
    static func decision(_ view: QuestionsView, answers: [Int: String]) -> String {
        var input = (try? JSONSerialization.jsonObject(with: Data(view.inputJSON.utf8))) as? [String: Any] ?? [:]
        var map: [String: String] = [:]
        for q in view.questions { map[q.question] = answers[q.id] ?? "" }
        input["answers"] = map
        return PermissionFormat.encode(["behavior": "allow", "updatedInput": input])
    }
}

struct PlanView: Equatable {
    let title: String
    let markdown: String
    let inputJSON: String  // the original tool_input, echoed back on approval
}

enum PlanFormat {
    static func view(input: [String: Any]) -> PlanView? {
        guard let plan = input["plan"] as? String, !plan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return PlanView(title: title(of: plan), markdown: plan, inputJSON: PermissionFormat.compactJSON(input, limit: .max))
    }

    /// The plan's first heading, else its first line, so the collapsed row says which plan this is.
    static func title(of plan: String) -> String {
        let lines = plan.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let pick = lines.first { $0.hasPrefix("#") } ?? lines.first ?? ""
        let clean = Words.plain(String(pick.drop { $0 == "#" || $0 == " " }))
        return clean.isEmpty ? "Review the plan" : Words.clip(clean, 90)
    }

    enum Choice { case approve, approveAcceptEdits, revise(String) }

    /// Like AskUserQuestion, ExitPlanMode needs `updatedInput` next to "allow" or the terminal still asks.
    static func decision(_ view: PlanView, _ choice: Choice) -> String {
        let input = (try? JSONSerialization.jsonObject(with: Data(view.inputJSON.utf8))) as? [String: Any] ?? [:]
        switch choice {
        case .approve:
            return PermissionFormat.encode(["behavior": "allow", "updatedInput": input])
        case .approveAcceptEdits:
            // Accept-edits mode for this session only, as a permission update on the approval.
            return PermissionFormat.encode(["behavior": "allow", "updatedInput": input,
                                            "updatedPermissions": [["type": "setMode", "mode": "acceptEdits", "destination": "session"]]])
        case .revise(let message):
            return PermissionFormat.encode(["behavior": "deny", "message": message])
        }
    }
}

/// Small text helpers shared by the card kinds.
enum Words {
    /// Markdown markers read as noise in a one-line headline.
    static func plain(_ s: String) -> String {
        var out = s
        for mark in ["**", "__", "`"] { out = out.replacingOccurrences(of: mark, with: "") }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cuts to `max` columns, not characters: a CJK character is twice as wide as a Latin one, so counting
    /// characters let a Chinese headline run to four lines where an English one took two.
    static func clip(_ s: String, _ max: Int) -> String {
        guard width(s) > max else { return s }
        var used = 0
        var out = ""
        for ch in s {
            let w = width(String(ch))
            if used + w > max - 1 { break }
            used += w
            out.append(ch)
        }
        return out.trimmingCharacters(in: .whitespaces) + "…"
    }

    static func width(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) { $0 + ($1.value >= 0x2E80 ? 2 : 1) }
    }
}
