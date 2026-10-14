import Foundation

// process_meeting.process(), in-process (D22). Same stages in the same order and the same warning texts (the UI shows them),
// on the engines behind Engine*.swift and the library behind Store*.swift. Heavy work runs on a detached Task at .utility
// priority (see ProcessorJob); models are unloaded after every meeting. The session dir is never touched here: the caller
// removes it after success, so a crash or a cancel leaves the raw audio to retry.

enum Processor {
    static let minTrackSeconds = 0.5, silentPeak: Float = 1e-4   // MIN_TRACK_SECONDS, SILENT_PEAK
    static let gap = 1.0
    static let namingTimeout: TimeInterval = 120   // NAMING_TIMEOUT
    static let oldLabel = ["mic": "Me", "system": "Them"], what = ["mic": "Mic", "system": "Call"]
    static let inPersonLabel = ["mic": "Room", "system": "Them"]   // IN_PERSON_LABEL: the mic is the whole room, not the user alone
    static let defaultUserName = "Me"   // Python's notes.USER_NAME ("Fahad") is this Mac's name; the droplet always passes one

    struct Engines {
        var transcriber: (URL?) -> any Transcriber = { Engine.transcriber(modelDir: $0) }
        var diarizer: () -> any Diarizer = { Engine.diarizer() }
        var echoRemover: () -> any EchoRemover = { Engine.echoRemover() }
        var linkModel: (URL) -> URL? = { EngineVocab.linkDroppyModel(into: $0) }
        var droppyVocab: () -> [String] = { EngineVocab.loadDroppyVocab() }
        /// Apple's SpeechTranscriber for a locale; the closure gets the pipeline log (model-download progress).
        var apple: (String, @escaping @Sendable (String) -> Void) -> any Transcriber = { Engine.apple(locale: $0, log: $1) }
        var availability = { EngineAvailability(parakeet: Engine.hasParakeet, apple: AppleTranscriber.isAvailable) }
        /// False in the Store build: no diarizer, so each track is one speaker.
        var hasDiarizer = Engine.hasDiarizer
    }

    struct Params {
        var session: URL
        var container: URL?
        var outRoot: String
        var userName: String?
        var resolution: NotesProviders.Resolution
        var engines = Engines()
        var log: (String) -> Void = { _ in }
        /// Debug builds only: abort() at this stage (the crash/responsiveness gate). Default from EAVESDROPPY_DEBUG_CRASH.
        var crashAt: String? = ProcessInfo.processInfo.environment["EAVESDROPPY_DEBUG_CRASH"]
    }

    struct Result: Equatable { var folder: String; var meetingID: Int; var warnings: [String] }

    private static func crash(_ p: Params, _ stage: String) {
        #if DEBUG
        if p.crashAt == stage { p.log("DEBUG crash at \(stage)"); abort() }
        #endif
    }

    // MARK: small helpers (process_meeting.py)

    private static func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }

    /// user_name_of: first usable name of --user-name, meta.json user_name, else the default.
    static func userNameOf(_ cands: String?...) -> String {
        for c in cands { if let c, !PyText.strip(c).isEmpty { return PyText.words(c).joined(separator: " ") } }
        return defaultUserName
    }

    /// read_user_notes
    static func readUserNotes(_ session: URL, _ meta: [String: Any]) -> String {
        for n in [meta["user_notes_file"] as? String, "notes.txt"] {
            guard let n, !n.isEmpty else { continue }
            let p = n.hasPrefix("/") ? n : session.path + "/" + n
            if PyPath.exists(p), !PyPath.isDir(p), let t = try? String(contentsOfFile: p, encoding: .utf8) { return t }
        }
        return ""
    }

    /// read_custom_template: meta custom_template (the text), else custom_template_file inside the container.
    static func readCustomTemplate(_ meta: [String: Any], container: String, warnings: inout [String]) -> String? {
        if let t = meta["custom_template"] as? String, !PyText.strip(t).isEmpty { return t }
        guard let name = meta["custom_template_file"] as? String, !name.isEmpty else { return nil }
        let e = PyPath.expanduser(name), p = e.hasPrefix("/") ? e : container + "/" + e
        guard PyPath.under(p, [container]) else { warnings.append("Custom template file \(name) is outside the container; ignored"); return nil }
        do { return try String(contentsOfFile: p, encoding: .utf8) }
        catch { warnings.append("Custom template file \(name) unreadable: \(error.localizedDescription)"); return nil }
    }

    /// clean_stale: .incoming-* stage dirs left behind by a killed run.
    static func cleanStale(_ root: String, maxAge: TimeInterval = 3600) {
        let fm = FileManager.default
        for n in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where n.hasPrefix(".incoming-") {
            let p = root + "/" + n
            if let a = try? fm.attributesOfItem(atPath: p), a[.type] as? FileAttributeType == .typeDirectory,
               let m = a[.modificationDate] as? Date, Date().timeIntervalSince(m) > maxAge { try? fm.removeItem(atPath: p) }
        }
    }

    /// reusable: a folder an earlier, killed attempt of this same session made (it is in `leftover`, inside outRoot) that no meeting owns.
    static func reusable(_ folder: String, leftover: [String], outRoot: String, _ db: StoreDB) throws -> Bool {
        guard leftover.contains(folder), PyPath.under(folder, [outRoot]), PyPath.isDir(folder) else { return false }
        return try db.rows("SELECT 1 FROM meetings WHERE folder = ?", [folder]).isEmpty
    }

    private static func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { g in
            g.addTask { try await op() }
            g.addTask { try await Task.sleep(nanoseconds: UInt64(seconds * 1e9)); return nil }
            defer { g.cancelAll() }
            guard let first = try await g.next() else { throw CancellationError() }
            guard let v = first else { throw NotesProviderError.timedOut("the provider", Int(seconds)) }
            return v
        }
    }

    // MARK: echo stage

    struct EchoOutcome { var bleed: Bool; var mic: URL; var dedup: Bool }

    /// echo_stage. Bleed check on the 16 kHz tracks; returns the mic to transcribe and diarize. dedup == true means removal was
    /// tried and failed (or is unavailable), so the caller drops duplicate words instead. Never dedups a clean meeting.
    static func echoStage(mic16: URL, sys16: URL, offset: Double, removal: Bool, remover: any EchoRemover, tmp: URL,
                          warnings: inout [String], log: (String) -> Void) async throws -> EchoOutcome {
        let mic: [Float], sysRaw: [Float]
        let det: Echo.Bleed
        do {
            mic = try Echo.load16k(mic16)
            sysRaw = try Echo.load16k(sys16)
            det = Echo.detect(mic: mic, system: Echo.alignStart(sysRaw, offsetS: offset))
        } catch is CancellationError { throw CancellationError()
        } catch { warnings.append("Echo detection failed: \(error.localizedDescription)"); return EchoOutcome(bleed: false, mic: mic16, dedup: false) }
        guard det.bleed else { return EchoOutcome(bleed: false, mic: mic16, dedup: false) }
        log("Echo: bleed detected (share \(det.share.map { "\($0)" } ?? "None"), lag \(det.lagMs) ms)")
        guard removal else { warnings.append("Speaker echo detected; echo removal is off"); return EchoOutcome(bleed: true, mic: mic16, dedup: false) }
        let out = tmp.appendingPathComponent("mic-clean16k.wav")
        var failedReason: String?
        do {
            let r = try Echo.removeEcho(mic: mic, system: sysRaw, remover: remover, systemOffsetS: offset)
            if r.failed { failedReason = r.reason } else {
                let cleaned = tmp.appendingPathComponent("mic-cleaned.wav")
                try ProcessorAudio.writeMonoFloat(r.cleaned, rate: Double(Echo.sr), to: cleaned)
                try EngineAudio.to16kWav(cleaned, out)  // the engines only ever see 16-bit PCM
                let c = r.selfCheck
                func f(_ v: Double?) -> String { v.map { "\($0)" } ?? "None" }
                log("Echo removed ({'reduction_echo_dB': \(f(c?.reductionEchoDb)), 'near_change_dB': \(f(c?.nearChangeDb)), 'ok': \((c?.ok ?? false) ? "True" : "False")})")
            }
        } catch is CancellationError { throw CancellationError()
        } catch is Echo.RemoverMissing {  // not a failure of this meeting: say so once and fall back to dedup
            log("Echo removal unavailable: LocalVQE not built (tools/build_localvqe.sh)")
            warnings.append("Echo removal unavailable (LocalVQE not built)")
            return EchoOutcome(bleed: true, mic: mic16, dedup: true)
        } catch { failedReason = error.localizedDescription }
        if let failedReason {
            log("Echo removal failed: \(failedReason)")
            warnings.append("Echo removal failed; removed duplicate words instead")
            return EchoOutcome(bleed: true, mic: mic16, dedup: true)
        }
        return EchoOutcome(bleed: true, mic: out, dedup: false)
    }

    // MARK: language

    /// The one engine for every track of this meeting (D33): the setting in meta.json, and for Auto a pre-pass with Apple mul_IN over
    /// the first 180 s of speech of each track, scored by `LanguageDetector`. Throws a readable error when no engine can run.
    static func chooseEngine(_ p: Params, meta: [String: Any], tracks: [(key: String, url: URL)], tmp: URL, warnings: inout [String]) async throws -> EngineChoice {
        let avail = p.engines.availability()
        switch try Routing.plan(MeetingLanguage.parse(meta["language"]), avail, warnings: &warnings) {
        case .fixed(let c): return c
        case .detect:
            p.log("Detecting language")
            var texts: [String] = []
            do {
                let apple = p.engines.apple(Routing.mixedLocale, p.log)
                for (key, url) in tracks {
                    try Task.checkCancellation()
                    let excerpt = tmp.appendingPathComponent("detect-\(key).wav")
                    guard try ProcessorAudio.speechExcerpt(url, to: excerpt, seconds: LanguageDetector.excerptSeconds) > 0 else { continue }
                    texts += try await apple.transcribe(excerpt, hotwords: [], names: []).words.map(\.text)
                }
            } catch is CancellationError { throw CancellationError()
            } catch {
                let why = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                guard avail.parakeet else { throw error }
                warnings.append("Language detection failed (\(why)); used the English engine")
                return try Routing.english(avail, "language detection failed")
            }
            let d = LanguageDetector.share(of: texts)
            p.log("Language detection: \(String(format: "%.1f", d.share * 100)) % function words over \(d.tokens) words (threshold \(String(format: "%.1f", LanguageDetector.threshold * 100)) %)")
            return try Routing.resolve(share: d.share, tokens: d.tokens, avail)
        }
    }

    // MARK: notes

    /// generate_and_store. Returns the warning to show ("Summary failed: ...", or the provider status text) or nil. On failure the transcript is untouched;
    /// the notes become a placeholder (status 'failed' / 'none'), unless keepGood and the existing notes were fine.
    static func generateAndStore(_ db: StoreDB, _ mid: Int, template: String?, customText: String?, keepGood: Bool = false, userName: String?,
                                 droppyVocab: [String], resolution: NotesProviders.Resolution) async throws -> String? {
        guard let m = try StoreLibrary.storedMeeting(db, mid) else { throw StoreError("no meeting \(mid)") }
        let hint = EngineVocab.buildHotwords(attendees: m.attendees, vocabLines: droppyVocab).map {
            String($0.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)[0])
        }
        let out: NotesOutcome
        do {
            out = try await NotesGenerator.generate(meeting: m.notes, template: template, customText: customText, namesHint: hint,
                                                    userName: userNameOf(userName), resolution: resolution)
        } catch let e as NotesPromptError { throw StoreError(e.localizedDescription) }  // unknown template, custom without text
        let warning = out.error.map { out.status == .none ? $0 : "Summary failed: \($0)" }
        if out.error != nil && keepGood && m.summaryStatus == "ok" { return warning }
        try StoreLibrary.setNotes(db, mid, notesMD: out.notesMD, actions: out.error == nil ? out.actions : nil, status: out.status.rawValue, template: template)
        return warning
    }

    // MARK: process

    static func process(_ p: Params) async throws -> Result {
        let transcriberBox = LockedBox<(any Transcriber)?>(nil), diarizerBox = LockedBox<(any Diarizer)?>(nil)
        do {
            let r = try await run(p, transcriberBox, diarizerBox)
            await transcriberBox.value?.unload(); await diarizerBox.value?.unload()
            return r
        } catch {
            await transcriberBox.value?.unload(); await diarizerBox.value?.unload()
            throw error
        }
    }

    private static func run(_ p: Params, _ transcriberBox: LockedBox<(any Transcriber)?>, _ diarizerBox: LockedBox<(any Diarizer)?>) async throws -> Result {
        let fm = FileManager.default
        let t0 = Date()
        func mark(_ name: String) { p.log("stage \(name) done at +\(String(format: "%.1f", Date().timeIntervalSince(t0))) s") }
        let session = URL(fileURLWithPath: PyPath.resolve(p.session.path))
        let container = p.container.map { PyPath.resolve(PyPath.abspath(PyPath.expanduser($0.path))) }
            ?? PyPath.parent(PyPath.parent(session.path))
        let outRoot = PyPath.abspath(PyPath.expanduser(p.outRoot))

        let meta: [String: Any], title: String, startISO: String
        do {
            let d = try Data(contentsOf: session.appendingPathComponent("meta.json"))
            guard let o = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw StoreCrash(kind: "TypeError", message: "meta.json is not an object") }
            meta = o
            guard let t = o["title"] as? String, let s = o["start"] as? String else { throw StoreCrash(kind: "KeyError", message: "'title' or 'start'") }
            let parsed = try StoreDates.parse(s)
            guard parsed.hasOffset else { throw StoreError("meta.json start must include a UTC offset") }
            title = t; startISO = parsed.iso
        } catch let e as StoreError where e.description.hasPrefix("meta.json start") { throw e
        } catch { throw StoreError("bad or missing meta.json (need title, start): \((error as? StoreCrash)?.description ?? error.localizedDescription)") }

        let attendees = (meta["attendees"] as? [Any] ?? []).map { ($0 as? String) ?? "\($0)" }
        let trackOff = (meta["track_offsets"] as? [String: Any] ?? [:]).mapValues(num)
        let isImport = meta["source"] as? String == "import"
        let source = isImport ? "import" : "record"
        let echoRemoval = (meta["echo_removal"] as? Bool) != false
        let inPerson = !isImport && meta["setting"] as? String == "in_person"   // no call: the mic carries the whole room, nothing plays back into it
        var template = (meta["template"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "general"
        let userName = userNameOf(p.userName, meta["user_name"] as? String)
        let userNotes = readUserNotes(session, meta)

        try StoreMirror.checkOutRoot(outRoot)
        try fm.createDirectory(atPath: outRoot, withIntermediateDirectories: true)
        cleanStale(outRoot)
        var warnings: [String] = []
        let customText: String? = template == "custom" ? readCustomTemplate(meta, container: container, warnings: &warnings) : meta["custom_template"] as? String
        if !NotesPrompt.templateIDs.contains(template) || (template == "custom" && PyText.strip(customText ?? "").isEmpty) {
            warnings.append("Template '\(template)' unavailable; used General")
            template = "general"
        }
        let db = try StoreDB(path: URL(fileURLWithPath: container).appendingPathComponent("library.db"))
        defer { db.close() }

        // All intermediates live on local disk; only finished files are copied into outRoot, at the end.
        let tmp = fm.temporaryDirectory.appendingPathComponent("eavesdroppy-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        var files: [(key: String, url: URL)]
        var labels: [String: String], names: [String: String]
        if isImport {
            let srcs = ((try? fm.contentsOfDirectory(atPath: session.path)) ?? []).filter { $0.hasPrefix("import.") }.sorted()
            guard srcs.count == 1 else { throw StoreError("expected exactly one import.<ext> in \(session.path), found \(srcs.count)") }
            files = [("mic", session.appendingPathComponent(srcs[0]))]; labels = ["mic": "Room"]; names = ["mic": "Recording"]
        } else {
            let mic = session.appendingPathComponent("mic.wav")
            guard PyPath.exists(mic.path) else { throw StoreError("\(mic.path) not found") }
            files = [("mic", mic)]; labels = inPerson ? inPersonLabel : oldLabel; names = what
            if PyPath.exists(session.appendingPathComponent("system.wav").path) { files.append(("system", session.appendingPathComponent("system.wav"))) }
        }

        let droppy = p.engines.droppyVocab()
        let hot = EngineVocab.buildHotwords(attendees: attendees, vocabLines: droppy)
        let droppyKeys = Set(droppy.map { PyText.strip($0.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)[0].description).lowercased() })
        let att = EngineVocab.attendeeNames(attendees).filter { !droppyKeys.contains($0.lowercased()) }   // a name the dictionary has keeps its looser matching

        var prepped: [String: EngineAudio.Track] = [:], w16: [(key: String, url: URL)] = []
        var failures: [String] = []
        var duration = 0.0
        for (key, path) in files {
            try Task.checkCancellation()
            let off = trackOff[key] ?? 0.0
            let tr: EngineAudio.Track
            do { tr = try EngineAudio.prepareTrack(key: key, src: path, tmp: tmp); prepped[key] = tr }
            catch is CancellationError { throw CancellationError() }
            catch { failures.append("\(names[key]!) track unreadable (\((error as? LocalizedError)?.errorDescription ?? "\(error)"))"); continue }
            duration = max(duration, off + tr.duration)
            if tr.duration < minTrackSeconds {
                warnings.append("\(names[key]!) track too short (\(String(format: "%.1f", tr.duration)) s), skipped")
            } else if tr.peak < silentPeak {
                if !(inPerson && key == "system") { warnings.append("\(names[key]!) audio was silent") }   // a quiet call-audio track is what an in-person meeting records
            } else {
                let dst = tmp.appendingPathComponent("\(key)16k.wav")
                do { try EngineAudio.to16kWav(tr.mono, dst); w16.append((key, dst)) }
                catch is CancellationError { throw CancellationError() }
                catch { failures.append("\(names[key]!) track transcription failed (\((error as? LocalizedError)?.errorDescription ?? "\(error)"))") }
            }
        }

        mark("track prep")
        // echo (record sessions with a usable system track): mic transcription and diarization use the cleaned mic
        var src = Dictionary(uniqueKeysWithValues: w16.map { ($0.key, $0.url) })
        var bleed = false, dedup = false
        var sysOff = 0.0
        var echoWarnings: [String] = []
        if inPerson {
            p.log("Echo: skipped (in-person meeting: no call audio to bleed into the mic)")
        } else if let mic16 = src["mic"], let sys16 = src["system"] {
            sysOff = (trackOff["system"] ?? 0.0) - (trackOff["mic"] ?? 0.0)
            let e = try await echoStage(mic16: mic16, sys16: sys16, offset: sysOff, removal: echoRemoval, remover: p.engines.echoRemover(), tmp: tmp,
                                        warnings: &echoWarnings, log: p.log)
            bleed = e.bleed; src["mic"] = e.mic; dedup = e.dedup
        }

        mark("echo")
        let choice = try await chooseEngine(p, meta: meta, tracks: w16.map { ($0.key, src[$0.key]!) }, tmp: tmp, warnings: &warnings)
        p.log("Language: \(choice.label) (\(choice.reason))")
        let transcriber: any Transcriber
        if choice.engine == .apple {
            transcriber = p.engines.apple(choice.locale ?? Routing.mixedLocale, p.log)
        } else {
            let modelDir = p.engines.linkModel(URL(fileURLWithPath: container).appendingPathComponent("models/parakeet-tdt-0.6b-v3"))
            p.log(modelDir.map { "Using Droppy's Parakeet model via \($0.path)" } ?? "Droppy's Parakeet model not found; FluidAudio will use its own cache")
            p.log("Custom vocabulary (\(hot.count)): \(String(hot.joined(separator: ", ").prefix(300)))")
            transcriber = p.engines.transcriber(modelDir)
        }
        transcriberBox.value = transcriber
        p.log("Transcribing with \(choice.engine == .apple ? "Apple (\(choice.locale ?? ""))" : "Parakeet")")
        var words: [(track: String, words: [Turns.Word])] = []
        var romanized = 0, wordTotal = 0
        for (key, _) in w16 {
            try Task.checkCancellation()
            do {
                let res = try await transcriber.transcribe(src[key]!, hotwords: hot, names: Set(att))
                let latin = RomanScript.enforce(res.words)   // Urdu/Hindi is always written in Latin letters
                romanized += latin.count; wordTotal += latin.words.count
                words.append((key, latin.words.map { Turns.Word(text: $0.text, start: $0.start, end: $0.end) }))
                duration = max(duration, (trackOff[key] ?? 0.0) + res.durationSeconds)
            } catch is CancellationError { throw CancellationError()
            } catch { failures.append("\(names[key]!) track transcription failed (\((error as? LocalizedError)?.errorDescription ?? "\(error)"))") }
        }
        p.log("Roman script: \(romanized) of \(wordTotal) words transliterated to Latin")
        if failures.count == files.count { throw StoreError(failures.joined(separator: "; ")) }
        warnings += failures + echoWarnings   // some tracks failed, others carried the meeting
        mark("transcription")
        crash(p, "after-asr")
        func wordsOf(_ k: String) -> [Turns.Word]? { words.first { $0.track == k }?.words }
        if let micW = wordsOf("mic"), let sysW = wordsOf("system") {   // system words onto the mic clock
            let sysw = sysW.map { Turns.Word(text: $0.text, start: $0.start + sysOff, end: $0.end + sysOff) }
            var m = micW
            if dedup { m = Echo.dedupWords(m, sysw).kept }   // removal failed: drop repeats
            if bleed { m = Echo.dropResidue(m, sysw, gap: gap).kept }   // removal leaves 1-2 word scraps that dedup can't see
            words[words.firstIndex { $0.track == "mic" }!].words = m
        }

        var diar: [String: Voiceprints.Diarization] = [:]
        let diarizer = p.engines.diarizer(); diarizerBox.value = diarizer
        if !p.engines.hasDiarizer { p.log("Speaker separation: not available in this build; each track is one speaker") }
        for (key, ws) in words where !ws.isEmpty && p.engines.hasDiarizer {
            try Task.checkCancellation()
            do { diar[key] = Self.voiceprintDiarization(try await diarizer.diarize(src[key]!)) }
            catch is CancellationError { throw CancellationError() }
            catch { warnings.append("Speaker separation failed on the \(names[key]!) track (\((error as? LocalizedError)?.errorDescription ?? "\(error)")); labelled it as one speaker") }
        }
        mark("diarization")
        try Task.checkCancellation()
        let people = try StorePeople.load(db)
        let assembled = Turns.assemble(wordsByTrack: words, diarByTrack: diar, people: people, attendees: attendees, source: source, bleed: bleed,
                                       offsets: trackOff, labels: labels, participants: (meta["participants"] as? [Any] ?? []).map { "\($0)" },
                                       autoNaming: (meta["auto_naming"] as? Bool) != false, userName: userName, inPerson: inPerson)
        var recs = assembled.recs
        let turns = assembled.turns
        if !assembled.prompt.isEmpty, case .provider(let prov) = p.resolution {
            let prompt = assembled.prompt
            do {
                let reply = try await withTimeout(namingTimeout) { try await prov.complete(prompt: prompt) }
                recs = Turns.applyNaming(recs, reply: reply, allowed: assembled.candidates, snippets: assembled.snippets)
            } catch is CancellationError { throw CancellationError()
            } catch NotesProviderError.cancelled { throw CancellationError()
            } catch { warnings.append("Speaker naming failed: \((error as? LocalizedError)?.errorDescription ?? "\(error)")") }
        }

        mark("naming")
        var play = prepped.mapValues(\.mono)
        if let m16 = w16.first(where: { $0.key == "mic" })?.url, let used = src["mic"], used != m16, let sr = prepped["mic"]?.sampleRate {   // echo removed: play the cleaned mic
            do {   // the cleaned mic is 16 kHz; bring it back to the recording's rate for the mix
                let up = tmp.appendingPathComponent("mic-cleaned-up.wav")
                try ProcessorAudio.resampleMono(used, to: up, rate: sr)
                play["mic"] = up
            } catch is CancellationError { throw CancellationError()
            } catch { warnings.append("Playback audio still has the echo (\((error as? LocalizedError)?.errorDescription ?? "\(error)"))") }
        }
        let audioTmp = tmp.appendingPathComponent("audio.m4a")
        let mixTracks = files.compactMap { f in play[f.key].map { (f.key, $0) } }
        let mixOffsets = Dictionary(uniqueKeysWithValues: prepped.keys.map { ($0, trackOff[$0] ?? 0.0) })
        do { try ProcessorAudio.mixToM4A(tracks: mixTracks, offsets: mixOffsets, dst: audioTmp, tmp: tmp) }
        catch is CancellationError { throw CancellationError() }
        catch {   // the meeting's audio must not be lost to one failed encoder call: start the file again, once
            p.log("AAC mix failed (\(error.localizedDescription)); retrying")
            try? fm.removeItem(at: audioTmp)
            try ProcessorAudio.mixToM4A(tracks: mixTracks, offsets: mixOffsets, dst: audioTmp, tmp: tmp)
        }
        mark("mix")
        let rawDir = try ProcessorAudio.keepRaw(session: session, files: files, extraMeta: choice.meta, log: p.log).path   // before the rename: a failure here leaves no half-made meeting folder
        mark("raw archive")

        // a killed earlier run of this session left a meeting without a folder: replace it, don't duplicate it.
        // Its output folder may exist already (killed between the rename and set_audio): reuse that name, not "(2)".
        var leftover: [String] = []
        for r in try db.rows("SELECT id, pending_folder FROM meetings WHERE raw_dir = ? AND folder IS NULL", [rawDir]) {
            _ = try StoreLibrary.deleteMeeting(db, r.int(0) ?? 0)
            if let pf = r.text(1), !pf.isEmpty { leftover.append(PyPath.norm(pf)) }
        }
        let spk = recs.map { r in
            NewSpeaker(label: r.label, track: isImport ? "room" : r.track, cluster: r.clusterID,
                       personID: (r.kind == .me || r.kind == .auto) ? r.personID : nil,
                       suggestedPersonID: r.kind == .suggest ? r.personID : nil, score: r.score, kind: r.namedBy == "intro" ? "intro" : r.kind.rawValue,  // unlinked and never learned until saved
                       embedding: r.embedding.map { e in e.withUnsafeBufferPointer { Data(buffer: $0) } })
        }
        let mid = try StoreLibrary.addMeeting(db, NewMeeting(title: title, start: startISO, duration: duration, source: source, rawDir: rawDir,
                                                             template: template, attendees: attendees, userNotes: userNotes, summaryStatus: "pending", bleed: bleed),
                                              speakers: spk, turns: turns.map { NewTurn(speaker: $0.speaker, start: $0.start, end: $0.end, text: $0.text) })
        crash(p, "after-add-meeting")
        var stage: String?, renamed = false, final = ""
        do {
            if let w = try await generateAndStore(db, mid, template: template, customText: customText, userName: userName,
                                                  droppyVocab: droppy, resolution: p.resolution) { warnings.append(w) }
            guard let m = try StoreLibrary.meeting(db, mid) else { throw StoreError("no meeting \(mid)") }
            let name = try StoreMirror.folderName(title: m.title, start: m.start)
            final = PyPath.join(outRoot, name)
            var n = 1
            while PyPath.exists(final), !(try reusable(final, leftover: leftover, outRoot: outRoot, db)) { n += 1; final = PyPath.join(outRoot, "\(name) (\(n))") }
            try StoreLibrary.setPendingFolder(db, mid, final)
            var tpl = Array((outRoot + "/.incoming-XXXXXX").utf8CString)
            guard mkdtemp(&tpl) != nil else { throw StoreError("could not create a staging folder in \(outRoot)") }
            let st = String(cString: tpl); stage = st
            try Data(try StoreMirror.renderTranscript(m).utf8).write(to: URL(fileURLWithPath: st + "/transcript.md"))
            try Data(try StoreMirror.renderNotes(m).utf8).write(to: URL(fileURLWithPath: st + "/notes.md"))
            try fm.copyItem(at: audioTmp, to: URL(fileURLWithPath: st + "/" + PyPath.name(final) + ".m4a"))
            if PyPath.exists(final) { try fm.removeItem(atPath: final) }   // the earlier attempt's folder (reusable): the new files replace it
            try fm.moveItem(atPath: st, toPath: final)
            renamed = true
            crash(p, "after-rename")
            try StoreLibrary.setAudio(db, mid, audioPath: final + "/" + PyPath.name(final) + ".m4a", folder: final)
        } catch {   // no half-made meeting: the session dir is kept, so a retry starts clean
            if let stage { try? fm.removeItem(atPath: stage) }
            if renamed { try? fm.removeItem(atPath: final) }   // in place but not recorded: with the row gone nothing would point at it
            _ = try? StoreLibrary.deleteMeeting(db, mid)
            throw error
        }
        mark("notes and folder")
        // voiceprints learn only now: the meeting is complete, so a failed run that gets retried never counts twice
        for (pid, emb) in Voiceprints.learnable(recs, bleed: bleed) {
            do { try StoreVoiceprint.update(db, personID: pid, embedding: emb) }
            catch { warnings.append("Voiceprint not updated: \(error)") }   // the meeting is done; a print that cannot learn is a warning
        }
        do {   // the meeting is complete: whatever goes wrong with retention is a warning, never a failed run
            let days = num(meta["retention_days"])
            if days != 0 {
                var w2: [String] = []
                _ = try StoreLibrary.expireAudio(db, days: Int(days), exclude: [mid]) { try StoreMirror.removePath($0, roots: [outRoot, container], warn: { w2.append($0) }) }
                warnings += w2
            }
        } catch { warnings.append("Audio retention skipped: \(error)") }
        return Result(folder: final, meetingID: mid, warnings: warnings)
    }

    /// EngineDiarization -> Voiceprints.Diarization; clusters keep the order of their first segment (Python's dict order).
    static func voiceprintDiarization(_ d: EngineDiarization) -> Voiceprints.Diarization {
        var order: [String] = []
        for s in d.segments where d.embeddings[s.cluster] != nil && !order.contains(s.cluster) { order.append(s.cluster) }
        return Voiceprints.Diarization(segments: d.segments.map { Voiceprints.Segment(start: $0.start, end: $0.end, cluster: $0.cluster) },
                                       embeddings: order.map { Voiceprints.ClusterEmbedding(cluster: $0, vector: d.embeddings[$0]!) })
    }
}

/// A tiny lock-protected cell, so `process` can unload the engines `run` created even when `run` throws.
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock(); private var v: T
    init(_ v: T) { self.v = v }
    var value: T { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
}
