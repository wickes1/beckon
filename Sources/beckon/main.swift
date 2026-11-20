// beckon — the hook binary. Claude Code runs it on every hooked event, so it does as little as possible:
// read the hook JSON from stdin, wrap it with where the session lives (process ancestry + a few env vars),
// hand it to the app over the socket, and for waiting events print whatever decision comes back.
//
// Fail open, always: if the app isn't running, the socket is missing, or anything at all goes wrong,
// a hook prints nothing and exits 0, so Claude Code behaves exactly as if beckon weren't installed.
// Darwin only (no Foundation) to keep cold start low.
import BeckonCore
import Darwin

signal(SIGPIPE, SIG_IGN)
signal(SIGALRM) { _ in
    let text = "✗ the beckon app is running but did not answer within 10 s\n"
    _ = text.withCString { write(STDOUT_FILENO, $0, strlen($0)) }
    _exit(1)
}

func usage(asked: Bool = false) -> Never {
    let text = """
    usage:
      beckon hook <EventName>     run by Claude Code hooks; reads the hook JSON on stdin
      beckon hook Stop --rewake   as an asyncRewake Stop hook: stays in the background and wakes the idle
                                  session (exit 2) with a reply typed on the Done card
      beckon notify --title <text> [--message <text>] [--step <text>]... [--brave-tab <id> | --url <http(s) url>] [--key <name>]
                                  show an "Action needed" card for this session (for skills that need the user
                                  to do something, e.g. log in). --key names it so `dismiss` can take it down.
      beckon dismiss --key <name> remove that card once the thing is done
      beckon doctor               check the app, hooks and permissions
      beckon test                 show a sample card, to see that the panel works
      beckon --version

    """
    // Help that was asked for is the output and a success; a wrong invocation is an error. Exit 1 for it, never
    // the conventional 2: from a hook Claude Code reads 2 as "block this" (the prompt is refused, the turn can't end).
    fputs(text, asked ? stdout : stderr)
    exit(asked ? 0 : 1)
}

func readAll(_ fd: Int32) -> [UInt8] {
    var out: [UInt8] = []
    var buf = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let n = read(fd, &buf, buf.count)
        if n > 0 { out.append(contentsOf: buf[0..<n]) } else if n < 0 && errno == EINTR { continue } else { break }
    }
    return out
}

func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    var off = 0
    while off < bytes.count {
        let n = bytes[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if n > 0 { off += n } else if n < 0 && errno == EINTR { continue } else { return false }
    }
    return true
}

func jsonString(_ s: String) -> String {
    var out = "\""
    for u in s.unicodeScalars {
        switch u {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if u.value < 0x20 {
                let hex = String(u.value, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            } else {
                out.unicodeScalars.append(u)
            }
        }
    }
    return out + "\""
}

// Parent chain up to launchd: [{pid, ppid, comm, tty}]. The app picks out the claude process,
// its tty and its shell from this; the CLI just reports.
func ancestry() -> String {
    var parts: [String] = []
    var pid = getpid()
    for _ in 0..<16 {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { break }
        let ppid = info.kp_eproc.e_ppid
        let comm = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        var tty = ""
        let dev = info.kp_eproc.e_tdev
        if dev != -1, let name = devname(dev, S_IFCHR) { tty = String(cString: name) }
        parts.append("{\"pid\":\(pid),\"ppid\":\(ppid),\"comm\":\(jsonString(comm)),\"tty\":\(jsonString(tty))}")
        if ppid <= 1 { break }
        pid = ppid
    }
    return "[" + parts.joined(separator: ",") + "]"
}

// Only the variables that say which terminal / window the session is in.
let envKeys = ["__CFBundleIdentifier", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TMUX", "TMUX_PANE",
               "ITERM_SESSION_ID", "VSCODE_PID", "VSCODE_IPC_HOOK_CLI", "GHOSTTY_RESOURCES_DIR"]
func envJSON() -> String {
    var parts: [String] = []
    for k in envKeys { if let v = getenv(k) { parts.append("\(jsonString(k)):\(jsonString(String(cString: v)))") } }
    return "{" + parts.joined(separator: ",") + "}"
}

/// Sends one envelope. nil = the app isn't reachable; otherwise the reply (empty for fire-and-forget events).
func send(event: String, payload: [UInt8], wait: Bool) -> [UInt8]? {
    var envelope = Array("{\"v\":1,\"event\":\(jsonString(event)),\"wait\":\(wait),\"pid\":\(getpid()),\"ancestry\":\(ancestry()),\"env\":\(envJSON()),\"payload\":".utf8)
    envelope += payload
    envelope += Array("}".utf8)

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var nosigpipe: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
    // Never let a stuck app stall Claude on a fire-and-forget event.
    var sendTimeout = timeval(tv_sec: 0, tv_usec: 300_000)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let path = Array(BeckonPaths.socket.utf8)
    guard path.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: path)
        raw[path.count] = 0
    }
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else {  // app not running
        // Refused means the socket file is there with nobody behind it. An app that crashed or was force-quit
        // also left its presence file, and Claude Code skips phone pushes for as long as that exists.
        if errno == ECONNREFUSED { unlink(BeckonPaths.presenceFile) }
        return nil
    }
    guard writeAll(fd, envelope) else { return nil }
    shutdown(fd, SHUT_WR)  // the app reads to EOF, so the request needs no framing
    // A waiting event blocks here until the user answers in the panel, the item is resolved elsewhere
    // (empty reply), or Claude Code's hook timeout kills this process.
    return wait ? readAll(fd) : []
}

func isBlank(_ bytes: [UInt8]) -> Bool { !bytes.contains { $0 != 0x0A && $0 != 0x20 } }

func fail(_ message: String) -> Never {
    fputs("beckon: \(message)\n", stderr)
    exit(1)
}

let argv = CommandLine.arguments
guard argv.count >= 2 else { usage() }

switch argv[1] {
case "--version", "-v":
    print(beckonVersion)

case "--help", "-h":
    usage(asked: true)

case "hook":
    // Not usage(): Claude Code shows the first line a failed hook writes to stderr, so that line says what is wrong.
    guard argv.count == 3 || (argv.count == 4 && argv[2] == "Stop" && argv[3] == "--rewake") else {
        fail("can't read this hook command line: the hooks and the beckon CLI (\(beckonVersion)) are probably different versions")
    }
    // Headless runs (`claude -p`, the SDK) have nobody at a terminal, and `claude -p` does not exit while an
    // asyncRewake Stop hook is still alive (seen live: it hung until the hook was killed). Stay out of them.
    // Both variables are Claude Code's own; when neither is set the session counts as attended.
    if let attended = getenv("CLAUDE_CODE_SESSION_ATTENDED"), String(cString: attended) == "0" { exit(0) }
    if let entry = getenv("CLAUDE_CODE_ENTRYPOINT"), String(cString: entry).hasPrefix("sdk") { exit(0) }
    let event = argv[2]
    let rewake = argv.count == 4
    let payload = readAll(STDIN_FILENO)
    guard !payload.isEmpty, let reply = send(event: event, payload: payload, wait: rewake || waitingEvents.contains(event)),
          !isBlank(reply) else { exit(0) }
    if rewake {
        // The user's reply from the Done card. As an asyncRewake hook, exit 2 wakes the idle session
        // and hands it stderr.
        _ = writeAll(STDERR_FILENO, reply)
        exit(2)
    }
    _ = writeAll(STDOUT_FILENO, reply)

case "notify", "dismiss":
    var fields: [String] = []
    var steps: [String] = []
    var seen: Set<String> = []
    var i = 2
    while i < argv.count {
        let flag = argv[i]
        guard i + 1 < argv.count else { usage() }
        let value = argv[i + 1]
        switch flag {
        case "--title", "--message", "--key":
            fields.append("\(jsonString(String(flag.dropFirst(2)))):\(jsonString(value))")
        case "--url":
            // The app refuses anything else, and notify doesn't wait for its answer: say so here, by the app's own rule.
            if let why = webURLProblem(value) { fail("--url takes an http or https URL with a host, and \"\(value)\" \(why)") }
            fields.append("\"url\":\(jsonString(value))")
        case "--brave-tab":
            guard let id = Int(value) else { fail("--brave-tab takes the numeric tab id") }
            fields.append("\"brave_tab\":\(id)")
        case "--step":
            steps.append(jsonString(value))
        default:
            usage()
        }
        seen.insert(flag)
        i += 2
    }
    if argv[1] == "notify" && !seen.contains("--title") { fail("notify needs --title") }
    if argv[1] == "dismiss" && !seen.contains("--key") { fail("dismiss needs --key") }
    fields.append("\"steps\":[\(steps.joined(separator: ","))]")
    if let session = getenv("CLAUDE_CODE_SESSION_ID") { fields.append("\"session_id\":\(jsonString(String(cString: session)))") }
    var cwd = [CChar](repeating: 0, count: Int(PATH_MAX))
    if getcwd(&cwd, cwd.count) != nil { fields.append("\"cwd\":\(jsonString(String(cString: cwd)))") }
    // Unlike a hook, the caller asked for something to appear: tell it when nothing will.
    guard send(event: argv[1] == "notify" ? "Notify" : "Dismiss", payload: Array("{\(fields.joined(separator: ","))}".utf8), wait: false) != nil else {
        fail("the beckon app isn't running, so nothing was shown")
    }

case "test":
    guard argv.count == 2 else { usage() }
    // An "Action needed" card, because that kind shows wherever the user is looking: a sample prompt would be
    // held back while this terminal is in front, which is exactly when someone runs this.
    let card = #"{"title":"beckon is working","message":"A sample card. Real prompts are held back while you look at their terminal.","steps":["Click “I've done it” to close this card"],"key":"beckon-test"}"#
    guard send(event: "Notify", payload: Array(card.utf8), wait: false) != nil else {
        fail("the beckon app isn't running (open Beckon.app), so nothing was shown")
    }
    print("sample card sent: look at the top right of the screen")

case "doctor":
    alarm(10)  // doctor is asked by a person: a stuck app must end in an error, not a hang (SIGALRM exits)
    guard let reply = send(event: "Doctor", payload: Array("{}".utf8), wait: true) else {
        print("✗ the beckon app isn't running (open Beckon.app); hooks fall back to the terminal")
        print("  cli \(beckonVersion)")
        exit(1)
    }
    // First line is the verdict, the rest is the report.
    let text = String(decoding: reply, as: UTF8.self)
    let verdict = text.prefix { $0 != "\n" }
    print(text.dropFirst(verdict.count + 1), terminator: "")
    print("cli \(beckonVersion)")
    exit(verdict == "ok" ? 0 : 1)

default:
    usage()
}
exit(0)
