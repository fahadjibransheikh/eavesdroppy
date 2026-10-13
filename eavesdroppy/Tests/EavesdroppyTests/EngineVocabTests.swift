import AVFoundation
import Foundation
import Testing
@testable import Eavesdroppy

/// Golden tests for Port/Engine*.swift. Fixture: Fixtures/engine_vocab.json, produced by running the Python oracle
/// (tools/golden/engine_golden.py).
private struct Golden: Decodable {
    struct Attendees: Decodable { var attendees: [String]; var expected: [String] }
    struct Hot: Decodable { var attendees: [String]; var vocab: [String]; var expected: [String] }
    struct Droppy: Decodable { var raw: String; var expected: [String] }
    struct Vocab: Decodable { var hotwords: [String]; var names: [String] }
    struct Link: Decodable { var joint: String?; var linked: Bool; var files: [String] }
    struct Raw: Decodable { var word: String; var start: Double; var end: Double }
    struct Align: Decodable { var raw: [Raw]; var text: String; var expected: [EngineWord] }
    var common_words: [String]
    var attendees: [Attendees]
    var hotwords: [Hot]
    var droppy_vocab: [Droppy]
    var vocab_json: [Vocab]
    var link_model: [Link]
    var align: [Align]
}

private func golden() throws -> Golden {
    let url = try #require(Bundle.module.url(forResource: "engine_vocab", withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
}

private func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("engine-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@Test func attendeeNamesMatchPython() throws {
    let g = try golden(), common = Set(g.common_words)
    for c in g.attendees { #expect(EngineVocab.attendeeNames(c.attendees, commonWords: common) == c.expected, "\(c.attendees)") }
}

@Test func hotwordsMatchPython() throws {
    let g = try golden(), common = Set(g.common_words)
    for c in g.hotwords {
        #expect(EngineVocab.buildHotwords(attendees: c.attendees, vocabLines: c.vocab, commonWords: common) == c.expected, "\(c.attendees) \(c.vocab)")
    }
}

@Test func droppyVocabLinesMatchPython() throws {
    for c in try golden().droppy_vocab {
        #expect(EngineVocab.droppyVocabLines(c.raw) == c.expected, "\(c.raw)")
        #expect(EngineVocab.droppyVocabLines(Data(c.raw.utf8)) == c.expected)  // UserDefaults hands it back as Data
    }
    #expect(EngineVocab.droppyVocabLines(nil).isEmpty)
    #expect(EngineVocab.droppyVocabLines(42).isEmpty)
}

@Test func vocabJSONMatchesPython() throws {
    let url = try #require(Bundle.module.url(forResource: "engine_vocab", withExtension: "json", subdirectory: "Fixtures"))
    let raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let cases = try #require(raw["vocab_json"] as? [[String: Any]])
    let g = try golden()
    for (c, expect) in zip(g.vocab_json, cases) {
        let got = try #require(JSONSerialization.jsonObject(with: EngineVocab.vocabJSON(c.hotwords, names: Set(c.names))) as? NSDictionary)
        #expect(got == (expect["expected"] as? NSDictionary), "\(c.hotwords)")
    }
}

@Test func linkDroppyModelMatchesPython() throws {
    for c in try golden().link_model {
        let d = try tempDir()
        defer { try? FileManager.default.removeItem(at: d) }
        let src = d.appendingPathComponent("model")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        for f in ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "parakeet_vocab.json", "config.json"] + (c.joint.map { ["\($0).mlmodelc"] } ?? []) {
            try Data("x".utf8).write(to: src.appendingPathComponent(f))
        }
        let state = d.appendingPathComponent("state.json")
        try JSONSerialization.data(withJSONObject: ["installedModels": [EngineVocab.droppyModelKey: src.path]]).write(to: state)
        let link = d.appendingPathComponent("link")
        let got = EngineVocab.linkDroppyModel(into: link, state: state)
        #expect((got != nil) == c.linked, "joint \(c.joint ?? "none")")
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: link.path)) ?? []).sorted()
        if c.linked { #expect(files == c.files, "joint \(c.joint ?? "none")") }  // fixture lists files only when Python linked
        // a second run refreshes cleanly (stale links from an earlier model location are dropped)
        #expect((EngineVocab.linkDroppyModel(into: link, state: state) != nil) == c.linked)
    }
}

@Test func linkDroppyModelAbsentOrBroken() throws {
    let d = try tempDir()
    defer { try? FileManager.default.removeItem(at: d) }
    #expect(EngineVocab.linkDroppyModel(into: d.appendingPathComponent("l"), state: d.appendingPathComponent("missing.json")) == nil)
    let bad = d.appendingPathComponent("bad.json")
    try Data("{\"installedModels\": {}}".utf8).write(to: bad)
    #expect(EngineVocab.linkDroppyModel(into: d.appendingPathComponent("l"), state: bad) == nil)
    try Data("nope".utf8).write(to: bad)
    #expect(EngineVocab.linkDroppyModel(into: d.appendingPathComponent("l"), state: bad) == nil)
}

@Test func alignWordsMatchesPython() throws {
    let cases = try golden().align
    #expect(cases.count >= 300)
    for (n, c) in cases.enumerated() {
        let got = EngineVocab.alignWords(raw: c.raw.map { ($0.word, $0.start, $0.end) }, text: c.text)
        #expect(got.map(\.text) == c.expected.map(\.text), "case \(n): \(c.text)")
        #expect(got.count == c.expected.count)
        for (a, b) in zip(got, c.expected) {
            #expect(abs(a.start - b.start) < 1e-9 && abs(a.end - b.end) < 1e-9, "case \(n) \(a) vs \(b)")
        }
    }
}

@Test func alignWordsEmpty() {
    #expect(EngineVocab.alignWords(raw: [], text: "").isEmpty)
    // text with no timings: pure insertion at 0, zero width
    let w = EngineVocab.alignWords(raw: [], text: "hi there")
    #expect(w == [EngineWord(text: "hi", start: 0, end: 0), EngineWord(text: "there", start: 0, end: 0)])
}

// MARK: audio

private func writeWav(_ url: URL, channels: [[Float]], rate: Double) throws {
    let f = try AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels.count,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false])
    let buf = try #require(AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(channels[0].count)))
    buf.frameLength = AVAudioFrameCount(channels[0].count)
    for (i, ch) in channels.enumerated() { for (j, v) in ch.enumerated() { buf.floatChannelData![i][j] = v } }
    try f.write(from: buf)
}

private func tone(_ n: Int, rate: Double, hz: Double, amp: Float) -> [Float] {
    (0..<n).map { amp * Float(sin(2 * Double.pi * hz * Double($0) / rate)) }
}

@Test func prepareTrackPicksLoudestChannel() throws {
    let d = try tempDir()
    defer { try? FileManager.default.removeItem(at: d) }
    let src = d.appendingPathComponent("stereo.wav")
    try writeWav(src, channels: [tone(48_000, rate: 48_000, hz: 300, amp: 0.1), tone(48_000, rate: 48_000, hz: 500, amp: 0.5)], rate: 48_000)
    let t = try EngineAudio.prepareTrack(key: "mic", src: src, tmp: d)
    #expect(t.mono.lastPathComponent == "mic-mono.wav")
    #expect(abs(t.duration - 1.0) < 1e-9 && t.sampleRate == 48_000)
    #expect(abs(t.peak - 0.5) < 1e-3)
    let mono = try AVAudioFile(forReading: t.mono)
    #expect(mono.processingFormat.channelCount == 1 && mono.length == 48_000)
    // a mono source is used as is
    let m = d.appendingPathComponent("mono.wav")
    try writeWav(m, channels: [tone(8_000, rate: 16_000, hz: 300, amp: 0.2)], rate: 16_000)
    #expect(try EngineAudio.prepareTrack(key: "x", src: m, tmp: d).mono == m)
}

@Test func prepareTrackRejectsEmpty() throws {
    let d = try tempDir()
    defer { try? FileManager.default.removeItem(at: d) }
    let src = d.appendingPathComponent("empty.wav")
    let f = try AVAudioFile(forWriting: src, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                                                        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
    _ = f
    #expect(throws: (any Error).self) { try EngineAudio.prepareTrack(key: "mic", src: src, tmp: d) }
}

@Test func repairWavRecoversCrashedRecording() throws {
    let d = try tempDir()
    defer { try? FileManager.default.removeItem(at: d) }
    let src = d.appendingPathComponent("crashed.wav")
    try writeWav(src, channels: [tone(16_000, rate: 16_000, hz: 440, amp: 0.3)], rate: 16_000)
    #expect(try EngineAudio.repairWav(src) == false)  // a healthy file is left alone
    // simulate the crash: data-chunk size 0 and a ragged tail (3 stray bytes past the last whole frame)
    let h = try FileHandle(forUpdating: src)
    var data = try Data(contentsOf: src)
    let range = try #require(data.range(of: Data("data".utf8)))
    try h.seek(toOffset: UInt64(range.upperBound)); try h.write(contentsOf: Data(count: 4))
    try h.seekToEnd(); try h.write(contentsOf: Data([1, 2, 3]))
    try h.close()
    data = try Data(contentsOf: src)
    #expect(try EngineAudio.repairWav(src) == true)
    let f = try AVAudioFile(forReading: src)
    #expect(f.length == 16_000)
    #expect(try EngineAudio.repairWav(src) == false)  // idempotent
}

@Test func to16kWavProducesMono16BitAt16k() throws {
    let d = try tempDir()
    defer { try? FileManager.default.removeItem(at: d) }
    let src = d.appendingPathComponent("in.wav"), dst = d.appendingPathComponent("out.wav")
    try writeWav(src, channels: [tone(48_000 * 2, rate: 48_000, hz: 1000, amp: 0.5)], rate: 48_000)
    try EngineAudio.to16kWav(src, dst)
    let f = try AVAudioFile(forReading: dst)
    #expect(f.fileFormat.sampleRate == 16_000 && f.fileFormat.channelCount == 1)
    #expect(f.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == 16)
    #expect(abs(Int(f.length) - 32_000) <= 64)
    let buf = try #require(AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)))
    try f.read(into: buf)
    let peak = (0..<Int(buf.frameLength)).map { abs(buf.floatChannelData![0][$0]) }.max() ?? 0
    #expect(abs(peak - 0.5) < 0.02)
}

#if !canImport(FluidAudio)
@Test func storeBuildReportsTranscriptionUnavailable() async throws {
    await #expect(throws: EngineError.unavailable) { try await Engine.transcriber().transcribe(URL(fileURLWithPath: "/dev/null"), hotwords: [], names: []) }
    await #expect(throws: EngineError.unavailable) { try await Engine.diarizer().diarize(URL(fileURLWithPath: "/dev/null")) }
    #expect(EngineError.unavailable.errorDescription == "Transcription is unavailable in this build.")
}
#endif

#if !EAVESDROPPY_PERSONAL
@Test func storeBuildHasNoEchoRemoverBinary() {
    #expect(throws: EngineError.unavailable) { try Engine.echoRemover().clean(mic: [0], reference: [0]) }
}
#endif
