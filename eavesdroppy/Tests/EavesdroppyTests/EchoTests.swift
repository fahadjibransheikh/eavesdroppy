import AVFoundation
import Foundation
import Testing
@testable import Eavesdroppy

@Suite struct EchoTests {
    typealias F = LogicFixture

    // Measured against the Python oracle: synthetic cases agree to all 4 decimals of every score and on every lag
    // (max deviation 0.0); the real recording agrees on lag (52 ms), verdict, share, and all 7 scores to 4 decimals;
    // load16k is within 6e-8 of soundfile + scipy (one float32 ulp), resamplePoly within 1.2e-7. The bounds below
    // are looser than measured only to survive another FFT implementation or CPU: scores 5e-4 (a one-unit flip in the
    // 4th decimal), lag exact (the detector's own rounding is 1 ms, so any lag drift is a real difference), samples 1e-6.
    let scoreTol = 5e-4
    let sampleTol: Float = 1e-6

    static func lcg(_ seed: UInt32, _ n: Int) -> [Double] {
        var x = seed, out = [Double](repeating: 0, count: n)
        for i in 0..<n { x = x &* 1664525 &+ 1013904223; out[i] = Double(x >> 8) / 16777216.0 * 2 - 1 }
        return out
    }

    /// The recipe of synth() in tools/golden/logic_golden.py.
    static func synth(_ r: [String: Any]) -> (mic: [Float], sys: [Float]) {
        let n = Int((F.d(r["seconds"]) * 16000).rounded(.toNearestOrEven))
        let seeds = (r["seeds"] as! [Any]).map { UInt32(F.i($0)) }
        let (n1, n2, n3) = (lcg(seeds[0], n), lcg(seeds[1], n), lcg(seeds[2], n))
        var gs = (0..<n).map { ($0 / 4000 * 7 + 3) % 5 < 3 ? 1.0 : 0.1 }
        let gn = (0..<n).map { ($0 / 4000 * 11 + 1) % 4 < 2 ? 1.0 : 0.05 }
        for case let p as [Any] in r["silent"] as? [Any] ?? [] { for i in Int(F.d(p[0]) * 16000)..<min(n, Int(F.d(p[1]) * 16000)) { gs[i] = 0 } }
        if r["sys_dead"] != nil { gs = gs.map { _ in 0 } }
        let sys = (0..<n).map { F.d(r["sys_scale"]) * gs[$0] * n1[$0] }
        let d = F.i(r["delay_samples"])
        let from = r["echo_from_s"].map { F.d($0) } ?? 0, until = r["echo_until_s"].map { F.d($0) } ?? 1e9
        let mic = (0..<n).map { i -> Double in
            var e = i - d >= 0 && i - d < n ? sys[i - d] : 0.0
            if r["echo_from_s"] != nil || r["echo_until_s"] != nil { e = Double(i) >= from * 16000 && Double(i) < until * 16000 ? e : 0.0 }
            return F.d(r["near_gain"]) * gn[i] * n2[i] + F.d(r["gain_echo"]) * e + F.d(r["floor"]) * n3[i]
        }
        return (mic.map(Float.init), sys.map(Float.init))
    }

    func check(_ got: Echo.Bleed, _ want: [String: Any], _ name: String, scoreTol: Double) {
        #expect(got.verdict == want["verdict"] as! String && got.bleed == F.b(want["bleed"]), Comment(rawValue: "\(name): verdict \(got.verdict)"))
        #expect(got.lagMs == F.i(want["lag_ms"]), Comment(rawValue: "\(name): lag \(got.lagMs) vs \(F.i(want["lag_ms"]))"))
        let wantShare = want["share"] is NSNull ? nil : F.d(want["share"])
        #expect(got.share == wantShare || abs(got.share! - wantShare!) < 1e-3, Comment(rawValue: "\(name): share \(String(describing: got.share)) vs \(String(describing: wantShare))"))
        let times = (want["times"] as! [Any]).map(F.d)
        #expect(got.times == times, Comment(rawValue: "\(name): times"))
        let scores = (want["scores"] as! [Any]).map { $0 is NSNull ? nil : F.d($0) }
        #expect(got.scores.count == scores.count, Comment(rawValue: "\(name): window count"))
        for (g, w) in zip(got.scores, scores) {
            #expect((g == nil) == (w == nil) && (g == nil || abs(g! - w!) <= scoreTol), Comment(rawValue: "\(name): score \(String(describing: g)) vs \(String(describing: w))"))
        }
    }

    @Test func detectMatchesPythonOnSyntheticSignals() throws {
        let cases = try F.json("echo")["detect"] as! [[String: Any]]
        #expect(cases.count >= 15)
        var verdicts = Set<String>()
        for c in cases {
            let name = c["name"] as! String
            let (mic, sys) = Self.synth(c["recipe"] as! [String: Any])
            let aligned = Echo.alignStart(sys, offsetS: F.d(c["offset_s"]))
            let got = Echo.detect(mic: mic, system: aligned)
            check(got, c["expected"] as! [String: Any], name, scoreTol: scoreTol)
            if let gl = c["global_lag_ms"] as? NSNumber { #expect(Echo.estimateLagMs(mic, aligned) == gl.intValue, Comment(rawValue: "\(name): global lag")) }
            verdicts.insert(got.verdict)
        }
        #expect(verdicts == ["bleed", "clean", "unknown"])
    }

    @Test func helpersMatchPython() throws {
        let h = try F.json("echo")["helpers"] as! [String: Any]
        for c in h["align_start"] as! [[String: Any]] {
            #expect(Echo.alignStart(F.f(c["x"]), offsetS: F.d(c["offset"])) == F.f(c["expected"]), "align_start \(F.d(c["offset"]))")
        }
        for c in h["shift_reference"] as! [[String: Any]] {
            let got = Echo.shiftReference(F.f(c["x"]), lagMs: F.i(c["lag"]), n: F.i(c["n"]))
            #expect(got.count == F.i(c["expected_len"]) && Array(got.prefix(3)) == F.f(c["expected_head"]) && got.reduce(0.0) { $0 + Double($1) } == F.d(c["expected_sum"]),
                    "shift_reference lag \(F.i(c["lag"])) n \(F.i(c["n"]))")
        }
    }

    @Test func shiftReferenceTargetAndReductionMatchPython() throws {
        let h = try F.json("echo")["helpers"] as! [String: Any]
        for c in h["shift_reference_target"] as! [[String: Any]] {
            let got = Echo.shiftReference(F.f(c["x"]), lagMs: F.i(c["lag"]), n: F.i(c["n"]), targetMs: F.i(c["target"]))
            #expect(Array(got.prefix(3)) == F.f(c["expected_head"]) && got.reduce(0.0) { $0 + Double($1) } == F.d(c["expected_sum"]),
                    "shift_reference lag \(F.i(c["lag"])) target \(F.i(c["target"])) n \(F.i(c["n"]))")
        }
        for c in h["reduction"] as! [[String: Any]] {
            let win = { (v: Any) -> [Echo.Window] in (v as! [Any]).map { Echo.Window(t: 0, score: $0 is NSNull ? nil : F.d($0), lagMs: nil) } }
            let want = c["expected"] is NSNull ? nil : F.d(c["expected"])
            #expect(Echo.reduction(win(c["mic"]!), win(c["out"]!)) == want, "reduction \(c["mic"]!) -> \(c["out"]!)")
        }
    }

    /// Stand-in for LocalVQE: records the references it was given; `passThrough` returns the mic untouched for the first n calls.
    final class FakeRemover: EchoRemover, @unchecked Sendable {
        let lock = NSLock(); var refs: [[Float]] = []; let passThrough: Int; let cancel: [Float]
        init(passThrough: Int, cancel: [Float]) { self.passThrough = passThrough; self.cancel = cancel }
        func clean(mic: [Float], reference: [Float]) throws -> [Float] {
            lock.withLock { refs.append(reference) }
            return lock.withLock { refs.count } <= passThrough ? mic : cancel
        }
    }

    @Test func chunkWithoutEchoIsNotRunAndAFlakyModelIsRetried() throws {
        let r: [String: Any] = ["seconds": 25, "seeds": [101, 202, 303], "gain_echo": 0.4, "delay_samples": 960, "near_gain": 0.3, "floor": 0.01, "sys_scale": 0.5]
        let (mic, sys) = Self.synth(r)
        // echo present: the first two answers leave the echo in, the third is the near end alone (a perfect canceller)
        let (nearOnly, _) = Self.synth(r.merging(["gain_echo": 0.0]) { $1 })
        let fake = FakeRemover(passThrough: 2, cancel: nearOnly)
        let y = try Echo.cleanChunk(mic: mic, system: sys, lagMs: 60, remover: fake, plans: Echo.Plans())
        #expect(y == nearOnly && fake.refs.count == 3)
        #expect(fake.refs[1] != fake.refs[0] && fake.refs[2] != fake.refs[1])   // each retry moves the reference
        // no coherent echo (the mic has none): LocalVQE is never called
        let none = FakeRemover(passThrough: 0, cancel: nearOnly)
        #expect(try Echo.cleanChunk(mic: nearOnly, system: sys, lagMs: 60, remover: none, plans: Echo.Plans()) == nil && none.refs.isEmpty)
        // a model that never cancels: every candidate is tried, the best (all equal) is returned, the self-check fails
        let stuck = FakeRemover(passThrough: 99, cancel: nearOnly)
        let ys = try Echo.cleanChunk(mic: mic, system: sys, lagMs: 60, remover: stuck, plans: Echo.Plans())
        #expect(ys == mic && stuck.refs.count == 1 + Echo.retryLagsMs.count)
        let chk = Echo.selfCheck(mic: mic, out: mic, system: sys, lagMs: 60)
        #expect(!chk.ok && abs(chk.reductionEchoDb ?? 99) < 0.5)
        #expect(Echo.selfCheck(mic: mic, out: nearOnly, system: sys, lagMs: 60).ok)
    }

    @Test func resamplePolyMatchesScipy() throws {
        for c in try F.json("echo")["resample"] as! [[String: Any]] {
            let rate = F.i(c["rate"]), n = F.i(c["n"])
            let x = Self.lcg(UInt32(F.i(c["seed"])), n).map { Float($0 * 0.5) }
            let y = rate == 16000 ? x : Echo.resamplePoly(x, from: rate)
            #expect(y.count == F.i(c["y_len"]), "rate \(rate): length")
            let idx = (c["idx"] as! [Any]).map(F.i), want = F.f(c["y"])
            let err = zip(idx, want).map { abs(y[$0] - $1) }.max() ?? 0
            #expect(err < sampleTol, "rate \(rate): max abs error \(err)")
        }
    }

    @Test func load16kReadsStereoWavLikeSoundfile() throws {
        let c = try F.json("echo")["load"] as! [String: Any]
        let n = F.i(c["n"]), left = Self.lcg(7, n).map { Float($0 * 0.3) }, right = (0..<n).map { Float(sin(Double($0) * 0.05) * 0.2) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("logic-load-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2,
                                                                 AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true], commonFormat: .pcmFormatFloat32, interleaved: false)
            let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(n))!
            buf.frameLength = AVAudioFrameCount(n)
            for i in 0..<n { buf.floatChannelData![0][i] = left[i]; buf.floatChannelData![1][i] = right[i] }
            try file.write(from: buf)
        }
        let y = try Echo.load16k(url)
        #expect(y.count == F.i(c["y_len"]))
        let idx = (c["idx"] as! [Any]).map(F.i), want = F.f(c["y"])
        let err = zip(idx, want).map { abs(y[$0] - $1) }.max() ?? 0
        #expect(err < sampleTol, "max abs error \(err)")
    }

    @Test func dedupWordsMatchesPython() throws {
        let cases = try F.json("echo")["dedup"] as! [[String: Any]]
        for (n, c) in cases.enumerated() {
            let got = Echo.dedupWords(F.words(c["mic"]), F.words(c["sys"]), window: F.d(c["window"]))
            let dropped = (c["dropped"] as! [[Any]]).map { (Turns.Word(text: $0[0] as! String, start: F.d($0[1]), end: F.d($0[2])), $0[3] as! String) }
            #expect(got.kept == F.words(c["kept"]) && got.dropped.map { [$0.word.text, $0.echoOf] } == dropped.map { [$0.0.text, $0.1] }
                    && got.dropped.map(\.word) == dropped.map(\.0), "dedup \(n)")
        }
        #expect(cases.contains { !($0["dropped"] as! [Any]).isEmpty })
    }

    @Test func dropResidueMatchesPython() throws {
        let cases = try F.json("echo")["residue"] as! [[String: Any]]
        for (n, c) in cases.enumerated() {
            let got = Echo.dropResidue(F.words(c["mic"]), F.words(c["sys"]), gap: F.d(c["gap"]), maxWords: F.i(c["max_words"]), slack: F.d(c["slack"]))
            #expect(got.kept == F.words(c["kept"]) && got.dropped == F.words(c["dropped"]), "residue \(n)")
        }
        #expect(cases.contains { !($0["dropped"] as! [Any]).isEmpty })
    }

    static let realDir = NSHomeDirectory() + "/Library/Application Support/Droppy/Droplets/eavesdroppy/Container/raw/20261013-123545-736-0001"

    /// The recording is never copied into the repo: this test reads it in place and skips when it is absent.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: EchoTests.realDir + "/mic.flac")))
    func realRecording() throws {
        let fx = try F.json("real_recording"), dir = URL(fileURLWithPath: Self.realDir)
        // detector verdict through the real loader (AVFoundation FLAC read, mono mix, 48 -> 16 kHz resample)
        let got = try Echo.detectBleed(mic: dir.appendingPathComponent("mic.flac"), system: dir.appendingPathComponent("system.flac"), systemOffsetS: F.d(fx["offset_s"]))
        check(got, fx["expected"] as! [String: Any], "real", scoreTol: scoreTol)
        // the loader itself, sampled every 4001st frame, against soundfile + scipy
        for (track, v) in fx["samples"] as! [String: [String: Any]] {
            let y = try Echo.load16k(dir.appendingPathComponent("\(track).flac"))
            #expect(y.count == F.i(v["len"]), "\(track): length")
            let idx = (v["idx"] as! [Any]).map(F.i), want = F.f(v["y"])
            let err = zip(idx, want).map { abs(y[$0] - $1) }.max() ?? 0
            let rms = (y.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(y.count)).squareRoot()
            #expect(err < sampleTol, "\(track): max abs sample error \(err)")
            #expect(abs(rms / F.d(v["rms"]) - 1) < 1e-3, "\(track): rms \(rms) vs \(F.d(v["rms"]))")
        }
    }
}
