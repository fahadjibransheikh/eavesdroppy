#if canImport(FluidAudio)
import AVFoundation
import Darwin
import Foundation
import Testing
@testable import Eavesdroppy

/// CLI path (what `process_meeting.py` runs: `fluidaudiocli` subprocesses) against the in-process engine, on a real
/// recording of this Mac and on synthetic voices. The oracle is tools/golden/engine_oracle.py; set
/// EAVESDROPPY_ORACLE_DIR to a directory holding a previous run to skip re-running it.
/// Skips when the recording, the Python venv or the CLI is absent. Prints "EQUIV ..." lines with the numbers.

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let session = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Droppy/Droplets/eavesdroppy/Container/raw/20261013-123545-736-0001")
private let python = repoRoot.appendingPathComponent(".venv/bin/python")
private let cli = repoRoot.appendingPathComponent("bin/fluidaudiocli")
private let haveInputs = FileManager.default.fileExists(atPath: session.appendingPathComponent("mic.flac").path)
    && FileManager.default.isExecutableFile(atPath: python.path) && FileManager.default.isExecutableFile(atPath: cli.path)

private struct Oracle: Decodable {
    struct Track: Decodable {
        var words: [EngineWord]
        var duration_seconds: Double
        var segments: [[AnyCodable]]
        var embeddings: [String: [Float]]
        var transcribe_s: Double
        var diarize_s: Double
        var duration: Double
        var sr: Double
        var peak: Double
    }
    var hotwords: [String]
    var model_dir: String?
    var tracks: [String: Track]
}

/// Decodes a JSON number or string, for the `[start, end, "S1"]` segment triples.
private struct AnyCodable: Decodable {
    var number: Double?
    var string: String?
    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        number = try? c.decode(Double.self)
        string = try? c.decode(String.self)
    }
}

private func oracleDir() throws -> URL {
    if let p = ProcessInfo.processInfo.environment["EAVESDROPPY_ORACLE_DIR"], FileManager.default.fileExists(atPath: p + "/oracle.json") {
        return URL(fileURLWithPath: p)
    }
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("engine-oracle-\(UUID().uuidString)")
    let p = Process()
    p.executableURL = python
    p.arguments = [repoRoot.appendingPathComponent("tools/golden/engine_oracle.py").path, session.path, out.path]
    p.currentDirectoryURL = repoRoot
    let log = Pipe()
    p.standardOutput = log; p.standardError = log
    try p.run()
    let text = String(decoding: log.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw EngineError.failed("oracle failed: \(text.suffix(500))") }
    return out
}

private func loadOracle() throws -> (Oracle, URL) {
    let dir = try oracleDir()
    return (try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: dir.appendingPathComponent("oracle.json"))), dir)
}

private func norm(_ w: String) -> String { String(w.lowercased().filter { $0.isLetter || $0.isNumber }) }

/// Word error rate of `hyp` against `ref` (Levenshtein over normalised tokens) with the edit counts.
private func wer(ref: [String], hyp: [String]) -> (rate: Double, sub: Int, ins: Int, del: Int) {
    let r = ref.map(norm), h = hyp.map(norm)
    var d = [[(c: Int, s: Int, i: Int, d: Int)]](repeating: [(Int, Int, Int, Int)](repeating: (0, 0, 0, 0), count: h.count + 1), count: r.count + 1)
    for i in 0...r.count { d[i][0] = (i, 0, 0, i) }
    for j in 0...h.count { d[0][j] = (j, 0, j, 0) }
    for i in 1...max(r.count, 1) where i <= r.count {
        for j in 1...max(h.count, 1) where j <= h.count {
            if r[i - 1] == h[j - 1] { d[i][j] = d[i - 1][j - 1]; continue }
            let s = d[i - 1][j - 1], ins = d[i][j - 1], del = d[i - 1][j]
            let best = min(s.c, ins.c, del.c)
            d[i][j] = best == s.c ? (s.c + 1, s.s + 1, s.i, s.d) : best == ins.c ? (ins.c + 1, ins.s, ins.i + 1, ins.d) : (del.c + 1, del.s, del.i, del.d + 1)
        }
    }
    let e = d[r.count][h.count]
    return (r.isEmpty ? 0 : Double(e.c) / Double(r.count), e.s, e.i, e.d)
}

private func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

private func cosine(_ a: [Float], _ b: [Float]) -> Double {
    var dot = 0.0, na = 0.0, nb = 0.0
    for (x, y) in zip(a, b) { dot += Double(x * y); na += Double(x * x); nb += Double(y * y) }
    return dot / (na.squareRoot() * nb.squareRoot())
}

/// Seconds on which both segment lists have the same cluster (mapped by index, "S1" to "S1"), over the longer one's total.
private func segmentAgreement(_ a: [EngineSegment], _ b: [(Double, Double, String)]) -> Double {
    var same = 0.0, total = 0.0
    for s in a { total += s.end - s.start }
    for s in a { for t in b where t.2 == s.cluster { same += max(0, min(s.end, t.1) - max(s.start, t.0)) } }
    return total > 0 ? same / total : 1
}

@Suite(.serialized, .enabled(if: haveInputs, "needs the recording, the Python venv and bin/fluidaudiocli")) struct EngineEquivalence {
    @Test func transcriptionMatchesCLI() async throws {
        let (oracle, dir) = try loadOracle()
        let modelDir = oracle.model_dir.map { URL(fileURLWithPath: $0) }
        let t = FluidTranscriber(modelDir: modelDir)
        let before = footprintMB()
        var peak = before
        for key in ["mic", "system", "mix", "say"] {
            guard let ref = oracle.tracks[key] else { continue }
            let wav = dir.appendingPathComponent("\(key)16k.wav")
            let t0 = Date()
            let got = try await t.transcribe(wav, hotwords: oracle.hotwords, names: [])
            let secs = Date().timeIntervalSince(t0)
            peak = max(peak, footprintMB())
            let e = wer(ref: ref.words.map(\.text), hyp: got.words.map(\.text))
            var dt = 0.0
            if got.words.map(\.text) == ref.words.map(\.text) {
                for (a, b) in zip(got.words, ref.words) { dt = max(dt, abs(a.start - b.start), abs(a.end - b.end)) }
            }
            let identical = got.words == ref.words
            print(String(format: "EQUIV transcribe %@: %d vs %d words, WER %.4f (sub %d ins %d del %d), identical=%@, max time diff %.4f s, duration %.3f vs %.3f, in-process %.1f s vs CLI %.1f s",
                         key, got.words.count, ref.words.count, e.rate, e.sub, e.ins, e.del, "\(identical)", dt, got.durationSeconds, ref.duration_seconds, secs, ref.transcribe_s))
            #expect(e.rate <= 0.005, "\(key) WER \(e.rate)")
            #expect(dt <= 0.05, "\(key) word timing drift \(dt)")
            #expect(abs(got.durationSeconds - ref.duration_seconds) < 0.01)
        }
        let loaded = footprintMB()
        await t.unload()
        let after = footprintMB()
        try await Task.sleep(for: .seconds(2))
        malloc_zone_pressure_relief(nil, 0)
        print(String(format: "EQUIV memory (phys footprint MB): before load %.0f, peak while loaded %.0f, loaded %.0f, after unload %.0f, 2 s later + malloc relief %.0f", before, peak, loaded, after, footprintMB()))
    }

    @Test func diarizationMatchesCLI() async throws {
        let (oracle, dir) = try loadOracle()
        let d = FluidDiarizer()
        let before = footprintMB()
        var peak = before
        for key in ["mic", "system", "mix", "say"] {
            guard let ref = oracle.tracks[key] else { continue }
            let got = try await d.diarize(dir.appendingPathComponent("\(key)16k.wav"))
            peak = max(peak, footprintMB())
            let refSegs = ref.segments.map { ($0[0].number ?? 0, $0[1].number ?? 0, $0[2].string ?? "") }
            let agree = segmentAgreement(got.segments, refSegs)
            var drift = 0.0
            if got.segments.count == refSegs.count {
                for (a, b) in zip(got.segments, refSegs) { drift = max(drift, abs(a.start - b.0), abs(a.end - b.1)) }
            }
            var minCos = 1.0
            for (c, e) in ref.embeddings { minCos = min(minCos, got.embeddings[c].map { cosine($0, e) } ?? 0) }
            print(String(format: "EQUIV diarize %@: clusters %d vs %d, segments %d vs %d, cluster agreement %.4f, max boundary drift %.4f s, min embedding cosine %.6f",
                         key, got.embeddings.count, ref.embeddings.count, got.segments.count, refSegs.count, agree, drift, minCos))
            #expect(Set(got.embeddings.keys) == Set(ref.embeddings.keys), "\(key) cluster ids")
            #expect(got.segments.count == refSegs.count)
            #expect(agree > 0.99)
            #expect(drift < 0.02)
            #expect(minCos > 0.999)
            for v in got.embeddings.values {
                #expect(v.count == 256)
                #expect(abs(cosine(v, v) - 1) < 1e-5)
            }
        }
        let loaded = footprintMB()
        await d.unload()
        let after = footprintMB()
        try await Task.sleep(for: .seconds(2))
        malloc_zone_pressure_relief(nil, 0)
        print(String(format: "EQUIV diarizer memory (MB): before %.0f, peak %.0f, loaded %.0f, after unload %.0f, 2 s later + malloc relief %.0f", before, peak, loaded, after, footprintMB()))
    }

    @Test func tooShortOrSilentTrackGivesEmptyDiarization() async throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("engine-short-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: d) }
        let f = try AVAudioFile(forWriting: d, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                                                          AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
        let buf = try #require(AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 4_000))
        buf.frameLength = 4_000   // 0.25 s, under the 0.5 s floor
        try f.write(from: buf)
        #expect(try await FluidDiarizer().diarize(d) == .empty)
    }

    @Test func cancellationStopsBeforeWork() async throws {
        let (oracle, dir) = try loadOracle()
        let t = FluidTranscriber(modelDir: oracle.model_dir.map { URL(fileURLWithPath: $0) })
        let task = Task { try await t.transcribe(dir.appendingPathComponent("mic16k.wav"), hotwords: [], names: []) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let d = FluidDiarizer()
        let task2 = Task { try await d.diarize(dir.appendingPathComponent("mic16k.wav")) }
        task2.cancel()
        await #expect(throws: CancellationError.self) { try await task2.value }
    }

    /// The whole in-process path from the recording: FLAC, loudest channel, 16 kHz WAV, then ASR.
    @Test func inProcessPathFromFlacMatchesCLI() async throws {
        let (oracle, dir) = try loadOracle()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("engine-flac-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let t = FluidTranscriber(modelDir: oracle.model_dir.map { URL(fileURLWithPath: $0) })
        for key in ["mic", "system"] {
            guard let ref = oracle.tracks[key] else { continue }
            let track = try EngineAudio.prepareTrack(key: key, src: session.appendingPathComponent("\(key).flac"), tmp: tmp)
            let wav = tmp.appendingPathComponent("\(key)16k.wav")
            try EngineAudio.to16kWav(track.mono, wav)
            // resampling differs from afconvert's in the last bits; compare samples before trusting the ASR numbers
            let mine = try AVAudioFile(forReading: wav), theirs = try AVAudioFile(forReading: dir.appendingPathComponent("\(key)16k.wav"))
            let n = Int(min(mine.length, theirs.length))
            func samples(_ f: AVAudioFile) throws -> [Float] {
                let b = try #require(AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)))
                try f.read(into: b)
                return Array(UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength)))
            }
            let a = try samples(mine), b = try samples(theirs)
            var err = 0.0, sig = 0.0
            for i in 0..<n { err += Double((a[i] - b[i]) * (a[i] - b[i])); sig += Double(b[i] * b[i]) }
            let snr = 10 * log10(sig / max(err, 1e-30))
            let got = try await t.transcribe(wav, hotwords: oracle.hotwords, names: [])
            let e = wer(ref: ref.words.map(\.text), hyp: got.words.map(\.text))
            print(String(format: "EQUIV flac path %@: samples %d vs %d, SNR vs afconvert wav %.1f dB, peak %.4f vs %.4f, WER vs CLI %.4f (sub %d ins %d del %d)",
                         key, Int(mine.length), Int(theirs.length), snr, track.peak, ref.peak, e.rate, e.sub, e.ins, e.del))
            #expect(abs(Int(mine.length) - Int(theirs.length)) <= 2)
            #expect(snr > 40)
            #expect(e.rate <= 0.02, "\(key) WER vs CLI \(e.rate)")
        }
        await t.unload()
    }

    @Test func localVQEMatchesPython() throws {
        let (_, dir) = try loadOracle()
        let lv = LocalVQEProcess()
        guard lv.isInstalled, FileManager.default.fileExists(atPath: dir.appendingPathComponent("lvqe-out.wav").path) else { return }
        let mic = try LocalVQEProcess.readFloatWav(dir.appendingPathComponent("lvqe-mic.wav"))
        let ref = try LocalVQEProcess.readFloatWav(dir.appendingPathComponent("lvqe-ref.wav"))
        let expected = try LocalVQEProcess.readFloatWav(dir.appendingPathComponent("lvqe-out.wav"))
        let got = try lv.clean(mic: mic, reference: ref)
        #expect(got.count == mic.count && expected.count == mic.count)
        let diff = zip(got, expected).map { abs($0 - $1) }.max() ?? 0
        let rms = (expected.reduce(0) { $0 + Double($1 * $1) } / Double(expected.count)).squareRoot()
        print(String(format: "EQUIV localvqe: %d samples, max abs diff vs echo._localvqe %.2e (output rms %.4f)", got.count, diff, rms))
        #expect(diff < 1e-5)
        #expect(rms > 1e-4)  // the chunk is not silence, so the comparison means something
    }

    @Test func localVQEFailsLoudly() {
        let lv = LocalVQEProcess(binary: URL(fileURLWithPath: "/nonexistent/localvqe"), model: URL(fileURLWithPath: "/nonexistent/model.gguf"))
        #expect(throws: EngineError.self) { try lv.clean(mic: [0, 0], reference: [0, 0]) }
    }
}
#endif
