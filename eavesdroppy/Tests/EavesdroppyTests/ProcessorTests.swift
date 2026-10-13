import AVFoundation
import Foundation
import Testing
@testable import Eavesdroppy

// Processor.process on fake engines (any build), and the golden run against process_meeting.py (personal build, opt-in).

struct FixedProvider: NotesProvider {
    var id = "fixed", displayName = "Fixed"
    var reply = "## Summary\n- Fixed summary line [T0]\n\n## Action items\n- [ ] Alice — send the numbers — Friday [T0]\n"
    func isAvailable() async -> Bool { true }
    func complete(prompt: String) async throws -> String { reply }
}

struct FakeTranscriber: Transcriber {
    func transcribe(_ audio: URL, hotwords: [String], names: Set<String>) async throws -> EngineTranscript {
        let who = audio.lastPathComponent.hasPrefix("system") ? "call" : "mic"
        let ws = "hello there everyone this is the \(who) track speaking clearly".split(separator: " ").enumerated().map {
            EngineWord(text: String($1), start: 0.2 + Double($0) * 0.25, end: 0.4 + Double($0) * 0.25)
        }
        return EngineTranscript(words: ws, durationSeconds: 3)
    }
    func unload() async {}
}

struct FakeDiarizer: Diarizer {
    func diarize(_ audio: URL) async throws -> EngineDiarization {
        let v = [Float](repeating: 0, count: 255) + [1]
        return EngineDiarization(segments: [EngineSegment(start: 0, end: 3, cluster: "S1")], embeddings: ["S1": v])
    }
    func unload() async {}
}

struct SlowTranscriber: Transcriber {
    func transcribe(_ audio: URL, hotwords: [String], names: Set<String>) async throws -> EngineTranscript {
        for _ in 0..<200 { try Task.checkCancellation(); try await Task.sleep(nanoseconds: 20_000_000) }
        return EngineTranscript(words: [], durationSeconds: 3)
    }
    func unload() async {}
}

/// A scratch container with one recorded session (two 3 s tracks) and an output folder.
struct Scratch {
    let root: URL, container: URL, session: URL, out: URL

    init(name: String = "20261013-120000-000-0001", system: Bool = true, meta: [String: Any] = [:]) throws {
        root = URL(fileURLWithPath: PyPath.resolve(FileManager.default.temporaryDirectory.path)).appendingPathComponent("proc-test-\(UUID().uuidString)")
        container = root.appendingPathComponent("container")
        session = container.appendingPathComponent("sessions/\(name)")
        out = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try Self.tone(440, to: session.appendingPathComponent("mic.wav"))
        if system { try Self.tone(660, to: session.appendingPathComponent("system.wav")) }
        var m: [String: Any] = ["title": "Weekly sync", "start": "2026-10-13T12:00:00+05:00", "attendees": ["Alice Jones"], "source": "record",
                                "track_offsets": ["mic": 0.0, "system": 0.0], "template": "general", "user_name": "Fahad", "echo_removal": true]
        for (k, v) in meta { m[k] = v }
        try JSONSerialization.data(withJSONObject: m).write(to: session.appendingPathComponent("meta.json"))
    }

    static func tone(_ hz: Double, to url: URL) throws {
        let x = (0..<(48_000 * 3)).map { Float(0.3 * sin(2 * Double.pi * hz * Double($0) / 48_000)) }
        try ProcessorAudio.writeMonoFloat(x, rate: 48_000, to: url)
    }

    static func fakeEngines(_ transcriber: any Transcriber = FakeTranscriber()) -> Processor.Engines {
        Processor.Engines(transcriber: { _ in transcriber }, diarizer: { FakeDiarizer() }, echoRemover: { UnavailableEchoRemoverStub() },
                          linkModel: { _ in nil }, droppyVocab: { [] })
    }

    func params(transcriber: any Transcriber = FakeTranscriber(), resolution: NotesProviders.Resolution = .provider(FixedProvider())) -> Processor.Params {
        var p = Processor.Params(session: session, container: container, outRoot: out.path, userName: nil, resolution: resolution)
        p.engines = Self.fakeEngines(transcriber)
        p.crashAt = nil
        return p
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

struct UnavailableEchoRemoverStub: EchoRemover {
    func clean(mic: [Float], reference: [Float]) throws -> [Float] { throw EngineError.unavailable }
}

private func count(_ db: StoreDB, _ table: String) throws -> Int { try db.rows("SELECT COUNT(*) FROM \(table)")[0].int(0) ?? -1 }

@Suite struct ProcessorTests {
    @Test func processesASessionEndToEnd() async throws {
        let s = try Scratch(); defer { s.remove() }
        let r = try await Processor.process(s.params())
        #expect(r.warnings.isEmpty, "\(r.warnings)")
        #expect(r.folder == s.out.path + "/2026-10-13 1200 – Weekly sync")
        let db = try StoreDB(path: s.container.appendingPathComponent("library.db")); defer { db.close() }
        #expect(try count(db, "meetings") == 1)
        let m = try db.rows("SELECT title, start, source, folder, audio_path, raw_dir, summary_status, notes_md, bleed, pending_folder FROM meetings")[0]
        #expect(m.text(0) == "Weekly sync"); #expect(m.text(1) == "2026-10-13T12:00:00+05:00"); #expect(m.text(2) == "record")
        #expect(m.text(3) == r.folder); #expect(m.text(4) == r.folder + "/2026-10-13 1200 – Weekly sync.m4a")
        #expect(m.text(5) == s.container.path + "/raw/20261013-120000-000-0001"); #expect(m.text(6) == "ok")
        #expect(m.text(7)?.contains("Fixed summary line [00:00]") == true); #expect(m.int(8) == 0); #expect(m.v[9] == .null)
        #expect(try count(db, "speakers") == 2); #expect(try count(db, "action_items") == 1)
        let turns = try db.rows("SELECT s.label, t.text FROM turns t JOIN speakers s ON s.id = t.speaker_id ORDER BY t.idx")
        #expect(turns.count == 2)
        #expect(Set(turns.compactMap { $0.text(0) }) == ["Me", "Speaker 1"])
        for f in ["notes.md", "transcript.md", "2026-10-13 1200 – Weekly sync.m4a"] { #expect(FileManager.default.fileExists(atPath: r.folder + "/" + f), "\(f)") }
        for f in ["mic.flac", "system.flac", "meta.json"] { #expect(FileManager.default.fileExists(atPath: m.text(5)! + "/" + f), "\(f)") }
        #expect(FileManager.default.fileExists(atPath: s.session.appendingPathComponent("mic.wav").path), "the caller removes the session, not the processor")
        #expect(try String(contentsOfFile: r.folder + "/transcript.md", encoding: .utf8).contains("# Weekly sync"))
    }

    @Test func retryReplacesTheOrphanARunLeftAndReusesItsFolder() async throws {
        let s = try Scratch(); defer { s.remove() }
        // what a killed run leaves: a meeting row with no folder, its pending folder already renamed into place
        let raw = s.container.path + "/raw/20261013-120000-000-0001", pending = s.out.path + "/2026-10-13 1200 – Weekly sync"
        try FileManager.default.createDirectory(atPath: pending, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: URL(fileURLWithPath: pending + "/notes.md"))
        do {
            let db = try StoreDB(path: s.container.appendingPathComponent("library.db")); defer { db.close() }
            let id = try StoreLibrary.addMeeting(db, NewMeeting(title: "Weekly sync", start: "2026-10-13T12:00:00+05:00", rawDir: raw, summaryStatus: "pending"))
            try StoreLibrary.setPendingFolder(db, id, pending)
        }
        let r = try await Processor.process(s.params())
        #expect(r.folder == pending, "reused the killed run's folder, not '(2)'")
        let db = try StoreDB(path: s.container.appendingPathComponent("library.db")); defer { db.close() }
        #expect(try count(db, "meetings") == 1, "the orphan row is gone")
        #expect(try String(contentsOfFile: pending + "/notes.md", encoding: .utf8).contains("Fixed summary line"))
    }

    @Test func aTakenFolderGetsASuffixWhenNoOrphanOwnsIt() async throws {
        let s = try Scratch(); defer { s.remove() }
        try FileManager.default.createDirectory(atPath: s.out.path + "/2026-10-13 1200 – Weekly sync", withIntermediateDirectories: true)
        let r = try await Processor.process(s.params())
        #expect(r.folder.hasSuffix("Weekly sync (2)"))
    }

    @Test func cancellationLeavesNoMeetingAndNoFolder() async throws {
        let s = try Scratch(); defer { s.remove() }
        let task = Task { try await Processor.process(s.params(transcriber: SlowTranscriber())) }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let db = try StoreDB(path: s.container.appendingPathComponent("library.db")); defer { db.close() }
        #expect(try count(db, "meetings") == 0)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: s.out.path))?.isEmpty ?? true)
        #expect(FileManager.default.fileExists(atPath: s.session.appendingPathComponent("mic.wav").path))
    }

    @Test func noProviderSavesTheTranscriptWithAStatus() async throws {
        let s = try Scratch(); defer { s.remove() }
        let r = try await Processor.process(s.params(resolution: .none(status: NotesProviders.noProviderStatus)))
        #expect(r.warnings == [NotesProviders.noProviderStatus])
        let db = try StoreDB(path: s.container.appendingPathComponent("library.db")); defer { db.close() }
        #expect(try db.rows("SELECT summary_status FROM meetings")[0].text(0) == "none")
        #expect(try count(db, "turns") == 2)
    }

    @Test func aTrackThatFailsToTranscribeIsAWarningAndTheOtherCarries() async throws {
        struct MicOnly: Transcriber {
            func transcribe(_ audio: URL, hotwords: [String], names: Set<String>) async throws -> EngineTranscript {
                if audio.lastPathComponent.hasPrefix("system") { throw EngineError.failed("model crashed") }
                return try await FakeTranscriber().transcribe(audio, hotwords: hotwords, names: names)
            }
            func unload() async {}
        }
        let s = try Scratch(); defer { s.remove() }
        let r = try await Processor.process(s.params(transcriber: MicOnly()))
        #expect(r.warnings == ["Call track transcription failed (model crashed)"])
    }

    @Test func everyTrackFailingFailsTheMeetingAndKeepsEverythingElseClean() async throws {
        struct Broken: Transcriber {
            func transcribe(_ audio: URL, hotwords: [String], names: Set<String>) async throws -> EngineTranscript { throw EngineError.unavailable }
            func unload() async {}
        }
        let s = try Scratch(); defer { s.remove() }
        await #expect(throws: StoreError.self) { try await Processor.process(s.params(transcriber: Broken())) }
        let db = try StoreDB(path: s.container.appendingPathComponent("library.db")); defer { db.close() }
        #expect(try count(db, "meetings") == 0)
    }

    @Test func badMetaIsRefused() async throws {
        let s = try Scratch(meta: ["start": "2026-10-13T12:00:00"]); defer { s.remove() }
        do { _ = try await Processor.process(s.params()); Issue.record("expected a failure") }
        catch { #expect("\(error)".contains("UTC offset")) }
    }
}

#if canImport(FluidAudio)
/// Opt-in: tools/golden/process_golden.py sets EAVESDROPPY_PROCESS_GOLDEN_DIR and runs this on the same scratch session
/// process_meeting.py already processed. Writes <dir>/sw.log and <dir>/sw.json; the script compares the databases.
@Suite struct ProcessorGolden {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EAVESDROPPY_PROCESS_GOLDEN_DIR"] != nil)) func goldenRun() async throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["EAVESDROPPY_PROCESS_GOLDEN_DIR"]!)
        let side = dir.appendingPathComponent("sw")
        let reply = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("tools/golden/fake_notes_reply.md"), encoding: .utf8)
        let lines = LockedBox<[String]>([])
        var p = Processor.Params(session: side.appendingPathComponent("container/sessions/20261013-123545-736-0001"),
                                 container: side.appendingPathComponent("container"), outRoot: side.appendingPathComponent("out").path,
                                 userName: "Fahad", resolution: .provider(FixedProvider(reply: PyText.strip(reply))))
        p.log = { l in lines.value += [l] }
        p.crashAt = nil
        let t0 = Date()
        let r = try await Processor.process(p)
        try lines.value.joined(separator: "\n").write(to: dir.appendingPathComponent("sw.log"), atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: ["folder": r.folder, "meeting_id": r.meetingID, "warnings": r.warnings, "seconds": Date().timeIntervalSince(t0)])
            .write(to: dir.appendingPathComponent("sw.json"))
    }
}
#endif

#if EAVESDROPPY_PERSONAL
/// Echo.removeEcho (LocalVQE) against echo.remove_echo on the same 16 kHz tracks: lags, self-check numbers, the cleaned audio.
@Suite struct EchoRemovalGolden {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EAVESDROPPY_PROCESS_GOLDEN_DIR"] != nil), arguments: ["echo", "echo-synth"])
    func removeEchoMatchesPython(sub: String) throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["EAVESDROPPY_PROCESS_GOLDEN_DIR"]!).appendingPathComponent(sub)
        let oracle = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("echo-py.json"))) as! [String: Any]
        let off = oracle["offset"] as! Double, py = oracle["remove"] as! [String: Any], det = oracle["detect"] as! [String: Any]
        let mic = try Echo.load16k(dir.appendingPathComponent("mic16k.wav")), sys = try Echo.load16k(dir.appendingPathComponent("system16k.wav"))

        let d = Echo.detect(mic: mic, system: Echo.alignStart(sys, offsetS: off))
        var report = ["detect: swift bleed=\(d.bleed) share=\(d.share ?? -1) lag=\(d.lagMs) | python bleed=\(det["bleed"]!) share=\(det["share"]!) lag=\(det["lag_ms"]!)"]
        #expect(d.bleed == (det["bleed"] as! Bool)); #expect(d.lagMs == (det["lag_ms"] as! Int))

        let r = try Echo.removeEcho(mic: mic, system: sys, remover: Engine.echoRemover(), systemOffsetS: off)
        let pyChk = py["self_check"] as! [String: Any]
        report.append("remove: swift failed=\(r.failed) reason=\(r.reason ?? "-") lag=\(r.lagMs ?? -1) chunkLags=\(r.chunkLagsMs.map { $0.map(String.init) ?? "nil" }) selfCheck=\(String(describing: r.selfCheck))")
        report.append("        python failed=\(py["failed"]!) reason=\(py["reason"] ?? "-") lag=\(py["lag_ms"]!) chunkLags=\(py["chunk_lags_ms"]!) selfCheck=\(pyChk)")
        #expect(r.failed == (py["failed"] as! Bool)); #expect(r.reason == (py["reason"] as? String)); #expect(r.lagMs == (py["lag_ms"] as? Int))
        let pyLags = (py["chunk_lags_ms"] as! [Any]).map { $0 as? Int }
        #expect(r.chunkLagsMs == pyLags)
        #expect(r.selfCheck?.reductionEchoDb == (pyChk["reduction_echo_dB"] as? Double)); #expect(r.selfCheck?.nearChangeDb == (pyChk["near_change_dB"] as? Double))
        // the cleaned audio: SNR of the Swift output against Python's
        let ref = try Echo.load16k(dir.appendingPathComponent("cleaned-py.wav"))
        let n = min(ref.count, r.cleaned.count)
        var num = 0.0, den = 1e-20
        for i in 0..<n { let e = Double(r.cleaned[i]) - Double(ref[i]); num += Double(ref[i]) * Double(ref[i]); den += e * e }
        report.append("cleaned audio: \(ref.count) vs \(r.cleaned.count) samples, SNR of swift vs python = \(10 * log10(num / den)) dB")
        try report.joined(separator: "\n").write(to: dir.appendingPathComponent("echo-sw.txt"), atomically: true, encoding: .utf8)
    }
}
#endif

#if EAVESDROPPY_PERSONAL
import Darwin

/// The responsiveness gate (research/swift-port-plan.md, Risks): process a long recording with the real engines at .utility
/// priority while the main queue is probed every 20 ms. Opt-in: EAVESDROPPY_GATE_DIR=<dir holding container/sessions/<name>>
/// (tools/golden/make_long_fixture.py). Writes <dir>/gate.json and prints "GATE ..." lines.
@Suite struct ProcessingGate {
    final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var latencies: [Double] = [], footprints: [(t: Double, mb: Double)] = [], stop = false
        let t0 = Date()
        func record(_ v: Double) { lock.withLock { latencies.append(v) } }
        func note(_ mb: Double) { lock.withLock { footprints.append((Date().timeIntervalSince(t0), mb)) } }
        var halted: Bool { lock.withLock { stop } }
        func halt() { lock.withLock { stop = true } }
        var snapshot: ([Double], [(t: Double, mb: Double)]) { lock.withLock { (latencies, footprints) } }
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t(); var n = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n) } }
        return r == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    static func cpuSeconds() -> Double {
        var u = rusage(); getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
    }

    static func pct(_ v: [Double], _ p: Double) -> Double { v.isEmpty ? -1 : v.sorted()[min(v.count - 1, Int(Double(v.count) * p))] }

    @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["EAVESDROPPY_GATE_DIR"] != nil))
    func aLongRecordingKeepsTheMainThreadResponsive() async throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["EAVESDROPPY_GATE_DIR"]!)
        let name = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("container/sessions").path).first { !$0.hasPrefix(".") }!
        let out = dir.appendingPathComponent("out")
        try? FileManager.default.removeItem(at: out)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("container/raw"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("container/library.db"))
        let probe = Probe()
        let stages = LockedBox<[(Double, String)]>([])
        var p = Processor.Params(session: dir.appendingPathComponent("container/sessions/\(name)"), container: dir.appendingPathComponent("container"),
                                 outRoot: out.path, userName: "Fahad", resolution: .provider(FixedProvider()))
        p.log = { l in stages.value += [(Date().timeIntervalSince(probe.t0), l)] }
        p.crashAt = nil
        let sampler = Thread {
            var lastMem = 0.0
            while !probe.halted {
                let sent = Date()
                DispatchQueue.main.async { probe.record(Date().timeIntervalSince(sent) * 1000) }
                if Date().timeIntervalSince(probe.t0) - lastMem >= 2 { lastMem = Date().timeIntervalSince(probe.t0); probe.note(ProcessingGate.footprintMB()) }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        sampler.qualityOfService = QualityOfService.userInteractive
        let cpu0 = Self.cpuSeconds(), wall0 = Date(), mem0 = Self.footprintMB()
        sampler.start()
        let params = p
        let result = try await Task.detached(priority: .utility) { try await Processor.process(params) }.value
        let wall = Date().timeIntervalSince(wall0), cpu = Self.cpuSeconds() - cpu0
        probe.halt()
        try await Task.sleep(nanoseconds: 100_000_000)
        let (lat, mem) = probe.snapshot
        var u = rusage(); getrusage(RUSAGE_SELF, &u)
        let report: [String: Any] = [
            "wall_s": wall, "cpu_s": cpu, "avg_cores": cpu / wall, "peak_rss_mb": Double(u.ru_maxrss) / 1_048_576,
            "footprint_start_mb": mem0, "footprint_peak_mb": mem.map(\.mb).max() ?? -1, "footprint_end_mb": Self.footprintMB(),
            "main_samples": lat.count, "main_latency_ms": ["p50": Self.pct(lat, 0.5), "p90": Self.pct(lat, 0.9), "p99": Self.pct(lat, 0.99), "max": lat.max() ?? -1,
                                                          "over_50ms": lat.filter { $0 > 50 }.count, "over_100ms": lat.filter { $0 > 100 }.count, "over_250ms": lat.filter { $0 > 250 }.count],
            "stages": stages.value.map { "\(String(format: "%.1f", $0.0)) s  \($0.1)" }, "footprint_timeline_mb": mem.map { "\(String(format: "%.0f", $0.t)) s: \(String(format: "%.0f", $0.mb))" },
            "warnings": result.warnings, "folder": result.folder,
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: dir.appendingPathComponent("gate.json"))
        print("GATE", String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
        #expect(lat.count > 100, "the main queue was serviced while the job ran")
    }
}
#endif
