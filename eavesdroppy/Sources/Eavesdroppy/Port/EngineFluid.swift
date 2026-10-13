#if canImport(FluidAudio)
import AVFoundation
import CoreML
import FluidAudio
import Foundation

// In-process equivalents of the two `fluidaudiocli` calls the Python oracle makes (pinned commit e560c64):
//
//   transcribe <wav> --output-json out --model-version v3 [--local-model-dir D]
//              [--custom-vocab V --vocab-disable-spotter-rescue --vocab-min-similarity 0.6]
//   process <wav> --mode offline --min-segment-duration 0.3 --output out
//
// The bodies below follow TranscribeCommand.runBatch and ProcessCommand.runOffline in that checkout step for step,
// because the equivalence test (EngineEquivalenceTests) holds them to the CLI's output.

/// `process_meeting.transcribe`. Models stay loaded between tracks of one meeting; call `unload()` after it.
public actor FluidTranscriber: Transcriber {
    private let modelDir: URL?
    private var asr: AsrManager?

    /// `modelDir`: a directory holding Parakeet v3's compiled models under FluidAudio's file names, normally
    /// `EngineVocab.linkDroppyModel(into:)`, so Droppy's copy is used and nothing is downloaded twice. nil falls
    /// back to FluidAudio's own cache, downloading once if it is empty (what the CLI does without `--local-model-dir`).
    public init(modelDir: URL?) { self.modelDir = modelDir }

    private func manager() async throws -> AsrManager {
        if let asr { return asr }
        let version = AsrModelVersion.v3
        let models: AsrModels
        if let modelDir {
            guard FileManager.default.fileExists(atPath: modelDir.path) else { throw EngineError.modelMissing(modelDir.path) }
            models = try AsrModels.loadLocal(from: modelDir, version: version, encoderPrecision: .int8, encoderComputeUnits: nil)
        } else {
            models = try await AsrModels.downloadAndLoad(version: version, encoderPrecision: .int8, encoderComputeUnits: nil)
        }
        let config = ASRConfig(
            tdtConfig: TdtConfig(blankId: version.blankId), encoderHiddenSize: version.encoderHiddenSize,
            melChunkContext: nil, dualDecodeArbitration: false, seamGapRepair: true, seamTimingRealignment: true)
        let m = AsrManager(config: config)
        try await m.loadModels(models)
        asr = m
        return m
    }

    public func transcribe(_ audio: URL, hotwords: [String], names: Set<String>) async throws -> EngineTranscript {
        try Task.checkCancellation()
        let asr = try await manager()
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let url = audio.standardizedFileURL
        var result: ASRResult
        var samples: [Float]?
        if hotwords.isEmpty {
            result = try await asr.transcribe(url, decoderState: &state, language: nil)
        } else {
            samples = try AudioConverter().resampleAudioFile(url)
            result = try await asr.transcribe(samples!, decoderState: &state, language: nil)
        }
        if let samples {
            try Task.checkCancellation()
            result = try await Self.applyVocabulary(to: result, samples: samples, hotwords: hotwords, names: names)
        }
        let tokens = result.tokenTimings ?? []
        let raw = Self.mergeTokensIntoWords(tokens).map { (word: $0.word, start: $0.start, end: $0.end) }
        return EngineTranscript(words: EngineVocab.alignWords(raw: raw, text: result.text), durationSeconds: result.duration)
    }

    public func unload() async {
        await asr?.cleanup()
        asr = nil
    }

    /// The `--custom-vocab` branch of runBatch with `--vocab-disable-spotter-rescue --vocab-min-similarity 0.6`.
    /// Goes through the vocab file and `loadWithCtcTokens`, the same code path as the CLI (sanitising, CTC tokenising).
    private static func applyVocabulary(to result: ASRResult, samples: [Float], hotwords: [String], names: Set<String>) async throws -> ASRResult {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("eavesdroppy-vocab-\(UUID().uuidString).json")
        try EngineVocab.vocabJSON(hotwords, names: names).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let (vocab, ctcModels) = try await CustomVocabularyContext.loadWithCtcTokens(from: file.path)
        let spotter = CtcKeywordSpotter(models: ctcModels, blankId: ctcModels.vocabulary.count)
        let spot = try await spotter.spotKeywordsWithLogProbs(audioSamples: samples, customVocabulary: vocab, minScore: nil)
        guard let tokens = result.tokenTimings, !tokens.isEmpty, !spot.logProbs.isEmpty else { return result }
        let size = ContextBiasingConstants.rescorerConfig(forVocabSize: vocab.terms.count)
        let rescorer = try await VocabularyRescorer.create(
            spotter: spotter, vocabulary: vocab,
            config: VocabularyRescorer.Config(
                shortTermCbwTaperPivot: ContextBiasingConstants.defaultShortTermCbwTaperPivot,
                spotterRescueMinSimilarity: ContextBiasingConstants.defaultSpotterRescueMinSimilarity,
                spotterRescueMultiWordMinSimilarity: ContextBiasingConstants.defaultSpotterRescueMultiWordMinSimilarity,
                spotterRescueEnabled: false),   // --vocab-disable-spotter-rescue
            ctcModelDirectory: CtcModels.defaultCacheDirectory(for: ctcModels.variant))
        let out = rescorer.ctcTokenRescore(
            transcript: result.text, tokenTimings: tokens, logProbs: spot.logProbs, frameDuration: spot.frameDuration,
            cbw: size.cbw, marginSeconds: ContextBiasingConstants.defaultMarginSeconds,
            minSimilarity: EngineVocab.globalMinSimilarity)   // --vocab-min-similarity 0.6
        guard out.wasModified else { return result }
        return ASRResult(text: out.text, confidence: result.confidence, duration: result.duration,
                         processingTime: result.processingTime, tokenTimings: result.tokenTimings)
    }

    /// TranscribeCommand's `WordTimingMerger.mergeTokensIntoWords`, verbatim (CLI-internal, so not importable). It
    /// differs from the library's `buildWordTimings`: it splits only on a leading space, newline or tab.
    static func mergeTokensIntoWords(_ timings: [TokenTiming]) -> [(word: String, start: Double, end: Double)] {
        var out: [(word: String, start: Double, end: Double)] = []
        var word = "", start: Double?, end = 0.0
        for t in timings {
            if t.token.hasPrefix(" ") || t.token.hasPrefix("\n") || t.token.hasPrefix("\t") {
                if !word.isEmpty, let s = start { out.append((word, s, end)) }
                word = t.token.trimmingCharacters(in: .whitespacesAndNewlines)
                start = t.startTime; end = t.endTime
            } else {
                if start == nil { start = t.startTime }
                word += t.token; end = t.endTime
            }
        }
        if !word.isEmpty, let s = start { out.append((word, s, end)) }
        return out
    }
}

/// `speakers.diarize`: FluidAudio offline VBx with `--min-segment-duration 0.3`.
public actor FluidDiarizer: Diarizer {
    public static let minTrackSeconds = 0.5   // MIN_TRACK_SECONDS
    private var manager: OfflineDiarizerManager?

    public init() {}

    /// Every other value is the CLI's `process --mode offline` default (equal to FluidAudio's `.community`).
    static func config() -> OfflineDiarizerConfig {
        OfflineDiarizerConfig(
            clusteringThreshold: 0.6, Fa: 0.07, Fb: 0.8, windowDuration: 10.0, sampleRate: 16_000,
            segmentationStepRatio: 0.2, embeddingBatchSize: 32, embeddingExcludeOverlap: true, embeddingSkipStrategy: .none,
            minSegmentDuration: 0.3, minGapDuration: 0.1, exclusiveSegments: true,
            speechOnsetThreshold: 0.5, speechOffsetThreshold: 0.5, segmentationMinDurationOn: 0, segmentationMinDurationOff: 0,
            maxVBxIterations: 20, convergenceTolerance: 1e-4, embeddingExportPath: nil)
    }

    private func loaded() async throws -> OfflineDiarizerManager {
        if let manager { return manager }
        let m = OfflineDiarizerManager(config: Self.config())
        let models = try await OfflineDiarizerModels.load(
            from: OfflineDiarizerModels.defaultModelsDirectory(),
            configuration: MLModelConfigurationUtils.defaultConfiguration(computeUnits: .all))
        m.initialize(models: models)
        manager = m
        return m
    }

    public func diarize(_ audio: URL) async throws -> EngineDiarization {
        try Task.checkCancellation()
        let f = try AVAudioFile(forReading: audio)
        if Double(f.length) / f.processingFormat.sampleRate < Self.minTrackSeconds { return .empty }   // the CLI fails below ~0.5 s
        let m = try await loaded()
        try Task.checkCancellation()
        let result: DiarizationResult
        do { result = try await m.process(audio.standardizedFileURL) }
        catch OfflineDiarizationError.noSpeechDetected { return .empty }
        var segments: [EngineSegment] = [], emb: [String: [Float]] = [:]
        for s in result.segments {
            let cid = String(describing: s.speakerId)
            segments.append(EngineSegment(start: Self.double(s.startTimeSeconds), end: Self.double(s.endTimeSeconds), cluster: cid))
            if emb[cid] == nil, !s.embedding.isEmpty { emb[cid] = Self.unit(s.embedding) }   // identical across a cluster's segments
        }
        segments.sort { ($0.start, $0.end, $0.cluster) < ($1.start, $1.end, $1.cluster) }
        return EngineDiarization(segments: segments, embeddings: emb)
    }

    public func unload() async { manager = nil }   // OfflineDiarizerManager has no unload; dropping it frees the MLModels

    /// The CLI writes Float seconds as shortest-decimal JSON and Python reads them as doubles; do the same.
    private static func double(_ f: Float) -> Double { Double("\(f)") ?? Double(f) }

    private static func unit(_ v: [Float]) -> [Float] {
        let n = sqrt(v.reduce(Float(0)) { $0 + $1 * $1 })
        return n > 0 ? v.map { $0 / n } : v
    }
}
#endif
