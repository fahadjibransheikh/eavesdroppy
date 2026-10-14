import Foundation

// Engine seam (research/swift-port-plan.md, D21/D22/D27). The pipeline talks to these protocols only; the
// FluidAudio and LocalVQE implementations are compiled in by the personal build (EAVESDROPPY_PERSONAL=1). A Store
// build gets the stubs at the bottom, which throw `EngineError.unavailable`. Apple's SpeechTranscriber (EngineApple.swift)
// is a system framework and is in both builds; the Store build's only speech engine.

/// One recognised word. Same shape as the dicts `process_meeting.transcribe` returns.
public struct EngineWord: Equatable, Sendable, Codable {
    public var text: String
    public var start: Double
    public var end: Double
    public init(text: String, start: Double, end: Double) { self.text = text; self.start = start; self.end = end }
}

public struct EngineTranscript: Equatable, Sendable {
    public var words: [EngineWord]
    public var durationSeconds: Double
    public init(words: [EngineWord], durationSeconds: Double) { self.words = words; self.durationSeconds = durationSeconds }
}

/// One diarization segment; `cluster` is FluidAudio's speaker id ("S1"...). Mirrors `speakers.diarize` tuples.
public struct EngineSegment: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var cluster: String
    public init(start: Double, end: Double, cluster: String) { self.start = start; self.end = end; self.cluster = cluster }
}

/// Mirrors `speakers.diarize`: segments sorted by (start, end, cluster) and one unit-norm 256-d embedding per cluster.
public struct EngineDiarization: Equatable, Sendable {
    public var segments: [EngineSegment]
    public var embeddings: [String: [Float]]
    public static let empty = EngineDiarization(segments: [], embeddings: [:])
    public init(segments: [EngineSegment], embeddings: [String: [Float]]) { self.segments = segments; self.embeddings = embeddings }
}

public enum EngineError: Error, LocalizedError, Equatable {
    case unavailable
    case modelMissing(String)
    case failed(String)
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "Transcription is unavailable in this build."
        case .modelMissing(let m): return "Speech model not found: \(m)"
        case .failed(let m): return m
        }
    }
}

/// Speech to words. `audio` is any file AVFoundation reads; the pipeline passes the 16 kHz mono 16-bit WAV.
/// `hotwords` are vocab lines (`term` or `term: alias, alias`, see `EngineVocab.buildHotwords`); `names` are the
/// hotwords that are attendee names, which get the stricter match (`EngineVocab.nameSimilarity`).
/// Cancellation is checked between stages only: one CoreML pass over a track cannot be interrupted.
public protocol Transcriber: Sendable {
    func transcribe(_ audio: URL, hotwords: [String], names: Set<String>) async throws -> EngineTranscript
    /// Free the models. The pipeline calls this after each meeting (Parakeet is ~460 MB inside Droppy's process).
    func unload() async
}

/// Who spoke when, plus one voiceprint per cluster.
public protocol Diarizer: Sendable {
    func diarize(_ audio: URL) async throws -> EngineDiarization
    func unload() async
}

/// One aligned, equal-length chunk through the echo canceller: `mic` and `reference` are 16 kHz mono floats.
/// Returns the cleaned mic, same length, latency already trimmed (`echo._localvqe`). Chunking, lag estimation and
/// the self-check live with the pure logic (Echo.swift), not here.
public protocol EchoRemover: Sendable {
    func clean(mic: [Float], reference: [Float]) throws -> [Float]
}

#if !canImport(FluidAudio)
/// Store build: no speech engine is linked yet (D21).
public struct UnavailableTranscriber: Transcriber {
    public init() {}
    public func transcribe(_ audio: URL, hotwords: [String], names: Set<String>) async throws -> EngineTranscript { throw EngineError.unavailable }
    public func unload() async {}
}

public struct UnavailableDiarizer: Diarizer {
    public init() {}
    public func diarize(_ audio: URL) async throws -> EngineDiarization { throw EngineError.unavailable }
    public func unload() async {}
}
#endif

#if !EAVESDROPPY_PERSONAL
public struct UnavailableEchoRemover: EchoRemover {
    public init() {}
    public func clean(mic: [Float], reference: [Float]) throws -> [Float] { throw EngineError.unavailable }
}
#endif

/// The engines for this build.
public enum Engine {
    /// Parakeet and the diarizer come with FluidAudio, which only the personal build links.
    public static let hasParakeet: Bool = {
        #if canImport(FluidAudio)
        return true
        #else
        return false
        #endif
    }()
    public static var hasDiarizer: Bool { hasParakeet }

    /// Apple's SpeechTranscriber for a locale ("mul_IN", "en_US"); `log` receives the model-download progress.
    static func apple(locale: String, log: @escaping @Sendable (String) -> Void) -> any Transcriber { AppleTranscriber(locale: locale, log: log) }

    public static func transcriber(modelDir: URL? = nil) -> any Transcriber {
        #if canImport(FluidAudio)
        return FluidTranscriber(modelDir: modelDir)
        #else
        return UnavailableTranscriber()
        #endif
    }

    public static func diarizer() -> any Diarizer {
        #if canImport(FluidAudio)
        return FluidDiarizer()
        #else
        return UnavailableDiarizer()
        #endif
    }

    public static func echoRemover() -> any EchoRemover {
        #if EAVESDROPPY_PERSONAL
        return LocalVQEProcess()
        #else
        return UnavailableEchoRemover()
        #endif
    }
}
