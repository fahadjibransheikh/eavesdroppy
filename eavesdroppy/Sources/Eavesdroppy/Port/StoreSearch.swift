import Foundation

// FTS retrieval for Ask (notes.retrieve, D14): the rows that feed the prompt. The Ask prompt and the model call are the notes area's.

enum StoreScope { case meeting(Int), person(Int) }

struct StoreSegment: Equatable { var meetingID: Int, title: String, date: String, ts: String, speaker: String, text: String }
struct StoreNoteExcerpt: Equatable { var meetingID: Int, title: String, date: String, notes: String }

enum StoreSearch {
    static let stop: Set<String> = Set(("a an the and or but of to in on at for with from by is are was were be been it its this that these those i me my we our "
        + "you your he she they them what which who whom how when where why did do does done have has had about any all can could "
        + "would should will just not no yes so if then than there here as into out up over after before again").split(separator: " ").map(String.init))

    /// \w+ tokens (Python's \w, as Library.ftsQuery tokenises).
    static func tokens(_ text: String) -> [String] {
        let q = Library.ftsQuery(text, maxTerms: .max)
        return q.isEmpty ? [] : String(q.dropFirst().dropLast(2)).components(separatedBy: "\"* AND \"")
    }

    /// library.fts_query(text, "OR"): every \w+ token quoted with prefix matching, joined by OR; "" if none.
    static func ftsQueryOR(_ text: String) -> String {
        Library.ftsQuery(text).replacingOccurrences(of: "\"* AND \"", with: "\"* OR \"")
    }

    /// scope: nil = everything, a meeting, or the meetings a person spoke in. Returns the k best-matching turns and the notes
    /// excerpts of the best meetings; with no usable search words, the newest meetings' notes.
    static func retrieve(_ db: StoreDB, question: String, scope: StoreScope? = nil, k: Int = 40, notesLimit: Int = 5, notesChars: Int = 3000)
        throws -> (segments: [StoreSegment], notes: [StoreNoteExcerpt]) {
        let q = ftsQueryOR(tokens(question).filter { !stop.contains($0.lowercased()) && $0.unicodeScalars.count > 1 }.joined(separator: " "))
        var `where` = "", mwhere = "", args: [Any?] = []
        switch scope {
        case .meeting(let id): `where` = " AND meeting_id = ?"; mwhere = " AND id = ?"; args = [id]
        case .person(let id):
            let sub = " IN (SELECT meeting_id FROM speakers WHERE person_id = ?)"
            `where` = " AND meeting_id" + sub; mwhere = " AND id" + sub; args = [id]
        case nil: break
        }
        var segments: [StoreSegment] = [], order: [Int] = []
        if !q.isEmpty {
            let rows = try db.rows("SELECT meeting_id, kind, turn_idx FROM search WHERE search MATCH ?" + `where`
                                   + " ORDER BY bm25(search, 1.0, 4.0, 2.0, 3.0) LIMIT 400", [q] + args)
            for r in rows { if let m = r.int(0), !order.contains(m) { order.append(m) } }
            for r in rows.filter({ $0.text(1) == "t" }).prefix(k) {
                guard let mid = r.int(0), let t = try db.rows(
                    "SELECT m.title, m.start, t.start AS ts, t.text, COALESCE(s.label, '?') AS speaker FROM turns t"
                    + " JOIN meetings m ON m.id = t.meeting_id LEFT JOIN speakers s ON s.id = t.speaker_id"
                    + " WHERE t.meeting_id = ? AND t.idx = ?", [mid, r.int(2)]).first else { continue }
                segments.append(StoreSegment(meetingID: mid, title: t.text(0) ?? "", date: PyText.prefix(t.text(1) ?? "", 10),
                                             ts: StoreMirror.fmtTS(t.double(2) ?? 0), speaker: t.text(4) ?? "?", text: t.text(3) ?? ""))
            }
        }
        if order.isEmpty {  // nothing matched or nothing to search for: the newest meetings in scope
            order = try db.rows("SELECT id FROM meetings WHERE 1=1" + mwhere + " ORDER BY start DESC LIMIT 3", args).compactMap { $0.int(0) }
        }
        var notes: [StoreNoteExcerpt] = []
        for mid in order.prefix(notesLimit) {
            guard let m = try db.rows("SELECT title, start, notes_md FROM meetings WHERE id = ?", [mid]).first,
                  !PyText.strip(m.text(2) ?? "").isEmpty else { continue }
            notes.append(StoreNoteExcerpt(meetingID: mid, title: m.text(0) ?? "", date: PyText.prefix(m.text(1) ?? "", 10),
                                          notes: PyText.prefix(m.text(2) ?? "", notesChars)))
        }
        return (segments, notes)
    }
}
