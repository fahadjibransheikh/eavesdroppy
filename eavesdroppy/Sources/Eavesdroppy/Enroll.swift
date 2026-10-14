import AVFoundation
import CoreAudio
import DroppyKit

/// D5: "Teach Eavesdroppy your voice". Records 25 s from the microphone to <container>/enroll/recording.wav, moves it to
/// enroll/last.wav (kept, overwritten by the next one, so a bad print can be diagnosed) and hands it to
/// `enroll <wav> --name <name>`. Audio runs on audioQ like the meeting recorder (Core Audio can block); the meter
/// and countdown are read by a main-thread timer. A microphone or format change mid-recording aborts it.
@MainActor final class Enrollment: ObservableObject {
    /// `confirm`: the new voice matches the saved one below the threshold (cosine `match`); nothing is saved until the user says so.
    enum State: Equatable { case idle, recording, processing, done(seconds: Double, meetingMatch: Double?), confirm(match: Double), failed(String) }
    static let micChanged = "Your microphone changed while recording. Try again."

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
    private var pending: (name: String, onFinished: () -> Void)?  // while .confirm: what Save needs

    var active: Bool { state == .recording || state == .processing }

    /// Asks for the microphone like the meeting recorder does (through host.permissions), then records.
    func start(host: DropletHost, name: String, onFinished: @escaping () -> Void) {
        guard !active else { return }
        // argparse would read a leading "-" in --name as an option
        guard !name.hasPrefix("-") else { state = .failed("Your name can't start with a dash"); return }
        state = .recording; level = 0; remaining = Self.duration; pending = nil
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
        let url = dir.appendingPathComponent("recording.wav")
        let tap = EnrollTap(); self.tap = tap
        audioQ.async {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: url)
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
                if let why = tap.changed { self.abort(tap, Self.micChanged, why); return }
                if left <= 0 { self.finish(tap, url, name, id, onFinished) }
            }
        }
    }

    private func finish(_ tap: EnrollTap, _ url: URL, _ name: String, _ id: Int, _ onFinished: @escaping () -> Void) {
        ticker?.invalidate(); ticker = nil
        state = .processing; level = 0
        audioQ.async {
            tap.stop()
            let why = tap.changed ?? tap.deviceChangedSinceStart()
            let kept = url.deletingLastPathComponent().appendingPathComponent("last.wav")
            if why == nil { try? FileManager.default.removeItem(at: kept); try? FileManager.default.moveItem(at: url, to: kept) } else { try? FileManager.default.removeItem(at: url) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.run == id else { return }
                    if let why { log("enroll: \(why)"); self.state = .failed(Self.micChanged); return }
                    log("enroll: recorded \(Int(Self.duration)) s from \(tap.device.description), kept as \(kept.lastPathComponent)")
                    self.submit(kept, name: name, force: false, id: id, onFinished)
                }
            }
        }
    }

    private func submit(_ wav: URL, name: String, force: Bool, id: Int, _ onFinished: @escaping () -> Void) {
        Pipeline.submit(["enroll", wav.path, "--name=\(name)", "--user-name=\(name)"] + (force ? ["--force"] : [])) { r in
            MainActor.assumeIsolated {
                guard self.run == id else { return }
                switch r {
                case .success(let j):
                    if j["confirm"] as? Bool == true {
                        self.pending = (name, onFinished); self.state = .confirm(match: (j["old_match"] as? Double) ?? 0)
                        return
                    }
                    func num(_ k: String) -> Double? { (j[k] as? Double) ?? (j[k] as? Int).map(Double.init) }
                    self.state = .done(seconds: num("seconds") ?? 0, meetingMatch: num("meeting_match"))
                case .failure(let e): self.state = .failed(e.description)
                }
                onFinished()
            }
        }
    }

    /// The user chose "Save anyway" for a voice that differs from the saved one: the kept sample is enrolled again with --force.
    func saveAnyway() {
        guard case .confirm = state, let p = pending else { return }
        pending = nil; state = .processing
        submit(containerDir.appendingPathComponent("enroll/last.wav"), name: p.name, force: true, id: run, p.onFinished)
    }

    /// The user chose Cancel on the confirmation: the saved voice stays.
    func keepSaved() { pending = nil; state = .idle }

    /// A microphone or format change: the recording is discarded (the previous last.wav stays).
    private func abort(_ tap: EnrollTap, _ message: String, _ detail: String) {
        log("enroll: aborted, \(detail)")
        run += 1
        ticker?.invalidate(); ticker = nil
        audioQ.async { tap.stop(); try? FileManager.default.removeItem(at: tap.url) }
        self.tap = nil; state = .failed(message); level = 0
    }

    /// Harness only: puts a state on screen for the shots.
    func demo(_ s: State) { state = s; level = 0.4 }

    /// Stops a recording in progress (deactivation, or the user backing out) and removes its file.
    func cancel() {
        guard active else { return }
        run += 1
        ticker?.invalidate(); ticker = nil
        if let t = tap { audioQ.async { t.stop(); try? FileManager.default.removeItem(at: t.url) } }
        tap = nil; state = .idle; level = 0
    }
}

/// The input device an engine records from, for the log and for noticing a change mid-recording.
struct InputDevice: Equatable, CustomStringConvertible {
    var id: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    var name = "unknown", uid = "", rate = 0.0, channels = 0
    var description: String { "\"\(name)\" (uid \(uid.isEmpty ? "unknown" : uid), \(Int(rate)) Hz, \(channels) channel\(channels == 1 ? "" : "s"))" }

    private static func string(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var v: CFString = "" as CFString, size = UInt32(MemoryLayout<CFString>.size)
        let err = withUnsafeMutablePointer(to: &v) { AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, UnsafeMutableRawPointer($0)) }
        return err == noErr ? v as String : nil
    }

    /// The device `engine`'s input node is bound to (the system default unless the node says otherwise), with the node's format.
    static func of(_ engine: AVAudioEngine) -> InputDevice {
        var dev = engine.inputNode.auAudioUnit.deviceID
        if dev == kAudioObjectUnknown { dev = CallAudio.defaultInputDevice() }
        let f = engine.inputNode.outputFormat(forBus: 0)
        return InputDevice(id: dev, name: string(dev, kAudioObjectPropertyName) ?? "unknown", uid: string(dev, kAudioDevicePropertyDeviceUID) ?? "",
                           rate: f.sampleRate, channels: Int(f.channelCount))
    }
}

/// A microphone tap writing a WAV (TrackWriter: float32, the input's own rate, usually 48 kHz) plus a live level. A
/// configuration change, a new default input or a buffer in another format than the first marks the recording `changed`.
final class EnrollTap: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var writer: TrackWriter?
    private let lock = NSLock()
    private var _level: Float = 0
    private var _changed: String?
    private var observer: NSObjectProtocol?
    private var defaultListener: AudioObjectPropertyListenerBlock?
    private(set) var url = URL(fileURLWithPath: "/dev/null")
    private(set) var device = InputDevice()

    var level: Float { lock.withLock { _level } }
    /// Why the recording can no longer be trusted (the microphone or its format changed), or nil.
    var changed: String? { lock.withLock { _changed } }

    private func markChanged(_ why: String) { lock.withLock { if _changed == nil { _changed = why } } }

    /// audioQ. After stop(): the default input is no longer the device the recording started on.
    func deviceChangedSinceStart() -> String? {
        let now = CallAudio.defaultInputDevice()
        guard now != kAudioObjectUnknown, device.id != kAudioObjectUnknown, now != device.id else { return nil }
        return "the default input moved from \(device.name) to another device"
    }

    /// audioQ.
    func start(url: URL) throws {
        self.url = url
        let input = engine.inputNode
        // See Recorder.installMicTap: format nil and a check right before, never a format read earlier (NSException).
        let f = input.outputFormat(forBus: 0)
        guard f.sampleRate > 0, f.channelCount > 0 else { throw RecError("no microphone input available") }
        device = InputDevice.of(engine)
        let w = TrackWriter(lazyURL: url); writer = w
        let rate = f.sampleRate, channels = f.channelCount
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buf, when in
            if buf.format.sampleRate != rate || buf.format.channelCount != channels { self?.markChanged("the input format changed to \(buf.format.sampleRate) Hz, \(buf.format.channelCount) channel(s)"); return }
            w.write(buf, host: when.isHostTimeValid ? when.hostTime : 0)
            guard let ch = buf.floatChannelData?[0], buf.frameLength > 0 else { return }
            var sum: Float = 0
            for i in 0..<Int(buf.frameLength) { sum += ch[i] * ch[i] }
            let db = 20 * log10(max((sum / Float(buf.frameLength)).squareRoot(), 1e-7))
            self?.lock.withLock { self?._level = min(max((db + 55) / 45, 0), 1) }  // -55 dB..-10 dB -> 0..1
        }
        try engine.start()
        log("enroll: recording from \(device)")
        // After start, so the engine's own start-up notifications are not mistaken for a change.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.markChanged("the audio configuration changed (device or format)")
        }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.markChanged("the default input device changed") }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, audioQ, block) == noErr { defaultListener = block }
    }

    /// audioQ. Safe after a failed start().
    func stop() {
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
        if let block = defaultListener {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, audioQ, block); defaultListener = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        writer?.close()
    }
}
