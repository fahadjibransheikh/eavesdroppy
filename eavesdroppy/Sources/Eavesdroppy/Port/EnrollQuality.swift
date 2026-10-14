import AVFoundation
import Foundation

// Is a voice sample good enough to learn a voiceprint from? Mirrors speakers.enroll_quality / enroll_rejection (same
// thresholds, same sentences). Pure maths on the 16 kHz mono samples, the diarizer's segments and the native-rate
// peak / clipping counted before resampling; `NativeCommands.enroll` runs it, the tests and the real-audio calibration
// (RealRunTests.measureEnrollWavs) call it directly.
//
// Calibrated 2026-10-14 on 25 s cuts of the in-person archive raw/20261013-192230-merged/mic.flac (the user is "Speaker 1") and on
// the 65 s mic track of raw/20261013-123545-736-0001 (the enrollment golden sample). 375 single-speaker windows: one cluster,
// speech -35.0..-23.1 dBFS, SNR 9.3 or more, clipping at most 0.17 %. 39 windows with a second talker: two clusters, the smaller
// one 20..49 % of the speech. The golden sample: speech -33.5 dBFS, SNR 5.6. See the CHANGELOG for the whole table.

enum EnrollQuality {
    /// A second cluster with more than this share of all speech means somebody else was talking.
    static let maxOtherShare = 0.20
    /// Mean power of the dominant cluster's frames. The quietest clean window read -35.0, a distant talker -41.6 to -43.0.
    static let minSpeechDB = -40.0
    /// Fraction of native-rate samples at or above `clipLevel`.
    static let maxClipFraction = 0.01
    static let clipLevel: Float = 0.999
    /// Dominant-cluster speech level minus the 10th-percentile 20 ms frame power: a guard against gross noise only. Continuous
    /// clean speech with no pauses reads as low as 5.6 (the golden sample), the same as white noise mixed in at 0 dB SNR
    /// (5.6 to 6.3), so only noise louder than the voice is caught.
    static let minSNRdB = 3.0
    static let frame = 320   // 20 ms at 16 kHz
    private static let floorPower = 1e-14   // -140 dB

    struct Native: Equatable { var peak: Float; var clipFraction: Double; var rate: Double; var channels: Int }

    struct Metrics: Equatable {
        var dominant: String?
        var clusters = 0
        var totalSpeech = 0.0       // seconds of speech, all clusters
        var speech = 0.0            // seconds of speech, dominant cluster
        var otherShare = 0.0        // second-largest cluster / totalSpeech
        var overallDB = -140.0      // RMS of the whole sample
        var peakDB = -140.0         // native-rate peak
        var speechDB = -140.0       // RMS over the dominant cluster's frames
        var snrDB: Double?          // speechDB minus the 10th-percentile frame power; nil when there are no frames
        var clipFraction = 0.0
        var dominantShare: Double { totalSpeech > 0 ? speech / totalSpeech : 0 }
        /// The numbers in the `enroll` result.
        var json: [String: Any] {
            var d: [String: Any] = ["clusters": clusters, "speech_s": PyRound.round(speech, 1), "total_speech_s": PyRound.round(totalSpeech, 1),
                                    "other_share": PyRound.round(otherShare, 3), "overall_db": PyRound.round(overallDB, 1), "speech_db": PyRound.round(speechDB, 1),
                                    "peak_db": PyRound.round(peakDB, 1), "clip_fraction": PyRound.round(clipFraction, 5)]
            if let snrDB { d["snr_db"] = PyRound.round(snrDB, 1) }
            return d
        }
    }

    static func db(_ power: Double) -> Double { 10 * log10(max(power, floorPower)) }

    /// numpy.percentile (linear interpolation) of an ascending array.
    static func percentile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let pos = q * Double(sorted.count - 1), lo = Int(pos.rounded(.down)), hi = min(lo + 1, sorted.count - 1)
        return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - Double(lo))
    }

    /// Peak and clipping of the recording as written (float32 at the input's own rate), all channels.
    static func nativeStats(_ url: URL) throws -> Native {
        let f = try AVAudioFile(forReading: url)
        let fmt = f.processingFormat, ch = Int(fmt.channelCount)
        guard ch > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 1 << 16) else { throw Echo.LoadError(message: "cannot read \(url.lastPathComponent)") }
        var peak: Float = 0, clipped = 0, total = 0
        while f.framePosition < f.length {
            try f.read(into: buf)
            let n = Int(buf.frameLength)
            guard n > 0, let d = buf.floatChannelData else { break }
            for c in 0..<ch {
                for i in 0..<n { let a = abs(d[c][i]); if a > peak { peak = a }; if a >= clipLevel { clipped += 1 } }
            }
            total += n * ch
        }
        return Native(peak: peak, clipFraction: total > 0 ? Double(clipped) / Double(total) : 0, rate: fmt.sampleRate, channels: ch)
    }

    static func measure(samples x: [Float], segments: [EngineSegment], native: Native) -> Metrics {
        var m = Metrics(clipFraction: native.clipFraction)
        m.peakDB = 20 * log10(max(Double(native.peak), 1e-7))
        var order: [String] = [], secs: [String: Double] = [:]
        for s in segments { if secs[s.cluster] == nil { order.append(s.cluster) }; secs[s.cluster, default: 0] += max(0, s.end - s.start) }
        m.clusters = order.count
        m.totalSpeech = secs.values.reduce(0, +)
        guard var cid = order.first else { return m }
        for c in order where secs[c]! > secs[cid]! { cid = c }   // max(): first of equals
        m.dominant = cid; m.speech = secs[cid]!
        m.otherShare = m.totalSpeech > 0 ? (secs.filter { $0.key != cid }.values.max() ?? 0) / m.totalSpeech : 0

        let n = x.count / frame
        guard n > 0 else { return m }
        var power = [Double](repeating: 0, count: n)
        for i in 0..<n { var s = 0.0; for j in i * frame..<(i + 1) * frame { s += Double(x[j]) * Double(x[j]) }; power[i] = s / Double(frame) }
        m.overallDB = db(power.reduce(0, +) / Double(n))
        let step = Double(frame) / 16_000
        let mine = segments.filter { $0.cluster == cid }
        let inside = (0..<n).filter { i in
            let t0 = Double(i) * step, t1 = t0 + step
            return mine.contains { t0 >= $0.start && t1 <= $0.end }
        }
        let speechPower = inside.isEmpty ? power.reduce(0, +) / Double(n) : inside.map { power[$0] }.reduce(0, +) / Double(inside.count)
        m.speechDB = db(speechPower)
        m.snrDB = m.speechDB - db(percentile(power.sorted(), 0.10))
        return m
    }

    /// The reason to refuse this sample, in the words the Speakers page shows; nil when it is good. Checked in this order.
    static func rejection(_ m: Metrics, minSpeech: Double) -> String? {
        if m.dominant == nil { return "No speech was picked up. Check that the right microphone is selected, then try again." }
        if m.speech < minSpeech {
            return "Only \(String(format: "%.1f", m.speech)) seconds of speech were picked up, and at least \(String(format: "%.0f", minSpeech)) are needed. Read the passage steadily and closer to the microphone."
        }
        if m.otherShare > maxOtherShare {
            return "Another voice was picked up (\(Int(m.otherShare * 100 + 0.5))% of the speech). Record where only you are talking."
        }
        if m.speechDB < minSpeechDB {
            return "Too quiet: your voice was recorded at \(String(format: "%.0f", m.speechDB)) dB. Move closer to the microphone or raise its input volume."
        }
        if m.clipFraction > maxClipFraction {
            return "Too loud: \(String(format: "%.1f", m.clipFraction * 100))% of the recording is distorted. Move back from the microphone or lower its input volume."
        }
        if let snr = m.snrDB, snr < minSNRdB {
            return "Too much background noise. Move somewhere quieter, or closer to the microphone, and try again."
        }
        return nil
    }

    /// One log line with every number the verdict used.
    static func summary(_ m: Metrics) -> String {
        let f = { (v: Double) in String(format: "%.1f", v) }
        return "speech \(f(m.speech)) s of \(f(m.totalSpeech)) s in \(m.clusters) cluster(s), dominant share \(f(m.dominantShare * 100)) %, other voice \(f(m.otherShare * 100)) %; "
            + "level \(f(m.overallDB)) dBFS overall, \(f(m.speechDB)) dBFS speech, peak \(f(m.peakDB)) dBFS, clipped \(String(format: "%.3f", m.clipFraction * 100)) %; "
            + "SNR \(m.snrDB.map(f) ?? "n/a") dB"
    }
}
