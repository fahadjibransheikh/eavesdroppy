import Foundation

// Port of process_meeting.py's pure logic: build_turns, align_words and the DB/subprocess-free part of assemble.
// Python dicts are insertion-ordered and that order decides ties, so every "dict" here is an array of pairs.

/// Python `round(x, nd)` / `format(x, ".{nd}f")`: printf rounds the exact binary value, as Python does.
enum PyRound {
    static func round(_ x: Double, _ nd: Int) -> Double {
        guard x.isFinite else { return x }
        return Double(String(format: "%.\(nd)f", x)) ?? x
    }
}

enum Turns {
    struct Word: Equatable { var text: String; var start: Double; var end: Double }
    struct Turn: Equatable { var speaker: Int; var start: Double; var end: Double; var text: String }

    static let gap = 1.0
    static let maxWordS = 1.2  // Parakeet word ends often run on to the next word's start; no real word is held longer
    static let turnGap = 8.0  // same-speaker utterances further apart than this start a new turn
    static let turnMax = 30.0  // ...and no merged turn spans longer than this
    static let uttSplit = 20.0, uttMax = 40.0  // gapless speech splits at the first sentence end past uttSplit s, regardless past uttMax s
    static let fallbackKind = ["Me": Voiceprints.Kind.me, "Them": .remote, "Room": .room]

    /// Stable sort (Python's `sorted`): ties keep input order.
    static func stableSorted<T>(_ a: [T], by key: (T) -> Double) -> [T] {
        a.enumerated().sorted { (key($0.element), $0.offset) < (key($1.element), $1.offset) }.map(\.element)
    }

    /// tracks: (speaker, words) in dict order; offsets: seconds per speaker.
    static func build(_ tracks: [(speaker: Int, words: [Word])], offsets: [Int: Double] = [:]) -> [Turn] {
        struct Utt { var speaker: Int; var start: Double; var end: Double; var words: [String] }
        var utts: [Utt] = []
        for (spk, words) in tracks {
            let off = offsets[spk] ?? 0.0
            var cur: Int?
            for w in stableSorted(words, by: \.start) {
                let s = w.start + off, e = w.end + off
                var split = true
                if let c = cur {
                    let span = utts[c].end - utts[c].start
                    let sentenceEnd = utts[c].words.last?.unicodeScalars.last.map { ".?!".unicodeScalars.contains($0) } ?? false
                    split = s - utts[c].end > gap || span >= uttMax || (span >= uttSplit && sentenceEnd)
                }
                if split { utts.append(Utt(speaker: spk, start: s, end: e, words: [])); cur = utts.count - 1 }
                let c = cur!
                utts[c].words.append(w.text)
                utts[c].end = max(utts[c].end, e)
            }
        }
        var turns: [Turn] = []
        for u in stableSorted(utts, by: \.start) {
            let text = u.words.joined(separator: " ")
            if let last = turns.last, last.speaker == u.speaker, u.start - last.end <= turnGap,
               max(last.end, u.end) - last.start <= turnMax {
                turns[turns.count - 1].text += " " + text
                turns[turns.count - 1].end = max(last.end, u.end)
            } else {
                turns.append(Turn(speaker: u.speaker, start: u.start, end: u.end, text: text))
            }
        }
        return turns
    }

    // ---------- align_words ----------

    /// re.sub(r"\W", "", w).lower(): keep Unicode letters, numbers and "_".
    static func alignKey(_ w: String) -> String {
        var out = String.UnicodeScalarView()
        for s in w.unicodeScalars {
            switch s.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: out.append(s)
            default: if s.properties.numericType != nil || s == "_" { out.append(s) }
            }
        }
        return String(out).lowercased()
    }

    /// Custom vocab rewrites `text` but leaves word timings raw; map text tokens back onto the timings.
    /// Word ends are clamped first (maxWordS): a pause belongs to the gap between words, or `build` never sees it.
    static func align(_ rawIn: [(word: String, start: Double, end: Double)], _ text: String) -> [Word] {
        let raw = rawIn.enumerated().map { i, r in
            (word: r.word, start: r.start, end: max(r.start, min(r.end, r.start + maxWordS, i + 1 < rawIn.count ? rawIn[i + 1].start : r.end)))
        }
        let toks = text.split(whereSeparator: \.isWhitespace).map(String.init), words0 = raw.map { alignKey($0.word) }
        var words: [Word] = []
        for op in SequenceMatcher(words0, toks.map(alignKey)).opcodes() {
            let (a0, a1, b0, b1) = (op.a0, op.a1, op.b0, op.b1)
            if op.tag == .equal {
                for i in 0..<(a1 - a0) { words.append(Word(text: toks[b0 + i], start: raw[a0 + i].start, end: raw[a0 + i].end)) }
            } else if b1 > b0 && a1 > a0 {  // replaced span: spread the new tokens over the old span's time range
                let s = raw[a0].start, e = raw[a1 - 1].end, n = Double(b1 - b0)
                for i in 0..<(b1 - b0) {
                    words.append(Word(text: toks[b0 + i], start: s + (e - s) * Double(i) / n, end: s + (e - s) * Double(i + 1) / n))
                }
            } else if b1 > b0 {  // pure insertion: zero-width at the previous word
                let t = words.last?.end ?? raw.first?.start ?? 0.0
                for i in 0..<(b1 - b0) { words.append(Word(text: toks[b0 + i], start: t, end: t)) }
            }
        }
        return words
    }

    // ---------- assemble (pure part) ----------

    struct Assembled {
        var recs: [Voiceprints.Rec]
        var turns: [Turn]
        var candidates: [String]  // attendees + call participants minus the user: the allowed names for the reply
        var prompt: String  // "" = nothing to ask; otherwise send to the notes provider, then call `applyNaming`
    }

    /// "[mm:ss] text" lines per cluster key, for the naming prompt.
    static func namingSnippets(_ recs: [Voiceprints.Rec], _ turns: [Turn], n: Int = 10, chars: Int = 240) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for t in turns {
            let key = Voiceprints.clusterKey(recs[t.speaker])
            guard (out[key]?.count ?? 0) < n else { continue }
            let body = String(String.UnicodeScalarView(t.text.unicodeScalars.prefix(chars)))
            out[key, default: []].append("[\(Timestamp.format(t.start))] \(body)")
        }
        return out
    }

    /// Lowercase names/emails that identify the user: their configured name plus the enrolled Me person(s).
    static func ownNames(_ people: [Voiceprints.Person], userName: String) -> Set<String> {
        let norm = { (x: String) in x.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        var names: Set<String> = [norm(userName)]
        for p in people where p.isMe {
            for x in [p.name, p.email ?? ""] where !x.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { names.insert(norm(x)) }
        }
        names.remove("me")
        return names
    }

    /// Attendees minus the user: a full-name or email match, or a bare first name equal to the first name of a known name.
    static func dropUser(_ attendees: [String], _ names: Set<String>) -> [String] {
        let firsts = Set(names.compactMap { n in n.contains("@") ? nil : n.split(separator: " ").first.map(String.init) })
        return attendees.filter { a in
            let low = a.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return !names.contains(low) && !firsts.contains(low)
        }
    }

    /// Words + diarization -> speaker records, turns and the naming prompt. wordsByTrack in dict order;
    /// diarByTrack has no entry for a track whose diarization failed; offsets/labels per track (labels = the
    /// one-speaker-per-track fallback names). Turn `speaker` is an index into the returned records.
    /// `userName` is already resolved (--user-name, meta user_name, else "Fahad"). The notes-provider call and the
    /// warning on its failure belong to the caller. Divergence: a track without a `labels` entry is labelled by its
    /// name (Python raises KeyError).
    static func assemble(wordsByTrack: [(track: String, words: [Word])], diarByTrack: [String: Voiceprints.Diarization],
                         people: [Voiceprints.Person], attendees: [String], source: String, bleed: Bool,
                         offsets: [String: Double], labels: [String: String], participants: [String] = [],
                         autoNaming: Bool = true, userName: String, inPerson: Bool = false) -> Assembled {
        var mapped: [(track: String, words: [Word], speakers: [String?])] = []
        var kept: [String: Voiceprints.Diarization] = [:]
        for (track, words) in wordsByTrack {
            if let d = diarByTrack[track] {
                let sp = Voiceprints.wordsToSpeakers(words, d.segments)
                mapped.append((track, words, sp))
                let used = Set(sp.compactMap { $0 }).intersection(d.embeddings.map(\.cluster))  // only clusters that own words become speakers
                if !used.isEmpty {
                    kept[track] = Voiceprints.Diarization(segments: d.segments.filter { used.contains($0.cluster) },
                                                          embeddings: d.embeddings.filter { used.contains($0.cluster) })
                }
            } else {
                mapped.append((track, words, words.map { _ in nil }))
            }
        }
        var people = people
        var recs = Voiceprints.assignSpeakers(kept, people: &people, source: source, bleed: bleed, update: false, inPerson: inPerson)
        struct Key: Hashable { var track: String; var cluster: String? }
        var index: [Key: Int] = [:]
        for (i, r) in recs.enumerated() { index[Key(track: r.track, cluster: r.clusterID)] = i }

        func home(_ track: String, _ cid: String?) -> Int {
            if let i = index[Key(track: track, cluster: cid)] { return i }
            if let i = index[Key(track: track, cluster: nil)] { return i }
            let label = labels[track] ?? track
            index[Key(track: track, cluster: nil)] = recs.count
            recs.append(Voiceprints.Rec(track: track, clusterID: nil, label: label, personID: nil, score: 0.0,
                                        kind: fallbackKind[label] ?? .other, embedding: nil, speechS: 0.0))
            return recs.count - 1
        }

        var order: [Int] = [], byRec: [Int: [Word]] = [:]
        for m in mapped {
            for (w, sp) in zip(m.words, m.speakers) {
                let h = home(m.track, sp)
                if byRec[h] == nil { order.append(h) }
                byRec[h, default: []].append(w)
            }
        }
        let turns = build(order.map { (speaker: $0, words: byRec[$0]!) }, offsets: Dictionary(uniqueKeysWithValues: order.map { ($0, offsets[recs[$0].track] ?? 0.0) }))

        // call-app participant names are candidates too, never ground truth
        var seen = Set<String>(), pool: [String] = []
        for n in attendees + participants {
            let t = n.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty && seen.insert(t.lowercased()).inserted { pool.append(t) }
        }
        let cands = dropUser(pool, ownNames(people, userName: userName))
        let prompt = autoNaming ? Voiceprints.buildNamingPrompt(recs, attendees: cands, snippets: namingSnippets(recs, turns)) : ""
        return Assembled(recs: recs, turns: turns, candidates: cands, prompt: prompt)
    }

    /// Provider reply -> records with the names applied (the Python `apply_names(recs, parse_naming_reply(...))`).
    static func applyNaming(_ recs: [Voiceprints.Rec], reply: String, allowed: [String]) -> [Voiceprints.Rec] {
        Voiceprints.applyNames(recs, Voiceprints.parseNamingReply(reply, allowed: allowed))
    }
}

// ---------- difflib.SequenceMatcher (isjunk=None, autojunk=False) ----------

/// Line-for-line port of difflib's find_longest_match / get_matching_blocks / get_opcodes. Not
/// CollectionDifference: Myers picks different matches on ambiguous input, and the timings follow the matches.
struct SequenceMatcher {
    enum Tag { case equal, replace, delete, insert }
    struct Op { var tag: Tag; var a0: Int, a1: Int, b0: Int, b1: Int }
    private let a: [String], b: [String]
    private var b2j: [String: [Int]] = [:]

    init(_ a: [String], _ b: [String]) {
        self.a = a; self.b = b
        for (i, e) in b.enumerated() { b2j[e, default: []].append(i) }
    }

    func longestMatch(_ alo: Int, _ ahi: Int, _ blo: Int, _ bhi: Int) -> (i: Int, j: Int, k: Int) {
        var (besti, bestj, bestsize) = (alo, blo, 0)
        var j2len: [Int: Int] = [:]
        for i in alo..<max(alo, ahi) {
            var newj2len: [Int: Int] = [:]
            for j in b2j[a[i]] ?? [] {
                if j < blo { continue }
                if j >= bhi { break }
                let k = (j2len[j - 1] ?? 0) + 1
                newj2len[j] = k
                if k > bestsize { (besti, bestj, bestsize) = (i - k + 1, j - k + 1, k) }
            }
            j2len = newj2len
        }
        // no junk, so difflib's junk-extension loops reduce to extending over equal neighbours
        while besti > alo && bestj > blo && a[besti - 1] == b[bestj - 1] { besti -= 1; bestj -= 1; bestsize += 1 }
        while besti + bestsize < ahi && bestj + bestsize < bhi && a[besti + bestsize] == b[bestj + bestsize] { bestsize += 1 }
        return (besti, bestj, bestsize)
    }

    func matchingBlocks() -> [(i: Int, j: Int, k: Int)] {
        let la = a.count, lb = b.count
        var queue = [(0, la, 0, lb)], blocks: [(i: Int, j: Int, k: Int)] = []
        while let (alo, ahi, blo, bhi) = queue.popLast() {
            let x = longestMatch(alo, ahi, blo, bhi)
            if x.k > 0 {
                blocks.append(x)
                if alo < x.i && blo < x.j { queue.append((alo, x.i, blo, x.j)) }
                if x.i + x.k < ahi && x.j + x.k < bhi { queue.append((x.i + x.k, ahi, x.j + x.k, bhi)) }
            }
        }
        blocks.sort { ($0.i, $0.j, $0.k) < ($1.i, $1.j, $1.k) }
        var (i1, j1, k1) = (0, 0, 0), out: [(i: Int, j: Int, k: Int)] = []
        for (i2, j2, k2) in blocks {
            if i1 + k1 == i2 && j1 + k1 == j2 { k1 += k2 } else {
                if k1 > 0 { out.append((i1, j1, k1)) }
                (i1, j1, k1) = (i2, j2, k2)
            }
        }
        if k1 > 0 { out.append((i1, j1, k1)) }
        out.append((la, lb, 0))
        return out
    }

    func opcodes() -> [Op] {
        var (i, j) = (0, 0), out: [Op] = []
        for (ai, bj, size) in matchingBlocks() {
            var tag: Tag?
            if i < ai && j < bj { tag = .replace } else if i < ai { tag = .delete } else if j < bj { tag = .insert }
            if let tag { out.append(Op(tag: tag, a0: i, a1: ai, b0: j, b1: bj)) }
            (i, j) = (ai + size, bj + size)
            if size > 0 { out.append(Op(tag: .equal, a0: i - size, a1: i, b0: j - size, b1: j)) }
        }
        return out
    }
}
