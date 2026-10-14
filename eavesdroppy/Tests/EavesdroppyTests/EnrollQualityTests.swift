import Foundation
import Testing
@testable import Eavesdroppy

// EnrollQuality: the numbers (level, clipping, SNR, cluster shares) and the order the refusals are checked in. The refusal paths
// through `enroll` itself are in NativeCommandsTests; the thresholds were calibrated on real audio (RealRunTests.measureEnrollWavs).

@Suite struct EnrollQualityTests {
    private func seg(_ a: Double, _ b: Double, _ c: String) -> EngineSegment { EngineSegment(start: a, end: b, cluster: c) }
    private let native = EnrollQuality.Native(peak: 0.5, clipFraction: 0, rate: 48_000, channels: 1)

    /// 16 kHz: first half a loud tone (-20 dBFS RMS), second half quiet noise floor (-60 dBFS RMS).
    private func halves(seconds: Int = 20) -> [Float] {
        let n = 16_000 * seconds
        return (0..<n).map { i in
            i < n / 2 ? Float(0.1 * 2.0.squareRoot() * sin(2 * Double.pi * 200 * Double(i) / 16_000))
                      : Float(0.001 * 2.0.squareRoot() * sin(2 * Double.pi * 90 * Double(i) / 16_000))
        }
    }

    @Test func percentileInterpolatesLikeNumpy() {
        #expect(EnrollQuality.percentile([1, 2, 3, 4, 5], 0.10) == 1.4)
        #expect(EnrollQuality.percentile([7], 0.10) == 7)
        #expect(EnrollQuality.percentile([], 0.10) == 0)
    }

    @Test func measuresSpeechLevelAndSNRFromTheDominantClusterFrames() {
        let m = EnrollQuality.measure(samples: halves(), segments: [seg(0, 10, "S1"), seg(10, 20, "S2")], native: native)
        #expect(m.dominant == "S1"); #expect(m.clusters == 2)
        #expect(abs(m.speechDB - -20) < 0.1)
        #expect(abs(m.snrDB! - 40) < 0.5, "-20 dBFS speech over a -60 dBFS floor")
        #expect(abs(m.overallDB - -23) < 0.2, "mean power of the two halves")
        #expect(abs(m.otherShare - 0.5) < 1e-9)
    }

    @Test func dominantClusterTiesGoToTheFirst() {
        let m = EnrollQuality.measure(samples: halves(), segments: [seg(0, 5, "S2"), seg(5, 10, "S1")], native: native)
        #expect(m.dominant == "S2")
    }

    @Test func noSegmentsMeansNoDominantClusterAndStillMeasuresNothingElse() {
        let m = EnrollQuality.measure(samples: halves(), segments: [], native: native)
        #expect(m.dominant == nil); #expect(m.clusters == 0); #expect(m.snrDB == nil)
        #expect(EnrollQuality.rejection(m, minSpeech: 10)?.hasPrefix("No speech was picked up.") == true)
    }

    @Test func nativeStatsCountsPeakAndClippedSamplesBeforeResampling() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        var x = [Float](repeating: 0.25, count: 48_000)
        for i in 0..<480 { x[i * 100] = i % 2 == 0 ? 1 : -1 }   // 480 of 48 000 samples = 1.0 %
        try ProcessorAudio.writeMonoFloat(x, rate: 48_000, to: url)
        let n = try EnrollQuality.nativeStats(url)
        #expect(n.peak == 1); #expect(abs(n.clipFraction - 0.01) < 1e-9); #expect(n.rate == 48_000); #expect(n.channels == 1)
    }

    @Test func refusalsAreCheckedInOrderAndEachHasItsOwnSentence() {
        var m = EnrollQuality.Metrics(dominant: "S1", clusters: 2, totalSpeech: 20, speech: 8, otherShare: 0.4, speechDB: -60, snrDB: 1)
        m.clipFraction = 0.05
        #expect(EnrollQuality.rejection(m, minSpeech: 10) == "Only 8.0 seconds of speech were picked up, and at least 10 are needed. Read the passage steadily and closer to the microphone.")
        m.speech = 12
        #expect(EnrollQuality.rejection(m, minSpeech: 10) == "Another voice was picked up (40% of the speech). Record where only you are talking.")
        m.otherShare = 0.2
        #expect(EnrollQuality.rejection(m, minSpeech: 10) == "Too quiet: your voice was recorded at -60 dB. Move closer to the microphone or raise its input volume.")
        m.speechDB = -30
        #expect(EnrollQuality.rejection(m, minSpeech: 10) == "Too loud: 5.0% of the recording is distorted. Move back from the microphone or lower its input volume.")
        m.clipFraction = 0.01
        #expect(EnrollQuality.rejection(m, minSpeech: 10) == "Too much background noise. Move somewhere quieter, or closer to the microphone, and try again.")
        m.snrDB = 3
        #expect(EnrollQuality.rejection(m, minSpeech: 10) == nil, "every limit is inclusive: 20 % other voice, 1 % clipped, 3 dB, -40 dB")
        m.snrDB = nil
        #expect(EnrollQuality.rejection(m, minSpeech: 10) == nil, "no frames, no SNR verdict")
        m.speechDB = -40
        #expect(EnrollQuality.rejection(m, minSpeech: 10) == nil)
    }
}
