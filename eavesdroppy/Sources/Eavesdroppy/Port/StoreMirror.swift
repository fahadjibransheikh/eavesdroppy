import Foundation

// library.py's mirror: notes.md / transcript.md rendered from the DB into the output folder, plus the Python text and
// path semantics they depend on (str.strip, \s, \w, pathlib, Path.resolve), so folders and files come out identical.

enum PyText {
    /// str.isspace(): Unicode White_Space plus the C0 separators \x1c-\x1f.
    static func isSpace(_ u: Unicode.Scalar) -> Bool { u.properties.isWhitespace || (0x1c...0x1f).contains(u.value) }
    /// re \w on str: letters, numbers, underscore.
    static func isWord(_ u: Unicode.Scalar) -> Bool {
        if u == "_" { return true }
        switch u.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber: return true
        default: return false
        }
    }
    static func strip(_ s: String) -> String {
        var v = s.unicodeScalars[...]
        while let f = v.first, isSpace(f) { v = v.dropFirst() }
        while let l = v.last, isSpace(l) { v = v.dropLast() }
        return String(v)
    }
    /// s[:n] in code points (Swift's prefix counts grapheme clusters).
    static func prefix(_ s: String, _ n: Int) -> String { String(String.UnicodeScalarView(s.unicodeScalars.prefix(n))) }
    /// " ".join(s.split())
    static func words(_ s: String) -> [String] {
        var out: [String] = [], cur = String.UnicodeScalarView()
        for u in s.unicodeScalars { if isSpace(u) { if !cur.isEmpty { out.append(String(cur)); cur = .init() } } else { cur.append(u) } }
        if !cur.isEmpty { out.append(String(cur)) }
        return out
    }
}

enum PyPath {
    static var home: String { NSHomeDirectory() }
    static func comps(_ s: String) -> [String] { s.split(separator: "/").map(String.init).filter { $0 != "." } }
    /// pathlib's lexical normalisation: no "//", "." or trailing "/".
    static func norm(_ s: String) -> String {
        let c = comps(s).joined(separator: "/")
        return s.hasPrefix("/") ? "/" + c : (c.isEmpty ? "." : c)
    }
    static func name(_ s: String) -> String { comps(s).last ?? "" }
    static func parent(_ s: String) -> String { norm(String(norm(s).dropLast(name(s).count))) }
    static func join(_ a: String, _ b: String) -> String { norm(a + "/" + b) }
    static func expanduser(_ s: String) -> String { s == "~" ? home : (s.hasPrefix("~/") ? home + s.dropFirst(1) : s) }
    /// os.path.abspath: lexical, resolves ".." without touching the disk.
    static func abspath(_ s: String) -> String {
        let p = s.hasPrefix("/") ? s : FileManager.default.currentDirectoryPath + "/" + s
        var out: [String] = []
        for c in comps(p) { if c == ".." { _ = out.popLast() } else { out.append(c) } }
        return "/" + out.joined(separator: "/")
    }
    /// Path.resolve() (non-strict): symlinks followed for the part that exists, the rest kept as written.
    static func resolve(_ s: String) -> String {
        let all = comps(abspath(s))
        var tail: [String] = []
        var head = all
        while true {
            if let r = realpath("/" + head.joined(separator: "/"), nil) {
                defer { free(r) }
                let base = String(cString: r)
                return tail.isEmpty ? base : (base == "/" ? "" : base) + "/" + tail.joined(separator: "/")
            }
            guard let last = head.popLast() else { return "/" + tail.joined(separator: "/") }
            tail.insert(last, at: 0)
        }
    }
    static func isDir(_ p: String) -> Bool { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: p, isDirectory: &d) && d.boolValue }
    static func exists(_ p: String) -> Bool { FileManager.default.fileExists(atPath: p) }
    /// True if `path` resolves strictly inside one of `roots` (symlinks followed, so a link out is refused).
    static func under(_ path: String, _ roots: [String]) -> Bool {
        let p = comps(resolve(path))
        return roots.contains { let r = comps(resolve($0)); return p.count > r.count && p.starts(with: r) }
    }
}

enum StoreMirror {
    static let sep = "\n---\n", noSpeech = "_No speech detected._"

    struct Turn { var start: Double; var speaker: String; var text: String }
    struct Meeting {
        var id: Int, title: String, start: String, duration: Double, attendees: [String], notesMD: String
        var folder: String?, audioPath: String?, turns: [Turn]
    }

    static func fmtTS(_ sec: Double) -> String {
        let s = max(safeInt(max(sec, 0)), 0), h = s / 3600, m = s % 3600 / 60, r = s % 60
        return h > 0 ? "\(h):" + String(format: "%02d:%02d", m, r) : String(format: "%02d:%02d", m, r)
    }

    static func sanitizeTitle(_ title: String) -> String {
        var t = String.UnicodeScalarView()
        for u in title.unicodeScalars { t.append("/:\\?*\"<>|\r\n".unicodeScalars.contains(u) ? "-" : u) }
        let one = PyText.strip(PyText.words(String(t)).joined(separator: " "))
        let cut = PyText.strip(PyText.prefix(one, 80))
        return cut.isEmpty ? "Meeting" : cut
    }

    /// The date/time/offset pieces of a stored start ("2026-10-01T09:00:00-04:00"), as library does with fromisoformat:
    /// wall time in the stored offset, no conversion.
    static func startParts(_ start: String) throws -> (date: String, hm: String, offset: String) {
        let u = Array(start.unicodeScalars)
        func digits(_ r: Range<Int>) -> Bool { r.allSatisfy { $0 < u.count && u[$0].properties.numericType == .decimal } }
        var off = ""
        if start.hasSuffix("Z") { off = "+00:00" } else if u.count >= 6 {
            let o = String(String.UnicodeScalarView(u.suffix(6)))
            if (o.hasPrefix("+") || o.hasPrefix("-")), o[o.index(o.startIndex, offsetBy: 3)] == ":" { off = o }
        }
        guard u.count >= 19, digits(0..<4), u[4] == "-", digits(5..<7), u[7] == "-", digits(8..<10), u[10] == "T" || u[10] == " ",
              digits(11..<13), u[13] == ":", digits(14..<16), !off.isEmpty else {
            throw StoreCrash(kind: "ValueError", message: "Invalid isoformat string: '\(start)'")
        }
        return (String(String.UnicodeScalarView(u[0..<10])), String(String.UnicodeScalarView(u[11..<16])), off)
    }

    static func folderName(title: String, start: String) throws -> String {
        let p = try startParts(start)
        return "\(p.date) \(p.hm.replacingOccurrences(of: ":", with: "")) – \(sanitizeTitle(title))"
    }

    static func header(_ m: Meeting) throws -> String {
        let p = try startParts(m.start)
        return ["# \(m.title)", "", "- **Date:** \(p.date) \(p.hm) (UTC\(p.offset))", "- **Duration:** \(fmtTS(m.duration))",
                "- **Attendees:** \(m.attendees.isEmpty ? "—" : m.attendees.joined(separator: ", "))"].joined(separator: "\n")
    }

    static func transcriptBody(_ m: Meeting) -> String {
        m.turns.isEmpty ? noSpeech : m.turns.map { "**[\(fmtTS($0.start))] \($0.speaker):** \($0.text)" }.joined(separator: "\n\n")
    }

    static func renderTranscript(_ m: Meeting) throws -> String { "\(try header(m))\n\(sep)\n\(transcriptBody(m))\n" }

    static func renderNotes(_ m: Meeting) throws -> String {
        let n = PyText.strip(m.notesMD)
        return "\(try header(m))\n\n\(n.isEmpty ? "## Summary\n\n_Summary not generated yet._" : n)\n\n## Transcript\n\n\(transcriptBody(m))\n"
    }

    /// library.check_out_root: don't mkdir -p into a Drive path whose CloudStorage mount is not there.
    static func checkOutRoot(_ outRoot: String) throws {
        let cs = PyPath.comps(PyPath.home + "/Library/CloudStorage"), c = PyPath.comps(PyPath.norm(outRoot))
        guard c.count > cs.count, c.starts(with: cs) else { return }
        if !PyPath.isDir("/" + (cs + [c[cs.count]]).joined(separator: "/")) { throw StoreError("Drive folder not available: \(PyPath.norm(outRoot))") }
    }

    private static func writeAtomic(_ path: String, _ text: String) throws {
        let tmp = path + ".tmp"
        try Data(text.utf8).write(to: URL(fileURLWithPath: tmp))
        if rename(tmp, path) != 0 { throw CocoaError(.fileWriteUnknown) }
    }

    private static func fits(_ name: String, _ want: String) -> Bool {  // fullmatch(escape(want) + r"( \(\d+\))?")
        if name == want { return true }
        guard name.hasPrefix(want + " ("), name.hasSuffix(")") else { return false }
        let mid = name.dropFirst(want.count + 2).dropLast()
        return !mid.isEmpty && mid.unicodeScalars.allSatisfy { $0.properties.generalCategory == .decimalNumber }
    }

    private static func freeName(in dir: String, _ want: String) -> String {
        var final = PyPath.join(dir, want), n = 1
        while PyPath.exists(final) { n += 1; final = PyPath.join(dir, "\(want) (\(n))") }
        return final
    }

    /// Atomically (re)write notes.md and transcript.md in the meeting's folder, creating it (or renaming it after a title
    /// change, with its .m4a) first. Returns the folder and audio path to record.
    static func write(_ m: Meeting, outRoot: String) throws -> (folder: String, audioPath: String?) {
        let fm = FileManager.default, root = PyPath.norm(outRoot)
        try checkOutRoot(root)
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        let want = try folderName(title: m.title, start: m.start)
        var cur = (m.folder ?? "").isEmpty ? nil : PyPath.norm(m.folder!)
        var audio = (m.audioPath ?? "").isEmpty ? nil : PyPath.norm(m.audioPath!)
        if cur == nil || !PyPath.isDir(cur!) {
            let final = freeName(in: root, want)
            try fm.createDirectory(atPath: final, withIntermediateDirectories: false)
            cur = final
        } else if let c = cur, PyPath.name(c) != want, !fits(PyPath.name(c), want) {
            let final = freeName(in: PyPath.parent(c), want)
            if rename(c, final) != 0 { throw CocoaError(.fileWriteUnknown) }
            if let a = audio, PyPath.parent(a) == c { audio = PyPath.join(final, PyPath.name(a)) }
            cur = final
        }
        let folder = cur!
        if let a = audio, PyPath.parent(a) == folder, PyPath.exists(a), PyPath.name(a) != PyPath.name(folder) + ".m4a" {
            let new = PyPath.join(folder, PyPath.name(folder) + ".m4a")
            if rename(a, new) != 0 { throw CocoaError(.fileWriteUnknown) }
            audio = new
        }
        try writeAtomic(PyPath.join(folder, "transcript.md"), try renderTranscript(m))
        try writeAtomic(PyPath.join(folder, "notes.md"), try renderNotes(m))
        return (folder, audio)
    }

    /// library.sync_mirror: re-render one meeting's files and record the (possibly renamed) folder/audio path.
    static func syncMirror(_ db: StoreDB, _ id: Int, outRoot: String) throws {
        guard let m = try StoreLibrary.meeting(db, id) else { throw StoreError("no meeting \(id)") }
        let r = try write(m, outRoot: outRoot)
        try StoreLibrary.setAudio(db, id, audioPath: r.audioPath, folder: r.folder)
    }

    /// process_meeting.sync: a missing Drive or a file error is a warning, never a failed edit.
    static func sync(_ db: StoreDB, _ ids: [Int], outRoot: String, warn: (String) -> Void) throws {
        for id in ids {
            do { try syncMirror(db, id, outRoot: outRoot) }
            catch let e as StoreCrash { throw e }
            catch let e as StoreError { warn("Drive mirror not updated for meeting \(id): \(e.description)") }
            catch { warn("Drive mirror not updated for meeting \(id): \(error.localizedDescription)") }
        }
    }

    /// process_meeting.remove_path: delete one file/dir, only inside `roots`. "deleted", "absent", "failed" or "refused".
    static func removePath(_ p: String, roots: [String], warn: (String) -> Void) throws -> String {
        guard PyPath.under(p, roots) else { warn("Not deleting \(p): outside the Drive folder and the container"); return "refused" }
        let fm = FileManager.default
        guard (try? fm.attributesOfItem(atPath: p)) != nil else {
            // Drive offline looks like "absent"; it is not. The file may still exist, so this is a failed delete (a warning, and
            // expire-audio keeps the reference), never an error that fails the command after the database row is already gone.
            do { try checkOutRoot(p) } catch let e as StoreError { warn("Could not delete \(p): \(e.description)"); return "failed" }
            return "absent"
        }
        do { try fm.removeItem(atPath: p) } catch { warn("Could not delete \(p): \(error.localizedDescription)"); return "failed" }
        return "deleted"
    }
}
