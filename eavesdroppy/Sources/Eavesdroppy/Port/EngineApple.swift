import AVFoundation
import Foundation
import Speech

// Apple's on-device SpeechTranscriber (Speech framework, macOS 26 and later) behind the `Transcriber` seam. A system
// framework, so it is in both builds and needs no dependency. Locale mul_IN writes Urdu/Hindi/English code-switching in
// Latin script (research/stt-model-selection-2026-10-14.md); en_US and mul_IN are the two locales the pipeline asks for.
// The model lives in a system service: nothing to unload here, and the asset download is the OS's (AssetInventory).
//
// Not used: `hotwords` / `names` (SpeechTranscriber has no vocabulary biasing that matches Parakeet's; the notes
// prompt still gets the attendee names as a hint).

final class AppleTranscriber: Transcriber, @unchecked Sendable {
    let locale: String
    let log: @Sendable (String) -> Void   // download progress goes to the processing row through the pipeline log

    init(locale: String, log: @escaping @Sendable (String) -> Void = { _ in }) { self.locale = locale; self.log = log }

    /// True on macOS 26 or later on a Mac whose speech recognition can run.
    static var isAvailable: Bool {
        if #available(macOS 26.0, *) { return SpeechTranscriber.isAvailable }
        return false
    }

    func transcribe(_ audio: URL, hotwords: [String], names: Set<String>) async throws -> EngineTranscript {
        guard #available(macOS 26.0, *) else { throw EngineError.failed("Apple speech recognition needs macOS 26 or later") }
        return try await Self.run(audio, localeID: locale, log: log)
    }

    func unload() async {}

    @available(macOS 26.0, *)
    private static func run(_ audio: URL, localeID: String, log: @escaping @Sendable (String) -> Void) async throws -> EngineTranscript {
        try Task.checkCancellation()
        guard SpeechTranscriber.isAvailable else { throw EngineError.failed("Apple speech recognition is not available on this Mac") }
        guard let loc = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeID)) else {
            throw EngineError.failed("Apple speech recognition does not support \(localeID) on this Mac")
        }
        let transcriber = SpeechTranscriber(locale: loc, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        try await installAssets(for: transcriber, log: log)
        try Task.checkCancellation()

        let file = try AVAudioFile(forReading: audio)
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .utility, modelRetention: .whileInUse))
        // The results sequence ends when the analyzer finishes; it has to be consumed while the analysis runs.
        let collected = Task { () -> [(word: String, start: Double, end: Double)] in
            var out: [(word: String, start: Double, end: Double)] = []
            for try await r in transcriber.results {
                for run in r.text.runs {
                    let from = run.audioTimeRange?.start.seconds ?? out.last?.end ?? r.range.start.seconds
                    let to = run.audioTimeRange?.end.seconds ?? from
                    out += split(String(r.text[run.range].characters), from, to)
                }
            }
            return out
        }
        do {
            try await withTaskCancellationHandler {
                if let last = try await analyzer.analyzeSequence(from: file) { try await analyzer.finalizeAndFinish(through: last) }
                else { await analyzer.cancelAndFinishNow() }
            } onCancel: {
                collected.cancel()
                Task { await analyzer.cancelAndFinishNow() }
            }
        } catch {
            collected.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
        let raw = try await collected.value
        try Task.checkCancellation()
        // Same rule as Turns.align: a word never runs past the next word's start or Turns.maxWordS.
        let words = raw.enumerated().map { i, w in
            EngineWord(text: w.word, start: w.start,
                       end: max(w.start, min(w.end, w.start + Turns.maxWordS, i + 1 < raw.count ? raw[i + 1].start : w.end)))
        }
        return EngineTranscript(words: words, durationSeconds: Double(file.length) / file.processingFormat.sampleRate)
    }

    /// A run is normally one word with a space on one side ("Also, "), occasionally two: spread its time range over the words.
    static func split(_ text: String, _ from: Double, _ to: Double) -> [(word: String, start: Double, end: Double)] {
        let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        return parts.enumerated().map { i, w in
            let n = Double(parts.count)
            return (w, from + (to - from) * Double(i) / n, from + (to - from) * Double(i + 1) / n)
        }
    }

    /// Reserves the locale and downloads its model when the OS has not got it yet (639 MB for mul_IN, once). Not calling
    /// `AssetInventory.reserve` by hand: `assetInstallationRequest` reserves the locale as a side effect.
    @available(macOS 26.0, *)
    private static func installAssets(for transcriber: SpeechTranscriber, log: @escaping @Sendable (String) -> Void) async throws {
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }   // nil: installed
        log("Downloading speech model…")
        let progress = request.progress
        let ticker = Task {   // the processing row shows the newest log line
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                log("Downloading speech model… \(Int(progress.fractionCompleted * 100)) %")
            }
        }
        defer { ticker.cancel() }
        try await request.downloadAndInstall()
        log("Speech model ready")
    }
}
