import Foundation
import Testing
@testable import BeckonApp

@Suite struct WhereTheSessionLives {
    // Seen live from a VS Code terminal: the hook's own shell has no tty, the claude process above it does.
    private let ancestry: [[String: Any]] = [
        ["pid": 27217, "ppid": 84334, "comm": "zsh", "tty": ""],
        ["pid": 84334, "ppid": 84191, "comm": "claude", "tty": "ttys009"],
        ["pid": 84191, "ppid": 55314, "comm": "zsh", "tty": "ttys009"],
        ["pid": 55314, "ppid": 55292, "comm": "Code Helper", "tty": ""],
    ]

    // The tty is how the Ghostty / Terminal.app tab is found: it must be the first real one up the chain,
    // as a device path, not an empty string from a process without a terminal.
    @Test func ttyIsTheFirstRealOneUpTheChain() {
        let l = Location(env: ["TERM_PROGRAM": "ghostty"], ancestry: ancestry)
        #expect(l.tty == "/dev/ttys009")
        #expect(l.bundleID == Apps.ghostty)
    }

    // The VS Code extension matches a terminal's shell pid (84191 here) against this list: every pid has to be in it.
    @Test func pidsCoverTheWholeChain() {
        #expect(Location(env: [:], ancestry: ancestry).pids == [27217, 84334, 84191, 55314])
    }

    // macOS sets __CFBundleIdentifier for anything launched from an app; it beats TERM_PROGRAM, which a
    // multiplexer or a nested terminal can overwrite.
    @Test func bundleIdentifierWinsOverTermProgram() {
        #expect(Surface.bundleID(env: ["__CFBundleIdentifier": "com.microsoft.VSCode", "TERM_PROGRAM": "tmux"]) == "com.microsoft.VSCode")
        #expect(Surface.bundleID(env: ["TERM_PROGRAM": "Apple_Terminal"]) == Apps.terminal)
        #expect(Surface.bundleID(env: ["TERM_PROGRAM": "tmux"]) == nil)
    }
}

@Suite struct HerdrTerminals {
    // herdr-core gives every terminal TERM_PROGRAM=ghostty and no bundle id: read as Ghostty, a click would
    // raise the wrong app and "already looking" would ask Ghostty about a terminal it doesn't have.
    @Test func herdrTerminalIsNotMistakenForGhostty() {
        let env = ["HC_TERMINAL_ID": "t14", "TERM_PROGRAM": "ghostty"]
        #expect(Surface.bundleID(env: env) == Apps.herdr)
        #expect(Location(env: env, ancestry: []).herdrTerminal == "t14")
        #expect(Surface.bundleID(env: ["TERM_PROGRAM": "ghostty"]) == Apps.ghostty)
        #expect(Surface(env: ["HC_TERMINAL_ID": ""]).bundleID == nil)
    }

    // The parent decides whether a Done card is shown: only a real lead may hide it. A top-level session
    // (null) and an answer that isn't the record both leave the card showing.
    @Test func parentIsReadFromTheRecord() {
        #expect(Herdr.parent(fromGet: Data(#"{"address":"t1k","parent":"t14","state":"live"}"#.utf8)) == "t14")
        #expect(Herdr.parent(fromGet: Data(#"{"address":"t14","parent":null}"#.utf8)) == nil)
        #expect(Herdr.parent(fromGet: Data("not json".utf8)) == nil)
    }

    // "Is he looking at it" compares this with the terminal id; a missing answer must come out as nil so
    // the caller falls back to "Herdr is frontmost" instead of reading it as a different terminal.
    @Test func shownTerminalIsReadFromStatus() {
        #expect(Herdr.shown(fromStatus: Data(#"{"zoom":1.0,"agent":"t14","errors":[]}"#.utf8)) == "t14")
        #expect(Herdr.shown(fromStatus: Data(#"{"zoom":1.0}"#.utf8)) == nil)
        #expect(Herdr.shown(fromStatus: Data()) == nil)
    }
}

@Suite struct TabScripts {
    // The tty goes into AppleScript source: a quote in it must not be able to end the string and run something else.
    @Test func ttyIsQuotedIntoTheScript() {
        #expect(Script.quote(#"/dev/tty"; do shell script "x"#) == #""/dev/tty\"; do shell script \"x""#)
        let script = Focus.terminalScript(app: Apps.ghostty, tty: "/dev/ttys016", action: .focus)!
        #expect(script.contains(#"if tty of term is "/dev/ttys016" then"#))
    }

    // Apps without a tab-level script get plain app activation instead of a script that can't work.
    @Test func unknownTerminalHasNoScript() {
        #expect(Focus.terminalScript(app: "com.googlecode.iterm2", tty: "/dev/ttys001", action: .focus) == nil)
        #expect(Focus.terminalScript(app: Apps.terminal, tty: "/dev/ttys001", action: .isFront) != nil)
    }
}
