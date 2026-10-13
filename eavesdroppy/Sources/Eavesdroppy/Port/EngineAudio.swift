import AVFoundation
import Foundation

/// Ports of `process_meeting.repair_wav`, `prepare_track` and `to_16k_wav`: get a recording into the 16 kHz mono
/// 16-bit WAV the engines take. In-process (AVFoundation), no `afconvert` subprocess.
public enum EngineAudio {
    public struct Track: Equatable {
        public var mono: URL        // mono float file at the recording's rate (`src` itself if it already was mono)
        public var sampleRate: Double
        public var duration: Double
        public var peak: Float      // of the loudest channel
    }

    private static let block: AVAudioFrameCount = 1 << 18   // BLOCK

    /// `repair_wav`. AVAudioFile only finalizes the WAV header on close, so a crashed recording has a data-chunk size
    /// of 0 (or past EOF) and reads as 0 frames though the audio is on disk. Point the sizes at EOF, truncated to
    /// whole frames. Returns true if the file was modified.
    @discardableResult
    public static func repairWav(_ url: URL) throws -> Bool {
        let h = try FileHandle(forUpdating: url)
        defer { try? h.close() }
        let end = try h.seekToEnd()
        try h.seek(toOffset: 0)
        let head = try h.read(upToCount: 12) ?? Data()
        guard head.count == 12, head.prefix(4) == Data("RIFF".utf8), head.suffix(4) == Data("WAVE".utf8) else { return false }
        func u32(_ d: Data) -> UInt32 { d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian }
        func u16(_ d: Data) -> UInt16 { d.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian }
        var pos: UInt64 = 12, blockAlign: UInt64 = 0, dataStart: UInt64 = 0, size: UInt64 = 0, found = false
        while pos + 8 <= end {
            try h.seek(toOffset: pos)
            guard let hdr = try h.read(upToCount: 8), hdr.count == 8 else { break }
            let id = String(decoding: hdr.prefix(4), as: UTF8.self)
            size = UInt64(u32(hdr.suffix(4)))
            if id == "fmt " && size >= 14 {   // same offset for PCM, float and WAVE_FORMAT_EXTENSIBLE
                try h.seek(toOffset: pos + 8 + 12)
                blockAlign = UInt64(u16(try h.read(upToCount: 2) ?? Data(count: 2)))
            } else if id == "data" { dataStart = pos + 8; found = true; break }
            pos += 8 + size + (size & 1)
        }
        guard found, blockAlign != 0, !(size > 0 && size < 0xFFFF_FFFF && dataStart + size <= end) else { return false }
        let n = (end - dataStart) / blockAlign * blockAlign
        try h.truncate(atOffset: dataStart + n)
        // shortcut: sizes cap at 4 GiB (~3 h of 48 kHz stereo float), as in the Python; RF64 if recordings get that long
        func le(_ v: UInt64) -> Data { var x = UInt32(min(v, 0xFFFF_FFFF)).littleEndian; return Data(bytes: &x, count: 4) }
        try h.seek(toOffset: 4); try h.write(contentsOf: le(dataStart + n - 8))
        try h.seek(toOffset: dataStart - 4); try h.write(contentsOf: le(n))
        return true
    }

    /// `prepare_track`: repair `src` if crash-truncated, then stream it once to find the loudest channel and its peak.
    /// A multi-channel `src` is written to `tmp/<key>-mono.wav` (loudest channel, not the mean: a quiet or silent
    /// channel would dilute it).
    public static func prepareTrack(key: String, src: URL, tmp: URL) throws -> Track {
        if src.pathExtension.lowercased() == "wav" { try repairWav(src) }
        let file = try AVAudioFile(forReading: src)
        let fmt = file.processingFormat, ch = Int(fmt.channelCount)
        guard file.length > 0 else { throw EngineError.failed("\(src.lastPathComponent) has no audio") }
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: block) else { throw EngineError.failed("out of memory") }
        var sumsq = [Double](repeating: 0, count: ch), peaks = [Float](repeating: 0, count: ch)
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buf, frameCount: block)
            if buf.frameLength == 0 { break }
            for c in 0..<ch {
                let p = buf.floatChannelData![c]
                var s = 0.0, m: Float = 0
                for i in 0..<Int(buf.frameLength) { let v = p[i]; s += Double(v) * Double(v); m = max(m, abs(v)) }
                sumsq[c] += s; peaks[c] = max(peaks[c], m)
            }
        }
        let best = sumsq.indices.max { sumsq[$0] < sumsq[$1] } ?? 0
        var mono = src
        if ch > 1 {
            mono = tmp.appendingPathComponent("\(key)-mono.wav")
            let out = try AVAudioFile(forWriting: mono, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: fmt.sampleRate, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            ])
            let monoFmt = out.processingFormat
            guard let o = AVAudioPCMBuffer(pcmFormat: monoFmt, frameCapacity: block) else { throw EngineError.failed("out of memory") }
            file.framePosition = 0
            while file.framePosition < file.length {
                try Task.checkCancellation()
                try file.read(into: buf, frameCount: block)
                if buf.frameLength == 0 { break }
                o.frameLength = buf.frameLength
                o.floatChannelData![0].update(from: buf.floatChannelData![best], count: Int(buf.frameLength))
                try out.write(from: o)
            }
        }
        return Track(mono: mono, sampleRate: fmt.sampleRate, duration: Double(file.length) / fmt.sampleRate, peak: peaks[best])
    }

    /// `to_16k_wav`: any audio file to 16 kHz mono 16-bit PCM WAV (`afconvert -f WAVE -d LEI16@16000`).
    public static func to16kWav(_ src: URL, _ dst: URL) throws {
        let file = try AVAudioFile(forReading: src)
        let inFmt = file.processingFormat
        guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: inFmt, to: outFmt) else { throw EngineError.failed("cannot convert \(src.lastPathComponent) to 16 kHz") }
        conv.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        let out = try AVAudioFile(forWriting: dst, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ])
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: block),
              let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: AVAudioFrameCount(Double(block) * 16_000 / inFmt.sampleRate) + 4096)
        else { throw EngineError.failed("out of memory") }
        var done = false
        while !done {
            try Task.checkCancellation()
            var err: NSError?
            let status = conv.convert(to: outBuf, error: &err) { _, outStatus in
                if file.framePosition >= file.length { outStatus.pointee = .endOfStream; return nil }
                do { try file.read(into: inBuf, frameCount: block) } catch { outStatus.pointee = .endOfStream; return nil }
                if inBuf.frameLength == 0 { outStatus.pointee = .endOfStream; return nil }
                outStatus.pointee = .haveData
                return inBuf
            }
            if status == .error { throw EngineError.failed("audio conversion failed: \(err?.localizedDescription ?? "unknown")") }
            if outBuf.frameLength > 0 { try out.write(from: outBuf) }
            if status == .endOfStream { done = true }
        }
    }
}
