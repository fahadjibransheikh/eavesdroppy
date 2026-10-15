import Foundation

// Native handlers for process_meeting.py's library subcommands (cmd_rename_meeting ... cmd_expire_audio): same arguments, same
// JSON envelope, same effects. A cut-over dispatches by `StoreCommands.handles(args[0])`. Errors carry Python's `ERROR:` reason.

enum StoreCommands {
    struct Spec { var positionals: [(String, Bool)] = [], options: [(String, Bool)] = [], flags: [String] = [] }  // (name, isInt)

    private static let specs: [String: Spec] = [
        "rename-meeting": Spec(positionals: [("id", true), ("title", false)]),
        "rename-speaker": Spec(positionals: [("speaker_id", true), ("name", false)], options: [("--person-id", true)], flags: ["--new-person", "--me"]),
        "set-user-notes": Spec(positionals: [("id", true)], flags: ["--clear"]),
        "delete": Spec(positionals: [("id", true)]),
        "set-action-done": Spec(positionals: [("action_id", true)], flags: ["--undone"]),
        "set-action-exported": Spec(positionals: [("action_id", true), ("target", false), ("external_id", false)]),
        "expire-audio": Spec(positionals: [("days", true)]),
    ]

    static func handles(_ command: String) -> Bool { specs[command] != nil }

    /// The D26 default output folder when neither `outRoot` nor $EAVESDROPPY_OUT_ROOT says otherwise.
    static var defaultOutRoot: String { PyPath.home + "/Documents/Eavesdroppy" }

    struct Parsed { var pos: [String] = [], opt: [String: String] = [:], flag: Set<String> = [] }

    /// A small argparse: positionals and options in any order, `--` ends options, `--opt=value`, negative numbers are values.
    static func parse(_ args: [String], _ spec: Spec) throws -> Parsed {
        let common = ["--container", "--out-root", "--user-name"]
        var p = Parsed(), extra: [String] = [], endOpts = false, i = 0
        while i < args.count {
            let a = args[i]; i += 1
            let isNeg = a.range(of: #"^-\d+$|^-\d*\.\d+$"#, options: .regularExpression) != nil
            if endOpts || !a.hasPrefix("-") || a == "-" || isNeg || a.contains(" ") && !a.hasPrefix("--") { p.pos.append(a); continue }
            if a == "--" { endOpts = true; continue }
            let name = String(a.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0])
            if spec.flags.contains(name) { p.flag.insert(name); continue }
            guard spec.options.contains(where: { $0.0 == name }) || common.contains(name) else { extra.append(a); continue }
            if a.contains("=") { p.opt[name] = String(a.dropFirst(name.count + 1)); continue }
            guard i < args.count, !args[i].hasPrefix("-") || args[i].range(of: #"^-\d+$|^-\d*\.\d+$"#, options: .regularExpression) != nil else {
                throw StoreError("bad arguments: argument \(name): expected one argument")
            }
            p.opt[name] = args[i]; i += 1
        }
        let need = spec.positionals.map { $0.0 }
        if p.pos.count < need.count { throw StoreError("bad arguments: the following arguments are required: \(need[p.pos.count...].joined(separator: ", "))") }
        if p.pos.count > need.count || !extra.isEmpty {
            throw StoreError("bad arguments: unrecognized arguments: \((Array(p.pos[need.count...]) + extra).joined(separator: " "))")
        }
        for (k, (name, isInt)) in spec.positionals.enumerated() where isInt && Int(p.pos[k]) == nil {
            throw StoreError("bad arguments: argument \(name): invalid int value: '\(p.pos[k])'")
        }
        for (name, isInt) in spec.options where isInt && p.opt[name] != nil && Int(p.opt[name]!) == nil {
            throw StoreError("bad arguments: argument \(name): invalid int value: '\(p.opt[name]!)'")
        }
        return p
    }

    /// Runs one subcommand (`args` = the subcommand and its arguments, as for Pipeline.run) and returns its JSON envelope.
    /// `stdin` is set-user-notes' text. `warn` receives what Python prints as `WARNING:` on stderr.
    static func run(_ args: [String], container: URL, outRoot: URL?, stdin: String? = nil, warn: (String) -> Void = { _ in }) throws -> Data {
        do {
            guard let cmd = args.first, let spec = specs[cmd] else { throw StoreError("bad arguments: unknown command \(args.first ?? "")") }
            let a = try parse(Array(args.dropFirst()), spec)
            let containerPath = PyPath.resolve(PyPath.abspath(PyPath.expanduser(a.opt["--container"] ?? container.path)))
            let out = PyPath.abspath(PyPath.expanduser(a.opt["--out-root"] ?? outRoot?.path
                                                       ?? ProcessInfo.processInfo.environment["EAVESDROPPY_OUT_ROOT"] ?? defaultOutRoot))
            let int = { (k: Int) in Int(a.pos[k])! }
            let result: [String: Any]
            if cmd == "expire-audio", int(0) <= 0 { throw StoreError("DAYS must be positive") }
            if cmd == "set-user-notes", !a.flag.contains("--clear"), PyText.strip(stdin ?? "").isEmpty {
                throw StoreError("no text on stdin (use --clear to empty the notes)")
            }
            if cmd == "rename-speaker", [a.opt["--person-id"] != nil, a.flag.contains("--new-person"), a.flag.contains("--me")].filter({ $0 }).count > 1 {
                throw StoreError("use only one of --person-id, --new-person and --me")
            }
            guard PyPath.isDir(containerPath) else { throw StoreError("container not found: \(containerPath)") }
            let db = try StoreDB(path: URL(fileURLWithPath: containerPath).appendingPathComponent("library.db"))
            defer { db.close() }
            let roots = [out, containerPath]
            switch cmd {
            case "rename-meeting":
                try StoreLibrary.renameMeeting(db, int(0), a.pos[1])
                try StoreMirror.sync(db, [int(0)], outRoot: out, warn: warn)
                result = ["ok": true]
            case "rename-speaker":
                let ids = try renameSpeaker(db, speakerID: int(0), name: a.pos[1], personID: a.opt["--person-id"].flatMap { Int($0) },
                                            newPerson: a.flag.contains("--new-person"), me: a.flag.contains("--me"))
                try StoreMirror.sync(db, ids, outRoot: out, warn: warn)
                result = ["meetings": ids]
            case "set-user-notes":
                try StoreLibrary.setUserNotes(db, int(0), a.flag.contains("--clear") ? "" : stdin ?? "")
                try StoreMirror.sync(db, [int(0)], outRoot: out, warn: warn)
                result = ["ok": true]
            case "delete":
                guard let info = try StoreLibrary.deleteMeeting(db, int(0)) else { throw StoreError("no meeting \(int(0))") }
                for p in [info.folder, info.audioPath, info.rawDir] where !(p ?? "").isEmpty { _ = try StoreMirror.removePath(p!, roots: roots, warn: warn) }
                result = ["ok": true]
            case "set-action-done":
                try StoreLibrary.setActionDone(db, int(0), done: !a.flag.contains("--undone"))
                result = ["ok": true]
            case "set-action-exported":
                try StoreLibrary.setActionExported(db, int(0), to: a.pos[1], externalID: a.pos[2])
                result = ["ok": true]
            default:  // expire-audio
                let done = try StoreLibrary.expireAudio(db, days: int(0)) { try StoreMirror.removePath($0, roots: roots, warn: warn) }
                result = ["deleted": done.filter { $0.1 == "deleted" }.count]
            }
            return try JSONSerialization.data(withJSONObject: result)
        } catch let e as StoreError {
            throw StoreError(PyText.words(e.description).joined(separator: " ").prefix(500).description)
        } catch let e as StoreCrash {
            throw StoreError(PyText.words(e.description).joined(separator: " ").prefix(500).description)
        } catch {
            throw StoreError("unexpected OSError: \(error.localizedDescription)")
        }
    }

    /// cmd_rename_speaker: relabel one speaker and teach the voiceprint. --person-id N: the speaker is person N (the print learns
    /// from it). --new-person: a person with this voice. --me: the user (the enrolled person, made from this voice when there is
    /// none yet). None: relabel only. The mic track of a bleed meeting never feeds a print.
    private static func renameSpeaker(_ db: StoreDB, speakerID: Int, name: String, personID: Int?, newPerson: Bool, me: Bool = false) throws -> [Int] {
        let name = PyText.strip(name)
        guard let row = try db.rows("SELECT s.track, s.kind, s.person_id, s.embedding, m.bleed FROM speakers s JOIN meetings m ON m.id = s.meeting_id"
                                    + " WHERE s.id = ?", [speakerID]).first else { throw StoreError("no speaker \(speakerID)") }
        if name.isEmpty { throw StoreError("empty name") }
        let emb = try row.data(3).map(StoreVoiceprint.vec)
        let learn = emb != nil && !((row.int(4) ?? 0) != 0 && row.text(0) == "mic")
        var pid = personID
        if me {
            if let existing = try db.rows("SELECT id FROM people WHERE is_me = 1 ORDER BY id LIMIT 1").first?.int(0) {
                pid = existing
                if learn, row.int(2) != existing, let e = emb { try StoreVoiceprint.update(db, personID: existing, embedding: e) }
            } else {
                pid = try StoreVoiceprint.addPerson(db, name: name, embedding: learn ? emb : nil, isMe: true)
            }
        } else if newPerson {
            pid = try StoreVoiceprint.addPerson(db, name: name, embedding: learn ? emb : nil)
        } else if let p = pid {
            if try db.rows("SELECT 1 FROM people WHERE id = ?", [p]).isEmpty { throw StoreError("no person \(p)") }
            let already = row.int(2) == p && ["me", "auto"].contains(row.text(1) ?? "")  // learned when the meeting was processed
            if learn, !already, let e = emb { try StoreVoiceprint.update(db, personID: p, embedding: e) }
        }
        return try StoreLibrary.renameSpeaker(db, speakerID, name, personID: pid)
    }
}
