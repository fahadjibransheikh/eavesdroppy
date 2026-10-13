#if EAVESDROPPY_PERSONAL
import AVFoundation
import Foundation

/// `echo._localvqe`, step for step: write the mic chunk and the aligned reference as float WAVs, run the standalone
/// LocalVQE binary (`tools/build_localvqe.sh`, not FluidAudio's `enhance`, which ships a different model), read its
/// output, trim the model's latency, pad/trim to the input length. The binary is a subprocess, so this is the
/// personal build only (D27 decides what the Store build gets).
public struct LocalVQEProcess: EchoRemover {
    public static let sampleRate: Double = 16_000   // echo.SR
    public static let latency = 256                 // samples (16 ms): the model's output lags its input by one hop
    public static let timeout: TimeInterval = 900   // LOCALVQE_TIMEOUT, per call

    public var binary: URL
    public var model: URL

    public init(root: String? = nil) {
        let root = root ?? projectDir
        binary = URL(fileURLWithPath: root + "/.build-tools/localvqe/ggml/build/localvqe")
        model = URL(fileURLWithPath: root + "/.build-tools/models/localvqe-v1.4-aec-200K-f32.gguf")
    }

    public init(binary: URL, model: URL) { self.binary = binary; self.model = model }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: binary.path) && FileManager.default.fileExists(atPath: model.path)
    }

    public func clean(mic: [Float], reference ref: [Float]) throws -> [Float] {
        guard isInstalled else { throw EngineError.modelMissing("LocalVQE not built: run tools/build_localvqe.sh") }
        let n = mic.count
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lvqe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = dir.appendingPathComponent("m.wav"), r = dir.appendingPathComponent("r.wav"), o = dir.appendingPathComponent("o.wav")
        try Self.writeFloatWav(mic, to: m)
        try Self.writeFloatWav(ref, to: r)

        let log = dir.appendingPathComponent("log.txt")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)
        let p = Process()
        p.executableURL = binary
        p.arguments = [model.path, "--in-wav", m.path, r.path, "--out-wav", o.path]
        p.standardOutput = logHandle; p.standardError = logHandle
        try p.run()
        let deadline = Date().addingTimeInterval(Self.timeout)
        while p.isRunning {
            if Task.isCancelled { p.terminate(); p.waitUntilExit(); throw CancellationError() }
            if Date() > deadline { p.terminate(); p.waitUntilExit(); throw EngineError.failed("localvqe timed out after \(Int(Self.timeout)) s") }
            Thread.sleep(forTimeInterval: 0.05)
        }
        try? logHandle.close()
        guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: o.path) else {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            throw EngineError.failed("localvqe failed: " + String(text.suffix(600)))
        }
        let out = try Self.readFloatWav(o)
        var cleaned = Array(out.dropFirst(Self.latency))
        if cleaned.count < n { cleaned += [Float](repeating: 0, count: n - cleaned.count) }
        return Array(cleaned.prefix(n))
    }

    /// Mono 32-bit float WAV in libsndfile's layout (fmt, fact, data). Not AVAudioFile: it pads the header with JUNK/FLLR
    /// chunks (data at byte 4096), and LocalVQE's reader then reads the wrong samples.
    static func writeFloatWav(_ x: [Float], to url: URL) throws {
        guard !x.isEmpty else { throw EngineError.failed("empty audio chunk") }
        func u32(_ v: Int) -> Data { var n = UInt32(v).littleEndian; return Data(bytes: &n, count: 4) }
        func u16(_ v: Int) -> Data { var n = UInt16(v).littleEndian; return Data(bytes: &n, count: 2) }
        let bytes = x.count * 4
        var d = Data("RIFF".utf8) + u32(4 + 24 + 12 + 8 + bytes) + Data("WAVE".utf8)
        d += Data("fmt ".utf8) + u32(16) + u16(3) + u16(1) + u32(Int(sampleRate)) + u32(Int(sampleRate) * 4) + u16(4) + u16(32)
        d += Data("fact".utf8) + u32(4) + u32(x.count)
        d += Data("data".utf8) + u32(bytes)
        d += x.withUnsafeBytes { Data($0) }   // little-endian host
        try d.write(to: url)
    }

    /// Mono WAV reader that walks the chunks (JUNK/PEAK/fact are skipped). 16-bit PCM, which is what the binary writes,
    /// scales by 1/32768 like `soundfile.read(dtype="float32")`; 32-bit float is read as is.
    static func readFloatWav(_ url: URL) throws -> [Float] {
        let d = try Data(contentsOf: url)
        func u32(_ at: Int) -> Int { Int(d.subdata(in: at..<at + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian) }
        func u16(_ at: Int) -> Int { Int(d.subdata(in: at..<at + 2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian) }
        guard d.count >= 12, d.prefix(4) == Data("RIFF".utf8), d[8..<12] == Data("WAVE".utf8) else { throw EngineError.failed("not a WAV file") }
        var pos = 12, bits = 0, channels = 0
        while pos + 8 <= d.count {
            let id = String(decoding: d[pos..<pos + 4], as: UTF8.self), size = u32(pos + 4), body = pos + 8
            if id == "fmt " { channels = u16(body + 2); bits = u16(body + 14) }
            if id == "data" {
                guard channels == 1, bits == 16 || bits == 32 else { throw EngineError.failed("localvqe output is not mono 16-bit or float32 (\(channels) ch, \(bits) bit)") }
                let n = min(size, d.count - body) / (bits / 8)
                let raw = d.subdata(in: body..<body + n * (bits / 8))
                if bits == 32 { return raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } }
                return raw.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)).map { Float(Int16(littleEndian: $0)) / 32768 } }
            }
            pos = body + size + (size & 1)
        }
        throw EngineError.failed("WAV file has no data chunk")
    }
}
#endif
