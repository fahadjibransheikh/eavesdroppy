import Foundation

// library.py's write functions, one for one: each takes the connection and runs in its own transaction.

enum StoreLibrary {
    static func touch(_ db: StoreDB, _ id: Int, _ cols: [(String, Any?)] = []) throws {
        let sets = cols.map { "\($0.0) = ?, " }.joined()
        let args: [Any?] = cols.map { $0.1 } + [StoreClock.now(), id]
        if try db.run("UPDATE meetings SET \(sets)updated = ? WHERE id = ?", args) == 0 { throw StoreError("no meeting \(id)") }
    }

    /// library.get_meeting, reduced to what the mirror renders.
    static func meeting(_ db: StoreDB, _ id: Int) throws -> StoreMirror.Meeting? {
        guard let r = try db.rows("SELECT title, start, duration, attendees, notes_md, folder, audio_path, raw_dir FROM meetings WHERE id = ?", [id]).first
        else { return nil }
        guard let att = try? JSONSerialization.jsonObject(with: Data((r.text(3) ?? "[]").utf8), options: .fragmentsAllowed) as? [String]
        else { throw StoreCrash(kind: "TypeError", message: "attendees of meeting \(id) is not a JSON list of strings") }
        let turns = try db.rows("SELECT t.start, COALESCE(s.label, '?'), t.text FROM turns t LEFT JOIN speakers s ON s.id = t.speaker_id"
                                + " WHERE t.meeting_id = ? ORDER BY t.idx", [id])
            .map { StoreMirror.Turn(start: $0.double(0) ?? 0, speaker: $0.text(1) ?? "?", text: $0.text(2) ?? "") }
        return StoreMirror.Meeting(id: id, title: r.text(0) ?? "", start: r.text(1) ?? "", duration: r.double(2) ?? 0, attendees: att,
                                   notesMD: r.text(4) ?? "", folder: r.text(5), audioPath: r.text(6), turns: turns, rawDir: r.text(7))
    }

    static func renameMeeting(_ db: StoreDB, _ id: Int, _ title: String) throws {
        let t = PyText.strip(title)
        if t.isEmpty { throw StoreError("empty title") }
        try db.tx { try touch(db, id, [("title", t)]) }
    }

    static func setUserNotes(_ db: StoreDB, _ id: Int, _ text: String) throws {
        try db.tx { try touch(db, id, [("user_notes", text)]) }
    }

    /// Records the (possibly renamed) folder and audio path; the folder is in place, so pending_folder clears.
    static func setAudio(_ db: StoreDB, _ id: Int, audioPath: String? = nil, rawDir: String? = nil, folder: String? = nil) throws {
        try db.tx {
            var cols: [(String, Any?)] = []
            if let a = audioPath { cols.append(("audio_path", a)) }
            if let r = rawDir { cols.append(("raw_dir", r)) }
            if let f = folder { cols.append(("folder", f)); cols.append(("pending_folder", nil)) }
            if !cols.isEmpty { try touch(db, id, cols) }
        }
    }

    /// library.rename_speaker. Returns the sorted ids of meetings whose rendered files changed.
    static func renameSpeaker(_ db: StoreDB, _ speakerID: Int, _ name: String, personID: Int?) throws -> [Int] {
        let name = PyText.strip(name)
        if name.isEmpty { throw StoreError("empty name") }
        return try db.tx {
            guard let row = try db.rows("SELECT meeting_id, label FROM speakers WHERE id = ?", [speakerID]).first,
                  let mid = row.int(0) else { throw StoreError("no speaker \(speakerID)") }
            var affected: Set<Int> = [mid], renamed: [(Int, String)] = [(mid, row.text(1) ?? "")]
            // a rename settles an introduction-named speaker (kind "intro"): the user has now chosen the name
            try db.run("UPDATE speakers SET label = ?, person_id = COALESCE(?, person_id), kind = CASE WHEN kind = 'intro' THEN 'new' ELSE kind END WHERE id = ?",
                       [name, personID, speakerID])
            if let pid = personID {
                for r in try db.rows("SELECT id, meeting_id, label FROM speakers WHERE person_id = ? AND label != ?", [pid, name]) {
                    try db.run("UPDATE speakers SET label = ? WHERE id = ?", [name, r.int(0)])
                    affected.insert(r.int(1) ?? 0); renamed.append((r.int(1) ?? 0, r.text(2) ?? ""))
                }
            }
            for (m, old) in renamed { try relabelText(db, m, old, name) }
            for m in affected { try touch(db, m) }
            return affected.sorted()
        }
    }

    /// Whole-word, case-sensitive replace of `old` by `new` ((?<!\w)old(?!\w)), so "Speaker 2" leaves "Speaker 21" alone.
    static func relabel(_ text: String, _ old: String, _ new: String) -> String {
        let t = Array(text.unicodeScalars), o = Array(old.unicodeScalars)
        var out = String.UnicodeScalarView(), i = 0
        while i < t.count {
            if i + o.count <= t.count, t[i..<i + o.count].elementsEqual(o), i == 0 || !PyText.isWord(t[i - 1]),
               i + o.count == t.count || !PyText.isWord(t[i + o.count]) {
                out.append(contentsOf: new.unicodeScalars); i += o.count
            } else { out.append(t[i]); i += 1 }
        }
        return String(out)
    }

    private static func relabelText(_ db: StoreDB, _ mid: Int, _ old: String, _ new: String) throws {
        if old.isEmpty || old == new { return }
        if let notes = try db.rows("SELECT notes_md FROM meetings WHERE id = ?", [mid]).first?.text(0), relabel(notes, old, new) != notes {
            try db.run("UPDATE meetings SET notes_md = ? WHERE id = ?", [relabel(notes, old, new), mid])
        }
        for r in try db.rows("SELECT id, owner FROM action_items WHERE meeting_id = ?", [mid]) {
            let owner = r.text(1) ?? ""
            if relabel(owner, old, new) != owner { try db.run("UPDATE action_items SET owner = ? WHERE id = ?", [relabel(owner, old, new), r.int(0)]) }
        }
    }

    static func setActionDone(_ db: StoreDB, _ id: Int, done: Bool) throws {
        try db.tx { if try db.run("UPDATE action_items SET done = ? WHERE id = ?", [done ? 1 : 0, id]) == 0 { throw StoreError("no action item \(id)") } }
    }

    static func setActionExported(_ db: StoreDB, _ id: Int, to: String, externalID: String?, externalURL: String? = nil) throws {
        try db.tx {
            if try db.run("UPDATE action_items SET exported_to = ?, external_id = ?, external_url = ? WHERE id = ?", [to, externalID, externalURL, id]) == 0 {
                throw StoreError("no action item \(id)")
            }
        }
    }

    /// Deletes a meeting and everything under it (FTS follows via triggers). Returns folder/audio/raw paths so the caller can
    /// remove the files, or nil if there was no such meeting.
    static func deleteMeeting(_ db: StoreDB, _ id: Int) throws -> (folder: String?, audioPath: String?, rawDir: String?)? {
        try db.tx {
            guard let r = try db.rows("SELECT folder, audio_path, raw_dir FROM meetings WHERE id = ?", [id]).first else { return nil }
            try db.run("DELETE FROM meetings WHERE id = ?", [id])
            return (r.text(0), r.text(1), r.text(2))
        }
    }

    /// D20 retention: for meetings created more than `days` days ago, delete their audio (the m4a and the raw FLAC dir) and
    /// forget it. `delete` returns "deleted", "absent" or any other word when the path may still exist; a column is cleared
    /// only for a path that is gone. Returns [(path, outcome)].
    static func expireAudio(_ db: StoreDB, days: Int, now: Date = Date(), exclude: Set<Int> = [], delete: (String) throws -> String) throws -> [(String, String)] {
        if days == 0 { return [] }
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        var out: [(String, String)] = []
        for r in try db.rows("SELECT id, created, audio_path, raw_dir FROM meetings WHERE audio_path IS NOT NULL OR raw_dir IS NOT NULL") {
            let id = r.int(0) ?? 0, created = r.text(1) ?? ""
            guard let when = Fmt.parseISO(created) else { throw StoreCrash(kind: "ValueError", message: "Invalid isoformat string: '\(created)'") }
            if exclude.contains(id) || when >= cutoff { continue }
            var gone: [(String, Any?)] = []
            for (i, col) in ["audio_path", "raw_dir"].enumerated() {
                guard let p = r.text(2 + i), !p.isEmpty else { continue }
                let res = try delete(p)
                out.append((p, res))
                if res == "deleted" || res == "absent" { gone.append((col, nil)) }
            }
            if !gone.isEmpty { do { try db.tx { try touch(db, id, gone) } } catch is StoreError {} }  // deleted meanwhile
        }
        return out
    }
}
