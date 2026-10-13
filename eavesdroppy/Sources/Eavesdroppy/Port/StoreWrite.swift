import Foundation

// The library.py writes the processor needs and StoreLibrary did not have: add_meeting, set_notes, set_pending_folder,
// the notes input (get_meeting), the people table, and import_existing_drive_meetings with its transcript.md parser.

/// datetime.fromisoformat / isoformat(timespec="seconds") for the shapes meta.json and the library use.
enum StoreDates {
    private static let re = try! NSRegularExpression(pattern: #"^(\d{4})-(\d\d)-(\d\d)(?:[T ](\d\d):(\d\d)(?::(\d\d)(?:[.,]\d+)?)?)?(Z|[+-]\d\d(?::?\d\d(?::?\d\d)?)?)?$"#)

    struct Parsed { var iso: String; var hasOffset: Bool }

    /// "2026-10-13T12:35:45+05:00" -> same; "...Z" -> "+00:00"; fractions dropped; a naive time gets this Mac's offset
    /// (Python's `astimezone()`). Throws Python's ValueError text for anything else.
    static func parse(_ s: String) throws -> Parsed {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else {
            throw StoreCrash(kind: "ValueError", message: "Invalid isoformat string: '\(s)'")
        }
        func g(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
        let base = "\(g(1)!)-\(g(2)!)-\(g(3)!)T\(g(4) ?? "00"):\(g(5) ?? "00"):\(g(6) ?? "00")"
        guard let off = g(7) else {
            let c = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .current, year: Int(g(1)!), month: Int(g(2)!), day: Int(g(3)!),
                                   hour: Int(g(4) ?? "0"), minute: Int(g(5) ?? "0"), second: Int(g(6) ?? "0"))
            let secs = (c.date.map { TimeZone.current.secondsFromGMT(for: $0) }) ?? TimeZone.current.secondsFromGMT()
            let sign = secs < 0 ? "-" : "+", a = abs(secs)
            return Parsed(iso: base + String(format: "%@%02d:%02d", sign, a / 3600, a % 3600 / 60), hasOffset: false)
        }
        if off == "Z" { return Parsed(iso: base + "+00:00", hasOffset: true) }
        let d = off.dropFirst().replacingOccurrences(of: ":", with: "")
        return Parsed(iso: base + "\(off.first!)\(d.prefix(2)):\(d.count >= 4 ? String(d.dropFirst(2).prefix(2)) : "00")", hasOffset: true)
    }

    /// library._norm_start
    static func normStart(_ s: String) throws -> String { try parse(s).iso }
}

struct NewMeeting {
    var title: String, start: String
    var duration = 0.0, source = "record", folder: String? = nil, audioPath: String? = nil, rawDir: String? = nil
    var template = "general", attendees: [String] = [], userNotes = "", notesMD = "", summaryStatus: String? = nil, bleed = false
}

struct NewSpeaker {
    var label: String
    var track: String? = nil, cluster: String? = nil
    var personID: Int? = nil, suggestedPersonID: Int? = nil, score: Double? = nil, kind: String? = nil, embedding: Data? = nil
}

struct NewTurn { var speaker: Int; var start: Double; var end: Double; var text: String }

/// What generate_and_store reads from library.get_meeting.
struct StoredMeeting {
    var notes: NotesMeeting
    var attendees: [String]
    var summaryStatus: String
}

extension StoreLibrary {
    /// library.add_meeting: a meeting with its speakers, turns and action items in ONE transaction. Returns the meeting id.
    /// `turns[i].speaker` indexes `speakers`.
    static func addMeeting(_ db: StoreDB, _ m: NewMeeting, speakers: [NewSpeaker] = [], turns: [NewTurn] = [], actions: [NoteAction] = []) throws -> Int {
        if m.title.isEmpty || m.start.isEmpty { throw StoreError("meeting needs title and start") }
        let now = StoreClock.now(), start = try StoreDates.normStart(m.start)
        return try db.tx {
            try db.run("INSERT INTO meetings(title, start, duration, source, folder, audio_path, raw_dir, template, attendees,"
                       + " user_notes, notes_md, summary_status, bleed, created, updated) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                       [m.title, start, m.duration, m.source, m.folder, m.audioPath, m.rawDir, m.template.isEmpty ? "general" : m.template,
                        Voiceprints.jsonDumps(m.attendees), m.userNotes, m.notesMD,
                        m.summaryStatus.flatMap { $0.isEmpty ? nil : $0 } ?? (m.notesMD.isEmpty ? "none" : "ok"), m.bleed ? 1 : 0, now, now])
            let mid = db.lastInsertID
            var ids: [Int] = []
            for s in speakers {
                try db.run("INSERT INTO speakers(meeting_id, track, cluster, label, person_id, suggested_person_id, score, kind, embedding)"
                           + " VALUES (?,?,?,?,?,?,?,?,?)",
                           [mid, s.track, s.cluster, s.label, s.personID, s.suggestedPersonID, s.score, s.kind, s.embedding])
                ids.append(db.lastInsertID)
            }
            for (idx, t) in turns.enumerated() {
                guard ids.indices.contains(t.speaker) else { throw StoreError("turn \(idx): speaker index \(t.speaker) out of range") }
                try db.run("INSERT INTO turns(meeting_id, idx, speaker_id, start, end, text) VALUES (?,?,?,?,?,?)", [mid, idx, ids[t.speaker], t.start, t.end, t.text])
            }
            for a in actions { try insertAction(db, mid, a, nil) }
            return mid
        }
    }

    private struct Exported { var to: String?, id: String?, url: String? }

    private static func insertAction(_ db: StoreDB, _ mid: Int, _ a: NoteAction, _ prev: (done: Int, exp: (String?, String?, String?))?) throws {
        try db.run("INSERT INTO action_items(meeting_id, owner, task, due, done, turn_idx, exported_to, external_id, external_url) VALUES (?,?,?,?,?,?,?,?,?)",
                   [mid, a.owner, a.task, a.due, prev?.done ?? (a.done != 0 ? 1 : 0), a.turnIdx, prev?.exp.0, prev?.exp.1, prev?.exp.2])
    }

    /// library.set_notes. `actions` nil leaves the action items alone; a list REPLACES them, keeping done / exported state for
    /// items whose (owner, task) is unchanged (case-insensitive), so regenerating does not un-tick anything.
    static func setNotes(_ db: StoreDB, _ id: Int, notesMD: String, actions: [NoteAction]?, status: String = "ok", template: String? = nil) throws {
        try db.tx {
            var cols: [(String, Any?)] = [("notes_md", notesMD), ("summary_status", status)]
            if let t = template, !t.isEmpty { cols.append(("template", t)) }
            try touch(db, id, cols)
            guard let actions else { return }
            struct Key: Hashable { var owner: String, task: String }
            var old: [Key: (done: Int, exp: (String?, String?, String?))] = [:]
            for r in try db.rows("SELECT owner, task, done, exported_to, external_id, external_url FROM action_items WHERE meeting_id = ? ORDER BY id", [id]) {
                old[Key(owner: (r.text(0) ?? "").lowercased(), task: (r.text(1) ?? "").lowercased())] = (r.int(2) ?? 0, (r.text(3), r.text(4), r.text(5)))
            }
            try db.run("DELETE FROM action_items WHERE meeting_id = ?", [id])
            for a in actions { try insertAction(db, id, a, old[Key(owner: a.owner.lowercased(), task: a.task.lowercased())]) }
        }
    }

    /// library.set_pending_folder: the output folder about to be renamed into place (processing only).
    static func setPendingFolder(_ db: StoreDB, _ id: Int, _ path: String) throws {
        try db.tx { try touch(db, id, [("pending_folder", path)]) }
    }

    /// library.get_meeting, as generate_and_store uses it: the notes prompt input plus attendees and summary status.
    static func storedMeeting(_ db: StoreDB, _ id: Int) throws -> StoredMeeting? {
        guard let m = try meeting(db, id),
              let r = try db.rows("SELECT user_notes, template, summary_status FROM meetings WHERE id = ?", [id]).first else { return nil }
        let turns = try db.rows("SELECT t.idx, COALESCE(s.label, '?'), t.start, t.text FROM turns t LEFT JOIN speakers s ON s.id = t.speaker_id"
                                + " WHERE t.meeting_id = ? ORDER BY t.idx", [id])
            .map { NoteTurn(idx: $0.int(0) ?? 0, speaker: $0.text(1) ?? "?", start: $0.double(2) ?? 0, text: $0.text(3) ?? "") }
        return StoredMeeting(notes: NotesMeeting(header: try StoreMirror.header(m), turns: turns, userNotes: r.text(0) ?? "", template: r.text(1)),
                             attendees: m.attendees, summaryStatus: r.text(2) ?? "none")
    }
}

/// The `people` table as `Voiceprints.Person`s (id order; a NULL name reads as "", the Voiceprints contract).
enum StorePeople {
    static func load(_ db: StoreDB) throws -> [Voiceprints.Person] {
        try db.rows("SELECT id, name, email, is_me, voiceprint, n FROM people ORDER BY id").map { r in
            Voiceprints.Person(id: r.int(0) ?? 0, name: r.text(1) ?? "", email: r.text(2), isMe: (r.int(3) ?? 0) != 0,
                               voiceprint: r.data(4).flatMap { try? StoreVoiceprint.vec($0) }, n: r.int(5) ?? 0)
        }
    }
}

// MARK: - import-drive (library.import_existing_drive_meetings)

enum StoreImport {
    private static func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: .anchorsMatchLines) }
    private static let dateRE = rx(#"^- \*\*Date:\*\* (\d{4}-\d\d-\d\d) (\d\d:\d\d) \(UTC([+-]\d\d:\d\d)\)\s*$"#)
    private static let durRE = rx(#"^- \*\*Duration:\*\* (\d+(?::\d\d){1,2})\s*$"#)
    private static let attRE = rx(#"^- \*\*Attendees:\*\* (.*)$"#)
    private static let turnRE = rx(#"^\*\*\[(\d+(?::\d\d){1,2})\] (.+?):\*\* ?(.*)$"#)

    private static func first(_ re: NSRegularExpression, _ s: String) -> (NSTextCheckingResult, NSString)? {
        let ns = s as NSString
        return re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)).map { ($0, ns) }
    }

    /// library.parse_ts: '03:41' / '1:03:41' -> seconds.
    static func parseTS(_ s: String) -> Double { Double(s.split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) }) }

    struct ParsedTurn { var speaker: String; var start: Double; var text: String; var end = 0.0 }

    /// library._parse_turns
    static func parseTurns(_ body: String) -> [ParsedTurn] {
        var turns: [ParsedTurn] = []
        for sub in body.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
            let line = String(sub), stripped = PyText.strip(line)
            if stripped.isEmpty || stripped == StoreMirror.noSpeech { continue }
            let ns = line as NSString
            if let m = turnRE.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                turns.append(ParsedTurn(speaker: ns.substring(with: m.range(at: 2)), start: parseTS(ns.substring(with: m.range(at: 1))),
                                        text: PyText.strip(ns.substring(with: m.range(at: 3)))))
            } else if !turns.isEmpty {
                turns[turns.count - 1].text += " " + stripped
            }
        }
        return turns
    }

    /// library.parse_transcript_md: (title, start, duration, attendees, turns).
    static func parseTranscript(_ text: String) throws -> (title: String, start: String, duration: Double, attendees: [String], turns: [ParsedTurn]) {
        let head: String, body: String
        if let r = text.range(of: StoreMirror.sep) { head = String(text[..<r.lowerBound]); body = String(text[r.upperBound...]) } else { head = text; body = "" }
        let header = PyText.strip(head)
        let firstLine = header.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }).first.map(String.init) ?? ""
        let title = PyText.strip(String(firstLine.drop { $0 == "#" || $0 == " " }))
        guard !title.isEmpty, let (d, ns) = first(dateRE, header) else { throw StoreError("no title/date in header") }
        let start = try StoreDates.normStart("\(ns.substring(with: d.range(at: 1)))T\(ns.substring(with: d.range(at: 2))):00\(ns.substring(with: d.range(at: 3)))")
        let dur = first(durRE, header).map { parseTS($0.1.substring(with: $0.0.range(at: 1))) } ?? 0.0
        var attendees: [String] = []
        if let (a, ans) = first(attRE, header) {
            let raw = ans.substring(with: a.range(at: 1))
            if PyText.strip(raw) != "—" { attendees = raw.split(separator: ",", omittingEmptySubsequences: false).map { PyText.strip(String($0)) }.filter { !$0.isEmpty } }
        }
        return (title, start, dur, attendees, parseTurns(body))
    }

    private static func pySorted(_ names: [String]) -> [String] {
        names.sorted { Array($0.unicodeScalars.map(\.value)).lexicographicallyPrecedes(Array($1.unicodeScalars.map(\.value))) }
    }

    /// Import every <outRoot>/<folder>/ that has transcript.md (or notes.md) and is not yet in the library. Idempotent (keyed on the
    /// folder path). Never writes to the output folder.
    static func importExisting(_ db: StoreDB, outRoot: String) throws -> (imported: [Int], skipped: Int, failed: [(String, String)]) {
        var imported: [Int] = [], skipped = 0, failed: [(String, String)] = []
        let root = PyPath.abspath(outRoot), fm = FileManager.default
        guard PyPath.isDir(root) else { return (imported, skipped, failed) }
        let known = Set(try db.rows("SELECT folder FROM meetings WHERE folder IS NOT NULL").compactMap { $0.text(0) })
        let names = pySorted(((try? fm.contentsOfDirectory(atPath: root)) ?? []).filter { !$0.hasPrefix(".") && PyPath.isDir(PyPath.join(root, $0)) })
        for name in names {
            let f = PyPath.join(root, name), tm = f + "/transcript.md", nm = f + "/notes.md"
            if known.contains(f) { skipped += 1; continue }
            let hasT = PyPath.exists(tm) && !PyPath.isDir(tm), hasN = PyPath.exists(nm) && !PyPath.isDir(nm)
            if !hasT && !hasN { continue }
            do {
                let ntext = hasN ? try String(contentsOfFile: nm, encoding: .utf8) : ""
                let att = first(attRE, ntext)
                var head = ntext, nbody = ""
                if let r = ntext.range(of: "\n## Transcript") { head = String(ntext[..<r.lowerBound]); nbody = String(ntext[r.upperBound...]) }
                let notesMD: String
                if let (a, _) = att {  // head[att.end():].strip(); att.end() is an offset in `ntext`, which `head` is a prefix of
                    let end = a.range.location + a.range.length
                    notesMD = PyText.strip(end <= (head as NSString).length ? (head as NSString).substring(from: end) : "")
                } else { notesMD = "" }
                let status = notesMD.contains("Summary failed") ? "failed" : (notesMD.isEmpty ? "none" : "ok")
                var parsed: (title: String, start: String, duration: Double, attendees: [String], turns: [ParsedTurn])
                if hasT {
                    parsed = try parseTranscript(try String(contentsOfFile: tm, encoding: .utf8))
                } else {  // notes.md only: header from it, turns from after "## Transcript"
                    let cut = att.map { $0.0.range.location + $0.0.range.length } ?? 0
                    let p = try parseTranscript((head as NSString).substring(to: min(cut, (head as NSString).length)) + StoreMirror.sep)
                    parsed = (p.title, p.start, p.duration, p.attendees, parseTurns(nbody))
                }
                for i in parsed.turns.indices {  // end = next turn's start (last = meeting end)
                    parsed.turns[i].end = i + 1 < parsed.turns.count ? parsed.turns[i + 1].start : max(parsed.duration, parsed.turns[i].start)
                }
                var labels: [String] = []
                for t in parsed.turns where !labels.contains(t.speaker) { labels.append(t.speaker) }
                let kinds = ["Me": ("mic", "me"), "Them": ("system", "remote"), "Room": ("mic", "room")]
                let spk = labels.map { NewSpeaker(label: $0, track: kinds[$0]?.0, kind: kinds[$0]?.1 ?? "other") }
                let turns = parsed.turns.map { NewTurn(speaker: labels.firstIndex(of: $0.speaker)!, start: $0.start, end: $0.end, text: $0.text) }
                let audio = pySorted(((try? fm.contentsOfDirectory(atPath: f)) ?? []).filter { $0.hasSuffix(".m4a") }).first
                let actions = notesMD.split(whereSeparator: { $0.isNewline }).compactMap { NotesPrompt.parseActionLine(String($0)) }
                let mid = try StoreLibrary.addMeeting(db, NewMeeting(
                    title: parsed.title, start: parsed.start, duration: parsed.duration, source: labels.contains("Room") ? "import" : "record",
                    folder: f, audioPath: audio.map { f + "/" + $0 }, attendees: parsed.attendees, notesMD: notesMD, summaryStatus: status),
                    speakers: spk, turns: turns, actions: actions)
                imported.append(mid)
            } catch is CancellationError {
                throw CancellationError()
            } catch let e as StoreError { failed.append((f, e.description))
            } catch let e as StoreCrash { failed.append((f, e.message))
            } catch { failed.append((f, error.localizedDescription)) }
        }
        return (imported, skipped, failed)
    }
}
