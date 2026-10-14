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

    /// Clusters S1 and S2 with the given seconds of speech; S1's embedding is `unit(hot)` so two diarizers can disagree about the voice.
    struct Voices: Diarizer {
        var s1 = 12.0, s2 = 2.0, hot = 255
        func diarize(_ audio: URL) async throws -> EngineDiarization {
            var segs = [EngineSegment(start: 0, end: s1, cluster: "S1")]
            if s2 > 0 { segs.append(EngineSegment(start: s1, end: s1 + s2, cluster: "S2")) }
            var a = [Float](repeating: 0, count: 256); a[hot] = 1
            var b = [Float](repeating: 0, count: 256); b[(hot + 1) % 256] = 1
            return EngineDiarization(segments: segs, embeddings: ["S1": a, "S2": b])
        }
        func unload() async {}
    }
    struct Silent: Diarizer { func diarize(_ a: URL) async throws -> EngineDiarization { .empty }; func unload() async {} }

    /// 25 s at 48 kHz that reads as speech to EnrollQuality: harmonics at `speechDB` in 0.6 s bursts every 0.9 s over noise at `noiseDB`.
    /// `overdrive` multiplies the speech before it is clamped to +-1.
    static func voice(to url: URL, speechDB: Double = -25, noiseDB: Double = -60, overdrive: Float = 1) throws {
        var seed: UInt64 = 7
        let a = Float(pow(10, speechDB / 20) / 2.5.squareRoot()), n = Float(pow(10, noiseDB / 20) * 3.0.squareRoot())
        let x: [Float] = (0..<(48_000 * 25)).map { i in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let noise = (Float(seed >> 40) / Float(1 << 24) * 2 - 1) * n, t = Double(i) / 48_000
            let on = t.truncatingRemainder(dividingBy: 0.9) < 0.6
            let speech = on ? (1...5).reduce(Float(0)) { $0 + a * Float(sin(2 * Double.pi * 150 * Double($1) * t)) } : 0
            return max(-1, min(1, speech * overdrive + noise))
        }
        try ProcessorAudio.writeMonoFloat(x, rate: 48_000, to: url)
    }

    private func sample(_ s: Scratch, speechDB: Double = -25, noiseDB: Double = -60, overdrive: Float = 1, name: String = "enroll/sample.wav") throws -> URL {
        let wav = s.container.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: wav.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.voice(to: wav, speechDB: speechDB, noiseDB: noiseDB, overdrive: overdrive)
        return wav
    }

    private func refused(_ s: Scratch, _ wav: URL, _ d: any Diarizer) async -> String? {
        do { _ = try await NativeCommands.run(["enroll", wav.path, "--name", "Fahad"], ctx(s, diarizer: d)); return nil } catch { return "\(error)" }
    }

    private func people(_ s: Scratch) throws -> Int { let d = try db(s); defer { d.close() }; return try d.rows("SELECT id FROM people").count }

    @Test func enrollStoresTheDominantClusterAsMeAndUpdatesInPlace() async throws {
        let s = try Scratch(); defer { s.remove() }
        let wav = try sample(s)
        let out = try json(try await NativeCommands.run(["enroll", wav.path, "--name", "Fahad"], ctx(s, diarizer: Voices())))
        #expect(out["seconds"] as? Double == 12.0)
        #expect((out["quality"] as? [String: Any])?["clusters"] as? Int == 2)
        #expect(out["confirm"] == nil)
        #expect(FileManager.default.fileExists(atPath: wav.path), "the sample is kept for diagnosis")
        let elsewhere = s.root.appendingPathComponent("mine.wav")
        try Self.voice(to: elsewhere)
        let again = try json(try await NativeCommands.run(["enroll", elsewhere.path, "--name", "Fahad S"], ctx(s, diarizer: Voices(s1: 15))))
        #expect(again["person_id"] as? Int == out["person_id"] as? Int, "the Me row is updated, not duplicated")
        #expect(FileManager.default.fileExists(atPath: elsewhere.path), "a file the user pointed us at is never deleted")
        let d = try db(s); defer { d.close() }
        let rows = try d.rows("SELECT name, is_me, n, length(voiceprint) FROM people")
        #expect(rows.count == 1); #expect(rows[0].text(0) == "Fahad S"); #expect(rows[0].int(1) == 1); #expect(rows[0].int(2) == 1); #expect(rows[0].int(3) == 1024)
    }

    @Test func enrollRefusesTooLittleSpeech() async throws {
        let s = try Scratch(); defer { s.remove() }
        let wav = try sample(s, name: "short.wav")
        #expect(await refused(s, wav, Voices(s1: 4, s2: 0)) == "Only 4.0 seconds of speech were picked up, and at least 10 are needed. Read the passage steadily and closer to the microphone.")
        #expect(FileManager.default.fileExists(atPath: wav.path), "the sample stays so the user can retry")
        #expect(await refused(s, wav, Silent()) == "No speech was picked up. Check that the right microphone is selected, then try again.")
        #expect(try people(s) == 0)
    }

    @Test func enrollRefusesAnotherVoice() async throws {
        let s = try Scratch(); defer { s.remove() }
        let wav = try sample(s)
        #expect(await refused(s, wav, Voices(s1: 14, s2: 6)) == "Another voice was picked up (30% of the speech). Record where only you are talking.")
        #expect(await refused(s, wav, Voices(s1: 16, s2: 4)) == nil, "exactly 20 % is allowed")
    }

    @Test func enrollRefusesTooQuietTooLoudAndNoisySamples() async throws {
        let s = try Scratch(); defer { s.remove() }
        let quiet = try sample(s, speechDB: -55, noiseDB: -80, name: "quiet.wav")
        #expect(try await refused(s, quiet, Voices(s2: 0))?.hasPrefix("Too quiet: your voice was recorded at -") == true)
        let loud = try sample(s, speechDB: -12, overdrive: 8, name: "loud.wav")
        #expect(try await refused(s, loud, Voices(s2: 0))?.hasPrefix("Too loud: ") == true)
        let noisy = try sample(s, speechDB: -25, noiseDB: -12, name: "noisy.wav")
        #expect(await refused(s, noisy, Voices(s2: 0)) == "Too much background noise. Move somewhere quieter, or closer to the microphone, and try again.")
        #expect(try people(s) == 0, "nothing is saved for a refused sample")
        let good = try sample(s, name: "good.wav")
        #expect(await refused(s, good, Voices(s2: 0)) == nil)
        #expect(try people(s) == 1)
    }

    @Test func enrollAsksBeforeReplacingAVoiceThatSoundsDifferent() async throws {
        let s = try Scratch(); defer { s.remove() }
        let wav = try sample(s)
        _ = try await NativeCommands.run(["enroll", wav.path, "--name", "Fahad"], ctx(s, diarizer: Voices(hot: 255)))
        let same = try json(try await NativeCommands.run(["enroll", wav.path, "--name", "Fahad"], ctx(s, diarizer: Voices(hot: 255))))
        #expect(same["confirm"] == nil); #expect(same["old_match"] as? Double == 1.0)
        let diff = try json(try await NativeCommands.run(["enroll", wav.path, "--name", "Fahad"], ctx(s, diarizer: Voices(hot: 7))))
        #expect(diff["confirm"] as? Bool == true); #expect(diff["old_match"] as? Double == 0.0); #expect(diff["person_id"] == nil)
        func print255() throws -> Bool {   // is the stored print still the first one?
            let d = try db(s); defer { d.close() }
            let v = try StoreVoiceprint.vec(try d.rows("SELECT voiceprint FROM people").first!.data(0)!)
            return v[255] == 1
        }
        #expect(try print255(), "nothing was replaced before the user said yes")
        let forced = try json(try await NativeCommands.run(["enroll", wav.path, "--name", "Fahad", "--force"], ctx(s, diarizer: Voices(hot: 7))))
        #expect(forced["confirm"] == nil); #expect(forced["person_id"] != nil)
        #expect(try !print255()); #expect(try people(s) == 1)
    }

    @Test func enrollReportsTheBestMatchToAMeetingClusterNamedMeByVoiceprint() async throws {
        let s = try Scratch(); defer { s.remove() }
        _ = try await processed(s)
        var v = [Float](repeating: 0, count: 256); v[255] = 1
        do {
            let d = try db(s); defer { d.close() }
            try d.tx { try d.run("UPDATE speakers SET kind = 'me', embedding = ? WHERE id = (SELECT MIN(id) FROM speakers)", [StoreVoiceprint.blob(v)]) }
        }
        let out = try json(try await NativeCommands.run(["enroll", try sample(s).path, "--name", "Fahad"], ctx(s, diarizer: Voices(s2: 0))))
        #expect(out["meeting_match"] as? Double == 1.0)
        let none = try Scratch(); defer { none.remove() }
        #expect(try json(try await NativeCommands.run(["enroll", try sample(none).path], ctx(none, diarizer: Voices(s2: 0))))["meeting_match"] == nil)
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
