import Foundation

// echo.py's remove_echo, process, _chunks and self_check (the part Echo.swift left to "the engine"): per-chunk lag
// estimation and reference alignment, crossfaded chunk cores, and the truth-free self-check. The model call itself is
// the `EchoRemover` (LocalVQE, personal build). Float32 where numpy is float32.

extension Echo {
    static let chunkS = 30, overlapS = 2   // CHUNK_S, OVERLAP_S
    static let minReductionDb = 3.0, maxNearLossDb = 3.0   // MIN_REDUCTION_DB, MAX_NEAR_LOSS_DB
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

    /// echo.self_check. Echo-dominant frames (system active, mic in the quieter half of those) must get >= 3 dB quieter;
    /// system-silent frames (near end alone) must keep their energy within 3 dB.
    static func selfCheck(mic micIn: [Float], out outIn: [Float], system sysIn: [Float]) -> SelfCheck {
        let n = min(micIn.count, outIn.count, sysIn.count)
        let mic = Array(micIn.prefix(n)), out = Array(outIn.prefix(n)), sys = Array(sysIn.prefix(n))
        var sa = active(sys, db: -45)
        var mf = frames(mic), of = frames(out)
        let k = min(sa.count, mf.count)
        sa = Array(sa.prefix(k)); mf = Array(mf.prefix(k)); of = Array(of.prefix(k))
        var red: Double?, near: Double?
        if sa.filter({ $0 }).count >= 20 {
            let r = mf.map(rms)
            let act = (0..<k).filter { sa[$0] }.map { r[$0] }.sorted()
            let med = act.count % 2 == 1 ? act[act.count / 2] : (act[act.count / 2 - 1] + act[act.count / 2]) / 2   // np.median in float32
            let ech = (0..<k).filter { sa[$0] && r[$0] <= med }
            red = PyRound.round(dB(energy(ech.map { mf[$0] }), energy(ech.map { of[$0] })), 1)
        }
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
            let y: [Float]
            let loud = s.reduce(0) { $0 + (abs($1) > 1e-4 ? 1 : 0) }
            if Double(loud) / Double(s.count) < 0.01 {  // reference silent: nothing to cancel
                y = m; lags.append(nil)
            } else {
                let lag = m.count > 10 * sr ? estimateLagMs(m, s, segS: chunkS, plans: plans) : glag
                lags.append(lag)
                y = try remover.clean(mic: m, reference: shiftReference(s, lagMs: lag, n: m.count))
            }
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
        let chk = selfCheck(mic: mic, out: r.cleaned, system: system)
        var failed = false, reason: String?
        if !chk.ok {
            failed = true
            reason = "self-check: " + ((chk.reductionEchoDb ?? 0) < minReductionDb ? "no meaningful echo reduction" : "near-end energy lost")
        }
        return Removal(failed: failed, reason: reason, selfCheck: chk, lagMs: r.globalLag, chunkLagsMs: r.chunkLags, seconds: secs(), cleaned: r.cleaned)
    }
}
