import Accelerate
import AVFoundation
import Foundation

// Port of echo.py minus LocalVQE (remove_echo, process, self_check: the EchoRemover engine owns those):
// load16k, the coherence bleed detector, align_start, dedup_words and drop_residue.
// numpy/scipy calls reproduced: signal.correlate(method="fft") -> zero-padded FFT correlation (Double);
// signal.coherence(nperseg=2048, noverlap=1536) -> periodic Hann, per-segment mean detrend, mean of |Pxy|^2/(Pxx Pyy)
// over the 300-3400 Hz bins; signal.resample_poly -> Kaiser(5.0) FIR designed as firwin does, float32 taps.

enum Echo {
    static let sr = 16000, frame = 320, hop = 160
    static let bleedThr = 0.02  // mean coherence 300-3400 Hz; unrelated speech <= 0.010, bleed >= 0.018 (synthetic sweep)
    static let bleedShare = 1.0 / 3  // flag when at least this share of scored windows reach the threshold
    static let targetLagMs = 60  // LocalVQE copes with an echo lag from ~40 ms up; a lead beyond ~20 ms breaks it

    struct Bleed: Equatable {
        var bleed: Bool; var verdict: String  // "bleed" | "clean" | "unknown"
        var share: Double?; var lagMs: Int; var scores: [Double?]; var times: [Double]; var thr: Double
    }
    struct Window: Equatable { var t: Double; var score: Double?; var lagMs: Int? }
    struct LoadError: Error { var message: String }

    // ---------- loading ----------
    /// FLAC/WAV/anything AVAudioFile reads -> mono float at 16 kHz. Channels are averaged (a + b) / 2 like numpy's
    /// mean(1), then resampled like scipy's resample_poly. Not bit-exact with soundfile + scipy (float32 FFT-free FIR,
    /// decoder rounding); tolerances are in the tests.
    static func load16k(_ url: URL) throws -> [Float] {
        let f = try AVAudioFile(forReading: url)
        let fmt = f.processingFormat, ch = Int(fmt.channelCount), rate = Int(fmt.sampleRate.rounded())
        guard ch > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 1 << 16) else { throw LoadError(message: "cannot read \(url.lastPathComponent)") }
        var x = [Float](); x.reserveCapacity(Int(f.length))
        while f.framePosition < f.length {
            try f.read(into: buf)
            let n = Int(buf.frameLength)
            guard n > 0, let d = buf.floatChannelData else { break }
            var m = [Float](UnsafeBufferPointer(start: d[0], count: n))
            for c in 1..<max(ch, 1) { m = vDSP.add(m, UnsafeBufferPointer(start: d[c], count: n)) }
            if ch > 1 { m = vDSP.divide(m, Float(ch)) }
            x += m
        }
        return rate == sr ? x : resamplePoly(x, from: rate)
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }

    private static func i0(_ x: Double) -> Double {
        var term = 1.0, sum = 1.0, k = 1.0
        while term > 1e-17 * sum { term *= x * x / 4 / (k * k); sum += term; k += 1 }
        return sum
    }

    /// scipy.signal.firwin(2*halfLen+1, 1/maxRate, window=("kaiser", 5.0)) * up, as float32 (resample_poly's filter).
    static func resampleFilter(up: Int, down: Int) -> [Float] {
        let maxRate = max(up, down), fc = 1.0 / Double(maxRate), halfLen = 10 * maxRate, taps = 2 * halfLen + 1
        let alpha = Double(taps - 1) / 2, beta = 5.0, i0b = i0(beta)
        var h = (0..<taps).map { n -> Double in
            let m = Double(n) - alpha, x = fc * m
            let sinc = x == 0 ? 1.0 : sin(Double.pi * x) / (Double.pi * x)
            let r = (m / alpha) * (m / alpha)
            return fc * sinc * i0(beta * max(0, 1 - r).squareRoot()) / i0b
        }
        let s = h.reduce(0, +)
        h = h.map { $0 / s * Double(up) }
        return h.map(Float.init)
    }

    /// scipy.signal.resample_poly(x, 16000/g, rate/g) for float32 input.
    static func resamplePoly(_ x: [Float], from rate: Int) -> [Float] {
        let g = gcd(sr, rate), up = sr / g, down = rate / g
        let h = resampleFilter(up: up, down: down), halfLen = 10 * max(up, down)
        let nOut = (x.count * up + down - 1) / down
        if nOut == 0 { return [] }
        let tmax = (h.count + up - 1) / up
        // phase p filter, reversed so the output is a plain dot product with a window of the padded input
        var phases = [[Float]](repeating: [Float](repeating: 0, count: tmax), count: up)
        for p in 0..<up {
            var t = 0
            while p + up * t < h.count { phases[p][tmax - 1 - t] = h[p + up * t]; t += 1 }
        }
        var xp = [Float](repeating: 0, count: tmax - 1) + x
        xp += [Float](repeating: 0, count: tmax + halfLen / up + 2)
        var out = [Float](repeating: 0, count: nOut)
        xp.withUnsafeBufferPointer { xb in
            for m in 0..<nOut {
                let n = m * down + halfLen
                let q = n / up, p = n % up
                var r: Float = 0
                phases[p].withUnsafeBufferPointer { vDSP_dotpr(xb.baseAddress! + q, 1, $0.baseAddress!, 1, &r, vDSP_Length(tmax)) }
                out[m] = r
            }
        }
        return out
    }

    // ---------- FFT ----------
    final class FFTPlan {
        let n: Int, log2n: vDSP_Length, setup: FFTSetupD
        init(_ n: Int) {
            self.n = n; log2n = vDSP_Length(n.trailingZeroBitCount)
            setup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2))!  // n is a power of two >= 4
        }
        deinit { vDSP_destroy_fftsetupD(setup) }
        func run(_ re: inout [Double], _ im: inout [Double], inverse: Bool = false) {
            re.withUnsafeMutableBufferPointer { r in
                im.withUnsafeMutableBufferPointer { i in
                    var sc = DSPDoubleSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    vDSP_fft_zipD(setup, &sc, 1, log2n, FFTDirection(inverse ? kFFTDirection_Inverse : kFFTDirection_Forward))
                }
            }
        }
    }
    final class Plans {
        private var cache: [Int: FFTPlan] = [:]
        func get(_ n: Int) -> FFTPlan { if let p = cache[n] { return p }; let p = FFTPlan(n); cache[n] = p; return p }
    }

    /// scipy.signal.correlate(m, a, mode="valid", method="fft"): c[k] = sum_t m[k+t] * a[t], k in 0...(len(m)-len(a)).
    /// Circular correlation of size >= len(m) is alias-free on exactly those lags.
    static func xcorrValid(_ m: [Float], _ a: [Float], _ plans: Plans) -> [Double] {
        var n = 4
        while n < m.count { n <<= 1 }
        let plan = plans.get(n)
        var mr = [Double](repeating: 0, count: n), mi = mr, ar = mr, ai = mr
        for i in 0..<m.count { mr[i] = Double(m[i]) }
        for i in 0..<a.count { ar[i] = Double(a[i]) }
        plan.run(&mr, &mi); plan.run(&ar, &ai)
        for k in 0..<n {  // M * conj(A)
            let r = mr[k] * ar[k] + mi[k] * ai[k], i = mi[k] * ar[k] - mr[k] * ai[k]
            mr[k] = r; mi[k] = i
        }
        plan.run(&mr, &mi, inverse: true)
        return (0...(m.count - a.count)).map { mr[$0] / Double(n) }
    }

    private static func argmax(_ c: ArraySlice<Double>) -> Int {  // first maximum, like numpy
        var best = c.startIndex
        for i in c.indices where c[i] > c[best] { best = i }
        return best - c.startIndex
    }

    // ---------- signal helpers ----------
    static func envelope(_ x: [Float]) -> [Float] {
        let n = x.count >= frame ? 1 + (x.count - frame) / hop : 0
        return (0..<n).map { i in
            var s: Float = 0
            x.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress! + i * hop, 1, &s, vDSP_Length(frame)) }
            return (s / Float(frame)).squareRoot()
        }
    }

    /// Put the system track on the mic track's clock. offsetS = system track start minus mic track start:
    /// > 0 pads the front, < 0 drops leading samples.
    static func alignStart(_ system: [Float], offsetS: Double) -> [Float] {
        let k = Int((abs(offsetS) * Double(sr)).rounded(.toNearestOrEven))
        return offsetS > 0 ? [Float](repeating: 0, count: k) + system : Array(system.dropFirst(k))
    }

    /// Reference cropped/padded to n samples. If the mic echo leads or barely trails it (lag < 40 ms) the reference is
    /// advanced so the echo lag becomes ~targetLagMs; otherwise it is left alone. `targetMs`: always move the echo lag
    /// to that value instead (advance, or delay with leading zeros).
    static func shiftReference(_ ref: [Float], lagMs: Int, n: Int, targetMs: Int? = nil) -> [Float] {
        let adv = targetMs.map { sr * ($0 - lagMs) / 1000 } ?? (lagMs < 40 ? sr * max(0, targetLagMs - lagMs) / 1000 : 0)
        var r = adv >= 0 ? Array(ref.dropFirst(adv).prefix(n)) : Array(([Float](repeating: 0, count: -adv) + ref).prefix(n))
        if r.count < n { r += [Float](repeating: 0, count: n - r.count) }
        return r
    }

    private static func slice(_ x: [Float], _ lo: Int, _ hi: Int) -> [Float] {  // Python x[lo:hi] for lo >= 0
        let a = min(lo, x.count), b = max(a, min(hi, x.count))
        return Array(x[a..<b])
    }

    /// Lag (ms) of the echo in mic relative to system (positive = mic echo is later), from waveform cross-correlation
    /// on the loudest segS seconds of the system track. Negative = the reference is behind the mic.
    static func estimateLagMs(_ mic: [Float], _ sysm: [Float], loMs: Int = -500, hiMs: Int = 800, segS: Int = 60,
                              plans: Plans = Plans()) -> Int {
        let w = segS * sr, e = envelope(sysm), h = sr / 100
        let wl = min(w / h, e.count)
        var prefix = [Double](repeating: 0, count: e.count + 1)
        for i in 0..<e.count { prefix[i + 1] = prefix[i] + Double(e[i]) * Double(e[i]) }
        let tot = (0...(e.count - wl)).map { prefix[$0 + wl] - prefix[$0] }
        let s = argmax(tot[...]) * h
        let a = slice(sysm, s, s + w)
        let lo = loMs * 16, hi = hiMs * 16
        var m = [Float](repeating: 0, count: max(0, -(s + lo))) + slice(mic, max(0, s + lo), s + a.count + hi)
        if m.count < a.count + hi - lo { m += [Float](repeating: 0, count: a.count + hi - lo - m.count) }
        let c = xcorrValid(m, a, plans)
        return Int((Double(argmax(c[0...(hi - lo)]) + lo) / 16).rounded(.toNearestOrEven))
    }

    /// Lag from waveform cross-correlation (0..lagMax), then mean magnitude-squared coherence of mic vs the lag-aligned
    /// system over 300-3400 Hz, per winS-second window. Null (unrelated speech) ~ 0.003; echo >> that.
    static func windowScoresCoh(_ mic: [Float], _ sysm: [Float], winS: Int = 10, lagMaxMs: Int = 800, activeDb: Double = -50,
                                minActive: Double = 0.15, plans: Plans = Plans()) -> [Window] {
        let w = winS * sr, L = lagMaxMs * 16, nper = 2048, step = 512
        let win = (0..<nper).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(nper)) }  // scipy 'hann', periodic
        let bins = (0...(nper / 2)).filter { k in let f = Double(k) * Double(sr) / Double(nper); return f >= 300 && f <= 3400 }
        let coh = FFTPlan(nper)
        var out: [Window] = []
        for s in stride(from: 0, to: sysm.count - w / 2, by: w) {
            let a = slice(sysm, s, s + w), m = slice(mic, s, s + w + L + 1)
            let t = Double(s) / Double(sr)
            let aEnv = envelope(a), thr = Float(pow(10.0, activeDb / 20))
            if a.count < w / 2 || Double(aEnv.filter { $0 > thr }.count) / Double(aEnv.count) < minActive {
                out.append(Window(t: t, score: nil, lagMs: nil)); continue
            }
            var mm = m
            if mm.count < a.count + L { mm += [Float](repeating: 0, count: a.count + L - mm.count) }
            mm = Array(mm.prefix(a.count + L))
            let c = xcorrValid(mm, a, plans)
            let lag = argmax(c[0...L])
            // coherence(mm[lag:lag+len(a)], a): packed as z = x + i y so one complex FFT gives both spectra
            let x = mm[lag..<(lag + a.count)]
            let nseg = (a.count - nper) / step + 1
            var pxx = [Double](repeating: 0, count: bins.count), pyy = pxx, pxr = pxx, pxi = pxx
            var re = [Double](repeating: 0, count: nper), im = re
            for sg in 0..<nseg {
                let o = sg * step
                var mx = 0.0, my = 0.0
                for i in 0..<nper { mx += Double(x[x.startIndex + o + i]); my += Double(a[o + i]) }
                mx /= Double(nper); my /= Double(nper)
                for i in 0..<nper { re[i] = (Double(x[x.startIndex + o + i]) - mx) * win[i]; im[i] = (Double(a[o + i]) - my) * win[i] }
                coh.run(&re, &im)
                for (j, k) in bins.enumerated() {
                    let (zr, zi, cr, ci) = (re[k], im[k], re[nper - k], im[nper - k])
                    let (xr, xi, yr, yi) = ((zr + cr) / 2, (zi - ci) / 2, (zi + ci) / 2, -(zr - cr) / 2)
                    pxx[j] += xr * xr + xi * xi; pyy[j] += yr * yr + yi * yi
                    pxr[j] += xr * yr + xi * yi; pxi[j] += xr * yi - xi * yr
                }
            }
            var sum = 0.0
            for j in bins.indices { sum += (pxr[j] * pxr[j] + pxi[j] * pxi[j]) / (pxx[j] * pyy[j]) }
            out.append(Window(t: t, score: PyRound.round(sum / Double(bins.count), 4), lagMs: Int((Double(lag) / 16).rounded(.toNearestOrEven))))
        }
        return out
    }

    // ---------- detector ----------
    /// Verdict from two 16 kHz tracks (the system track already on the mic's clock, see alignStart).
    /// "unknown" = no window had enough system audio to score (e.g. system track silent): treat as no bleed.
    static func detect(mic: [Float], system sysm: [Float], thr: Double = bleedThr) -> Bleed {
        if mic.count < sr || sysm.count < sr { return Bleed(bleed: false, verdict: "unknown", share: nil, lagMs: 0, scores: [], times: [], thr: thr) }
        let plans = Plans()
        let lag = estimateLagMs(mic, sysm, plans: plans)
        // the coherence scorer only searches lags >= 0, so a mic that leads the reference must be re-aligned first
        let wins = windowScoresCoh(mic, lag < 0 ? shiftReference(sysm, lagMs: lag, n: sysm.count) : sysm, plans: plans)
        let sc = wins.compactMap(\.score)
        if sc.isEmpty {
            return Bleed(bleed: false, verdict: "unknown", share: nil, lagMs: lag, scores: wins.map(\.score), times: wins.map(\.t), thr: thr)
        }
        let share = Double(sc.filter { $0 >= thr }.count) / Double(sc.count), bleed = share >= bleedShare
        return Bleed(bleed: bleed, verdict: bleed ? "bleed" : "clean", share: PyRound.round(share, 3), lagMs: lag,
                     scores: wins.map(\.score), times: wins.map(\.t), thr: thr)
    }

    static func detectBleed(mic: URL, system: URL, thr: Double = bleedThr, systemOffsetS: Double = 0.0) throws -> Bleed {
        detect(mic: try load16k(mic), system: alignStart(try load16k(system), offsetS: systemOffsetS), thr: thr)
    }

    // ---------- text fallback ----------
    private static func norm(_ t: String) -> String {  // re.sub(r"[^a-z0-9']", "", t.lower())
        var o = String.UnicodeScalarView()
        for s in t.lowercased().unicodeScalars where (s.value >= 97 && s.value <= 122) || (s.value >= 48 && s.value <= 57) || s == "'" { o.append(s) }
        return String(o)
    }

    /// Fallback when echo removal failed. A mic word is flagged as echo when the same word occurs in the system words
    /// within +-window s of its start, and it is either >= 4 letters or next to another flagged word.
    static func dedupWords(_ mic: [Turns.Word], _ system: [Turns.Word], window: Double = 1.5)
        -> (kept: [Turns.Word], dropped: [(word: Turns.Word, echoOf: String)]) {
        let sysw = system.compactMap { w -> (String, Double, String)? in let n = norm(w.text); return n.isEmpty ? nil : (n, w.start, w.text) }
        let cand = mic.map { w -> String? in
            let t = norm(w.text)
            return sysw.first { !t.isEmpty && $0.0 == t && abs(w.start - $0.1) <= window }?.2
        }
        var kept: [Turns.Word] = [], dropped: [(word: Turns.Word, echoOf: String)] = []
        for (i, w) in mic.enumerated() {
            let near = (i > 0 && cand[i - 1] != nil) || (i + 1 < cand.count && cand[i + 1] != nil)
            if let hit = cand[i], norm(w.text).count >= 4 || near { dropped.append((w, hit)) } else { kept.append(w) }
        }
        return (kept, dropped)
    }

    /// Bleed meetings: removal leaves scraps of the other side ("Where", "the", "is"). Drop any mic utterance (words
    /// split at `gap` s of silence) of <= maxWords words that overlaps system-track speech within `slack` s. Both
    /// word lists must be on one clock. Known trade-off: a real one-word backchannel while the other side talks goes too.
    static func dropResidue(_ mic: [Turns.Word], _ system: [Turns.Word], gap: Double = 1.0, maxWords: Int = 2, slack: Double = 0.5)
        -> (kept: [Turns.Word], dropped: [Turns.Word]) {
        var kept: [Turns.Word] = [], dropped: [Turns.Word] = [], run: [Turns.Word] = []
        func flush() {
            let end = run.map(\.end).max() ?? 0, first = run[0].start
            let hit = run.count <= maxWords && system.contains { $0.start - slack < end && $0.end + slack > first }
            if hit { dropped += run } else { kept += run }
            run.removeAll()
        }
        for w in Turns.stableSorted(mic, by: \.start) {
            if !run.isEmpty, w.start - run.map(\.end).max()! > gap { flush() }
            run.append(w)
        }
        if !run.isEmpty { flush() }
        return (kept, dropped)
    }
}
