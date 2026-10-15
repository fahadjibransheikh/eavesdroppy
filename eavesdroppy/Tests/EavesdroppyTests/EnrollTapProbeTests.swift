import Foundation
import Testing
@testable import Eavesdroppy

// Opt-in, on real hardware: EAVESDROPPY_ENROLL_PROBE=1. Records 3 s with the enrollment tap and nothing touched, and checks
// it is not taken for a microphone change. On macOS 26 the engine's input is a private CADefaultDeviceAggregate wrapper,
// and comparing its id with the default input failed every enrollment with "Your microphone changed while recording".
@Suite struct EnrollTapProbeTests {
    @Test func anUntouchedRecordingIsNotAMicrophoneChange() async throws {
        guard ProcessInfo.processInfo.environment["EAVESDROPPY_ENROLL_PROBE"] != nil else { return }
        let tap = EnrollTap()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try audioQ.sync { try tap.start(url: url) }
        try await Task.sleep(for: .seconds(3))
        audioQ.sync { tap.stop() }
        let after = audioQ.sync { tap.deviceChangedSinceStart() }
        print("PROBE device=\(tap.device) changed=\(tap.changed ?? "nil") after=\(after ?? "nil")")
        #expect(tap.changed == nil)
        #expect(after == nil)
        #expect(!tap.device.uid.hasPrefix("CADefaultDeviceAggregate"))
    }
}
