import Foundation

// Which speech engine and language a meeting is transcribed with (research/stt-model-selection-2026-10-14.md, D33 to D36).
// Pure and engine-free, so every rule here is unit-tested in both builds. One engine per meeting: the choice is made
// once, before transcription, and applies to every track.

/// The "Meeting language" setting. Raw values are what meta.json and the preference store carry.
enum MeetingLanguage: String, CaseIterable {
    case auto, english, mixed

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .english: return "English"
        case .mixed: return "Urdu/Hindi + English"
        }
    }

    /// The notes-window button's label: the menu items keep the full titles.
    var shortTitle: String { self == .mixed ? "Urdu/Hindi" : title }

    /// A missing or unknown value is Auto (recordings made before the setting existed).
    static func parse(_ raw: Any?) -> MeetingLanguage { (raw as? String).flatMap(MeetingLanguage.init(rawValue:)) ?? .auto }
}

enum SpeechEngine: String { case parakeet, apple }

/// What a meeting is transcribed with. `locale` is Apple's locale id ("mul_IN", "en_US"); nil for Parakeet.
struct EngineChoice: Equatable {
    var engine: SpeechEngine
    var locale: String?
    var mixed: Bool
    var reason: String

    /// The notes-header text: "Urdu/Hindi + English (Apple)" or "English (Parakeet)".
    var label: String { "\(mixed ? "Urdu/Hindi + English" : "English") (\(engine == .apple ? "Apple" : "Parakeet"))" }

    /// What the raw archive's meta.json records: the header line, and the engine and locale behind it.
    var meta: [String: Any] { ["transcript_language": label, "stt_engine": engine.rawValue, "stt_locale": locale ?? "", "stt_reason": reason] }
}

/// What this build and this Mac can run.
struct EngineAvailability: Equatable {
    var parakeet: Bool   // FluidAudio is compiled in (personal build)
    var apple: Bool      // SpeechTranscriber exists (macOS 26 or later)
}

enum Routing {
    static let mixedLocale = "mul_IN"
    /// The Store build's English engine. mul_IN: measured as good as en_US on English (research/swift-port-plan.md, D35), and one
    /// locale means one asset download and no detection pre-pass for a meeting that turns out to be mixed.
    static let englishLocale = "mul_IN"

    enum Plan: Equatable {
        case fixed(EngineChoice)
        /// Auto with Apple available: transcribe a leading excerpt with mul_IN and score it (`LanguageDetector`).
        case detect
    }

    static let noEngine = StoreError("Transcription needs macOS 26 or later in this build (it uses Apple's speech recognition).")

    /// `warnings` gets the one line the user should see when the setting could not be honoured.
    static func plan(_ setting: MeetingLanguage, _ a: EngineAvailability, warnings: inout [String]) throws -> Plan {
        switch setting {
        case .english:
            return .fixed(try english(a, "language set to English"))
        case .mixed:
            if a.apple { return .fixed(EngineChoice(engine: .apple, locale: mixedLocale, mixed: true, reason: "language set to Urdu/Hindi + English")) }
            guard a.parakeet else { throw noEngine }
            warnings.append("Urdu/Hindi + English needs macOS 26 or later; used the English engine")
            return .fixed(EngineChoice(engine: .parakeet, locale: nil, mixed: false, reason: "Apple speech recognition unavailable"))
        case .auto:
            if a.apple { return .detect }
            return .fixed(try english(a, "Apple speech recognition unavailable"))
        }
    }

    /// The outcome of detection: a mixed share at or above the threshold sends the whole meeting to Apple mul_IN.
    static func resolve(share: Double, tokens: Int, _ a: EngineAvailability) throws -> EngineChoice {
        if tokens >= LanguageDetector.minTokens, share >= LanguageDetector.threshold {
            return EngineChoice(engine: .apple, locale: mixedLocale, mixed: true,
                                reason: "\(percent(share)) of \(tokens) words are Urdu/Hindi function words")
        }
        let why = tokens < LanguageDetector.minTokens ? "only \(tokens) words to judge by" : "\(percent(share)) of \(tokens) words are Urdu/Hindi function words"
        return try english(a, why)
    }

    static func english(_ a: EngineAvailability, _ reason: String) throws -> EngineChoice {
        if a.parakeet { return EngineChoice(engine: .parakeet, locale: nil, mixed: false, reason: reason) }
        guard a.apple else { throw noEngine }
        return EngineChoice(engine: .apple, locale: englishLocale, mixed: false, reason: reason)
    }

    private static func percent(_ x: Double) -> String { String(format: "%.1f%%", x * 100) }
}

/// The share of words that are common romanized Urdu/Hindi function words. English text has almost none, so the
/// share separates the two without understanding either language.
enum LanguageDetector {
    /// How much audio the pre-pass transcribes, in seconds of speech, per track.
    static let excerptSeconds = 180.0
    /// Below this many words the evidence is too thin to call a meeting mixed.
    static let minTokens = 40
    /// Calibrated on the two real mixed sessions and the English sample (research/swift-port-plan.md, D34).
    static let threshold = 0.02

    /// Lowercase tokens. Words English also uses ("main", "is", "to", "me") are left out on purpose.
    static let functionWords: Set<String> = [
        "hai", "hain", "ka", "ki", "ke", "ko", "nahi", "nahin", "mein", "aur", "bhi", "kya", "ye", "yeh", "woh", "wo", "tha", "thi", "thay",
        "raha", "rahe", "rahi", "kar", "karna", "karte", "karo", "ho", "hoga", "hogi", "honge", "abhi", "sirf", "matlab", "accha", "acha", "theek", "thik",
        "haan", "ji", "toh", "lekin", "kyun", "kyunki", "jo", "isko", "usko", "hum", "humare", "hamare", "unka", "uska", "aap", "aapko", "kuch",
    ]

    static func tokens(_ words: [String]) -> [String] {
        words.flatMap { $0.split(whereSeparator: \.isWhitespace) }.map { Turns.alignKey(String($0)) }.filter { !$0.isEmpty }
    }

    static func share(of words: [String]) -> (share: Double, tokens: Int) {
        let t = tokens(words)
        guard !t.isEmpty else { return (0, 0) }
        return (Double(t.filter(functionWords.contains).count) / Double(t.count), t.count)
    }
}

/// Urdu/Hindi must come out in Latin script. Apple mul_IN already writes Latin; this is the guarantee, applied to every
/// engine's words.
enum RomanScript {
    private static let ranges: [ClosedRange<UInt32>] = [0x0600...0x06FF, 0x0750...0x077F, 0xFB50...0xFDFF, 0xFE70...0xFEFF,   // Arabic
                                                         0x0900...0x097F]                                                      // Devanagari

    static func needsTransliteration(_ s: String) -> Bool { s.unicodeScalars.contains(where: inRanges) }

    private static func inRanges(_ u: Unicode.Scalar) -> Bool { ranges.contains { $0.contains(u.value) } }

    /// Foundation's Any-Latin transform, diacritics stripped ("ā" -> "a"), then what the transform leaves behind for Perso-Arabic:
    /// ICU's dotted-circle placeholder, the aspiration mark, Arabic punctuation. Nothing in the listed ranges survives.
    // shortcut: Perso-Arabic leaves out short vowels ("نہیں" -> "nhy"); fine for a guarantee that should never fire (Apple writes Latin), not for reading
    static func latinize(_ s: String) -> String {
        var t = (s.applyingTransform(.toLatin, reverse: false) ?? s).applyingTransform(.stripDiacritics, reverse: false) ?? s
        for (a, b) in [("\u{25CC}", ""), ("\u{02B1}", "h"), ("\u{060C}", ","), ("\u{061B}", ";"), ("\u{061F}", "?")] { t = t.replacingOccurrences(of: a, with: b) }
        return String(String.UnicodeScalarView(t.unicodeScalars.filter { !inRanges($0) }))
    }

    /// Returns the words with every Arabic-script or Devanagari word transliterated, and how many were. A word that transliterates
    /// to nothing (a stray mark) is dropped.
    static func enforce(_ words: [EngineWord]) -> (words: [EngineWord], count: Int) {
        var out: [EngineWord] = [], n = 0
        out.reserveCapacity(words.count)
        for var w in words {
            if needsTransliteration(w.text) {
                n += 1
                let t = latinize(w.text).trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty { continue }
                w.text = t
            }
            out.append(w)
        }
        return (out, n)
    }
}
