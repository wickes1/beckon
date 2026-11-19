import Foundation
import Testing
@testable import BeckonApp

private func json(_ s: String) -> [String: Any] {
    try! JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: Any]
}

private let twoQuestions = json(#"""
{"questions":[
  {"question":"Which language?","header":"Language","multiSelect":false,
   "options":[{"label":"Swift","description":"One toolchain"},{"label":"Rust","description":"Second toolchain"}]},
  {"question":"Which terminals?","header":"Targets","multiSelect":true,
   "options":[{"label":"VS Code","description":""},{"label":"Ghostty","description":"","preview":"tty"},{"label":"Terminal.app","description":""}]}
]}
"""#)

private func decisionOf(_ s: String) -> [String: Any] {
    (json(s)["hookSpecificOutput"] as! [String: Any])["decision"] as! [String: Any]
}

@Suite struct QuestionAnswers {
    // Claude Code matches answers to questions by the question's text. Keyed any other way (header, index)
    // the tool sees no answer and the terminal dialog stays up.
    @Test func answersAreKeyedByQuestionTextAndEchoTheQuestions() {
        let view = QuestionFormat.view(input: twoQuestions)!
        let d = decisionOf(QuestionFormat.decision(view, answers: [0: "Swift", 1: "VS Code, Ghostty"]))
        #expect(d["behavior"] as? String == "allow")
        let input = d["updatedInput"] as! [String: Any]
        #expect((input["questions"] as! [Any]).count == 2)  // "allow" without the original questions is rejected
        #expect(input["answers"] as? [String: String] == ["Which language?": "Swift", "Which terminals?": "VS Code, Ghostty"])
    }

    // Multi-select is one string of labels joined with ", ", in the order the options were offered,
    // not the order they were clicked.
    @Test func multiSelectJoinsLabelsInOptionOrder() {
        let q = QuestionFormat.view(input: twoQuestions)!.questions[1]
        #expect(QuestionFormat.answer(q, picks: [2, 0], other: "") == "VS Code, Terminal.app")
        #expect(QuestionFormat.answer(q, picks: [1], other: " tmux ") == "Ghostty, tmux")
    }

    // "Other" must send what the user typed, never the word "Other", and on a single-select it replaces the pick.
    @Test func typedTextIsTheAnswerOnSingleSelect() {
        let q = QuestionFormat.view(input: twoQuestions)!.questions[0]
        #expect(QuestionFormat.answer(q, picks: [1], other: "") == "Rust")
        #expect(QuestionFormat.answer(q, picks: [1], other: "Zig") == "Zig")
    }

    // A payload beckon can't show completely must fall back to the terminal, not show a card missing a question.
    @Test func unreadableQuestionsFallBackToTheTerminal() {
        #expect(QuestionFormat.view(input: [:]) == nil)
        #expect(QuestionFormat.view(input: json(#"{"questions":[{"question":"A?","options":[]},{"header":"no text"}]}"#)) == nil)
    }

    @Test func previewAndHeaderSurvive() {
        let view = QuestionFormat.view(input: twoQuestions)!
        #expect(view.questions.map(\.header) == ["Language", "Targets"])
        #expect(view.questions[1].options[1].preview == "tty")
        #expect(view.questions[1].options[0].preview == nil)
    }
}

// A single-select pick sends the card as soon as nothing is left unanswered: a one-question card is one click,
// like an approval. It must not send while any question is still open, or the user loses the rest.
@Suite struct QuestionCompletion {
    @Test func oneSingleSelectPickCompletesAOneQuestionCard() {
        var d = Draft()
        #expect(!d.complete(1))
        d.picks[0] = [0]
        #expect(d.complete(1))
    }

    @Test func anOpenQuestionKeepsTheCardWaiting() {
        var d = Draft()
        d.picks[0] = [1]
        d.other[1] = "   "  // spaces are not an answer
        #expect(!d.complete(2))
        d.other[1] = "tmux"
        #expect(d.complete(2))
    }
}

@Suite struct PlanDecisions {
    private let input = json(##"{"plan":"# Fix the token refresh\n\n1. Move fetch into `auth.py`\n2. Retry once","planFilePath":"/tmp/p.md"}"##)

    // ExitPlanMode is only satisfied by "allow" together with updatedInput; a bare allow leaves the terminal asking.
    @Test func approvalEchoesTheInput() {
        let view = PlanFormat.view(input: input)!
        let d = decisionOf(PlanFormat.decision(view, .approve))
        #expect(d["behavior"] as? String == "allow")
        #expect((d["updatedInput"] as? [String: Any])?["planFilePath"] as? String == "/tmp/p.md")
        #expect(d["updatedPermissions"] == nil)  // "review each edit" must not change the permission mode
    }

    // Auto-accept must be scoped to this session: a wider destination would silently change saved settings.
    @Test func autoAcceptSwitchesModeForThisSessionOnly() {
        let d = decisionOf(PlanFormat.decision(PlanFormat.view(input: input)!, .approveAcceptEdits))
        let updates = d["updatedPermissions"] as! [[String: String]]
        #expect(updates == [["type": "setMode", "mode": "acceptEdits", "destination": "session"]])
    }

    @Test func revisingDeniesWithTheUsersWords() {
        let d = decisionOf(PlanFormat.decision(PlanFormat.view(input: input)!, .revise("skip step 2")))
        #expect(d["behavior"] as? String == "deny")
        #expect(d["message"] as? String == "skip step 2")
    }

    // The collapsed row and menu bar show only the title: it has to name the plan, not say "Plan".
    @Test func titleIsTheFirstHeading() {
        #expect(PlanFormat.view(input: input)!.title == "Fix the token refresh")
        #expect(PlanFormat.title(of: "Do `x` then y\nmore") == "Do x then y")
        #expect(PlanFormat.view(input: ["plan": "  \n"]) == nil)
    }
}

@Suite struct UpdateCards {
    // The headline is all the collapsed row shows, so it is Claude's first line, without Markdown markers.
    @Test func doneHeadlineIsTheFirstLine() {
        let d = Updates.done("## **VLAN gloss is ready**\n\nBuilt dist/ and checked it at 3 widths.")
        #expect(d.headline == "VLAN gloss is ready")
        #expect(d.summary == "Built dist/ and checked it at 3 widths.")  // the headline is not repeated in the body
    }

    // Seen live: a Chinese first line of 60 characters filled four lines of bold headline. Width, not count, is the limit.
    @Test func cjkHeadlineIsCutByWidth() {
        let line = String(repeating: "每一頁我都看過了", count: 8)  // 64 characters, 128 columns
        let d = Updates.done(line)
        #expect(Words.width(d.headline) <= 90)
        #expect(d.headline.hasSuffix("…"))
        #expect(d.summary == line)  // cut in the headline, so whole in the body
    }

    // A long first line is cut in the headline, so the body must still carry all of it.
    @Test func longFirstLineStaysWholeInTheBody() {
        let line = String(repeating: "word ", count: 30).trimmingCharacters(in: .whitespaces)
        let d = Updates.done(line + "\nsecond")
        #expect(d.headline.count == 90)
        #expect(d.summary.hasPrefix(line))
    }

    // A one-line message would otherwise be shown twice, as headline and as body.
    @Test func oneLineMessageHasNoBody() {
        #expect(Updates.done("All tests pass.") == DoneView(headline: "All tests pass.", summary: ""))
        #expect(Updates.done("").headline == "Claude finished")
    }

    @Test func failureNamesTheErrorInWords() {
        let f = Updates.failure(error: "rate_limit", details: nil, message: "API Error: Rate limit reached")
        #expect(f.headline == "Claude stopped: rate limit")
        #expect(f.error == "API Error: Rate limit reached")
    }

    // The reply reaches Claude as a hook's system reminder; without saying whose words these are,
    // Claude reads it as hook output and may not act on it.
    @Test func replySaysItIsFromTheUser() {
        let text = Updates.reply("also run the tests")
        #expect(text.contains("user"))
        #expect(text.hasSuffix("also run the tests"))
    }
}

@Suite struct PlanLinks {
    // A plan is text from the model, and a Markdown link hides where it goes behind its label. One click on the
    // card must never open a local file or start another app: only web links stay live, the rest keep their words.
    @Test func onlyWebLinksStayClickable() {
        let text = planText("Read [the notes](file:///Users/x/notes.app), [settings](x-apple.systempreferences:com.apple.preference.security), <file:///etc/hosts> and [the docs](https://example.com/docs).")
        #expect(text.runs.compactMap(\.link).map(\.absoluteString) == ["https://example.com/docs"])
        #expect(String(text.characters) == "Read the notes, settings, file:///etc/hosts and the docs.")
    }
}
