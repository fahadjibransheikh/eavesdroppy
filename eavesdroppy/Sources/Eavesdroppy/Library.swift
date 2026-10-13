import Foundation
import SQLite3

// Read-only view of <container>/library.db (decision D1: Python owns the schema and every write; see library.py's
// SCHEMA_V1). Foundation + SQLite3 only so it compiles outside the droplet for tests.

struct MeetingSummary: Identifiable, Hashable {
    var id: Int
    var title: String
    var start: String          // ISO 8601 with UTC offset
    var duration: Double
    var source: String
    var template: String
    var summaryStatus: String
    var folder: String?
    var audioPath: String?
    var openActions: Int
    // Search hits only:
    var snippet: String? = nil     // hits marked « »
    var hitTurnIdx: Int? = nil     // nil for a title/notes hit
    var hitTS: String? = nil

    var startDate: Date? { Fmt.parseISO(start) }
}

struct SpeakerRow: Identifiable, Hashable {
    var id: Int
    var track: String?
    var label: String
    var personID: Int?
    var kind: String?
    /// schema v2: the person a voiceprint match (kind "suggest") points at; a hint until the user confirms it.
    var suggestedPersonID: Int? = nil
}

/// A row of the people table: who the user can name a speaker as, or ask about.
struct PersonRow: Identifiable, Hashable {
    var id: Int
    var name: String
    var isMe: Bool
}

struct TurnRow: Identifiable, Hashable {
    var idx: Int
    var speakerID: Int?
    var speaker: String
    var start: Double
    var end: Double
    var text: String
    var id: Int { idx }
}

struct ActionRow: Identifiable, Hashable {
    var id: Int
    var owner: String
    var task: String
    var due: String
    var done: Bool
    var turnIdx: Int?
    var exportedTo: String?
    var externalID: String?
    /// schema v3: the exported item's link (Linear issue URL); nil for older rows and for Reminders.
    var externalURL: String? = nil
}

struct MeetingDetail: Hashable {
    var summary: MeetingSummary
    var attendees: [String]
    var notes: String
    var userNotes: String
    var speakers: [SpeakerRow]
    var turns: [TurnRow]
    var actions: [ActionRow]
}

struct PersonMe: Hashable { var id: Int; var name: String; var samples: Int; var updated: String? }

enum Fmt {
    private static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }()
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    static func parseISO(_ s: String) -> Date? { iso.date(from: s) ?? isoFrac.date(from: s) }

    /// "Today, 2:30 PM", "Yesterday, 11:30 PM", "Mon, 9:00 AM" within the last week, else "12 Oct, 11:30 PM" (with the
    /// year when it is not this one). Locale-aware: a 24-hour locale gets "14:30".
    static func when(_ s: String, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard let d = parseISO(s) else { return s }
        let time = d.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
        let day: String
        if calendar.isDate(d, inSameDayAs: now) { day = "Today" }
        else if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(d, inSameDayAs: y) { day = "Yesterday" }
        else if let w = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)), d >= w, d <= now {
            day = d.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).weekday(.abbreviated))
        } else {
            var f = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).day().month(.abbreviated)
            if !calendar.isDate(d, equalTo: now, toGranularity: .year) { f = f.year() }
            day = d.formatted(f)
        }
        return "\(day), \(time)"
    }
    /// "1h 05m" / "25m" / "—"
    static func length(_ sec: Double) -> String {
        let m = safeInt((sec / 60).rounded())
        return m <= 0 ? "—" : (m >= 60 ? "\(m / 60)h \(String(format: "%02d", m % 60))m" : "\(m)m")
    }
}

struct LibraryError: Error, CustomStringConvertible { let description: String }

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)  // SQLITE_TRANSIENT

enum Library {
    static func dbURL(_ container: URL) -> URL { container.appendingPathComponent("library.db") }

    /// library.fts_query(text, "AND"): every \w+ token (Python's str \w: letters, numbers, underscore), at most 32,
    /// each quoted with prefix matching, joined by AND. Quoting neutralises FTS syntax. "" when there are no tokens.
    static func ftsQuery(_ text: String, maxTerms: Int = 32) -> String {
        func word(_ u: Unicode.Scalar) -> Bool {
            if u == "_" { return true }
            switch u.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber: return true
            default: return false
            }
        }
        var toks: [String] = [], cur = String.UnicodeScalarView()
        for u in text.unicodeScalars {
            if word(u) { cur.append(u) } else if !cur.isEmpty { toks.append(String(cur)); cur = .init() }
        }
        if !cur.isEmpty { toks.append(String(cur)) }
        return toks.prefix(maxTerms).map { "\"\($0)\"*" }.joined(separator: " AND ")
    }
}

/// One read-only connection. Not thread-safe: confine to one queue (LibraryReader does).
final class LibraryDB {
    private var db: OpaquePointer?

    /// nil when the file does not exist yet (no meeting has been processed): callers show the empty state.
    init?(container: URL) throws {
        let url = Library.dbURL(container)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // file:///abs/path?mode=ro, percent-encoded by URL itself (so ? and # in the path cannot end it early).
        let uri = url.absoluteString + "?mode=ro"
        func open() throws {
            guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
                let why = db.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
                sqlite3_close(db); db = nil
                throw LibraryError(description: "could not open library.db: \(why)")
            }
            sqlite3_busy_timeout(db, 5000)
        }
        try open()
        // An idle WAL database has no -shm/-wal (the last writer deleted them on close), and the system SQLite refuses to
        // create them for a read-only connection ("unable to open database file", seen on 3.54). Create them empty
        // (O_CREAT without O_TRUNC, so a live writer's files are never touched) and reopen; SQLite initialises them itself.
        if sqlite3_exec(db, "SELECT 1 FROM sqlite_master LIMIT 1", nil, nil, nil) == SQLITE_CANTOPEN {
            sqlite3_close(db); db = nil
            for ext in ["-shm", "-wal"] { let fd = Darwin.open(url.path + ext, O_CREAT | O_RDWR, 0o644); if fd >= 0 { Darwin.close(fd) } }
            try open()
        }
    }

    deinit { sqlite3_close(db) }

    private enum Arg { case int(Int), text(String) }

    private func rows(_ sql: String, _ args: [Arg] = [], _ each: (OpaquePointer) -> Void) throws {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
            throw LibraryError(description: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(st) }
        for (i, a) in args.enumerated() {
            switch a {
            case .int(let v): sqlite3_bind_int64(st, Int32(i + 1), Int64(v))
            case .text(let v): sqlite3_bind_text(st, Int32(i + 1), v, -1, transient)
            }
        }
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_ROW, let st { each(st) } else if rc == SQLITE_DONE { return }
            else { throw LibraryError(description: String(cString: sqlite3_errmsg(db))) }
        }
    }

    /// Column names of `table`: the reader must work on a v1 or v2 database until a pipeline command migrates it.
    private func columns(_ table: String) -> Set<String> {
        var out = Set<String>()
        try? rows("PRAGMA table_info(\(table))") { if let n = str($0, 1) { out.insert(n) } }
        return out
    }

    // Column readers (NULL -> nil / zero).
    private func str(_ s: OpaquePointer, _ i: Int32) -> String? { sqlite3_column_text(s, i).map { String(cString: $0) } }
    private func int(_ s: OpaquePointer, _ i: Int32) -> Int? { sqlite3_column_type(s, i) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(s, i)) }

    private static let cols = "m.id, m.title, m.start, m.duration, m.source, m.template, m.summary_status, m.folder, m.audio_path,"
        + " (SELECT COUNT(*) FROM action_items a WHERE a.meeting_id = m.id AND a.done = 0)"

    private func summary(_ s: OpaquePointer) -> MeetingSummary {
        MeetingSummary(id: int(s, 0) ?? 0, title: str(s, 1) ?? "", start: str(s, 2) ?? "", duration: sqlite3_column_double(s, 3),
                       source: str(s, 4) ?? "record", template: str(s, 5) ?? "general", summaryStatus: str(s, 6) ?? "none",
                       folder: str(s, 7), audioPath: str(s, 8), openActions: int(s, 9) ?? 0)
    }

    /// Mirrors library.list_meetings: newest first; with a query, meetings with a hit (all words, prefix matched, in a
    /// turn, title, notes or typed notes), best bm25 first, one row per meeting with its best snippet. Ceiling: the
    /// 2000 best hits are ranked.
    func listMeetings(query: String?, limit: Int = 300, offset: Int = 0) throws -> [MeetingSummary] {
        let match = Library.ftsQuery(query ?? "")
        var out: [MeetingSummary] = []
        if match.isEmpty {
            try rows("SELECT \(Self.cols) FROM meetings m ORDER BY m.start DESC, m.id DESC LIMIT ? OFFSET ?", [.int(limit), .int(offset)]) {
                out.append(summary($0))
            }
            return out
        }
        struct Hit { var meetingID: Int; var kind: String; var turnIdx: Int?; var snippet: String }
        var best: [Hit] = [], seen = Set<Int>()
        try rows("SELECT meeting_id, kind, turn_idx, snippet(search, -1, '«', '»', '…', 16) AS snip FROM search"
                 + " WHERE search MATCH ? ORDER BY bm25(search, 1.0, 4.0, 2.0, 3.0) LIMIT 2000", [.text(match)]) { s in
            let mid = int(s, 0) ?? 0
            if seen.insert(mid).inserted { best.append(Hit(meetingID: mid, kind: str(s, 1) ?? "", turnIdx: int(s, 2), snippet: str(s, 3) ?? "")) }
        }
        for h in best.dropFirst(offset).prefix(limit) {
            var m: MeetingSummary?
            try rows("SELECT \(Self.cols) FROM meetings m WHERE m.id = ?", [.int(h.meetingID)]) { m = summary($0) }
            guard var row = m else { continue }
            row.snippet = h.snippet
            if h.kind == "t", let idx = h.turnIdx {
                row.hitTurnIdx = idx
                try rows("SELECT start FROM turns WHERE meeting_id = ? AND idx = ?", [.int(h.meetingID), .int(idx)]) {
                    row.hitTS = Timestamp.format(sqlite3_column_double($0, 0))
                }
            }
            out.append(row)
        }
        return out
    }

    /// Meeting row + speakers + turns + action items (library.get_meeting without embeddings), or nil.
    func meeting(id: Int) throws -> MeetingDetail? {
        var head: (MeetingSummary, String, String, String)?
        try rows("SELECT \(Self.cols), m.attendees, m.notes_md, m.user_notes FROM meetings m WHERE m.id = ?", [.int(id)]) {
            head = (summary($0), str($0, 10) ?? "[]", str($0, 11) ?? "", str($0, 12) ?? "")
        }
        guard let (sum, att, notes, typed) = head else { return nil }
        let attendees = (try? JSONSerialization.jsonObject(with: Data(att.utf8)) as? [String]) ?? []
        var d = MeetingDetail(summary: sum, attendees: attendees, notes: notes, userNotes: typed, speakers: [], turns: [], actions: [])
        let hasSuggested = columns("speakers").contains("suggested_person_id")
        try rows("SELECT id, track, label, person_id, kind, \(hasSuggested ? "suggested_person_id" : "NULL") FROM speakers WHERE meeting_id = ? ORDER BY id", [.int(id)]) {
            d.speakers.append(SpeakerRow(id: int($0, 0) ?? 0, track: str($0, 1), label: str($0, 2) ?? "?", personID: int($0, 3), kind: str($0, 4),
                                         suggestedPersonID: int($0, 5)))
        }
        try rows("SELECT t.idx, t.speaker_id, COALESCE(s.label, '?'), t.start, t.end, t.text FROM turns t"
                 + " LEFT JOIN speakers s ON s.id = t.speaker_id WHERE t.meeting_id = ? ORDER BY t.idx", [.int(id)]) {
            d.turns.append(TurnRow(idx: int($0, 0) ?? 0, speakerID: int($0, 1), speaker: str($0, 2) ?? "?",
                                   start: sqlite3_column_double($0, 3), end: sqlite3_column_double($0, 4), text: str($0, 5) ?? ""))
        }
        let hasURL = columns("action_items").contains("external_url")
        try rows("SELECT id, owner, task, due, done, turn_idx, exported_to, external_id, \(hasURL ? "external_url" : "NULL") FROM action_items WHERE meeting_id = ? ORDER BY id", [.int(id)]) {
            d.actions.append(ActionRow(id: int($0, 0) ?? 0, owner: str($0, 1) ?? "", task: str($0, 2) ?? "", due: str($0, 3) ?? "",
                                       done: (int($0, 4) ?? 0) != 0, turnIdx: int($0, 5), exportedTo: str($0, 6), externalID: str($0, 7),
                                       externalURL: str($0, 8)))
        }
        return d
    }

    /// Everyone in the people table with a name, the user first: the "This is…" and Ask-about pickers.
    func people() throws -> [PersonRow] {
        var out: [PersonRow] = []
        try rows("SELECT id, name, is_me FROM people ORDER BY is_me DESC, name COLLATE NOCASE, id") {
            let name = (str($0, 1) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let id = int($0, 0), !name.isEmpty { out.append(PersonRow(id: id, name: name, isMe: (int($0, 2) ?? 0) != 0)) }
        }
        return out
    }

    /// The enrolled user (people.is_me = 1), if any.
    func me() throws -> PersonMe? {
        var p: PersonMe?
        try rows("SELECT id, name, n, updated FROM people WHERE is_me = 1 ORDER BY id LIMIT 1") {
            p = PersonMe(id: int($0, 0) ?? 0, name: str($0, 1) ?? "Me", samples: int($0, 2) ?? 0, updated: str($0, 3))
        }
        return p
    }

    /// A citation names a meeting by title and local date (YYYY-MM-DD); starts are stored with their own offset.
    func findMeeting(title: String, date: String) throws -> Int? {
        var id: Int?
        try rows("SELECT id FROM meetings WHERE title = ? AND substr(start, 1, 10) = ? ORDER BY id DESC LIMIT 1", [.text(title), .text(date)]) {
            id = int($0, 0)
        }
        if id == nil {  // the model may have shortened or re-cased the title
            try rows("SELECT id FROM meetings WHERE title LIKE ? ESCAPE '\\' AND substr(start, 1, 10) = ? ORDER BY id DESC LIMIT 1",
                     [.text(title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")), .text(date)]) {
                id = int($0, 0)
            }
        }
        return id
    }
}

/// All reads happen here, off the main thread, on one serial queue; each opens its own short-lived connection (cheap,
/// and it can never hold a WAL snapshot open between calls). A missing database or one without tables yet is the
/// empty state, not an error.
final class LibraryReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "eavesdroppy.library.read", qos: .userInitiated)
    private var container: URL
    init(container: URL) { self.container = container }
    func setContainer(_ c: URL) { queue.sync { container = c } }

    /// Runs `work` on the queue, then `done` on the main queue.
    func read<T>(empty: T, _ work: @escaping (LibraryDB) throws -> T, done: @escaping (Result<T, Error>) -> Void) {
        queue.async {
            let r: Result<T, Error>
            do { r = .success(try LibraryDB(container: self.container).map(work) ?? empty) }
            catch let e as LibraryError where e.description.contains("no such table") { r = .success(empty) }
            catch { r = .failure(error) }
            DispatchQueue.main.async { done(r) }
        }
    }
}
