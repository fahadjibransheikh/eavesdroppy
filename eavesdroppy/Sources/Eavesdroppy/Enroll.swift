import AVFoundation
import DroppyKit

/// D5: "Teach Eavesdroppy your voice". Records 25 s from the microphone to <container>/enroll/<ts>.wav and hands it
/// to `enroll <wav> --name <name>`. Audio runs on audioQ like the meeting recorder (Core Audio can block); the meter
/// and countdown are read by a main-thread timer.
@MainActor final class Enrollment: ObservableObject {
    enum State: Equatable { case idle, recording, processing, done(seconds: Double), failed(String) }

    static let duration = 25.0
    /// About 25 seconds read aloud at a relaxed pace, with a spread of sounds.
    static let passage = "Hi, this is my voice. I'm teaching Eavesdroppy to recognise me, so it can tell which parts of a call I said. "
        + "On a normal day I might talk through a project update, agree a few deadlines, and ask someone to send over the latest numbers. "
        + "Quick brown foxes jump over lazy dogs, and zebras vex quiet judges. I'll keep going at a relaxed pace until the timer runs out."

    @Published private(set) var state: State = .idle
    @Published private(set) var level: Float = 0        // 0...1
    @Published private(set) var remaining = Enrollment.duration

    private var tap: EnrollTap?
    private var ticker: Timer?
    private var started = Date()
    private var run = 0  // a stale callback (cancelled, or a newer run) is ignored

    var active: Bool { state == .recording || state == .processing }

    /// Asks for the microphone like the meeting recorder does (through host.permissions), then records.
    func start(host: DropletHost, name: String, onFinished: @escaping () -> Void) {
        guard !active else { return }
        // argparse would read a leading "-" in --name as an option
        guard !name.hasPrefix("-") else { state = .failed("Your name can't start with a dash"); return }
        state = .recording; level = 0; remaining = Self.duration
        run += 1
        let id = run
        switch host.permissions.status(for: .microphone) {
        case .granted: begin(name: name, run: id, onFinished: onFinished)
        case .notDetermined:
            Task {
                let s = await host.permissions.request(.microphone)
                guard self.run == id else { return }
                if s == .granted { self.begin(name: name, run: id, onFinished: onFinished) } else { self.deny(host) }
            }
        default: deny(host)
        }
    }

    private func deny(_ host: DropletHost) {
        state = .failed("Microphone access is off for Droppy")
        host.permissions.openSystemSettings(for: .microphone)
    }

    private func begin(name: String, run id: Int, onFinished: @escaping () -> Void) {
        let dir = containerDir.appendingPathComponent("enroll")
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent(f.string(from: Date()) + ".wav")
        let tap = EnrollTap(); self.tap = tap
        audioQ.async {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try tap.start(url: url)
                DispatchQueue.main.async { MainActor.assumeIsolated { self.running(tap, url, name, id, onFinished) } }
            } catch {
                tap.stop()
                DispatchQueue.main.async { MainActor.assumeIsolated { if self.run == id { self.state = .failed("\(error)") } } }
            }
        }
    }

    private func running(_ tap: EnrollTap, _ url: URL, _ name: String, _ id: Int, _ onFinished: @escaping () -> Void) {
        guard run == id else { audioQ.async { tap.stop() }; return }
        started = Date()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.run == id else { return }
                let left = Self.duration - Date().timeIntervalSince(self.started)
                self.level = tap.level; self.remaining = max(left, 0)
                if left <= 0 { self.finish(tap, url, name, id, onFinished) }
            }
        }
    }

    private func finish(_ tap: EnrollTap, _ url: URL, _ name: String, _ id: Int, _ onFinished: @escaping () -> Void) {
        ticker?.invalidate(); ticker = nil
        state = .processing; level = 0
        audioQ.async {
            tap.stop()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.run == id else { return }
                    Pipeline.submit(["enroll", url.path, "--name=\(name)", "--user-name=\(name)"]) { r in
                        MainActor.assumeIsolated {
                            guard self.run == id else { return }
                            switch r {
                            case .success(let j): self.state = .done(seconds: (j["seconds"] as? Double) ?? Double(j["seconds"] as? Int ?? 0))
                            case .failure(let e): self.state = .failed(e.description)
                            }
                            onFinished()
                        }
                    }
                }
            }
        }
    }

    /// Stops a recording in progress (deactivation, or the user backing out) and removes its file.
    func cancel() {
        guard active else { return }
        run += 1
        ticker?.invalidate(); ticker = nil
        if let t = tap { audioQ.async { t.stop(); try? FileManager.default.removeItem(at: t.url) } }
        tap = nil; state = .idle; level = 0
    }
}

/// A microphone tap writing a WAV (TrackWriter: float32, the input's own rate, usually 48 kHz) plus a live level.
final class EnrollTap: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var writer: TrackWriter?
    private let lock = NSLock()
    private var _level: Float = 0
    private(set) var url = URL(fileURLWithPath: "/dev/null")

    var level: Float { lock.withLock { _level } }

    /// audioQ.
    func start(url: URL) throws {
        self.url = url
        let input = engine.inputNode
        // See Recorder.installMicTap: format nil and a check right before, never a format read earlier (NSException).
        let f = input.outputFormat(forBus: 0)
        guard f.sampleRate > 0, f.channelCount > 0 else { throw RecError("no microphone input available") }
        let w = TrackWriter(lazyURL: url); writer = w
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buf, when in
            w.write(buf, host: when.isHostTimeValid ? when.hostTime : 0)
            guard let ch = buf.floatChannelData?[0], buf.frameLength > 0 else { return }
            var sum: Float = 0
            for i in 0..<Int(buf.frameLength) { sum += ch[i] * ch[i] }
            let db = 20 * log10(max((sum / Float(buf.frameLength)).squareRoot(), 1e-7))
            self?.lock.withLock { self?._level = min(max((db + 55) / 45, 0), 1) }  // -55 dB..-10 dB -> 0..1
        }
        try engine.start()
    }

    /// audioQ. Safe after a failed start().
    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        writer?.close()
    }
}
