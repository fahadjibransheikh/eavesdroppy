import Foundation

/// Ports of `process_meeting.py`: vocabulary lines, the vocab JSON FluidAudio reads, Droppy's model and dictionary,
/// and `align_words`. Pure and FluidAudio-free, so they run (and are golden-tested) in every build.
public enum EngineVocab {
    public static let nameSimilarity = 0.8   // NAME_SIM: attendee names need a closer match than the 0.6 global
    public static let globalMinSimilarity: Float = 0.6   // --vocab-min-similarity
    public static let maxWordSeconds = Turns.maxWordS   // MAX_WORD_S

    public static let droppyDefaultsDomain = "iordv.Droppy"
    public static let droppyVocabKey = "voiceTranscribe_customVocabulary"
    public static let droppyModelKey = "fluid_parakeet-tdt-v3"
    public static let modelFiles = ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc", "parakeet_vocab.json"]
    public static var droppyState: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Droppy/Extensions/voiceTranscribe/runtime-state.json")
    }

    // MARK: vocab lines

    /// Lowercase entries of the system word list (proper nouns are capitalised there, so they are not in it).
    public static let commonWords: Set<String> = {
        guard let text = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
        return Set(text.split(whereSeparator: \.isWhitespace).map(String.init).filter { $0 == $0.lowercased() && $0 != $0.uppercased() })
    }()

    private static func splitWords(_ s: String) -> [String] { s.split(whereSeparator: \.isWhitespace).map(String.init) }

    /// `attendee_names`: capitalised names only, kept whole; a one-word name must not be an ordinary English word.
    public static func attendeeNames(_ attendees: [String], commonWords: Set<String> = EngineVocab.commonWords) -> [String] {
        var out: [String] = []
        for a in attendees {
            let toks = splitWords(a.replacingOccurrences(of: "[,:]", with: " ", options: .regularExpression))
            if toks.isEmpty || a.contains("@") || !toks.allSatisfy({ $0.first?.isUppercase == true }) { continue }
            if toks.count > 1 || !commonWords.contains(toks[0].lowercased()) { out.append(toks.joined(separator: " ")) }
        }
        return out
    }

    /// `build_hotwords`: Droppy dictionary lines first (they may carry aliases), then attendee names, deduped
    /// case-insensitively on the term before any ':'.
    public static func buildHotwords(attendees: [String], vocabLines: [String], commonWords: Set<String> = EngineVocab.commonWords) -> [String] {
        var out: [String] = [], seen = Set<String>()
        for line in vocabLines + attendeeNames(attendees, commonWords: commonWords) {
            let key = (line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !key.isEmpty, seen.insert(key).inserted { out.append(line) }
        }
        return out
    }

    /// `droppy_vocab_lines`: Droppy dictionary JSON (`[{canonical, variants}]`, as text or data) to
    /// `canonical` / `canonical: v1, v2` lines. Anything unreadable gives [].
    public static func droppyVocabLines(_ raw: Any?) -> [String] {
        let data: Data
        switch raw {
        case let s as String: data = Data(s.utf8)
        case let d as Data: data = d
        default: return []
        }
        guard let items = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return [] }
        // ',' and ':' are the line syntax
        func clean(_ v: Any) -> String { splitWords("\(v)".replacingOccurrences(of: "[,:]", with: " ", options: .regularExpression)).joined(separator: " ") }
        var lines: [String] = []
        for case let it as [String: Any] in items {
            let canonical = clean(it["canonical"] ?? "")
            if canonical.isEmpty { continue }
            let variants = ((it["variants"] as? [Any]) ?? []).map(clean).filter { !$0.isEmpty }
            lines.append(variants.isEmpty ? canonical : "\(canonical): \(variants.joined(separator: ", "))")
        }
        return lines
    }

    /// `load_droppy_vocab`. Inside Droppy `.standard` is Droppy's own domain; elsewhere (tests) read it by name.
    public static func loadDroppyVocab(defaults: [UserDefaults] = [.standard, UserDefaults(suiteName: droppyDefaultsDomain)].compactMap { $0 }) -> [String] {
        for d in defaults {
            let lines = droppyVocabLines(d.object(forKey: droppyVocabKey))
            if !lines.isEmpty { return lines }
        }
        return []
    }

    /// `vocab_json`: lines to FluidAudio's JSON vocab config. JSON, not the text list, because only it carries a
    /// per-term minSimilarity: lines whose term is in `names` get `nameSimilarity`.
    public static func vocabJSON(_ hotwords: [String], names: Set<String> = []) -> Data {
        let terms: [[String: Any]] = hotwords.map { line in
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let term = parts[0].trimmingCharacters(in: .whitespaces)
            let aliases = parts.count > 1
                ? parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } : []
            var t: [String: Any] = ["text": term]
            if !aliases.isEmpty { t["aliases"] = aliases }
            if names.contains(term) { t["minSimilarity"] = nameSimilarity }
            return t
        }
        return (try? JSONSerialization.data(withJSONObject: ["terms": terms], options: [.sortedKeys])) ?? Data()
    }

    // MARK: Droppy's Parakeet model

    /// `link_droppy_model`: symlink `linkDir` over Droppy's Parakeet v3 model, with the joint named the way FluidAudio
    /// expects (`JointDecisionv3`). Returns `linkDir`, or nil if Droppy's model is absent or the link dir ends up
    /// incomplete. Never downloads; the FluidAudio loader is pointed at this directory only.
    public static func linkDroppyModel(into linkDir: URL, state: URL = EngineVocab.droppyState) -> URL? {
        let fm = FileManager.default
        do {
            guard let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: state)) as? [String: Any],
                  let installed = obj["installedModels"] as? [String: Any],
                  let path = installed[droppyModelKey] as? String else { return nil }
            let src = URL(fileURLWithPath: path)
            let entries = try fm.contentsOfDirectory(atPath: src.path).sorted()
            try fm.createDirectory(at: linkDir, withIntermediateDirectories: true)
            for old in try fm.contentsOfDirectory(atPath: linkDir.path) {  // refresh: drop links from an earlier model location
                let p = linkDir.appendingPathComponent(old)
                if (try? fm.destinationOfSymbolicLink(atPath: p.path)) != nil { try fm.removeItem(at: p) }
            }
            for e in entries { try fm.createSymbolicLink(at: linkDir.appendingPathComponent(e), withDestinationURL: src.appendingPathComponent(e)) }
            if !fm.fileExists(atPath: src.appendingPathComponent("JointDecisionv3.mlmodelc").path),
               fm.fileExists(atPath: src.appendingPathComponent("JointDecision.mlmodelc").path) {
                try fm.createSymbolicLink(at: linkDir.appendingPathComponent("JointDecisionv3.mlmodelc"),
                                          withDestinationURL: src.appendingPathComponent("JointDecision.mlmodelc"))
            }
        } catch { return nil }
        return modelFiles.allSatisfy { fm.fileExists(atPath: linkDir.appendingPathComponent($0).path) } ? linkDir : nil
    }

    // MARK: align_words

    /// `align_words`: the one implementation is `Turns.align` (Python's SequenceMatcher, `\W` rule and all); this adapts the type.
    public static func alignWords(raw: [(word: String, start: Double, end: Double)], text: String) -> [EngineWord] {
        Turns.align(raw, text).map { EngineWord(text: $0.text, start: $0.start, end: $0.end) }
    }
}
