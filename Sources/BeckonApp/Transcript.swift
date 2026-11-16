import Foundation

/// Reads the session title and Claude's last words from the tail of the transcript JSONL.
/// The format is undocumented: every field is optional and a miss falls back to the project name / no context.
/// Titles: `{"type":"ai-title","aiTitle":…}` (seen); `{"type":"custom-title","customTitle":…}` from /rename (assumed, unverified).
enum Transcript {
    struct Info { var title: String?; var lastAssistantText: String? }

    static func read(_ path: String, tailBytes: Int = 1 << 20) -> Info {
        guard let h = FileHandle(forReadingAtPath: path) else { return Info() }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? h.seek(toOffset: start)
        guard let data = try? h.readToEnd() else { return Info() }
        var lines = data.split(separator: 0x0A)
        if start > 0, !lines.isEmpty { lines.removeFirst() }  // probably cut mid-line

        var info = Info()
        var custom: String?
        for line in lines.reversed() {
            if info.title != nil && info.lastAssistantText != nil { break }
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = obj["type"] as? String else { continue }
            switch type {
            case "custom-title" where custom == nil:
                custom = obj["customTitle"] as? String
            case "ai-title" where info.title == nil:
                info.title = obj["aiTitle"] as? String
            case "assistant" where info.lastAssistantText == nil:
                let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { info.lastAssistantText = text }
            default:
                break
            }
        }
        if let custom, !custom.isEmpty { info.title = custom }
        return info
    }
}
