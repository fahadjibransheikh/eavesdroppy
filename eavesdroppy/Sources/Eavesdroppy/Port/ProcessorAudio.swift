import Accelerate
import AVFoundation
import Foundation

/// The audio file work of process_meeting.py that is not an engine stage: keep_raw, mix_to_m4a and the odd-rate resample,
/// in-process (AVFoundation) instead of soundfile + afconvert, so the Store build needs no subprocess.
enum ProcessorAudio {
    static let block: AVAudioFrameCount = 1 << 18   // BLOCK

    /// Mono 32-bit float WAV at `rate`.
    static func writeMonoFloat(_ x: [Float], rate: Double, to url: URL) throws {
        let out = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                                                              AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false])
        var i = 0
        while i < x.count {
            let n = min(Int(block), x.count - i)
            guard let b = AVAudioPCMBuffer(pcmFormat: out.processingFormat, frameCapacity: AVAudioFrameCount(n)) else { throw EngineError.failed("out of memory") }
            b.frameLength = AVAudioFrameCount(n)
            x.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress! + i, count: n) }
            try out.write(from: b)
            i += n
        }
    }

    /// The first `seconds` of voiced audio of a 16 kHz mono file, as a 16-bit WAV: the 0.5 s windows louder than a tenth of the
    /// track's 90th-percentile level, joined in order (a call's mic track is mostly the other side's silence). Returns the
    /// excerpt's length in seconds; 0 when nothing is voiced, and then no file is written.
    // shortcut: a level gate, not a voice detector; a track that is all steady noise yields noise, which transcribes to few words
    static func speechExcerpt(_ src: URL, to dst: URL, seconds: Double) throws -> Double {
        let win = 8000   // 0.5 s at 16 kHz
        let f = try AVAudioFile(forReading: src)
        guard let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(win)) else { throw EngineError.failed("out of memory") }
        var level: [Float] = []
        while f.framePosition < f.length {
            try Task.checkCancellation()
            try f.read(into: buf, frameCount: AVAudioFrameCount(win))
            let n = Int(buf.frameLength)
            if n == 0 { break }
            level.append(vDSP.rootMeanSquare(UnsafeBufferPointer(start: buf.floatChannelData![0], count: n)))
        }
        guard !level.isEmpty else { return 0 }
        let gate = max(5e-4, level.sorted()[Int(Double(level.count - 1) * 0.9)] * 0.1)
        let voiced = level.indices.filter { level[$0] > gate }.prefix(Int((seconds * 2).rounded(.up)))
        var out: [Float] = []
        for w in voiced {
            f.framePosition = AVAudioFramePosition(w * win)
            try f.read(into: buf, frameCount: AVAudioFrameCount(win))
            out += UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength))
        }
        guard !out.isEmpty else { return 0 }
        try writeMono16(out, rate: 16_000, to: dst)
        return Double(out.count) / 16_000
    }

    /// Mono 16-bit PCM WAV as soundfile writes it from floats: x * 32767, rounded, clipped.
    static func writeMono16(_ x: [Float], rate: Int, to url: URL) throws {
        func u32(_ v: Int) -> Data { var n = UInt32(v).littleEndian; return Data(bytes: &n, count: 4) }
        func u16(_ v: Int) -> Data { var n = UInt16(v).littleEndian; return Data(bytes: &n, count: 2) }
        var d = Data()
        for part in [Data("RIFF".utf8), u32(36 + x.count * 2), Data("WAVE".utf8), Data("fmt ".utf8), u32(16), u16(1), u16(1), u32(rate), u32(rate * 2), u16(2), u16(16),
                     Data("data".utf8), u32(x.count * 2)] { d.append(part) }
        let pcm: [Int16] = x.map { Int16(max(-32768, min(32767, ($0 * 32767).rounded(.toNearestOrEven)))).littleEndian }
        pcm.withUnsafeBytes { d.append(contentsOf: $0) }
        try d.write(to: url)
    }

    /// `afconvert -f WAVE -d LEF32@rate` for a mono source: streamed through AVAudioConverter.
    static func resampleMono(_ src: URL, to dst: URL, rate: Double) throws {
        let file = try AVAudioFile(forReading: src)
        let inFmt = file.processingFormat
        guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: inFmt, to: outFmt) else { throw EngineError.failed("cannot resample \(src.lastPathComponent)") }
        conv.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        let out = try AVAudioFile(forWriting: dst, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                                                              AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false])
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: block),
              let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: AVAudioFrameCount(Double(block) * rate / inFmt.sampleRate) + 4096)
        else { throw EngineError.failed("out of memory") }
        var done = false
        while !done {
            try Task.checkCancellation()
            var err: NSError?
            let status = conv.convert(to: outBuf, error: &err) { _, st in
                if file.framePosition >= file.length { st.pointee = .endOfStream; return nil }
                do { try file.read(into: inBuf, frameCount: block) } catch { st.pointee = .endOfStream; return nil }
                if inBuf.frameLength == 0 { st.pointee = .endOfStream; return nil }
                st.pointee = .haveData
                return inBuf
            }
            if status == .error { throw EngineError.failed("audio conversion failed: \(err?.localizedDescription ?? "unknown")") }
            if outBuf.frameLength > 0 { try out.write(from: outBuf) }
            if status == .endOfStream { done = true }
        }
    }

    /// `mix_to_m4a`. tracks: (key, mono file), in dict order; offsets in seconds per key. Streams the mix twice (peak pass, then
    /// write pass) so long meetings stay small; a peak above 0.95 is scaled down to it. The first track's rate is the mix rate.
    static func mixToM4A(tracks: [(key: String, url: URL)], offsets: [String: Double], dst: URL, tmp: URL) throws {
        guard !tracks.isEmpty else { throw EngineError.failed("nothing to mix") }
        let sr = try AVAudioFile(forReading: tracks[0].url).processingFormat.sampleRate
        var parts: [(file: AVAudioFile, off: Int)] = []
        for (key, url) in tracks {
            var u = url
            if try AVAudioFile(forReading: u).processingFormat.sampleRate != sr {  // resample the odd one out to the first track's rate
                let rs = tmp.appendingPathComponent("\(key)-rs.wav")
                try resampleMono(u, to: rs, rate: sr)
                u = rs
            }
            parts.append((try AVAudioFile(forReading: u), Int(((offsets[key] ?? 0.0) * sr).rounded(.toNearestOrEven))))
        }
        let n = parts.map { $0.off + Int($0.file.length) }.max() ?? 0
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 1, interleaved: false)!
        guard let rd = AVAudioPCMBuffer(pcmFormat: parts[0].file.processingFormat, frameCapacity: block) else { throw EngineError.failed("out of memory") }
        var mixed = [Float]()
        func blocks(_ body: ([Float]) throws -> Void) throws {
            var i = 0
            while i < n {
                try Task.checkCancellation()
                let len = min(Int(block), n - i)
                mixed = [Float](repeating: 0, count: len)
                for (f, o) in parts {
                    let lo = max(i - o, 0), hi = min(i + len - o, Int(f.length))
                    guard hi > lo else { continue }
                    f.framePosition = AVAudioFramePosition(lo)
                    try f.read(into: rd, frameCount: AVAudioFrameCount(hi - lo))
                    let got = Int(rd.frameLength), dstOff = lo + o - i
                    let p = rd.floatChannelData![0]
                    for k in 0..<got { mixed[dstOff + k] += p[k] }
                }
                try body(mixed)
                i += len
            }
        }
        var peak: Float = 0
        try blocks { for v in $0 { peak = max(peak, abs(v)) } }
        let scale: Float = peak > 0.95 ? 0.95 / peak : 1.0
        let out = try AVAudioFile(forWriting: dst, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sr, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000])
        try blocks { b in
            guard let wb = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(b.count)) else { return }
            wb.frameLength = AVAudioFrameCount(b.count)
            for k in 0..<b.count { wb.floatChannelData![0][k] = b[k] * scale }
            try out.write(from: wb)
        }
    }

    /// `keep_raw`: archive the raw tracks as 24-bit FLAC beside the sessions dir (<container>/raw/<session>/), plus meta.json,
    /// since the recorder deletes the session dir once processing succeeds. A track that cannot be encoded is copied as is.
    /// `extraMeta` is merged into the archive's copy of meta.json (the engine and language the meeting was transcribed with);
    /// the session's own meta.json is left as it was.
    static func keepRaw(session: URL, files: [(key: String, url: URL)], extraMeta: [String: Any] = [:], log: (String) -> Void = { _ in }) throws -> URL {
        let fm = FileManager.default
        let dst = session.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("raw").appendingPathComponent(session.lastPathComponent)
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        for (key, url) in files {
            let out = dst.appendingPathComponent("\(key).flac")
            do {
                let f = try AVAudioFile(forReading: url)
                let fmt = f.processingFormat
                let w = try AVAudioFile(forWriting: out, settings: [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: fmt.sampleRate,
                                                                    AVNumberOfChannelsKey: Int(fmt.channelCount), AVLinearPCMBitDepthKey: 24])
                guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: block) else { throw EngineError.failed("out of memory") }
                while f.framePosition < f.length {
                    try Task.checkCancellation()
                    try f.read(into: buf, frameCount: block)
                    if buf.frameLength == 0 { break }
                    try w.write(from: buf)
                }
            } catch is CancellationError {
                try? fm.removeItem(at: out); throw CancellationError()
            } catch {
                log("FLAC archive of \(key) failed (\(error.localizedDescription)); kept the original file instead")
                try? fm.removeItem(at: out)
                let copy = dst.appendingPathComponent(url.lastPathComponent)
                try? fm.removeItem(at: copy)
                try fm.copyItem(at: url, to: copy)
            }
        }
        let meta = dst.appendingPathComponent("meta.json")
        try? fm.removeItem(at: meta)
        try fm.copyItem(at: session.appendingPathComponent("meta.json"), to: meta)
        if !extraMeta.isEmpty {
            var m = (try JSONSerialization.jsonObject(with: Data(contentsOf: meta)) as? [String: Any]) ?? [:]
            for (k, v) in extraMeta { m[k] = v }
            try JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys]).write(to: meta, options: .atomic)
        }
        return dst
    }
}
