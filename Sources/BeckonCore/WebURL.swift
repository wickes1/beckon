/// Why `text` is not a link beckon opens, or nil when it is one: http or https, with a host.
///
/// One rule for both sides. The CLI checks `notify --url` with it before sending, and the app checks it again on
/// arrival; notify doesn't wait for the app's answer, so a URL the CLI passes and the app refuses would leave the
/// caller with exit 0 and no card. Plain string work, because this module stays Foundation-free for the CLI's cold
/// start. It is stricter than Foundation's URL(string:) (an ASCII host of letters, digits, "-", "." and "_", or a
/// bracketed IPv6 address; a numeric port), so anything it accepts the app can parse and open: a URL outside that
/// fails in the CLI, out loud.
public func webURLProblem(_ text: String) -> String? {
    guard let colon = text.firstIndex(of: ":"), colon > text.startIndex,
          text[..<colon].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) })
    else { return "is not a URL" }
    let scheme = text[..<colon].lowercased()
    guard scheme == "http" || scheme == "https" else { return "has the scheme \"\(scheme.prefix(40))\", not http or https" }
    let rest = text[text.index(after: colon)...]
    guard rest.hasPrefix("//") else { return "has no host" }  // http:example.com is a path, not a host
    let authority = rest.dropFirst(2).prefix { !"/?#".contains($0) }
    var hostPort = authority
    if let at = authority.lastIndex(of: "@") {
        guard authority[..<at].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-._~!$&'()*+,;=:".contains($0)) })
        else { return "has an unreadable host" }
        hostPort = authority[authority.index(after: at)...]
    }
    let host: Substring, port: Substring
    if hostPort.first == "[" {
        guard let end = hostPort.firstIndex(of: "]") else { return "has an unreadable host" }
        host = hostPort[hostPort.index(after: hostPort.startIndex)..<end]
        port = hostPort[hostPort.index(after: end)...]
        guard host.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." }) else { return "has an unreadable host" }
    } else {
        let end = hostPort.firstIndex(of: ":") ?? hostPort.endIndex
        host = hostPort[..<end]
        port = hostPort[end...]
        guard host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-._".contains($0)) }) else { return "has an unreadable host" }
    }
    guard !host.isEmpty else { return "has no host" }
    guard port.isEmpty || (port.first == ":" && port.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber })) else { return "has an unreadable port" }
    return nil
}
