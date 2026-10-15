import AVFoundation
import CoreAudio
import Foundation
import Testing
@testable import Eavesdroppy

// Opt-in, on real hardware: EAVESDROPPY_TAP_RATE_TEST=1. Records 23 s, switches the default output device's sample rate
// at 3 s (what AirPods do when a call opens the mic and they drop to HFP), restores it at the end, and checks the call
// track is as long as the recording. Before the tap restarted on a rate change, the new-rate buffers were written at the
// old rate and the track came out shorter or longer than the meeting (2026-10-14: 1993 s of a 3987 s call).

private func outputDevice() -> AudioObjectID {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var dev = AudioObjectID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
    return dev
}

private func nominalRate(_ dev: AudioObjectID) -> Double {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var r = 0.0, size = UInt32(MemoryLayout<Double>.size)
    AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &r)
    return r
}

private func setNominalRate(_ dev: AudioObjectID, _ rate: Double) -> OSStatus {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var r = rate
    return AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Double>.size), &r)
}

@Suite struct RecorderRateTests {
    @Test func callTrackKeepsWallClockLengthAcrossAnOutputRateChange() async throws {
        guard ProcessInfo.processInfo.environment["EAVESDROPPY_TAP_RATE_TEST"] != nil else { return }
        let dev = outputDevice(), original = nominalRate(dev)
        let other = original == 48_000 ? 44_100.0 : 48_000.0
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rate-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { _ = setNominalRate(dev, original); try? FileManager.default.removeItem(at: dir) }

        // Something must be playing for the tap to deliver buffers: a quiet tone for the whole run.
        let tone = dir.appendingPathComponent("tone.wav")
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 48_000 * 30)!
        buf.frameLength = buf.frameCapacity
        for i in 0..<Int(buf.frameLength) { buf.floatChannelData![0][i] = 0.05 * sin(2 * .pi * 440 * Float(i) / 48_000) }
        try AVAudioFile(forWriting: tone, settings: fmt.settings).write(from: buf)
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay"); player.arguments = [tone.path]
        try player.run()
        defer { player.terminate() }
        try await Task.sleep(for: .seconds(1))

        let rec = Recorder(dir: dir)
        try audioQ.sync { try rec.start() }
        let t0 = Date()
        try await Task.sleep(for: .seconds(3))
        #expect(setNominalRate(dev, other) == noErr)
        try await Task.sleep(for: .seconds(20))
        let r = audioQ.sync { rec.stop() }
        let wall = Date().timeIntervalSince(t0) - (r.offsets["system"] ?? 0)

        let f = try AVAudioFile(forReading: dir.appendingPathComponent("system.wav"))
        let seconds = Double(f.length) / f.fileFormat.sampleRate
        print("RATE original=\(original) switched=\(other) now=\(nominalRate(dev)) file=\(f.fileFormat.sampleRate) Hz track=\(String(format: "%.2f", seconds)) s wall=\(String(format: "%.2f", wall)) s")
        // The restart leaves a gap of about half a second; a mislabelled rate is off by 8% (44.1 vs 48 kHz) of the 20 s after the switch.
        #expect(abs(seconds - wall) < 1.0)
        // And it plays at the right speed: the 440 Hz tone, in the last 5 s (after the switch), counted by zero crossings.
        let n = AVAudioFrameCount(5 * f.fileFormat.sampleRate)
        f.framePosition = f.length - AVAudioFramePosition(n) - AVAudioFramePosition(f.fileFormat.sampleRate)
        let tail = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: n)!
        try f.read(into: tail, frameCount: n)
        let x = tail.floatChannelData![0]
        var crossings = 0
        for i in 1..<Int(tail.frameLength) where (x[i - 1] < 0) != (x[i] < 0) { crossings += 1 }
        let hz = Double(crossings) / 2 / 5
        print("RATE tone after the switch: \(String(format: "%.0f", hz)) Hz")
        #expect(abs(hz - 440) < 10)
    }
}
