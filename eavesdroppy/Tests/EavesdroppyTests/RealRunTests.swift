import Foundation
import Testing
@testable import Eavesdroppy

// Opt-in runs on real audio, for the numbers in research/swift-port-plan.md (D33 to D36). Each test does nothing unless its
// environment variable is set, so the suite stays hermetic. Output goes to stdout ("REAL ..." lines).
//
//   EAVESDROPPY_REAL_SESSION=<dir with mic.wav [system.wav] meta.json>   Processor.process on a copy, notes provider off
//     + EAVESDROPPY_REAL_CONTAINER=<container> EAVESDROPPY_REAL_OUT=<output folder>   instead: the session (already inside
//       <container>/sessions) is processed in place into the real library and folder, with the user's notes provider (as the droplet does)
//   EAVESDROPPY_REAL_CMD="delete 2" + the two above   one StoreCommands subcommand on the real library (delete, rename-meeting ...)
//   EAVESDROPPY_EMBED_WAVS=a.wav,b.wav EAVESDROPPY_EMBED_OUT=<json>     speaker embedding of each wav by the enrollment path and by the meeting path
//   EAVESDROPPY_DETECT_WAVS=a.wav,b.wav                                  language-detection score of each 16 kHz mono wav
//   EAVESDROPPY_CANCEL_WAV=<16 kHz mono wav, 1+ min>                    cancels Apple's transcription after 1 s and times how long it takes to stop
//   EAVESDROPPY_COMPARE_WAV=<16 kHz mono wav> EAVESDROPPY_COMPARE_OUT=<dir>   words of mul_IN, en_US (and Parakeet) as text files

private let env = ProcessInfo.processInfo.environment

@Suite struct RealRunTests {
    @Test func processARealSession() async throws {
        guard let path = env["EAVESDROPPY_REAL_SESSION"] else { return }
        let fm = FileManager.default
        let live = env["EAVESDROPPY_REAL_CONTAINER"].map { (container: URL(fileURLWithPath: $0), out: env["EAVESDROPPY_REAL_OUT"]!) }
        let root = URL(fileURLWithPath: PyPath.resolve(fm.temporaryDirectory.path)).appendingPathComponent("real-run-\(UUID().uuidString)")
        let name = URL(fileURLWithPath: path).lastPathComponent
        let container = live?.container ?? root.appendingPathComponent("container"), session = container.appendingPathComponent("sessions/\(name)")
        if live == nil {
            try fm.createDirectory(at: container.appendingPathComponent("sessions"), withIntermediateDirectories: true)
            try fm.copyItem(at: URL(fileURLWithPath: path), to: session)
        }
        defer { if live == nil, env["EAVESDROPPY_KEEP"] == nil { try? fm.removeItem(at: root) } }

        let lines = LockedBox<[String]>([])
        let t0 = Date()
        var p = Processor.Params(session: session, container: container, outRoot: live?.out ?? root.appendingPathComponent("out").path, userName: nil,
                                 resolution: live == nil ? .none(status: "notes off for the real run") : await NotesProviders.resolve(NotesProviderConfig()))
        p.log = { l in lines.value.append(l); print("REAL log +\(String(format: "%.1f", Date().timeIntervalSince(t0))) s: \(l)") }
        p.crashAt = nil
        let r = try await Processor.process(p)
        let elapsed = Date().timeIntervalSince(t0)

        let notes = try String(contentsOfFile: r.folder + "/notes.md", encoding: .utf8)
        let header = notes.components(separatedBy: "\n\n")[1]
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: container.appendingPathComponent("raw/\(name)/meta.json"))) as! [String: Any]
        let body = notes.components(separatedBy: "## Transcript\n\n").last ?? ""
        let nonLatin = body.unicodeScalars.filter { RomanScript.needsTransliteration(String($0)) }.count
        let letters = body.unicodeScalars.filter { $0.properties.isAlphabetic }
        let latin = letters.filter { $0.value < 0x250 }.count
        print("REAL session \(name): total \(String(format: "%.1f", elapsed)) s, \(body.split(whereSeparator: \.isWhitespace).count) transcript words, warnings \(r.warnings)")
        print("REAL header: \(header.replacingOccurrences(of: "\n", with: " | "))")
        print("REAL engine \(raw["stt_engine"] ?? "?") locale \(raw["stt_locale"] ?? "?") language \(raw["transcript_language"] ?? "?") because \(raw["stt_reason"] ?? "?")")
        print("REAL script: \(nonLatin) Arabic/Devanagari characters; \(latin) of \(letters.count) letters are Latin (\(String(format: "%.1f", Double(latin) * 100 / Double(max(letters.count, 1)))) %)")
        for l in body.split(separator: "\n").filter({ !$0.isEmpty }).prefix(Int(env["EAVESDROPPY_REAL_LINES"] ?? "") ?? 14) { print("REAL | \(l.prefix(260))") }
        #expect(nonLatin == 0)
    }

    @Test func runARealStoreCommand() async throws {
        guard let cmd = env["EAVESDROPPY_REAL_CMD"], let c = env["EAVESDROPPY_REAL_CONTAINER"], let out = env["EAVESDROPPY_REAL_OUT"] else { return }
        let data = try StoreCommands.run(cmd.split(separator: " ").map(String.init), container: URL(fileURLWithPath: c), outRoot: URL(fileURLWithPath: out),
                                         warn: { print("REAL warn: \($0)") })
        print("REAL cmd \(cmd): \(String(decoding: data, as: UTF8.self))")
    }

    /// Speaker embedding of each wav by the enrollment path (Echo.load16k, writeMono16) and by the meeting path (prepareTrack, to16kWav),
    /// dominant cluster of each, as JSON in EAVESDROPPY_EMBED_OUT.
    @Test func embedWavsBothWays() async throws {
        guard let list = env["EAVESDROPPY_EMBED_WAVS"], let out = env["EAVESDROPPY_EMBED_OUT"] else { return }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("embed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        func dominant(_ r: EngineDiarization) -> (secs: Double, emb: [Float])? {
            var secs: [String: Double] = [:]
            for s in r.segments { secs[s.cluster, default: 0] += s.end - s.start }
            guard let c = secs.max(by: { $0.value < $1.value })?.key, let e = r.embeddings[c] else { return nil }
            return (secs[c]!, e)
        }
        var result: [String: Any] = [:]
        for path in list.split(separator: ",").map(String.init) {
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            let d = Engine.diarizer()
            let a = tmp.appendingPathComponent("\(name)-enroll.wav")
            try ProcessorAudio.writeMono16(try Echo.load16k(URL(fileURLWithPath: path)), rate: 16_000, to: a)
            let ea = dominant(try await d.diarize(a))
            let tr = try EngineAudio.prepareTrack(key: name, src: URL(fileURLWithPath: path), tmp: tmp)
            let b = tmp.appendingPathComponent("\(name)-meeting.wav")
            try EngineAudio.to16kWav(tr.mono, b)
            let eb = dominant(try await d.diarize(b))
            await d.unload()
            result[name] = ["enroll": ea?.emb ?? [], "enroll_secs": ea?.secs ?? 0, "meeting": eb?.emb ?? [], "meeting_secs": eb?.secs ?? 0]
            print("REAL embed \(name): enroll \(ea?.secs ?? 0) s, meeting \(eb?.secs ?? 0) s")
        }
        try JSONSerialization.data(withJSONObject: result).write(to: URL(fileURLWithPath: out))
    }

    @Test func scoreLanguageDetectionOfWavs() async throws {
        guard let list = env["EAVESDROPPY_DETECT_WAVS"] else { return }
        let apple = AppleTranscriber(locale: Routing.mixedLocale, log: { print("REAL \($0)") })
        for path in list.split(separator: ",").map(String.init) {
            let ex = FileManager.default.temporaryDirectory.appendingPathComponent("detect-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: ex) }
            let t0 = Date()
            let secs = try ProcessorAudio.speechExcerpt(URL(fileURLWithPath: path), to: ex, seconds: LanguageDetector.excerptSeconds)
            guard secs > 0 else { print("REAL detect \(URL(fileURLWithPath: path).lastPathComponent): no voiced audio"); continue }
            let words = try await apple.transcribe(ex, hotwords: [], names: []).words.map(\.text)
            let d = LanguageDetector.share(of: words)
            let hits = Dictionary(grouping: LanguageDetector.tokens(words).filter(LanguageDetector.functionWords.contains), by: { $0 }).mapValues(\.count)
            print("REAL detect \(URL(fileURLWithPath: path).lastPathComponent): excerpt \(String(format: "%.0f", secs)) s, \(d.tokens) words, share \(String(format: "%.2f", d.share * 100)) %, took \(String(format: "%.1f", Date().timeIntervalSince(t0))) s; top \(hits.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        }
    }

    @Test func compareEnginesOnAWav() async throws {
        guard let wav = env["EAVESDROPPY_COMPARE_WAV"], let out = env["EAVESDROPPY_COMPARE_OUT"] else { return }
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        var engines: [(String, any Transcriber)] = [("apple-mul_IN", AppleTranscriber(locale: "mul_IN")), ("apple-en_US", AppleTranscriber(locale: "en_US"))]
        if Engine.hasParakeet { engines.append(("parakeet", Engine.transcriber(modelDir: EngineVocab.linkDroppyModel(into: FileManager.default.temporaryDirectory.appendingPathComponent("cmp-\(UUID().uuidString)"))))) }
        let base = URL(fileURLWithPath: wav).deletingPathExtension().lastPathComponent
        for (name, t) in engines {
            let t0 = Date()
            let r = try await t.transcribe(URL(fileURLWithPath: wav), hotwords: [], names: [])
            let secs = Date().timeIntervalSince(t0)
            await t.unload()
            try r.words.map(\.text).joined(separator: " ").write(toFile: "\(out)/\(base).\(name).txt", atomically: true, encoding: .utf8)
            print("REAL compare \(base) \(name): \(r.words.count) words in \(String(format: "%.2f", secs)) s")
        }
    }

    @Test func cancellingAppleTranscriptionStopsPromptly() async throws {
        guard let wav = env["EAVESDROPPY_CANCEL_WAV"] else { return }
        let apple = AppleTranscriber(locale: Routing.mixedLocale)
        let task = Task { try await apple.transcribe(URL(fileURLWithPath: wav), hotwords: [], names: []) }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let t0 = Date()
        task.cancel()
        let outcome: String
        do { _ = try await task.value; outcome = "finished normally" } catch is CancellationError { outcome = "CancellationError" } catch { outcome = "other error: \(error)" }
        let took = Date().timeIntervalSince(t0)
        print("REAL cancel: \(outcome) \(String(format: "%.2f", took)) s after cancel")
        #expect(took < 5)
    }
}
