import Foundation
import SQLite3

// The library writer (decision D23): library.py's open_db, schema v4 and migrations on the system SQLite3 C API.
// Foundation + SQLite3 only. One connection, not thread-safe: confine to one queue.

/// library.LibraryError / process_meeting.Fail: a reason shown to the user as is.
struct StoreError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// What Python reports as "unexpected <Kind>: ..." (a bug, a locked database, a bad value): never softened to a warning.
struct StoreCrash: Error, CustomStringConvertible {
    let kind: String, message: String
    var description: String { "unexpected \(kind): \(message)" }
}

enum StoreClock {
    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'+00:00'"; return f
    }()
    /// library._now(): UTC, ISO 8601, whole seconds. Tests pin it.
    nonisolated(unsafe) static var now: () -> String = { fmt.string(from: Date()) }
}

enum StoreValue: Equatable {
    case null, int(Int64), real(Double), text(String), blob(Data)
}

struct StoreRow {
    let v: [StoreValue]
    func int(_ i: Int) -> Int? { if case .int(let x) = v[i] { return Int(x) }; if case .real(let d) = v[i] { return Int(d) }; return nil }
    func double(_ i: Int) -> Double? { if case .real(let x) = v[i] { return x }; if case .int(let n) = v[i] { return Double(n) }; return nil }
    func text(_ i: Int) -> String? { if case .text(let s) = v[i] { return s }; return nil }
    func data(_ i: Int) -> Data? { if case .blob(let d) = v[i] { return d }; return nil }
}

enum StoreSchema {
    static let peopleDDL = "CREATE TABLE IF NOT EXISTS people (id INTEGER PRIMARY KEY, name TEXT, email TEXT, "
        + "is_me INTEGER DEFAULT 0, voiceprint BLOB, n INTEGER, updated TEXT)"

    // Text identical to library.SCHEMA_V1 (whitespace included): the golden test compares sqlite_master verbatim.
    static let v1: [String] = [
        peopleDDL,
        """
        CREATE TABLE meetings (
                id INTEGER PRIMARY KEY,
                title TEXT NOT NULL,
                start TEXT NOT NULL,
                duration REAL NOT NULL DEFAULT 0,
                source TEXT NOT NULL DEFAULT 'record' CHECK (source IN ('record', 'import')),
                folder TEXT UNIQUE,
                audio_path TEXT,
                raw_dir TEXT,
                template TEXT NOT NULL DEFAULT 'general',
                attendees TEXT NOT NULL DEFAULT '[]',
                user_notes TEXT NOT NULL DEFAULT '',
                notes_md TEXT NOT NULL DEFAULT '',
                summary_status TEXT NOT NULL DEFAULT 'none',
                bleed INTEGER NOT NULL DEFAULT 0,
                created TEXT NOT NULL,
                updated TEXT NOT NULL)
        """,
        "CREATE INDEX meetings_start ON meetings(start)",
        """
        CREATE TABLE speakers (
                id INTEGER PRIMARY KEY,
                meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                track TEXT, cluster TEXT, label TEXT NOT NULL,
                person_id INTEGER REFERENCES people(id) ON DELETE SET NULL,
                score REAL, kind TEXT, embedding BLOB)
        """,
        "CREATE INDEX speakers_meeting ON speakers(meeting_id)",
        "CREATE INDEX speakers_person ON speakers(person_id)",
        """
        CREATE TABLE turns (
                id INTEGER PRIMARY KEY,
                meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                idx INTEGER NOT NULL,
                speaker_id INTEGER REFERENCES speakers(id) ON DELETE SET NULL,
                start REAL NOT NULL, end REAL NOT NULL, text TEXT NOT NULL,
                UNIQUE (meeting_id, idx))
        """,
        """
        CREATE TABLE action_items (
                id INTEGER PRIMARY KEY,
                meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                owner TEXT NOT NULL DEFAULT '', task TEXT NOT NULL, due TEXT NOT NULL DEFAULT '',
                done INTEGER NOT NULL DEFAULT 0, turn_idx INTEGER,
                exported_to TEXT, external_id TEXT)
        """,
        "CREATE INDEX action_items_meeting ON action_items(meeting_id)",
        """
        CREATE VIRTUAL TABLE search USING fts5(
                body, title, notes, user_notes,
                kind UNINDEXED, meeting_id UNINDEXED, turn_idx UNINDEXED,
                tokenize = 'unicode61 remove_diacritics 2')
        """,
        """
        CREATE TRIGGER turns_ai AFTER INSERT ON turns BEGIN
                INSERT INTO search(rowid, body, kind, meeting_id, turn_idx)
                VALUES (new.id, new.text, 't', new.meeting_id, new.idx); END
        """,
        """
        CREATE TRIGGER turns_au AFTER UPDATE OF text ON turns BEGIN
                UPDATE search SET body = new.text WHERE rowid = old.id; END
        """,
        "CREATE TRIGGER turns_ad AFTER DELETE ON turns BEGIN DELETE FROM search WHERE rowid = old.id; END",
        """
        CREATE TRIGGER meetings_ai AFTER INSERT ON meetings BEGIN
                INSERT INTO search(rowid, title, notes, user_notes, kind, meeting_id)
                VALUES (-new.id, new.title, new.notes_md, new.user_notes, 'm', new.id); END
        """,
        """
        CREATE TRIGGER meetings_au AFTER UPDATE OF title, notes_md, user_notes ON meetings BEGIN
                UPDATE search SET title = new.title, notes = new.notes_md, user_notes = new.user_notes
                WHERE rowid = -old.id; END
        """,
        "CREATE TRIGGER meetings_ad AFTER DELETE ON meetings BEGIN DELETE FROM search WHERE rowid = -old.id; END",
    ]

    /// migrations[n] upgrades user_version n -> n+1. Append only; never edit a shipped one.
    static let migrations: [[String]] = [
        v1,
        ["ALTER TABLE speakers ADD COLUMN suggested_person_id INTEGER REFERENCES people(id) ON DELETE SET NULL"],
        ["ALTER TABLE action_items ADD COLUMN external_url TEXT"],
        ["ALTER TABLE meetings ADD COLUMN pending_folder TEXT"],
    ]
}

final class StoreDB {
    private var h: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)  // SQLITE_TRANSIENT

    var lastInsertID: Int { Int(sqlite3_last_insert_rowid(h)) }

    /// library.open_db: create or open, WAL, foreign keys on, 5 s busy timeout, then apply pending migrations.
    init(path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(path.path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            let why = h.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close(h); h = nil
            throw StoreCrash(kind: "OperationalError", message: why)
        }
        sqlite3_busy_timeout(h, 5000)
        try run("PRAGMA journal_mode = WAL")
        try run("PRAGMA foreign_keys = ON")
        try migrate()
    }

    /// Read-only open for callers that must never change the library (the MCP server): SQLITE_OPEN_READONLY, no journal-mode
    /// pragma, no migrations. Throws a StoreError unless the file is exactly the schema this code writes (user_version == current).
    init(readOnly path: URL) throws {
        let uri = path.absoluteString + "?mode=ro"  // percent-encoded by URL, so ? and # in the path cannot end it early
        func open() throws {
            guard sqlite3_open_v2(uri, &h, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
                let why = h.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
                sqlite3_close(h); h = nil
                throw StoreCrash(kind: "OperationalError", message: why)
            }
            sqlite3_busy_timeout(h, 5000)
        }
        try open()
        // Same quirk as LibraryDB: a read-only connection to an idle WAL database cannot create -shm/-wal itself.
        // Create them empty (never truncating a live writer's) and reopen.
        if sqlite3_exec(h, "SELECT 1 FROM sqlite_master LIMIT 1", nil, nil, nil) == SQLITE_CANTOPEN {
            sqlite3_close(h); h = nil
            for ext in ["-shm", "-wal"] { let fd = Darwin.open(path.path + ext, O_CREAT | O_RDWR, 0o644); if fd >= 0 { Darwin.close(fd) } }
            try open()
        }
        let v = try rows("PRAGMA user_version")[0].int(0) ?? 0, n = StoreSchema.migrations.count
        if v != n {
            close()
            throw StoreError("library.db is schema v\(v) but this version of Eavesdroppy reads v\(n); "
                             + (v < n ? "open Eavesdroppy once so it updates the library, then try again" : "update Eavesdroppy"))
        }
    }

    deinit { close() }
    func close() { sqlite3_close(h); h = nil }

    private func migrate() throws {
        let v = try rows("PRAGMA user_version")[0].int(0) ?? 0, n = StoreSchema.migrations.count
        if v > n { throw StoreError("library.db schema v\(v) is newer than this code (v\(n))") }
        for i in v..<n {
            try run("BEGIN IMMEDIATE")
            do {
                for s in StoreSchema.migrations[i] { try run(s) }
                try run("PRAGMA user_version = \(i + 1)")
                try run("COMMIT")
            } catch { _ = try? run("ROLLBACK"); throw error }
        }
    }

    private func prepare(_ sql: String, _ args: [Any?]) throws -> OpaquePointer {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(h, sql, -1, &st, nil) == SQLITE_OK, let st else { throw fail() }
        for (i, a) in args.enumerated() {
            let n = Int32(i + 1)
            switch a {
            case nil: sqlite3_bind_null(st, n)
            case let x as Int: sqlite3_bind_int64(st, n, Int64(x))
            case let x as Int64: sqlite3_bind_int64(st, n, x)
            case let x as Bool: sqlite3_bind_int64(st, n, x ? 1 : 0)
            case let x as Double: sqlite3_bind_double(st, n, x)
            case let x as String: sqlite3_bind_text(st, n, x, -1, Self.transient)
            case let x as Data: _ = x.withUnsafeBytes { sqlite3_bind_blob(st, n, $0.baseAddress ?? UnsafeRawPointer(bitPattern: 1), Int32(x.count), Self.transient) }
            default: sqlite3_finalize(st); throw StoreCrash(kind: "InterfaceError", message: "cannot bind \(type(of: a!))")
            }
        }
        return st
    }

    private func fail() -> StoreCrash { StoreCrash(kind: "OperationalError", message: String(cString: sqlite3_errmsg(h))) }

    /// One statement, rows ignored. Returns the number of rows it changed (UPDATE/DELETE/INSERT).
    @discardableResult func run(_ sql: String, _ args: [Any?] = []) throws -> Int {
        let st = try prepare(sql, args)
        defer { sqlite3_finalize(st) }
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_DONE { return Int(sqlite3_changes(h)) }
            if rc != SQLITE_ROW { throw fail() }
        }
    }

    func rows(_ sql: String, _ args: [Any?] = []) throws -> [StoreRow] {
        let st = try prepare(sql, args)
        defer { sqlite3_finalize(st) }
        var out: [StoreRow] = []
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_DONE { return out }
            if rc != SQLITE_ROW { throw fail() }
            out.append(StoreRow(v: (0..<sqlite3_column_count(st)).map { i in
                switch sqlite3_column_type(st, i) {
                case SQLITE_INTEGER: return .int(sqlite3_column_int64(st, i))
                case SQLITE_FLOAT: return .real(sqlite3_column_double(st, i))
                case SQLITE_TEXT: return .text(String(cString: sqlite3_column_text(st, i)))
                case SQLITE_BLOB: return .blob(Data(bytes: sqlite3_column_blob(st, i) ?? UnsafeRawPointer(bitPattern: 1)!, count: Int(sqlite3_column_bytes(st, i))))
                default: return .null
                }
            }))
        }
    }

    /// `with tx(db):` = BEGIN IMMEDIATE ... COMMIT, ROLLBACK on error.
    func tx<T>(_ body: () throws -> T) throws -> T {
        try run("BEGIN IMMEDIATE")
        do { let r = try body(); try run("COMMIT"); return r } catch { _ = try? run("ROLLBACK"); throw error }
    }
}
