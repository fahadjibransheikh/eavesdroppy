import Foundation
import Testing
@testable import Eavesdroppy

// The native subcommands behind Pipeline.run: regenerate, ask, enroll, import-drive, linear-*, and the routing itself.

private struct Failing: NotesProvider {
    var id = "failing", displayName = "Failing"
    func isAvailable() async -> Bool { true }
    func complete(prompt: String) async throws -> String { throw NotesProviderError.timedOut("Failing", 5) }
}

private struct Echoing: NotesProvider {   // returns the prompt, so a test can see what reached the model
    var id = "echo", displayName = "Echo"
    func isAvailable() async -> Bool { true }
    func complete(prompt: String) async throws -> String { prompt }
}

private func ctx(_ s: Scratch, _ r: NotesProviders.Resolution = .provider(FixedProvider()), diarizer: any Diarizer = FakeDiarizer(), env: [String: String] = [:]) -> NativeCommands.Context {
    var c = NativeCommands.Context(container: s.container)
    c.outRoot = s.out; c.env = env
    c.engines = Processor.Engines(transcriber: { _ in FakeTranscriber() }, diarizer: { diarizer }, echoRemover: { UnavailableEchoRemoverStub() }, linkModel: { _ in nil }, droppyVocab: { [] })
    c.resolution = { r }
    return c
}

private func json(_ d: Data) throws -> [String: Any] { try JSONSerialization.jsonObject(with: d) as! [String: Any] }

private func processed(_ s: Scratch) async throws -> Processor.Result { try await Processor.process(s.params()) }

private func db(_ s: Scratch) throws -> StoreDB { try StoreDB(path: s.container.appendingPathComponent("library.db")) }

@Suite(.serialized) struct NativeCommandsTests {
    @Test func regenerateReplacesNotesAndRewritesTheMirror() async throws {
        let s = try Scratch(); defer { s.remove() }
        let r = try await processed(s)
        let reply = "## Summary\n- A different summary [T1]\n"
        let out = try json(try await NativeCommands.run(["regenerate", String(r.meetingID), "--template", "standup"], ctx(s, .provider(FixedProvider(reply: reply)))))
        #expect(out["ok"] as? Bool == true); #expect((out["warnings"] as? [String]) == [])
        let d = try db(s); defer { d.close() }
        let m = try d.rows("SELECT notes_md, template, summary_status FROM meetings")[0]
        #expect(m.text(0)?.contains("A different summary") == true); #expect(m.text(1) == "standup"); #expect(m.text(2) == "ok")
        #expect(try String(contentsOfFile: r.folder + "/notes.md", encoding: .utf8).contains("A different summary"))
        #expect(try d.rows("SELECT COUNT(*) FROM action_items")[0].int(0) == 0, "the new notes have no action items, so the list is replaced")
    }

    @Test func aFailedRegenerateKeepsGoodNotes() async throws {
        let s = try Scratch(); defer { s.remove() }
        let r = try await processed(s)
        let out = try json(try await NativeCommands.run(["regenerate", String(r.meetingID)], ctx(s, .provider(Failing()))))
        #expect((out["warnings"] as? [String]) == ["Summary failed: Failing timed out after 5 s"])
        let d = try db(s); defer { d.close() }
        #expect(try d.rows("SELECT notes_md, summary_status FROM meetings")[0].text(1) == "ok")
        #expect(try d.rows("SELECT notes_md FROM meetings")[0].text(0)?.contains("Fixed summary line") == true)
    }

    @Test func regenerateRefusesAMissingMeetingAndUnreadableCustomText() async throws {
        let s = try Scratch(); defer { s.remove() }
        _ = try await processed(s)
        await #expect(throws: StoreError.self) { try await NativeCommands.run(["regenerate", "99"], ctx(s)) }
        do { _ = try await NativeCommands.run(["regenerate", "1", "--custom-text-file", "/nonexistent/x.txt"], ctx(s)); Issue.record("expected a failure") }
        catch { #expect("\(error)".hasPrefix("cannot read /nonexistent/x.txt")) }
    }

    @Test func askRetrievesAndAnswers() async throws {
        let s = try Scratch(); defer { s.remove() }
        let r = try await processed(s)
        let out = try json(try await NativeCommands.run(["ask", "what did everyone say clearly", "--meeting-id", String(r.meetingID)], ctx(s, .provider(Echoing()))))
        let answer = out["answer"] as? String ?? ""
        #expect(answer.contains("what did everyone say clearly")); #expect(answer.contains("speaking clearly"), "a retrieved turn reached the prompt")
        do { _ = try await NativeCommands.run(["ask", "q", "--meeting-id", "1", "--person-id", "1"], ctx(s)); Issue.record("expected a failure") }
        catch { #expect("\(error)" == "use either --meeting-id or --person-id, not both") }
        do { _ = try await NativeCommands.run(["ask", "   "], ctx(s)); Issue.record("expected a failure") }
        catch { #expect("\(error)" == "empty question") }
        do { _ = try await NativeCommands.run(["ask", "q"], ctx(s, .none(status: "no provider here"))); Issue.record("expected a failure") }
        catch { #expect("\(error)" == "no provider here") }
    }

    @Test func importDriveRoundTripsAMirrorAndIsIdempotent() async throws {
        let s = try Scratch(); defer { s.remove() }
        let r = try await processed(s)
        let before = try String(contentsOfFile: r.folder + "/notes.md", encoding: .utf8)
        // forget the database, keep the folder: the importer must rebuild the meeting from the files alone
        try FileManager.default.removeItem(at: s.container.appendingPathComponent("library.db"))
        for ext in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: s.container.path + "/library.db" + ext) }
        let first = try json(try await NativeCommands.run(["import-drive"], ctx(s)))
        #expect(first["imported"] as? Int == 1); #expect(first["skipped"] as? Int == 0); #expect(first["failed"] as? Int == 0)
        let second = try json(try await NativeCommands.run(["import-drive"], ctx(s)))
        #expect(second["imported"] as? Int == 0); #expect(second["skipped"] as? Int == 1)
        let d = try db(s); defer { d.close() }
        let m = try d.rows("SELECT title, start, duration, attendees, folder, audio_path, summary_status, source FROM meetings")[0]
        #expect(m.text(0) == "Weekly sync"); #expect(m.text(1) == "2026-10-13T12:00:00+05:00"); #expect(m.text(3) == "[\"Alice Jones\"]")
        #expect(m.text(4) == r.folder); #expect(m.text(5) == r.folder + "/2026-10-13 1200 – Weekly sync.m4a"); #expect(m.text(6) == "ok")
        #expect(try d.rows("SELECT COUNT(*) FROM turns")[0].int(0) == 2)
        #expect(try d.rows("SELECT COUNT(*) FROM action_items")[0].int(0) == 1)
        // a sync re-renders the same files from the imported rows
        try StoreMirror.sync(d, [1], outRoot: s.out.path) { _ in }
        #expect(try String(contentsOfFile: r.folder + "/notes.md", encoding: .utf8) == before)
    }

    @Test func importDriveKeepsTheSettingAndLanguageLinesOutOfTheNotes() async throws {
        let s = try Scratch(meta: ["setting": "call", "call_apps": ["Zoom"], "language": "mixed"]); defer { s.remove() }
        let r = try await processed(s)
        let before = try String(contentsOfFile: r.folder + "/notes.md", encoding: .utf8)
        #expect(before.contains("- **Setting:** Call (Zoom)\n- **Language:** Urdu/Hindi + English (Apple)\n"))
        try FileManager.default.removeItem(at: s.container.appendingPathComponent("library.db"))
        for ext in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: s.container.path + "/library.db" + ext) }
        try FileManager.default.removeItem(at: s.container.appendingPathComponent("raw"))   // the raw archive is gone: the lines can only come from the old file
        #expect(try json(try await NativeCommands.run(["import-drive"], ctx(s)))["imported"] as? Int == 1)
        let d = try db(s); defer { d.close() }
        try StoreMirror.sync(d, [1], outRoot: s.out.path) { _ in }
        #expect(try String(contentsOfFile: r.folder + "/notes.md", encoding: .utf8) == before)
    }

    @Test func importDriveReportsAFolderItCannotParse() async throws {
        let s = try Scratch(); defer { s.remove() }
        try FileManager.default.createDirectory(atPath: s.out.path + "/bad", withIntermediateDirectories: true)
        try Data("not a transcript".utf8).write(to: URL(fileURLWithPath: s.out.path + "/bad/transcript.md"))
        let out = try json(try await NativeCommands.run(["import-drive"], ctx(s)))
        #expect(out["imported"] as? Int == 0); #expect(out["failed"] as? Int == 1)
        #expect((out["errors"] as? [String])?.first == s.out.path + "/bad: no title/date in header")
    }

    // MARK: enroll

    struct LongSpeech: Diarizer {
        var seconds = 12.0
        func diarize(_ audio: URL) async throws -> EngineDiarization {
            EngineDiarization(segments: [EngineSegment(start: 0, end: seconds, cluster: "S1"), EngineSegment(start: seconds, end: seconds + 2, cluster: "S2")],
                              embeddings: ["S1": [Float](repeating: 0, count: 255) + [1], "S2": [1] + [Float](repeating: 0, count: 255)])
        }
        func unload() async {}
    }

    @Test func enrollStoresTheDominantClusterAsMeAndUpdatesInPlace() async throws {
        let s = try Scratch(); defer { s.remove() }
        let wav = s.container.appendingPathComponent("enroll/sample.wav")
        try FileManager.default.createDirectory(at: wav.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Scratch.tone(300, to: wav)
        let out = try json(try await NativeCommands.run(["enroll", wav.path, "--name", "Fahad"], ctx(s, diarizer: LongSpeech())))
        #expect(out["seconds"] as? Double == 12.0)
        #expect(!FileManager.default.fileExists(atPath: wav.path), "the droplet's own recording is deleted")
        let elsewhere = s.root.appendingPathComponent("mine.wav")
        try Scratch.tone(300, to: elsewhere)
        let again = try json(try await NativeCommands.run(["enroll", elsewhere.path, "--name", "Fahad S"], ctx(s, diarizer: LongSpeech(seconds: 15))))
        #expect(again["person_id"] as? Int == out["person_id"] as? Int, "the Me row is updated, not duplicated")
        #expect(FileManager.default.fileExists(atPath: elsewhere.path), "a file the user pointed us at is never deleted")
        let d = try db(s); defer { d.close() }
        let rows = try d.rows("SELECT name, is_me, n, length(voiceprint) FROM people")
        #expect(rows.count == 1); #expect(rows[0].text(0) == "Fahad S"); #expect(rows[0].int(1) == 1); #expect(rows[0].int(2) == 1); #expect(rows[0].int(3) == 1024)
    }

    @Test func enrollRefusesTooLittleSpeech() async throws {
        let s = try Scratch(); defer { s.remove() }
        let wav = s.root.appendingPathComponent("short.wav")
        try Scratch.tone(300, to: wav)
        do { _ = try await NativeCommands.run(["enroll", wav.path], ctx(s, diarizer: LongSpeech(seconds: 4))); Issue.record("expected a failure") }
        catch { #expect("\(error)" == "enrollment sample has only 4.0 s of speech; need 10 s") }
        #expect(FileManager.default.fileExists(atPath: wav.path), "the sample stays so the user can retry")
        struct Silent: Diarizer { func diarize(_ a: URL) async throws -> EngineDiarization { .empty }; func unload() async {} }
        do { _ = try await NativeCommands.run(["enroll", wav.path], ctx(s, diarizer: Silent())); Issue.record("expected a failure") }
        catch { #expect("\(error)" == "enrollment sample has no detectable speech") }
    }

    // MARK: Linear

    final class StubProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
        nonisolated(unsafe) static var seen: [URLRequest] = []
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.seen.append(request)
            let (code, body) = Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func stubbed<T>(_ h: @escaping (URLRequest) -> (Int, Data), _ body: () async throws -> T) async rethrows -> T {
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [StubProtocol.self]
        StubProtocol.handler = h; StubProtocol.seen = []
        let old = LinearAPI.session; LinearAPI.session = URLSession(configuration: cfg)
        defer { LinearAPI.session = old }
        return try await body()
    }

    @Test func linearTeamsAndExportAreIdempotent() async throws {
        let s = try Scratch(); defer { s.remove() }
        _ = try await processed(s)
        let env = ["EAVESDROPPY_LINEAR_KEY": "lin_api_x"]
        // serialized: StubProtocol is process-wide state
        try await stubbed({ req in
            let body = String(data: req.httpBodyStream.map { st in st.open(); defer { st.close() }; var d = Data(); var b = [UInt8](repeating: 0, count: 4096)
                while st.hasBytesAvailable { let n = st.read(&b, maxLength: 4096); if n <= 0 { break }; d.append(b, count: n) }; return d } ?? req.httpBody ?? Data(), encoding: .utf8) ?? ""
            if body.contains("teams {") { return (200, Data(#"{"data":{"teams":{"nodes":[{"id":"t1","name":"Eng","key":"ENG"}]}}}"#.utf8)) }
            return (200, Data(#"{"data":{"issueCreate":{"success":true,"issue":{"id":"uuid-1","identifier":"ENG-7","url":"https://linear.app/x/issue/ENG-7"}}}}"#.utf8))
        }) {
            let teams = try json(try await NativeCommands.run(["linear-teams"], ctx(s, env: env)))
            #expect((teams["teams"] as? [[String: String]]) == [["id": "t1", "name": "Eng", "key": "ENG"]])
            #expect(StubProtocol.seen.first?.value(forHTTPHeaderField: "Authorization") == "lin_api_x", "personal keys go without Bearer")
            let d = try db(s); defer { d.close() }
            let aid = try d.rows("SELECT id FROM action_items")[0].int(0)!
            let made = try json(try await NativeCommands.run(["linear-export", String(aid), "--team", "t1"], ctx(s, env: env)))
            #expect(made["identifier"] as? String == "ENG-7"); #expect(made["url"] as? String == "https://linear.app/x/issue/ENG-7")
            let row = try d.rows("SELECT exported_to, external_id, external_url FROM action_items WHERE id = ?", [aid])[0]
            #expect(row.text(0) == "linear"); #expect(row.text(1) == "ENG-7")
            let seen = StubProtocol.seen.count
            let repeatCall = try json(try await NativeCommands.run(["linear-export", String(aid), "--team", "t1"], ctx(s, env: env)))
            #expect(repeatCall["identifier"] as? String == "ENG-7"); #expect(StubProtocol.seen.count == seen, "a repeat never creates a second issue")
        }
    }

    @Test func linearErrorsReadLikePythons() async throws {
        let s = try Scratch(); defer { s.remove() }
        do { _ = try await NativeCommands.run(["linear-teams"], ctx(s)); Issue.record("expected a failure") } catch { #expect("\(error)" == "Linear API key not set") }
        await stubbed({ _ in (400, Data(#"{"errors":[{"message":"bad key"},{"message":"worse"}]}"#.utf8)) }) {
            do { _ = try await NativeCommands.run(["linear-teams"], ctx(s, env: ["EAVESDROPPY_LINEAR_KEY": "k"])); Issue.record("expected a failure") }
            catch { #expect("\(error)" == "Linear: bad key; worse") }
        }
        await stubbed({ _ in (502, Data("<html>".utf8)) }) {
            do { _ = try await NativeCommands.run(["linear-teams"], ctx(s, env: ["EAVESDROPPY_LINEAR_KEY": "k"])); Issue.record("expected a failure") }
            catch { #expect("\(error)" == "Linear returned HTTP 502 with a non-JSON body") }
        }
        #expect(NativeCommands.linearDescription(owner: "Alice", due: "Fri", title: "Weekly sync", start: "2026-10-13T12:00:00+05:00", turn: (65, "Me", "hello"))
                == "Owner: Alice\nDue: Fri\n\nFrom meeting: Weekly sync (2026-10-13)\n\n> [01:05] Me: hello")
        #expect(NativeCommands.linearDescription(owner: "", due: "", title: "T", start: "2026-10-13", turn: nil) == "From meeting: T (2026-10-13)")
    }
}

/// Opt-in (tools/golden/import_golden.py): the Swift importer on the mirror folders the Python importer already read.
@Suite struct ImportGolden {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EAVESDROPPY_IMPORT_GOLDEN_DIR"] != nil)) func importsLikePython() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["EAVESDROPPY_IMPORT_GOLDEN_DIR"]!)
        for ext in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dir.path + "/sw.db" + ext) }
        let db = try StoreDB(path: dir.appendingPathComponent("sw.db")); defer { db.close() }
        let r = try StoreImport.importExisting(db, outRoot: dir.appendingPathComponent("mirror").path)
        let again = try StoreImport.importExisting(db, outRoot: dir.appendingPathComponent("mirror").path)
        let out: [String: Any] = ["imported": r.imported.count, "skipped": r.skipped, "failed": r.failed.map { [$0.0, $0.1] },
                                  "again_imported": again.imported.count, "again_skipped": again.skipped]
        try JSONSerialization.data(withJSONObject: out).write(to: dir.appendingPathComponent("sw.json"))
    }
}

#if canImport(FluidAudio)
/// Opt-in (tools/golden/enroll_golden.sh): `enroll` on the same sample process_meeting.py enrolled, with the real diarizer.
@Suite struct EnrollGolden {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EAVESDROPPY_ENROLL_GOLDEN_DIR"] != nil)) func enrollsLikePython() async throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["EAVESDROPPY_ENROLL_GOLDEN_DIR"]!)
        let container = dir.appendingPathComponent("sw-container")
        try? FileManager.default.removeItem(at: container)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        var c = NativeCommands.Context(container: container)
        c.outRoot = dir.appendingPathComponent("out")
        let data = try await NativeCommands.run(["enroll", dir.appendingPathComponent("sample.wav").path, "--name", "Fahad"], c)
        try data.write(to: dir.appendingPathComponent("sw.json"))
    }
}
#endif
