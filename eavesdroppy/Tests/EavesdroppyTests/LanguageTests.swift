import AVFoundation
import Foundation
import Testing
@testable import Eavesdroppy

// Engine and language routing (D33 to D36): script enforcement, language scoring, the routing table, the notes header,
// and the processor choosing one engine per meeting on fake engines (any build).

private final class Lines: @unchecked Sendable {
    private let lock = NSLock(); private var v: [String] = []
    func add(_ s: String) { lock.withLock { v.append(s) } }
    var all: [String] { lock.withLock { v } }
}

/// Records the locales the processor asked Apple for.
private final class Asked: @unchecked Sendable {
    private let lock = NSLock(); private var v: [String] = []
    func add(_ s: String) { lock.withLock { v.append(s) } }
    var all: [String] { lock.withLock { v } }
}

private func scalarsIn(_ s: String) -> Bool { RomanScript.needsTransliteration(s) }

@Suite struct RomanScriptTests {
    @Test func devanagariAndPerso_ArabicWordsComeOutLatin() {
        let words = ["नहीं", "हमारा", "मैं", "نہیں", "میں", "ہے", "کیا", "ٹھیک", "٣٤"].enumerated().map { EngineWord(text: $1, start: Double($0), end: Double($0) + 0.5) }
        let r = RomanScript.enforce(words)
        #expect(r.count == 9)
        #expect(r.words.count == 9)
        for w in r.words {
            #expect(!w.text.isEmpty); #expect(!scalarsIn(w.text), "\(w.text)")
            #expect(w.text.unicodeScalars.allSatisfy { $0.isASCII }, "diacritics stripped: \(w.text)")
        }
        #expect(r.words.map(\.start) == words.map(\.start), "timings untouched")
    }

    @Test func knownWordsComeOutAsExpected() {
        #expect(RomanScript.latinize("नहीं") == "nahim"); #expect(RomanScript.latinize("हमारा") == "hamara"); #expect(RomanScript.latinize("ہے") == "hai")
        #expect(RomanScript.latinize("کیا") == "kya"); #expect(RomanScript.latinize("،") == ",")
    }

    @Test func latinWordsAreUntouchedAndNotCounted() {
        let words = [EngineWord(text: "Hamara", start: 0, end: 1), EngineWord(text: "résumé", start: 1, end: 2), EngineWord(text: "Q3", start: 2, end: 3)]
        let r = RomanScript.enforce(words)
        #expect(r.words == words); #expect(r.count == 0)
    }

    @Test func aMixedWordKeepsItsLatinPart() {
        let r = RomanScript.enforce([EngineWord(text: "Q3में", start: 0, end: 1)])
        #expect(r.count == 1)
        #expect(r.words.count == 1 && r.words[0].text.hasPrefix("Q3") && !scalarsIn(r.words[0].text), "\(r.words)")
    }

    @Test func aMarkThatTransliteratesToNothingIsDropped() {
        let r = RomanScript.enforce([EngineWord(text: "\u{064B}", start: 0, end: 1), EngineWord(text: "ok", start: 1, end: 2)])   // a bare Arabic fathatan
        #expect(r.count == 1); #expect(r.words.map(\.text) == ["ok"])
    }

    @Test func everyListedRangeIsDetected() {
        for u in [0x0600, 0x06FF, 0x0750, 0x077F, 0xFB50, 0xFDFF, 0xFE70, 0xFEFF, 0x0900, 0x097F] as [UInt32] {
            #expect(RomanScript.needsTransliteration("a" + String(UnicodeScalar(u)!)), Comment(rawValue: String(u, radix: 16)))
        }
        for u in [0x05FF, 0x0780, 0xFB4F, 0xFE6F, 0x08FF, 0x0980] as [UInt32] {   // one outside each edge
            #expect(!RomanScript.needsTransliteration(String(UnicodeScalar(u)!)), Comment(rawValue: String(u, radix: 16)))
        }
    }
}

@Suite struct LanguageDetectorTests {
    @Test func englishScoresNearZeroAndRomanUrduHigh() {
        let en = "Anyway this is the top five features of iOS 27 in my order of how good they are. Also if you haven't already gotten subscribed to the channel".split(separator: " ").map(String.init)
        let ur = "Kuch gaps hai unko aapne wahan pe rehire karna hai, engineering side pe. Mujhe lagta hai ki hum log is par kaam kar rahe hain aur ye theek hai".split(separator: " ").map(String.init)
        #expect(LanguageDetector.share(of: en).share < LanguageDetector.threshold)
        #expect(LanguageDetector.share(of: ur).share > 0.1)
        #expect(LanguageDetector.share(of: []).tokens == 0)
    }

    @Test func caseAndPunctuationDoNotMatter() {
        let s = LanguageDetector.share(of: ["Hai,", "NAHI.", "\"Kya\"", "hello"])
        #expect(s.tokens == 4); #expect(s.share == 0.75)
    }

    @Test func wordsEnglishAlsoUsesAreNotCounted() {
        for w in ["main", "to", "is", "me", "the", "so", "or", "he", "she"] { #expect(!LanguageDetector.functionWords.contains(w), Comment(rawValue: w)) }
    }
}

@Suite struct RoutingTests {
    private let both = EngineAvailability(parakeet: true, apple: true)
    private let appleOnly = EngineAvailability(parakeet: false, apple: true)
    private let parakeetOnly = EngineAvailability(parakeet: true, apple: false)
    private let neither = EngineAvailability(parakeet: false, apple: false)

    private func plan(_ s: MeetingLanguage, _ a: EngineAvailability) throws -> (Routing.Plan, [String]) {
        var w: [String] = []
        let p = try Routing.plan(s, a, warnings: &w)
        return (p, w)
    }

    @Test func englishGoesToParakeetOrAppleEnUS() throws {
        guard case .fixed(let c) = try plan(.english, both).0 else { Issue.record("not fixed"); return }
        #expect(c.engine == .parakeet && c.label == "English (Parakeet)")
        guard case .fixed(let s) = try plan(.english, appleOnly).0 else { Issue.record("not fixed"); return }
        #expect(s.engine == .apple && s.locale == Routing.englishLocale && s.label == "English (Apple)")
    }

    @Test func mixedGoesToAppleMulIN() throws {
        for a in [both, appleOnly] {
            guard case .fixed(let c) = try plan(.mixed, a).0 else { Issue.record("not fixed"); return }
            #expect(c.engine == .apple && c.locale == "mul_IN" && c.mixed && c.label == "Urdu/Hindi + English (Apple)")
        }
    }

    @Test func mixedWithoutAppleFallsBackToParakeetWithAWarningAndFailsInTheStoreBuild() throws {
        let (p, w) = try plan(.mixed, parakeetOnly)
        guard case .fixed(let c) = p else { Issue.record("not fixed"); return }
        #expect(c.engine == .parakeet && !c.mixed); #expect(w.count == 1 && w[0].contains("macOS 26"))
        #expect(throws: StoreError.self) { _ = try plan(.mixed, neither) }
    }

    @Test func autoDetectsWhenAppleIsThereAndFallsBackWhenItIsNot() throws {
        #expect(try plan(.auto, both).0 == .detect); #expect(try plan(.auto, appleOnly).0 == .detect)
        guard case .fixed(let c) = try plan(.auto, parakeetOnly).0 else { Issue.record("not fixed"); return }
        #expect(c.engine == .parakeet)
        #expect(throws: StoreError.self) { _ = try plan(.auto, neither) }
    }

    @Test func detectionResultPicksTheEngineAtTheThreshold() throws {
        let t = LanguageDetector.threshold
        #expect(try Routing.resolve(share: t, tokens: 500, both).engine == .apple)
        #expect(try Routing.resolve(share: t, tokens: 500, both).mixed)
        #expect(try Routing.resolve(share: t - 0.001, tokens: 500, both).engine == .parakeet)
        #expect(try Routing.resolve(share: 0.3, tokens: LanguageDetector.minTokens - 1, both).engine == .parakeet, "too little to judge by")
        let store = try Routing.resolve(share: 0, tokens: 500, appleOnly)
        #expect(store.engine == .apple && !store.mixed && store.label == "English (Apple)")
    }

    @Test func theLanguageSettingParsesAndDefaultsToAuto() {
        #expect(MeetingLanguage.parse("mixed") == .mixed); #expect(MeetingLanguage.parse("english") == .english)
        #expect(MeetingLanguage.parse(nil) == .auto); #expect(MeetingLanguage.parse("klingon") == .auto)
    }
}

@Suite struct SpeechExcerptTests {
    @Test func joinsTheVoicedWindowsAndStopsAtTheLimit() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("excerpt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tone = (0..<32_000).map { Float(0.3 * sin(2 * Double.pi * 300 * Double($0) / 16_000)) }, quiet = [Float](repeating: 0, count: 16_000)
        let src = dir.appendingPathComponent("t.wav"), dst = dir.appendingPathComponent("x.wav")
        try ProcessorAudio.writeMono16(quiet + tone + quiet + tone, rate: 16_000, to: src)   // 1 s quiet, 2 s tone, 1 s quiet, 2 s tone
        #expect(try ProcessorAudio.speechExcerpt(src, to: dst, seconds: 3) == 3)
        #expect(try AVAudioFile(forReading: dst).length == 48_000)
        #expect(try ProcessorAudio.speechExcerpt(src, to: dst, seconds: 100) == 4, "all the voiced audio when there is less than the limit")
        try ProcessorAudio.writeMono16(quiet + quiet, rate: 16_000, to: src)
        try? FileManager.default.removeItem(at: dst)
        #expect(try ProcessorAudio.speechExcerpt(src, to: dst, seconds: 3) == 0 || !FileManager.default.fileExists(atPath: dst.path))
    }
}

@Suite struct LanguageProcessingTests {
    private func run(_ meta: [String: Any], apple: @escaping (String) -> any Transcriber = { FakeApple(locale: $0) },
                     availability: EngineAvailability = EngineAvailability(parakeet: true, apple: true), hasDiarizer: Bool = true,
                     lines: Lines = Lines(), asked: Asked = Asked()) async throws -> (Scratch, Processor.Result, Lines, Asked) {
        let s = try Scratch(meta: meta)
        var p = s.params(engines: Scratch.fakeEngines(FakeTranscriber(), apple: { loc in asked.add(loc); return apple(loc) }, availability: availability, hasDiarizer: hasDiarizer))
        p.log = { lines.add($0) }
        let r = try await Processor.process(p)
        return (s, r, lines, asked)
    }

    private func notes(_ r: Processor.Result) throws -> String { try String(contentsOfFile: r.folder + "/notes.md", encoding: .utf8) }
    private func rawMeta(_ s: Scratch) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: s.container.appendingPathComponent("raw/20261013-120000-000-0001/meta.json"))) as! [String: Any]
    }

    @Test func mixedUsesAppleOnEveryTrackAndRecordsIt() async throws {
        let (s, r, lines, asked) = try await run(["language": "mixed"]); defer { s.remove() }
        #expect(asked.all == ["mul_IN"], "one engine for the whole meeting: \(asked.all)")
        #expect(try notes(r).contains("- **Language:** Urdu/Hindi + English (Apple)\n"))
        #expect(try notes(r).contains("apple track speaking"), "both tracks went to Apple")
        let m = try rawMeta(s)
        #expect(m["transcript_language"] as? String == "Urdu/Hindi + English (Apple)"); #expect(m["stt_engine"] as? String == "apple"); #expect(m["stt_locale"] as? String == "mul_IN")
        #expect(lines.all.contains { $0.hasPrefix("Language: Urdu/Hindi + English (Apple)") }, "\(lines.all)")
        #expect(!lines.all.contains("Detecting language"), "a chosen language needs no detection")
    }

    @Test func englishUsesParakeetEvenWhenAppleIsAvailable() async throws {
        let (s, r, _, asked) = try await run(["language": "english"]); defer { s.remove() }
        #expect(asked.all.isEmpty); #expect(try notes(r).contains("- **Language:** English (Parakeet)\n")); #expect(try notes(r).contains("clearly"))
        #expect(try rawMeta(s)["stt_engine"] as? String == "parakeet")
    }

    @Test func autoRoutesAMixedMeetingToAppleAndAnEnglishOneToParakeet() async throws {
        let urdu = try await run([:], apple: { FakeApple(locale: $0, text: FakeApple.urdu) })
        defer { urdu.0.remove() }
        #expect(try notes(urdu.1).contains("- **Language:** Urdu/Hindi + English (Apple)\n"))
        #expect(urdu.2.all.contains("Detecting language")); #expect(urdu.3.all == ["mul_IN", "mul_IN"], "the pre-pass, then the meeting: \(urdu.3.all)")
        let en = try await run([:]); defer { en.0.remove() }
        #expect(try notes(en.1).contains("- **Language:** English (Parakeet)\n")); #expect(en.3.all == ["mul_IN"], "only the pre-pass: \(en.3.all)")
    }

    @Test func devanagariFromAnEngineIsWrittenInLatinAndCounted() async throws {
        let (s, r, lines, _) = try await run(["language": "mixed"], apple: { FakeApple(locale: $0, text: "yeh मीटिंग नहीं hai") }); defer { s.remove() }
        let n = try notes(r)
        #expect(!n.unicodeScalars.contains { RomanScript.needsTransliteration(String($0)) }, Comment(rawValue: n))
        #expect(lines.all.contains("Roman script: 4 of 8 words transliterated to Latin"), "\(lines.all.filter { $0.hasPrefix("Roman") })")   // 2 per track
    }

    @Test func theStoreBuildTranscribesEnglishWithApple() async throws {
        let (s, r, lines, asked) = try await run(["language": "english"], availability: EngineAvailability(parakeet: false, apple: true), hasDiarizer: false); defer { s.remove() }
        #expect(asked.all == [Routing.englishLocale]); #expect(try notes(r).contains("- **Language:** English (Apple)\n"))
        #expect(lines.all.contains { $0.hasPrefix("Speaker separation: not available") })
        #expect(r.warnings.isEmpty, "\(r.warnings)")
        let db = try StoreDB(path: s.container.appendingPathComponent("library.db")); defer { db.close() }
        #expect(Set(try db.rows("SELECT label FROM speakers").compactMap { $0.text(0) }) == ["Me", "Them"], "one speaker per track")
    }

    @Test func noEngineAtAllIsAClearError() async throws {
        let s = try Scratch(meta: ["language": "english"]); defer { s.remove() }
        var p = s.params(engines: Scratch.fakeEngines(availability: EngineAvailability(parakeet: false, apple: false)))
        p.log = { _ in }
        await #expect(throws: StoreError.self) { _ = try await Processor.process(p) }
    }

    @Test func mixedWithoutAppleFallsBackToParakeetAndWarns() async throws {
        let (s, r, _, asked) = try await run(["language": "mixed"], availability: EngineAvailability(parakeet: true, apple: false)); defer { s.remove() }
        #expect(asked.all.isEmpty); #expect(r.warnings.contains { $0.contains("macOS 26") }, "\(r.warnings)")
        #expect(try notes(r).contains("- **Language:** English (Parakeet)\n"))
    }

    @Test func aFailedDetectionFallsBackToParakeetWithAWarning() async throws {
        struct Broken: Transcriber {
            func transcribe(_ audio: URL, hotwords: [String], names: Set<String>) async throws -> EngineTranscript { throw EngineError.failed("no speech model") }
            func unload() async {}
        }
        let (s, r, _, _) = try await run([:], apple: { _ in Broken() }); defer { s.remove() }
        #expect(r.warnings.contains { $0.hasPrefix("Language detection failed (no speech model)") }, "\(r.warnings)")
        #expect(try notes(r).contains("- **Language:** English (Parakeet)\n"))
    }

    @Test func theHeaderIsKeptWhenTheRawAudioExpires() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lang-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("raw"), withIntermediateDirectories: true)
        try Data(#"{"transcript_language":"Urdu\/Hindi + English (Apple)","setting":"in_person"}"#.utf8).write(to: dir.appendingPathComponent("raw/meta.json"))
        var m = StoreMirror.Meeting(id: 1, title: "Sync", start: "2026-10-13T19:22:30+05:00", duration: 60, attendees: [], notesMD: "## Summary\n\nx",
                                    folder: nil, audioPath: nil, turns: [], rawDir: dir.path + "/raw")
        #expect(try StoreMirror.header(m).hasSuffix("- **Setting:** In person\n- **Language:** Urdu/Hindi + English (Apple)"))
        let first = try StoreMirror.write(m, outRoot: dir.path + "/out")
        try FileManager.default.removeItem(at: dir.appendingPathComponent("raw"))
        m.rawDir = nil; m.folder = first.folder
        _ = try StoreMirror.write(m, outRoot: dir.path + "/out")
        #expect(try String(contentsOfFile: first.folder + "/notes.md", encoding: .utf8).contains("- **Language:** Urdu/Hindi + English (Apple)\n"))
        m.folder = nil; m.title = "Other"; m.rawDir = nil
        #expect(try !String(contentsOfFile: StoreMirror.write(m, outRoot: dir.path + "/out2").folder + "/notes.md", encoding: .utf8).contains("Language"), "a meeting that never had one gains none")
    }

    @Test func theProcessingRowShowsTheDownloadAndDetection() {
        #expect(processingStage(afterLog: "Detecting language") == "Detecting language")
        #expect(processingStage(afterLog: "Downloading speech model… 42 %") == "Downloading speech model… 42 %")
        #expect(processingStage(afterLog: "Speech model ready") == "Transcribing")
        #expect(processingStage(afterLog: "Transcribing with Apple (mul_IN)") == "Transcribing", "the row leaves 'Detecting language' when the real transcription starts")
        #expect(processingStage(afterLog: "stage echo done at +1.0 s") == "Transcribing")
    }
}
