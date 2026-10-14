import Foundation

// The rest of process_meeting.py's subcommands, natively: process, regenerate, ask, enroll, import-drive, linear-teams and
// linear-export. (rename-meeting ... expire-audio are StoreCommands.) Same arguments, same JSON envelope, same `ERROR:`
// reasons. `Pipeline.run` calls `NativeCommands.run` for every command here; the Python path is the personal-build fallback.

/// Settings the native handlers need that live in the droplet's main-actor Prefs. Updated by Prefs on every change.
enum NativeConfig {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _provider = NotesProviderConfig()
    static var provider: NotesProviderConfig { get { lock.withLock { _provider } } set { lock.withLock { _provider = newValue } } }
}

/// linear_call: one Linear GraphQL request -> the `data` dict. Personal API keys go in Authorization with no Bearer.
enum LinearAPI {
    static let url = URL(string: "https://api.linear.app/graphql")!
    static let timeout: TimeInterval = 30   // LINEAR_TIMEOUT
    nonisolated(unsafe) static var session: URLSession = .shared   // tests swap in a stub

    static func call(_ query: String, variables: [String: Any] = [:], key: String?) async throws -> [String: Any] {
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { throw StoreError("Linear API key not set") }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        for (k, v) in ["Content-Type": "application/json", "Authorization": key, "User-Agent": "eavesdroppy/1.0"] { req.setValue(v, forHTTPHeaderField: k) }
        let body: Data, code: Int
        do {   // GraphQL errors (bad key, bad team) arrive as 4xx with a JSON body, which URLSession returns rather than throws
            let (d, r) = try await session.data(for: req)
            body = d; code = (r as? HTTPURLResponse)?.statusCode ?? 200
        } catch is CancellationError { throw CancellationError()
        } catch { throw StoreError("Linear request failed: \((error as? URLError)?.localizedDescription ?? error.localizedDescription)") }
        guard let j = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { throw StoreError("Linear returned HTTP \(code) with a non-JSON body") }
        if let errs = j["errors"] as? [Any], !errs.isEmpty {
            throw StoreError("Linear: " + errs.map { ($0 as? [String: Any])?["message"].map { "\($0)" } ?? "\($0)" }.joined(separator: "; "))
        }
        guard code == 200, let data = j["data"] as? [String: Any] else { throw StoreError("Linear returned HTTP \(code)") }
        return data
    }
}

enum NativeCommands {
    struct Context {
        var container: URL
        var outRoot: URL?
        var stdin: String? = nil
        var env: [String: String] = [:]
        var engines = Processor.Engines()
        var resolution: () async -> NotesProviders.Resolution = { await NotesProviders.resolve(NativeConfig.provider) }
        var warn: (String) -> Void = { _ in }
        var log: (String) -> Void = { _ in }
    }

    private static let specs: [String: StoreCommands.Spec] = [
        "process": .init(positionals: [("session_dir", false)]),
        "regenerate": .init(positionals: [("id", true)], options: [("--template", false), ("--custom-text-file", false)]),
        "ask": .init(positionals: [("question", false)], options: [("--meeting-id", true), ("--person-id", true)]),
        "enroll": .init(positionals: [("wav", false)], options: [("--name", false)], flags: ["--force"]),
        "import-drive": .init(),
        "linear-teams": .init(),
        "linear-export": .init(positionals: [("action_id", true)], options: [("--team", false)]),
    ]

    /// Every subcommand the native side runs.
    static func handles(_ command: String) -> Bool { StoreCommands.handles(command) || specs[command] != nil }

    /// Runs one subcommand and returns its JSON envelope. Throws StoreError with Python's `ERROR:` reason, or CancellationError.
    static func run(_ args: [String], _ ctx: Context) async throws -> Data {
        guard let cmd = args.first, let spec = specs[cmd] else {
            return try StoreCommands.run(args, container: ctx.container, outRoot: ctx.outRoot, stdin: ctx.stdin, warn: ctx.warn)
        }
        do {
            let a = try StoreCommands.parse(Array(args.dropFirst()), spec)
            let containerPath = PyPath.resolve(PyPath.abspath(PyPath.expanduser(a.opt["--container"] ?? ctx.container.path)))
            let out = PyPath.abspath(PyPath.expanduser(a.opt["--out-root"] ?? ctx.outRoot?.path
                                                       ?? ProcessInfo.processInfo.environment["EAVESDROPPY_OUT_ROOT"] ?? StoreCommands.defaultOutRoot))
            let userName = a.opt["--user-name"]
            let int = { (k: Int) in Int(a.pos[k])! }
            guard PyPath.isDir(containerPath) else { throw StoreError("container not found: \(containerPath)") }
            let container = URL(fileURLWithPath: containerPath)
            var result: [String: Any]
            switch cmd {
            case "process":
                let r = try await Processor.process(Processor.Params(session: URL(fileURLWithPath: a.pos[0]), container: container, outRoot: out, userName: userName,
                                                                     resolution: await ctx.resolution(), engines: ctx.engines, log: ctx.log))
                result = ["folder": r.folder, "meeting_id": r.meetingID, "warnings": r.warnings]
            case "regenerate":
                result = try await regenerate(id: int(0), template: a.opt["--template"], customFile: a.opt["--custom-text-file"], userName: userName,
                                              container: container, out: out, ctx)
            case "ask":
                result = try await ask(a.pos[0], meetingID: a.opt["--meeting-id"].flatMap { Int($0) }, personID: a.opt["--person-id"].flatMap { Int($0) },
                                       userName: userName, container: container, ctx)
            case "enroll":
                result = try await enroll(wav: a.pos[0], name: a.opt["--name"] ?? "Me", force: a.flag.contains("--force"), container: container, ctx)
            case "import-drive":
                let db = try StoreDB(path: container.appendingPathComponent("library.db")); defer { db.close() }
                let r = try StoreImport.importExisting(db, outRoot: out)
                result = ["imported": r.imported.count, "skipped": r.skipped, "failed": r.failed.count, "ids": r.imported, "errors": r.failed.map { "\($0.0): \($0.1)" }]
            case "linear-teams":
                let data = try await LinearAPI.call("{ teams { nodes { id name key } } }", key: ctx.env["EAVESDROPPY_LINEAR_KEY"])
                let nodes = ((data["teams"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
                result = ["teams": nodes.map { ["id": $0["id"] ?? "", "name": $0["name"] ?? "", "key": $0["key"] ?? ""] }]
            default:  // linear-export
                guard let team = a.opt["--team"] else { throw StoreError("bad arguments: the following arguments are required: --team") }
                result = try await linearExport(actionID: int(0), team: team, container: container, ctx)
            }
            return try JSONSerialization.data(withJSONObject: result)
        } catch is CancellationError { throw CancellationError()
        } catch let e as StoreError { throw StoreError(oneLine(e.description))
        } catch let e as StoreCrash { throw StoreError(oneLine(e.description))
        } catch { throw StoreError("unexpected OSError: \(error.localizedDescription)") }
    }

    private static func oneLine(_ s: String) -> String { PyText.words(s).joined(separator: " ").prefix(500).description }

    // MARK: handlers

    static func regenerate(id: Int, template: String?, customFile: String?, userName: String?, container: URL, out: String, _ ctx: Context) async throws -> [String: Any] {
        var custom: String?
        if let f = customFile {
            do { custom = try String(contentsOfFile: f, encoding: .utf8) } catch { throw StoreError("cannot read \(f): \(error.localizedDescription)") }
        }
        var warnings: [String] = []
        let db = try StoreDB(path: container.appendingPathComponent("library.db")); defer { db.close() }
        guard try StoreLibrary.meeting(db, id) != nil else { throw StoreError("no meeting \(id)") }
        if let w = try await Processor.generateAndStore(db, id, template: template, customText: custom, keepGood: true, userName: userName,
                                                        droppyVocab: ctx.engines.droppyVocab(), resolution: await ctx.resolution()) { warnings.append(w) }
        try StoreMirror.sync(db, [id], outRoot: out) { warnings.append($0) }
        return ["ok": true, "warnings": warnings]
    }

    static func ask(_ question: String, meetingID: Int?, personID: Int?, userName: String?, container: URL, _ ctx: Context) async throws -> [String: Any] {
        if meetingID != nil && personID != nil { throw StoreError("use either --meeting-id or --person-id, not both") }
        let scope: StoreScope? = meetingID.map { .meeting($0) } ?? personID.map { .person($0) }
        let db = try StoreDB(path: container.appendingPathComponent("library.db")); defer { db.close() }
        if PyText.strip(question).isEmpty { throw StoreError("empty question") }
        let r = try StoreSearch.retrieve(db, question: question, scope: scope)
        db.close()
        do {
            let answer = try await NotesGenerator.ask(
                question: question, segments: r.segments.map { .init(title: $0.title, date: $0.date, ts: $0.ts, speaker: $0.speaker, text: $0.text) },
                notes: r.notes.map { .init(title: $0.title, date: $0.date, notes: $0.notes) }, userName: Processor.userNameOf(userName), resolution: await ctx.resolution())
            return ["answer": answer]
        } catch is CancellationError { throw CancellationError()
        } catch { throw StoreError((error as? LocalizedError)?.errorDescription ?? "\(error)") }
    }

    /// Learns the user's voiceprint from a sample, after EnrollQuality has accepted it (nothing is saved otherwise). When the user already
    /// has a print and the new one matches it below `Voiceprints.meThr`, nothing is saved either and the result is
    /// `{"confirm": true, "match": cosine}`; the caller asks and re-runs with `--force` (replace, n = 1). The sample stays where it is.
    static func enroll(wav: String, name: String, force: Bool = false, container: URL, _ ctx: Context) async throws -> [String: Any] {
        let diarizer = ctx.engines.diarizer()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("eavesdroppy-enroll-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let r: EngineDiarization, x: [Float], native: EnrollQuality.Native
        do {   // any rate/channels -> 16 kHz mono 16-bit (soundfile's default WAV subtype)
            x = try Echo.load16k(URL(fileURLWithPath: wav))
            native = try EnrollQuality.nativeStats(URL(fileURLWithPath: wav))
            let p = tmp.appendingPathComponent("enroll.wav")
            try ProcessorAudio.writeMono16(x, rate: 16_000, to: p)
            r = try await diarizer.diarize(p)
            await diarizer.unload()
        } catch is CancellationError { await diarizer.unload(); throw CancellationError()
        } catch { await diarizer.unload(); throw StoreError((error as? LocalizedError)?.errorDescription ?? "\(error)") }
        let m = EnrollQuality.measure(samples: x, segments: r.segments, native: native)
        log("enroll: sample \(URL(fileURLWithPath: wav).lastPathComponent), \(Int(native.rate)) Hz, \(native.channels) channel(s); \(EnrollQuality.summary(m))")
        if let why = EnrollQuality.rejection(m, minSpeech: Voiceprints.minEnrollSpeech) { log("enroll refused: \(why)"); throw StoreError(why) }
        guard let cid = m.dominant, let emb = r.embeddings[cid] else { throw StoreError("enrollment sample has no voiceprint") }
        let seconds = PyRound.round(m.speech, 1)
        let db = try StoreDB(path: container.appendingPathComponent("library.db")); defer { db.close() }
        let cos = { (a: [Float], b: [Float]) -> Double? in a.count == b.count ? Double(Voiceprints.dot(Voiceprints.unit(a), Voiceprints.unit(b))) : nil }
        let saved = try db.rows("SELECT voiceprint FROM people WHERE is_me = 1 AND voiceprint IS NOT NULL ORDER BY id LIMIT 1").first?.data(0).flatMap { try? StoreVoiceprint.vec($0) }
        let oldMatch = saved.flatMap { cos($0, emb) }
        // the best cosine to any meeting cluster that was named Me by voiceprint
        let meetingMatch = try db.rows("SELECT embedding FROM speakers WHERE kind = 'me' AND embedding IS NOT NULL")
            .compactMap { $0.data(0).flatMap { try? StoreVoiceprint.vec($0) }.flatMap { cos($0, emb) } }.max()
        log("enroll: match to saved voice \(oldMatch.map { String(format: "%.3f", $0) } ?? "none"), best match to a meeting cluster named Me \(meetingMatch.map { String(format: "%.3f", $0) } ?? "none")")
        var result: [String: Any] = ["seconds": seconds, "quality": m.json]
        if let meetingMatch { result["meeting_match"] = PyRound.round(meetingMatch, 3) }
        if let oldMatch { result["old_match"] = PyRound.round(oldMatch, 3) }
        if !force, let oldMatch, oldMatch < Voiceprints.meThr { result["confirm"] = true; return result }
        let pid: Int
        if let row = try db.rows("SELECT id FROM people WHERE is_me = 1 ORDER BY id LIMIT 1").first?.int(0) {
            try db.tx { try db.run("UPDATE people SET name = ?, voiceprint = ?, n = 1, updated = ? WHERE id = ?", [name, StoreVoiceprint.blob(emb), StoreClock.now(), row]) }
            pid = row
        } else {
            pid = try db.tx { try StoreVoiceprint.addPerson(db, name: name, embedding: emb, isMe: true) }
        }
        result["person_id"] = pid
        return result
    }

    /// linear_description
    static func linearDescription(owner: String, due: String, title: String, start: String, turn: (start: Double, speaker: String, text: String)?) -> String {
        var lines = [("Owner", owner), ("Due", due)].filter { !$0.1.isEmpty }.map { "\($0.0): \($0.1)" }
        lines += ["", "From meeting: \(title) (\(PyText.prefix(start, 10)))"]
        if let t = turn { lines += ["", "> [\(StoreMirror.fmtTS(t.start))] \(t.speaker): \(t.text)"] }
        return PyText.strip(lines.joined(separator: "\n"))
    }

    static func linearExport(actionID: Int, team: String, container: URL, _ ctx: Context) async throws -> [String: Any] {
        let db = try StoreDB(path: container.appendingPathComponent("library.db")); defer { db.close() }
        guard let a = try db.rows("SELECT meeting_id, owner, task, due, turn_idx, exported_to, external_id, external_url FROM action_items WHERE id = ?", [actionID]).first
        else { throw StoreError("no action item \(actionID)") }
        if a.text(5) == "linear", let ident = a.text(6), !ident.isEmpty {   // idempotent: a repeat never creates a second issue
            return ["id": ident, "identifier": ident, "url": a.text(7) ?? ""]
        }
        guard let mid = a.int(0), let m = try db.rows("SELECT title, start FROM meetings WHERE id = ?", [mid]).first else { throw StoreError("no meeting \(a.int(0) ?? 0)") }
        var turn: (Double, String, String)?
        if let idx = a.int(4), let t = try db.rows("SELECT t.start, COALESCE(s.label, '?'), t.text FROM turns t LEFT JOIN speakers s ON s.id = t.speaker_id"
                                                   + " WHERE t.meeting_id = ? AND t.idx = ?", [mid, idx]).first {
            turn = (t.double(0) ?? 0, t.text(1) ?? "?", t.text(2) ?? "")
        }
        let desc = linearDescription(owner: a.text(1) ?? "", due: a.text(3) ?? "", title: m.text(0) ?? "", start: m.text(1) ?? "", turn: turn)
        let data = try await LinearAPI.call("mutation($input: IssueCreateInput!) { issueCreate(input: $input) { success issue { id identifier url } } }",
                                            variables: ["input": ["teamId": team, "title": a.text(2) ?? "", "description": desc]], key: ctx.env["EAVESDROPPY_LINEAR_KEY"])
        let res = data["issueCreate"] as? [String: Any]
        guard res?["success"] as? Bool == true, let issue = res?["issue"] as? [String: Any],
              let id = issue["id"] as? String, let ident = issue["identifier"] as? String, let url = issue["url"] as? String else { throw StoreError("Linear did not create the issue") }
        try StoreLibrary.setActionExported(db, actionID, to: "linear", externalID: ident, externalURL: url)
        return ["id": id, "identifier": ident, "url": url]
    }
}
