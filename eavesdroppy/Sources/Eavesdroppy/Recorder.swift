import AVFoundation
import CoreAudio

struct RecError: Error, CustomStringConvertible { let description: String; init(_ d: String) { description = d } }

/// Every Recorder call (start, stop, device restarts) runs on this serial queue, never on Droppy's main thread:
/// Core Audio can block for seconds (AirPods switching to HFP, a wedged HAL).
let audioQ = DispatchQueue(label: "eavesdroppy.audio", qos: .userInitiated)

/// Thread-safe WAV writer. Records host time of the first buffer (for track_offsets) and peak level.
/// Buffers in a different format than the file (the mic changing sample rate mid-call) are converted.
final class TrackWriter {
    let url: URL
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var converterSource: AVAudioFormat?
    private var _firstHost: UInt64 = 0
    private var _peak: Float = 0
    private var _frames: Int64 = 0
    private var _signalSeconds = 0.0
    private var failed = false
    private var warnedDrop = false
    private let isLazy: Bool
    private var closed = false
    /// Any thread. A write error (disk full) is reported once and the writer goes quiet.
    var onError: ((String) -> Void)?
    /// Any thread. Called once if buffers had to be dropped.
    var onWarning: ((String) -> Void)?

    var firstHost: UInt64 { lock.withLock { _firstHost } }
    var peak: Float { lock.withLock { _peak } }
    var frames: Int64 { lock.withLock { _frames } }
    /// Seconds of audio in buffers that peaked at `signalLevel` or more: -60 dBFS, well above a tap's dither and any quiet room tone.
    var signalSeconds: Double { lock.withLock { _signalSeconds } }
    static let signalLevel: Float = 1e-3

    init(url: URL, format: AVAudioFormat) throws {
        self.url = url; isLazy = false
        file = try Self.open(url, format)
    }

    /// For AVAudioEngine taps: the file is opened from the first buffer's own format, so a device change between
    /// reading the node's format and the first buffer can never leave the writer with a stale one.
    init(lazyURL url: URL) { self.url = url; isLazy = true }

    private static func open(_ url: URL, _ format: AVAudioFormat) throws -> AVAudioFile {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
                                       AVNumberOfChannelsKey: format.channelCount, AVLinearPCMBitDepthKey: 32,
                                       AVLinearPCMIsFloatKey: true]
        return try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: format.isInterleaved)
    }

    func write(_ input: AVAudioPCMBuffer, host: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard !failed, !closed else { return }
        if file == nil, isLazy {
            do { file = try Self.open(url, input.format) } catch {
                failed = true
                log("ERROR opening \(url.lastPathComponent): \(error)")
                onError?("could not write \(url.lastPathComponent): \(error.localizedDescription)")
                return
            }
        }
        guard let file else { return }
        guard let buf = matching(input, file.processingFormat) else {
            logLimited("drop-\(url.lastPathComponent)", "WARNING \(url.lastPathComponent): dropping a \(input.format) buffer (cannot convert)")
            if !warnedDrop { warnedDrop = true; onWarning?("Some audio could not be recorded (\(url.deletingPathExtension().lastPathComponent))") }
            return
        }
        if _firstHost == 0 { _firstHost = host != 0 ? host : mach_absolute_time() }
        var bufPeak: Float = 0
        if let ch = buf.floatChannelData {
            let n = Int(buf.frameLength), s = buf.stride
            for c in 0..<Int(buf.format.channelCount) { for i in 0..<n { bufPeak = max(bufPeak, abs(ch[c][i * s])) } }
            _peak = max(_peak, bufPeak)
        }
        do {
            try file.write(from: buf); _frames += Int64(buf.frameLength)
            if bufPeak >= Self.signalLevel, buf.format.sampleRate > 0 { _signalSeconds += Double(buf.frameLength) / buf.format.sampleRate }
        } catch {
            failed = true
            log("ERROR writing \(url.lastPathComponent): \(error)")
            onError?("could not write \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// `buf` itself if it already has the file's format, else a converted copy (nil if conversion fails). Lock held.
    private func matching(_ buf: AVAudioPCMBuffer, _ fmt: AVAudioFormat) -> AVAudioPCMBuffer? {
        let src = buf.format
        if src.sampleRate == fmt.sampleRate, src.channelCount == fmt.channelCount, src.commonFormat == fmt.commonFormat, src.isInterleaved == fmt.isInterleaved { return buf }
        guard src.sampleRate > 0, fmt.sampleRate > 0 else { return nil }  // the frame-capacity ratio below must be finite
        if converterSource != src { converter = AVAudioConverter(from: src, to: fmt); converterSource = src }
        guard let converter,
              let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(Double(buf.frameLength) * fmt.sampleRate / src.sampleRate) + 64) else { return nil }
        var fed = false
        var err: NSError?
        let status = converter.convert(to: out, error: &err) { _, st in
            if fed { st.pointee = .noDataNow; return nil }
            fed = true; st.pointee = .haveData; return buf
        }
        return status == .error ? nil : out
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        // No buffer ever arrived: leave an empty wav (as an eagerly opened file would be) so the session still has a mic.wav.
        if isLazy, file == nil, !failed, !closed { _ = try? AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1).flatMap { try Self.open(url, $0) } }
        file = nil; closed = true
    }
}

private func hostSeconds(_ h: UInt64) -> Double { AVAudioTime.seconds(forHostTime: h) }

// MARK: Core Audio helpers (property reads, adapted from AudioCap's CoreAudioUtils)

private func getProp<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, initial: T, qualifier: UnsafeRawPointer? = nil, qualifierSize: UInt32 = 0) throws -> T {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    let err = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(obj, &addr, qualifierSize, qualifier, &size, UnsafeMutableRawPointer($0)) }
    guard err == noErr else { throw RecError("AudioObjectGetPropertyData(\(String(sel, radix: 16))) failed: OSStatus \(err)") }
    return value
}

struct RecResult {
    var offsets: [String: Double]
    /// The call-audio track was captured but empty or all zeros: almost always a missing permission.
    var systemSilent: Bool
    /// Seconds of real signal on the call-audio track (0 when there is none). A silent room never reaches it; a call does.
    var systemSignalSeconds: Double
}

/// Confined to audioQ (the few cross-thread reads go through TrackWriter's lock), hence @unchecked.
final class Recorder: @unchecked Sendable {
    let dir: URL
    private(set) var startHost: UInt64 = 0
    private(set) var mic: TrackWriter?
    private(set) var system: TrackWriter?
    /// Non-nil if call audio could not be captured (mic-only recording).
    private(set) var systemWarning: String?
    /// Any thread; set before start(). A non-fatal problem the user should see (device change, dropped buffers).
    var onWarning: ((String) -> Void)?
    /// Any thread; set before start(). A track can no longer be written (disk full): the droplet stops the recording.
    var onFatal: ((String) -> Void)?

    private let engine = AVAudioEngine()  // no voice processing: it ducks other apps' audio
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "system-tap-io", qos: .userInitiated)
    private var ioDropped = 0  // ioQueue only
    // audioQ only:
    private var running = false
    private var observer: NSObjectProtocol?
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var micRestartPending = false, tapRestartPending = false
    private var restarts = 0  // capped so a device flapping (or a restart that re-triggers itself) can't loop forever

    init(dir: URL) { self.dir = dir }

    private func wire(_ w: TrackWriter) {
        w.onError = { [weak self] in self?.onFatal?($0) }
        w.onWarning = { [weak self] in self?.onWarning?($0) }
    }

    /// audioQ.
    func start() throws {
        startHost = mach_absolute_time()
        let input = engine.inputNode
        let w = TrackWriter(lazyURL: dir.appendingPathComponent("mic.wav"))
        wire(w); mic = w
        guard installMicTap() else { throw RecError("no microphone input available") }
        do { try engine.start() } catch { input.removeTap(onBus: 0); throw error }
        running = true
        log("mic started: \(input.outputFormat(forBus: 0))")

        // Droppy's loader builds for macOS 14.0; process taps need 14.2+ (the host runs 26).
        do {
            guard #available(macOS 14.4, *) else { throw RecError("process taps need macOS 14.4") }
            try startTap()
        } catch {
            systemWarning = "\(error)"
            log("WARNING system audio unavailable, mic only: \(error)")
            teardownTap()
            system?.close(); system = nil
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("system.wav"))
        }
        watchDevices()
    }

    /// installTap raises an uncatchable NSException (it would take Droppy down) when the format it is given disagrees
    /// with the node, or the node has no valid format (input device gone). So: never pass a format we read earlier
    /// (nil means "the node's own, now"), and check the node is usable immediately before. False if there is no input.
    private func installMicTap() -> Bool {
        guard let w = mic else { return false }
        let input = engine.inputNode
        let f = input.outputFormat(forBus: 0)
        guard f.sampleRate > 0, f.channelCount > 0 else { return false }
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { buf, when in
            w.write(buf, host: when.isHostTimeValid ? when.hostTime : 0)
        }
        return true
    }

    // MARK: device changes

    /// The engine stops itself when the input device or its format changes (AirPods connecting, unplugging a USB mic);
    /// the system default devices changing means the same. Restart what is affected, and tell the user.
    private func watchDevices() {
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            audioQ.async { self?.scheduleMicRestart("audio configuration changed") }
        }
        listen(kAudioHardwarePropertyDefaultInputDevice) { [weak self] in self?.scheduleMicRestart("default input changed") }
        listen(kAudioHardwarePropertyDefaultSystemOutputDevice) { [weak self] in self?.scheduleTapRestart("default output changed") }
    }

    private func listen(_ sel: AudioObjectPropertySelector, _ handler: @escaping () -> Void) {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, audioQ, block) == noErr { listeners.append((addr, block)) }
    }

    private func unwatchDevices() {
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
        for (var addr, block) in listeners { AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, audioQ, block) }
        listeners = []
    }

    // Debounced: a Bluetooth switch fires several notifications within a moment.
    private func scheduleMicRestart(_ why: String) {
        guard running, !micRestartPending, restarts < 20 else { return }
        micRestartPending = true; restarts += 1
        audioQ.asyncAfter(deadline: .now() + 0.4) { [self] in micRestartPending = false; restartMic(why) }
    }

    private func scheduleTapRestart(_ why: String) {
        guard running, system != nil, !tapRestartPending, restarts < 20 else { return }
        tapRestartPending = true; restarts += 1
        audioQ.asyncAfter(deadline: .now() + 0.4) { [self] in tapRestartPending = false; restartTap(why) }
    }

    private func restartMic(_ why: String) {
        guard running else { return }
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        engine.stop()
        guard installMicTap() else {  // the input device is gone: the next device change retries
            log("ERROR mic restart skipped (\(why)): no input device")
            onWarning?("Microphone stopped (\(why)): no input device")
            return
        }
        do {
            try engine.start()
            log("mic restarted (\(why)): \(input.outputFormat(forBus: 0))")
            onWarning?("Microphone changed (\(why)): recording continued, check the notes for a gap")
        } catch {
            log("ERROR mic restart failed (\(why)): \(error)")
            onWarning?("Microphone stopped (\(why)): \(error.localizedDescription)")
        }
    }

    private func restartTap(_ why: String) {
        guard running, #available(macOS 14.4, *) else { return }
        teardownTap()
        do {
            try startTap()
            log("system tap restarted (\(why))")
            onWarning?("Output device changed: call audio restarted, check the notes for a gap")
        } catch {
            teardownTap()
            log("ERROR system tap restart failed (\(why)): \(error)")
            onWarning?("Call audio stopped (\(why)): \(error.localizedDescription)")
        }
    }

    @available(macOS 14.4, *)
    private func startTap() throws {
        var pid = getpid()
        // Exclude our own process so we never record ourselves. Unknown (0) if we have no audio objects yet.
        let me = try getProp(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyTranslatePIDToProcessObject,
                             initial: AudioObjectID(kAudioObjectUnknown), qualifier: &pid, qualifierSize: UInt32(MemoryLayout<pid_t>.size))
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: me != kAudioObjectUnknown ? [me] : [])
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted
        desc.isPrivate = true
        var err = AudioHardwareCreateProcessTap(desc, &tapID)
        guard err == noErr else { throw RecError("AudioHardwareCreateProcessTap failed: OSStatus \(err)") }

        let outDev = try getProp(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, initial: AudioObjectID(kAudioObjectUnknown))
        let outUID = try getProp(outDev, kAudioDevicePropertyDeviceUID, initial: "" as CFString) as String
        var asbd = try getProp(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
        guard let fmt = AVAudioFormat(streamDescription: &asbd) else { throw RecError("bad tap format") }

        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "EavesdroppyTap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        err = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
        guard err == noErr else { throw RecError("AudioHardwareCreateAggregateDevice failed: OSStatus \(err)") }

        let w: TrackWriter  // a restart keeps appending to the same file (the writer converts if the format changed)
        if let existing = system { w = existing } else { w = try TrackWriter(url: dir.appendingPathComponent("system.wav"), format: fmt); wire(w); system = w }
        // v1: write directly in the IO callback (as AudioCap does).
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, ioQueue) { [weak self] _, inData, inTime, _, _ in
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: inData, deallocator: nil) else {
                guard let self else { return }
                self.ioDropped += 1
                logLimited("io-nobuf", "WARNING system IO buffer unreadable (\(self.ioDropped) so far)")
                if self.ioDropped == 1 { self.onWarning?("Some call audio could not be read") }
                return
            }
            w.write(buf, host: inTime.pointee.mHostTime)
        }
        guard err == noErr else { throw RecError("AudioDeviceCreateIOProcIDWithBlock failed: OSStatus \(err)") }
        err = AudioDeviceStart(aggID, procID)
        guard err == noErr else { throw RecError("AudioDeviceStart failed: OSStatus \(err)") }
        log("system tap started: \(fmt) out=\(outUID) excluded-self=\(me != kAudioObjectUnknown)")
    }

    private func teardownTap() {
        if aggID != kAudioObjectUnknown {
            AudioDeviceStop(aggID, procID)
            if let p = procID { AudioDeviceDestroyIOProcID(aggID, p); procID = nil }
            AudioHardwareDestroyAggregateDevice(aggID); aggID = AudioObjectID(kAudioObjectUnknown)
        }
        if #available(macOS 14.4, *), tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = AudioObjectID(kAudioObjectUnknown) }
    }

    /// audioQ. Stops everything, closes files, returns track offsets (seconds after session start of each track's first buffer).
    /// Safe to call after a failed start().
    func stop() -> RecResult {
        running = false
        unwatchDevices()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        teardownTap()
        mic?.close(); system?.close()
        var offsets: [String: Double] = [:]
        var silent = false, signal = 0.0
        for (name, w) in [("mic", mic), ("system", system)] {
            guard let w else { continue }
            if name == "system" && w.frames == 0 {  // never got a buffer: omit the track rather than hand over an empty wav
                log("WARNING system track received no audio; omitting system.wav")
                try? FileManager.default.removeItem(at: w.url); system = nil; silent = true; continue
            }
            if name == "system" { signal = w.signalSeconds }
            let off = w.firstHost == 0 ? 0 : max(0, hostSeconds(w.firstHost) - hostSeconds(startHost))
            offsets[name] = off
            log("stopped \(name): offset=\(String(format: "%.3f", off))s frames=\(w.frames) peak=\(String(format: "%.4f", w.peak))")
            if w.frames == 0 || w.peak == 0 {
                log("WARNING \(name) track is empty/silent (permission denied or nothing playing?)")
                if name == "system" { silent = true }
            }
        }
        return RecResult(offsets: offsets, systemSilent: silent, systemSignalSeconds: signal)
    }
}
