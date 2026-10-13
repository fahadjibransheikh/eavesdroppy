import Foundation

// Foundation-only text helpers for the library UI: transcript timestamps, Ask citations, search snippets.
// Links are rewritten into `eav://` URLs so Text(AttributedString(markdown:)) renders them tappable and
// OpenURLAction routes them, instead of custom text layout.

/// Double -> Int that cannot trap: NaN and infinities (SQLite REALs can hold either) become 0, huge values clamp.
func safeInt(_ x: Double) -> Int {
    guard x.isFinite else { return 0 }
    return Int(max(min(x, 9.0e15), -9.0e15))
}

enum Timestamp {
    /// `[03:41]` and `[1:03:41]` (brackets included). Hours are at most 3 digits, so no match can overflow an Int.
    /// [0-9], not \d: ICU's \d also matches Arabic-Indic and other Unicode digits.
    static let pattern = #"\[(?:[0-9]{1,3}:)?[0-9]{1,2}:[0-9]{2}\]"#
    private static let regex = try! NSRegularExpression(pattern: pattern)  // constant pattern, not external data

    /// "03:41", "1:03:41" (brackets optional) -> seconds. nil if it is not m:ss or h:mm:ss (m at most 2 digits, h at most 3).
    static func seconds(_ s: String) -> Int? {
        let parts = s.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              parts.dropFirst().allSatisfy({ $0.count == 2 }),
              (parts.first?.count ?? 9) <= (parts.count == 3 ? 3 : 2) else { return nil }
        var total = 0
        for p in parts {
            guard let n = Int(p) else { return nil }
            let (m, o1) = total.multipliedReportingOverflow(by: 60)
            let (t, o2) = m.addingReportingOverflow(n)
            if o1 || o2 { return nil }
            total = t
        }
        return total
    }

    /// Same format as library.fmt_ts: "03:41" or "1:03:41".
    static func format(_ sec: Double) -> String {
        let s = max(safeInt(sec), 0), h = s / 3600, m = s % 3600 / 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s % 60) : String(format: "%02d:%02d", m, s % 60)
    }

    static func matches(in text: String) -> [(range: NSRange, seconds: Int)] {
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            seconds(ns.substring(with: m.range)).map { (m.range, $0) }
        }
    }
}

/// `[Title, 2026-10-12, 03:41]`, the form Ask is told to cite in. The lazy title lets titles contain commas.
struct Citation: Equatable {
    var range: NSRange
    var title: String
    var date: String
    var seconds: Int

    private static let regex = try! NSRegularExpression(pattern: #"\[([^\[\]\n]+?),\s*(\d{4}-\d{2}-\d{2}),\s*((?:[0-9]{1,3}:)?[0-9]{1,2}:[0-9]{2})\]"#)

    static func parse(_ text: String) -> [Citation] {
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard let sec = Timestamp.seconds(ns.substring(with: m.range(at: 3))) else { return nil }
            return Citation(range: m.range, title: ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces),
                            date: ns.substring(with: m.range(at: 2)), seconds: sec)
        }
    }
}

enum DeepLink {
    case seek(Int)
    case cite(title: String, date: String, seconds: Int)

    static func seekURL(_ sec: Int) -> String { "eav://seek/\(sec)" }

    static func citeURL(_ c: Citation) -> String {
        var u = URLComponents(); u.scheme = "eav"; u.host = "cite"
        u.queryItems = [URLQueryItem(name: "t", value: c.title), URLQueryItem(name: "d", value: c.date), URLQueryItem(name: "s", value: String(c.seconds))]
        // Parentheses would end the markdown link destination early.
        return (u.string ?? "").replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
    }

    init?(_ url: URL) {
        guard url.scheme == "eav" else { return nil }
        if url.host == "seek", let s = Int(url.lastPathComponent) { self = .seek(s); return }
        if url.host == "cite", let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            func v(_ n: String) -> String? { q.first { $0.name == n }?.value }
            if let t = v("t"), let d = v("d"), let s = v("s").flatMap({ Int($0) }) { self = .cite(title: t, date: d, seconds: s); return }
        }
        return nil
    }
}

enum Md {
    /// Backslash-escape what would otherwise be markdown syntax inside link text.
    static func escape(_ s: String) -> String {
        var out = ""
        for ch in s { if "\\[]*_`".contains(ch) { out.append("\\") }; out.append(ch) }
        return out
    }

    /// Rewrites citations and bare timestamps into markdown links to `eav://` URLs (citations first, so the
    /// timestamp inside one is not linked a second time).
    static func linkify(_ md: String, citations: Bool = true) -> String {
        var spans: [(NSRange, String)] = []
        let ns = md as NSString
        if citations {
            for c in Citation.parse(md) {
                spans.append((c.range, "[\(escape(ns.substring(with: c.range)))](\(DeepLink.citeURL(c)))"))
            }
        }
        for t in Timestamp.matches(in: md) where !spans.contains(where: { NSIntersectionRange($0.0, t.range).length > 0 }) {
            spans.append((t.range, "[\(escape(ns.substring(with: t.range)))](\(DeepLink.seekURL(t.seconds)))"))
        }
        var out = md
        for (r, repl) in spans.sorted(by: { $0.0.location > $1.0.location }) {
            out = (out as NSString).replacingCharacters(in: r, with: repl)
        }
        return out
    }

    /// One markdown line -> styled inline text with tappable timestamps/citations.
    static func inline(_ line: String, citations: Bool = true) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: linkify(line, citations: citations), options: opts)) ?? AttributedString(line)
    }
}

/// library.py snippets mark hits with « and ».
func snippetRuns(_ s: String) -> [(text: String, hit: Bool)] {
    var runs: [(String, Bool)] = [], cur = "", hit = false
    for ch in s {
        if ch == "«" || ch == "»" {
            if !cur.isEmpty { runs.append((cur, hit)) }
            cur = ""; hit = ch == "«"
        } else { cur.append(ch) }
    }
    if !cur.isEmpty { runs.append((cur, hit)) }
    return runs
}

/// What the markdown renderer draws: headings, list items (indent in 2-space steps), paragraphs, blank-line gaps.
enum MdBlock: Equatable {
    case heading(Int, String), bullet(Int, String), check(Bool, Int, String), paragraph(String), gap

    static func parse(_ md: String) -> [MdBlock] {
        var out: [MdBlock] = [], para: [String] = []
        func flush() { if !para.isEmpty { out.append(.paragraph(para.joined(separator: " "))); para = [] } }
        for raw in md.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.replacingOccurrences(of: "\t", with: "    ")
            let t = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix { $0 == " " }.count / 2
            if t.isEmpty { flush(); if !out.isEmpty, out.last != .gap { out.append(.gap) }; continue }
            let level = t.prefix { $0 == "#" }.count
            if (1...6).contains(level), t.dropFirst(level).first == " " {
                flush(); out.append(.heading(level, String(t.dropFirst(level + 1)))); continue
            }
            if let mark = ["- ", "* ", "+ "].first(where: t.hasPrefix) {
                flush()
                let body = String(t.dropFirst(mark.count))
                if body.hasPrefix("[ ] ") { out.append(.check(false, indent, String(body.dropFirst(4)))) }
                else if body.hasPrefix("[x] ") || body.hasPrefix("[X] ") { out.append(.check(true, indent, String(body.dropFirst(4)))) }
                else { out.append(.bullet(indent, body)) }
                continue
            }
            para.append(t)
        }
        flush()
        while out.last == .gap { out.removeLast() }
        return out
    }
}
