import Foundation

// echo.py's remove_echo, process, _chunks and self_check (the part Echo.swift left to "the engine"): per-chunk lag
// estimation and reference alignment, crossfaded chunk cores, and the truth-free self-check. The model call itself is
// the `EchoRemover` (LocalVQE, personal build). Float32 where numpy is float32.

extension Echo {
    static let chunkS = 30, overlapS = 2   // CHUNK_S, OVERLAP_S
    static let minReductionDb = 3.0, maxNearLossDb = 3.0   // MIN_REDUCTION_DB, MAX_NEAR_LOSS_DB
    static let nullCoh = 0.003, chunkGoodDb = 6.0   // NULL_COH, CHUNK_GOOD_DB
    static let retryLagsMs = [160, 240, 100, 400]   // RETRY_LAGS_MS
    static let fr = 320   // FR

    struct SelfCheck: Equatable { var reductionEchoDb: Double?; var nearChangeDb: Double?; var ok: Bool }
    struct Removal {
        var failed: Bool; var reason: String?; var selfCheck: SelfCheck?; var lagMs: Int?; var chunkLagsMs: [Int?]
        var seconds: Double; var cleaned: [Float]
    }
    /// The model is not installed (Python's LocalVQEMissing): not a failure of this meeting; the caller falls back to dedup.
    struct RemoverMissing: Error { var reason: String }

    /// [(a, b)] core ranges covering n; a tail shorter than half a chunk merges into the previous one.
    static func chunks(_ n: Int, _ chunk: Int) -> [(Int, Int)] {
        var cuts = Array(stride(from: 0, to: n, by: chunk)) + [n]
        if cuts.count > 2 && cuts[cuts.count - 1] - cuts[cuts.count - 2] < chunk / 2 { cuts.remove(at: cuts.count - 2) }
        return Array(zip(cuts.dropLast(), cuts.dropFirst()))
    }

    private static func frames(_ x: [Float]) -> [ArraySlice<Float>] {
        (0..<(x.count / fr)).map { x[($0 * fr)..<(($0 + 1) * fr)] }
    }

    private static func rms(_ f: ArraySlice<Float>) -> Float {
        var s = 0.0
        for v in f { s += Double(v) * Double(v) }
        return Float((s / Double(f.count)).squareRoot())
    }

    /// echo.active: per-frame mask, frame RMS within `db` of the RMS of the non-silent frames.
    static func active(_ x: [Float], db: Double = -40) -> [Bool] {
        let r = frames(x).map(rms), on = r.filter { $0 > 1e-5 }
        if on.isEmpty { return [Bool](repeating: false, count: r.count) }
        let mean = on.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(on.count)
        let thr = Float(pow(10.0, db / 20) * mean.squareRoot())
        return r.map { $0 > thr }
    }

    private static func energy<S: Sequence>(_ fs: S) -> Double where S.Element == ArraySlice<Float> {
        var s = 0.0
        for f in fs { for v in f { s += Double(v) * Double(v) } }
        return s
    }

    private static func dB(_ a: Double, _ b: Double) -> Double { 10 * log10(a / max(b, 1e-20)) }

    /// echo._reduction: echo-to-rest ratio before/after, dB, over the windows where the mic is coherent with the reference
    /// (score >= bleedThr). Coherence g = E / (E + rest), so g / (1 - g) = E / rest. nil = no echo window to judge.
    static func reduction(_ mic: [Window], _ out: [Window]) -> Double? {
        var before = 0.0, after = 0.0, n = 0
        for (a, b) in zip(mic, out) {
            guard let sa = a.score, sa >= bleedThr, let sb = b.score else { continue }
            let g = min(sa, 0.999), h = min(max(sb.isNaN ? 0 : sb, nullCoh), 0.999)
            before += g / (1 - g); after += h / (1 - h); n += 1
        }
        return n > 0 ? PyRound.round(10 * log10(before / after), 1) : nil
    }

    /// echo.self_check. reduction_echo_dB: in the windows where the mic is coherent with the system track (echo present) the
    /// echo-to-rest ratio must fall by >= 3 dB (energy is the wrong yardstick, see echo.py); system-silent frames (near end
    /// alone) must keep their energy within 3 dB. lagMs < 0: the reference is advanced first.
    static func selfCheck(mic micIn: [Float], out outIn: [Float], system sysIn: [Float], lagMs: Int = 0, plans: Plans = Plans()) -> SelfCheck {
        let n = min(micIn.count, outIn.count, sysIn.count)
        let mic = Array(micIn.prefix(n)), out = Array(outIn.prefix(n)), sys = Array(sysIn.prefix(n))
        var sa = active(sys, db: -45)
        var mf = frames(mic), of = frames(out)
        let k = min(sa.count, mf.count)
        sa = Array(sa.prefix(k)); mf = Array(mf.prefix(k)); of = Array(of.prefix(k))
        var near: Double?
        let ref = lagMs < 0 ? shiftReference(sys, lagMs: lagMs, n: n) : sys
        let red = reduction(windowScoresCoh(mic, ref, plans: plans), windowScoresCoh(out, ref, plans: plans))
        // binary_dilation(sa, iterations=15): every active frame claims 15 frames each side
        var dil = [Bool](repeating: false, count: k)
        var lastOn = -1000
        for i in 0..<k { if sa[i] { lastOn = i }; if i - lastOn <= 15 { dil[i] = true } }
        var nextOn = 1000 + k
        for i in stride(from: k - 1, through: 0, by: -1) { if sa[i] { nextOn = i }; if nextOn - i <= 15 { dil[i] = true } }
        let quiet = (0..<k).filter { !dil[$0] }
        if quiet.count >= 20 && energy(quiet.map { mf[$0] }) > 1e-9 {
            near = PyRound.round(dB(energy(quiet.map { of[$0] }), energy(quiet.map { mf[$0] })), 1)
        }
        let ok = red != nil && red! >= minReductionDb && (near == nil || near! >= -maxNearLossDb)
        return SelfCheck(reductionEchoDb: red, nearChangeDb: near, ok: ok)
    }

    /// echo._clean_chunk: the cleaned chunk, or nil when the mic shows no coherent echo (nothing to remove; LocalVQE adds
    /// energy at pings and clicks on a sparse system track). The standalone LocalVQE sometimes returns a clip untouched
    /// (0.3 dB instead of 11-19 dB on a 34 s clip with a 260 ms echo; deterministic, flips with the echo lag and the clip
    /// bounds), visible as an unchanged echo window: retry at `retryLagsMs` and keep the best.
    static func cleanChunk(mic m: [Float], system s: [Float], lagMs lag: Int, remover: any EchoRemover, plans: Plans) throws -> [Float]? {
        let ref = shiftReference(s, lagMs: lag, n: m.count)
        let micScores = windowScoresCoh(m, ref, plans: plans)
        guard micScores.contains(where: { ($0.score ?? -1) >= bleedThr }) else { return nil }
        var best: [Float]?, bestDb = 0.0
        for target in [nil] + retryLagsMs.map(Optional.some) {
            try Task.checkCancellation()
            let y = try remover.clean(mic: m, reference: target == nil ? ref : shiftReference(s, lagMs: lag, n: m.count, targetMs: target))
            let db = reduction(micScores, windowScoresCoh(y, ref, plans: plans)) ?? 0
            if best == nil || db > bestDb { best = y; bestDb = db }
            if bestDb >= chunkGoodDb { break }
        }
        return best
    }

    /// echo.process: arrays -> (cleaned, per-chunk lags, global lag). Each chunk gets its own lag estimate and reference
    /// alignment; chunk cores are joined with a 50 ms crossfade taken from the overlap context.
    static func processChunks(mic: [Float], system sysIn: [Float], remover: any EchoRemover, chunkS: Int = Echo.chunkS, overlapS: Int = Echo.overlapS)
        throws -> (cleaned: [Float], chunkLags: [Int?], globalLag: Int) {
        let n = mic.count
        var system = Array(sysIn.prefix(n))
        if system.count < n { system += [Float](repeating: 0, count: n - system.count) }
        let chunk = chunkS * sr, ov = overlapS * sr, xf = Int(0.05 * Double(sr))
        var out = [Float](repeating: 0, count: n), wsum = out, lags: [Int?] = []
        let plans = Plans()
        let glag = n > sr ? estimateLagMs(mic, system, plans: plans) : 0
        for (a, b) in chunks(n, chunk) {
            try Task.checkCancellation()
            let lo = max(0, a - ov), hi = min(n, b + ov)
            let m = Array(mic[lo..<hi]), s = Array(system[lo..<hi])
            let lag = m.count > 10 * sr ? estimateLagMs(m, s, segS: chunkS, plans: plans) : glag
            let cleaned = try cleanChunk(mic: m, system: s, lagMs: lag, remover: remover, plans: plans)
            lags.append(cleaned == nil ? nil : lag)
            let y = cleaned ?? m
            for i in 0..<m.count {
                let t = lo + i
                var w: Float = 1
                if a > 0 { w *= Float(min(max(Double(t - (a - xf / 2)) / Double(xf), 0), 1)) }
                if b < n { w *= Float(min(max(Double((b + xf / 2) - t) / Double(xf), 0), 1)) }
                out[t] += y[i] * w
                wsum[t] += w
            }
        }
        for i in 0..<n { out[i] /= max(wsum[i], 1e-6) }
        return (out, lags, glag)
    }

    /// echo.remove_echo: clean the mic track (both 16 kHz mono, `system` NOT yet on the mic's clock: `systemOffsetS` as for
    /// `alignStart`). failed == true means the caller discards `cleaned` and falls back to dedup. Throws `RemoverMissing`
    /// for environment problems and CancellationError.
    static func removeEcho(mic: [Float], system sysIn: [Float], remover: any EchoRemover, chunkS: Int = Echo.chunkS, systemOffsetS: Double = 0.0) throws -> Removal {
        let t0 = Date()
        let system = alignStart(sysIn, offsetS: systemOffsetS)
        func secs() -> Double { PyRound.round(Date().timeIntervalSince(t0), 1) }
        if mic.count < 2 * sr || system.count < 2 * sr {
            return Removal(failed: true, reason: "track shorter than 2 s", selfCheck: nil, lagMs: nil, chunkLagsMs: [], seconds: secs(), cleaned: mic)
        }
        let r: (cleaned: [Float], chunkLags: [Int?], globalLag: Int)
        do { r = try processChunks(mic: mic, system: system, remover: remover, chunkS: chunkS) }
        catch is CancellationError { throw CancellationError() }
        catch EngineError.modelMissing(let m) { throw RemoverMissing(reason: m) }
        catch EngineError.unavailable { throw RemoverMissing(reason: "echo removal is unavailable in this build") }
        catch {
            let why = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return Removal(failed: true, reason: PyText.prefix(why, 300),
                           selfCheck: nil, lagMs: nil, chunkLagsMs: [], seconds: secs(), cleaned: mic)
        }
        let chk = selfCheck(mic: mic, out: r.cleaned, system: system, lagMs: r.globalLag)
        var failed = false, reason: String?
        if !chk.ok {
            failed = true
            reason = "self-check: " + ((chk.reductionEchoDb ?? 0) < minReductionDb ? "no meaningful echo reduction" : "near-end energy lost")
        }
        return Removal(failed: failed, reason: reason, selfCheck: chk, lagMs: r.globalLag, chunkLagsMs: r.chunkLags, seconds: secs(), cleaned: r.cleaned)
    }
}
