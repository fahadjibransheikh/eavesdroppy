import Foundation
import SQLite3
import Testing
@testable import Eavesdroppy

// Replays tools/golden/store_golden.py's cases on the Swift store and compares the envelope, warnings, every table, the search
// index and the rendered files with what the Python oracle produced.

private let pinned: Void = { StoreClock.now = { "2026-10-13T12:00:00+00:00" } }()
private let home = NSHomeDirectory()
private let missingDrive = home + "/Library/CloudStorage/ZZ-NoSuchMount-Eavesdroppy/Meetings"

private func loadGolden(_ dir: URL) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("golden.json"))) as? [String: Any]) ?? [:]
}
private let fixtureDir = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/store")
private let committed = loadGolden(fixtureDir)
private let committedNames = (committed["cases"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }

// MARK: raw SQLite for the checks (no migration, no helpers under test)

private func rawOpen(_ path: String) -> OpaquePointer? {
    var h: OpaquePointer?
    return sqlite3_open_v2(path, &h, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK ? h : nil
}

private func rawQuery(_ h: OpaquePointer, _ sql: String) -> (names: [String], rows: [[Any]]) {
    var st: OpaquePointer?
    guard sqlite3_prepare_v2(h, sql, -1, &st, nil) == SQLITE_OK else { return ([], []) }
    defer { sqlite3_finalize(st) }
    let names = (0..<sqlite3_column_count(st)).map { String(cString: sqlite3_column_name(st, $0)) }
    var rows: [[Any]] = []
    while sqlite3_step(st) == SQLITE_ROW {
        rows.append((0..<sqlite3_column_count(st)).map { i -> Any in
            switch sqlite3_column_type(st, i) {
            case SQLITE_INTEGER: return Int(sqlite3_column_int64(st, i))
            case SQLITE_FLOAT: return sqlite3_column_double(st, i)
            case SQLITE_TEXT: return String(cString: sqlite3_column_text(st, i))
            case SQLITE_BLOB: return Data(bytes: sqlite3_column_blob(st, i) ?? UnsafeRawPointer(bitPattern: 1)!, count: Int(sqlite3_column_bytes(st, i)))
            default: return NSNull()
            }
        })
    }
    return (names, rows)
}

private func dumpDB(_ path: String, root: String) -> Any {
    guard FileManager.default.fileExists(atPath: path), let h = rawOpen(path) else { return NSNull() }
    defer { sqlite3_close(h) }
    var out: [String: Any] = ["user_version": rawQuery(h, "PRAGMA user_version").rows[0][0],
                              "schema": rawQuery(h, "SELECT type, name, tbl_name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name").rows]
    for (t, order) in [("people", "id"), ("meetings", "id"), ("speakers", "id"), ("turns", "id"), ("action_items", "id"), ("search", "rowid")] {
        guard !rawQuery(h, "SELECT 1 FROM sqlite_master WHERE name = '\(t)'").rows.isEmpty else { continue }
        let q = rawQuery(h, "SELECT * FROM \(t) ORDER BY \(order)")
        out[t] = q.rows.map { r in
            Dictionary(uniqueKeysWithValues: zip(q.names, r).map { name, v -> (String, Any) in
                guard let d = v as? Data else { return (name, v) }
                if t == "people", name == "voiceprint" {
                    return (name, d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }.map { Double($0) })
                }
                return (name, "blob:\(d.count):" + d.prefix(8).map { String(format: "%02x", $0) }.joined())
            })
        }
    }
    return scrub(out, root)
}

private func dumpFiles(_ root: String) -> [String: String] {
    var out: [String: String] = [:]
    let fm = FileManager.default
    for rel in fm.enumerator(atPath: root)?.allObjects as? [String] ?? [] {
        let key = rel.precomposedStringWithCanonicalMapping
        if key.hasPrefix("container/library.db") { continue }
        var isDir: ObjCBool = false
        _ = fm.fileExists(atPath: root + "/" + rel, isDirectory: &isDir)
        if isDir.boolValue { out[key] = "<dir>"; continue }
        let ext = (rel as NSString).pathExtension
        out[key] = ["md", "txt"].contains(ext) ? (try? String(contentsOfFile: root + "/" + rel, encoding: .utf8)) ?? "<unreadable>"
            : "<\((try? fm.attributesOfItem(atPath: root + "/" + rel)[.size] as? Int) ?? -1) bytes>"
    }
    return out
}

private func scrub(_ o: Any, _ root: String) -> Any {
    switch o {
    case let s as String: return s.replacingOccurrences(of: root, with: "{ROOT}").replacingOccurrences(of: home, with: "{HOME}")
    case let a as [Any]: return a.map { scrub($0, root) }
    case let d as [String: Any]: return d.mapValues { scrub($0, root) }
    default: return o
    }
}

/// First difference between the oracle's value and ours (numbers within 1e-6), or nil.
private func firstDiff(_ want: Any, _ got: Any, _ path: String = "") -> String? {
    switch (want, got) {
    case (let w as [String: Any], let g as [String: Any]):
        if Set(w.keys) != Set(g.keys) { return "\(path): keys \(w.keys.sorted()) vs \(g.keys.sorted())" }
        for k in w.keys.sorted() { if let d = firstDiff(w[k]!, g[k]!, path + "/" + k) { return d } }
        return nil
    case (let w as [Any], let g as [Any]):
        if w.count != g.count { return "\(path): \(w.count) items vs \(g.count)" }
        for (i, (a, b)) in zip(w, g).enumerated() { if let d = firstDiff(a, b, "\(path)[\(i)]") { return d } }
        return nil
    case (let w as String, let g as String): return w == g ? nil : "\(path): \(w.debugDescription) vs \(g.debugDescription)"
    case (is NSNull, is NSNull): return nil
    case (let w as NSNumber, let g as NSNumber): return abs(w.doubleValue - g.doubleValue) <= 1e-6 ? nil : "\(path): \(w) vs \(g)"
    default: return "\(path): \(want) vs \(got)"
    }
}

// MARK: replay

private func materialize(root: String, base: String?, dir: URL, setupSQL: [String], files: [String: String]) throws {
    let fm = FileManager.default
    for d in ["out", "container"] { try fm.createDirectory(atPath: root + "/" + d, withIntermediateDirectories: true) }
    for (rel, text) in files {
        let p = root + "/" + rel
        try fm.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: p))
    }
    guard let base else { return }
    let db = root + "/container/library.db"
    try fm.copyItem(at: dir.appendingPathComponent(base), to: URL(fileURLWithPath: db))
    let h = rawOpen(db)!
    defer { sqlite3_close(h) }
    let q = root.replacingOccurrences(of: "'", with: "''")
    for col in ["folder", "audio_path", "raw_dir", "pending_folder"] {  // pending_folder does not exist before v4
        sqlite3_exec(h, "UPDATE meetings SET \(col) = replace(\(col), '{ROOT}', '\(q)')", nil, nil, nil)
    }
    for s in setupSQL { #expect(sqlite3_exec(h, s, nil, nil, nil) == SQLITE_OK, "setup_sql failed: \(s)") }
}

private func replay(_ c: [String: Any], golden: [String: Any], dir: URL) throws -> [String: Any] {
    _ = pinned
    let root = PyPath.resolve(NSTemporaryDirectory() + "storegolden-" + UUID().uuidString)
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: root) }
    let base = c["base"] is NSNull ? nil : (c["base"] as? String ?? golden["defaultBase"] as? String)
    try materialize(root: root, base: base, dir: dir, setupSQL: c["setup_sql"] as? [String] ?? [], files: golden["files"] as? [String: String] ?? [:])
    let container = URL(fileURLWithPath: root + (c["container"] as? String == "missing" ? "/nocontainer" : "/container"))
    let outRoot = URL(fileURLWithPath: c["out_root"] as? String == "missing-drive" ? missingDrive : root + "/out")

    if let asks = c["ask"] as? [[String: Any]] {
        let db = try StoreDB(path: container.appendingPathComponent("library.db"))
        let res = try asks.map { q -> [String: Any] in
            var scope: StoreScope?
            if let s = q["scope"] as? [String: Int] { scope = s["meeting_id"].map(StoreScope.meeting) ?? s["person_id"].map(StoreScope.person) }
            let r = try StoreSearch.retrieve(db, question: q["question"] as! String, scope: scope)
            return ["segments": r.segments.map { ["meeting_id": $0.meetingID, "title": $0.title, "date": $0.date, "ts": $0.ts, "speaker": $0.speaker, "text": $0.text] as [String: Any] },
                    "notes": r.notes.map { ["meeting_id": $0.meetingID, "title": $0.title, "date": $0.date, "notes": $0.notes] as [String: Any] }]
        }
        return ["ask": scrub(res, root)]
    }
    var steps: [[String: Any]] = []
    for s in c["steps"] as! [[String: Any]] {
        var warnings: [String] = [], res: [String: Any] = [:]
        do {
            let data = try StoreCommands.run(s["args"] as! [String], container: container, outRoot: outRoot, stdin: s["stdin"] as? String) { warnings.append($0) }
            res["ok"] = try JSONSerialization.jsonObject(with: data)
        } catch { res["error"] = "\(error)" }
        res["warnings"] = warnings
        steps.append(scrub(res, root) as! [String: Any])
    }
    return ["steps": steps, "db": dumpDB(container.path + "/library.db", root: root), "files": dumpFiles(root)]
}

private func check(_ name: String, golden: [String: Any], dir: URL) throws {
    let c = (golden["cases"] as! [[String: Any]]).first { $0["name"] as? String == name }!
    let got = try replay(c, golden: golden, dir: dir)
    let want = c["expect"] as! [String: Any]
    for key in ["steps", "ask", "db", "files"] where want[key] != nil {
        #expect(firstDiff(want[key]!, got[key] ?? NSNull(), key) == nil, "\(name): \(firstDiff(want[key]!, got[key] ?? NSNull(), key) ?? "")")
    }
}

@Test(arguments: committedNames) func goldenCase(_ name: String) throws {
    try check(name, golden: committed, dir: fixtureDir)
}

/// A case set built on a copy of a real library.db (not committed): STORE_GOLDEN_DIR=<dir written by store_golden.py --real>.
@Test(.enabled(if: ProcessInfo.processInfo.environment["STORE_GOLDEN_DIR"] != nil)) func realLibrary() throws {
    let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["STORE_GOLDEN_DIR"]!)
    let golden = loadGolden(dir)
    #expect(!(golden["cases"] as? [Any] ?? []).isEmpty)
    for c in golden["cases"] as? [[String: Any]] ?? [] { try check(c["name"] as! String, golden: golden, dir: dir) }
}

@Test func commandRouting() {
    for c in ["rename-meeting", "rename-speaker", "set-user-notes", "delete", "set-action-done", "set-action-exported", "expire-audio"] {
        #expect(StoreCommands.handles(c))
    }
    for c in ["process", "regenerate", "ask", "enroll", "import-drive", "linear-export", "linear-teams", "frobnicate"] { #expect(!StoreCommands.handles(c)) }
}
