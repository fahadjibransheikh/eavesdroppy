# Eavesdroppy: Swift port for the Droppy Store

Started 2026-10-13. The user wants to publish to the Store soon. The v1 decisions are D1 to D20 in `build-plan.md`; this file continues at D21.

## Store constraints (checked 2026-10-13 in `~/code/droppykit`)

- `Package.swift` may depend on DroppyKit alone (`Documentation.docc/Submitting.md`). FluidAudio cannot be a package dependency.
- A droplet is a dynamic library that runs inside Droppy's process, with no sandbox. Long work must stop on `deactivate()`.
- The Store pipeline builds a universal binary and signs it. A thin binary fails `validate`.
- Review sends back capabilities you don't use, design that ignores the surface, work that outlives `deactivate()`, and live activities that never yield.
- System frameworks are not package dependencies: `SQLite3` (with FTS5), Accelerate, AVFoundation, EventKit, Security and FoundationModels are all allowed.

## Decisions

| # | Decision | Why / alternative |
|---|---|---|
| D21 | Ask Droppy's maintainers first: allow FluidAudio as a dependency, or expose Droppy's own Parakeet and diarizer to droplets. Draft: `droppy-maintainer-request.md`. Port everything else meanwhile, behind a `Transcriber` protocol. | User choice, 2026-10-13. Fallbacks if they say no: vendor the FluidAudio source (Apache-2.0), or use Apple SpeechAnalyzer (accuracy not measured, and it has no diarization). |
| D22 | Everything runs in-process. Heavy stages run on a detached `Task` at `.utility` priority, are cancelled in `deactivate()`, and resume from the kept raw session on the next launch. | The CLI contract with Python goes away. A crash during processing loses no audio, because the raw FLACs are kept (as in v1). |
| D23 | Swift becomes the only writer of `library.db`, using the system `SQLite3` C API. The schema stays v4 and existing libraries open unchanged. | This reverses D1, because there is no Python in the Store build. |
| D24 | Notes and Ask providers, picked in Settings › Notes, in the user's order: Claude Code CLI (`claude -p`), OpenAI Codex CLI (`codex exec`, final message via `-o`), Grok Build CLI (`grok -p`), Apple Intelligence (FoundationModels, chunked summarise-then-merge because the context is small), or an API key (Anthropic, OpenAI or xAI, stored in the Keychain). Installed CLIs are detected by path. If no provider is available, the meeting is saved with its transcript only. | User: "people should be able to connect whatever AI subscription they use". Each CLI's flags must be checked against `--help` on a real install before shipping. Codex isn't installed on this Mac. |
| D25 | Port the MCP server into the droplet as a Streamable HTTP server on 127.0.0.1 with a per-install bearer token, using the `network-server` capability. The four tools stay the same. Settings shows the `claude mcp add --transport http …` line to copy. | User choice. A stdio server needs an executable, and a droplet is a dylib. |
| D26 | The Drive mirror becomes an output folder picked by the user, defaulting to `~/Documents/Eavesdroppy`. This Mac's existing Drive path carries over. | Store users don't share this Drive path. |
| D27 | Echo: A/B Apple's voice-processing AEC at capture time (`setVoiceProcessingEnabled`) against LocalVQE on the kept test fixtures. Ship Apple's if it is within tolerance. Otherwise, ask the maintainers about vendoring LocalVQE's C code. | LocalVQE is C++ with ggml, so it can't be a dependency. Apple's AEC is free, but it may duck other audio or colour the mic. |
| D28 | The Python pipeline stays in the repo as the reference: golden tests run both implementations on the same fixtures and compare turns, speakers and the prompt text. | A port without an oracle drifts silently. |

## Port mechanics (2026-10-13)

- **Seam:** the droplet already reaches the pipeline only through `Pipeline.run(args)` / `Pipeline.submit` (`Sources/Eavesdroppy/Pipeline.swift`). Each subcommand returns a JSON envelope. The port adds native Swift handlers for those same subcommands, with the same envelope. A cut-over then routes them in-process one at a time, falling back to Python until every command is native. The UI code doesn't change.
- **New code** goes in `Sources/Eavesdroppy/Port/`. Each area owns its files, so parallel work never touches the same file:
  - `Store*.swift`: SQLite writer and reader, schema, mirror, library subcommands. This is the library area.
  - `Turns.swift`, `Echo.swift`, `Voiceprints.swift`: the pure logic area.
  - `Notes*.swift`, `Providers/`: the notes and AI providers area.
  - `Engine*.swift`: the engine area. It is the only area that edits `Package.swift` dependencies.
- **Golden tests:** `Tests/EavesdroppyTests` (swift-testing; run with `swift test` in `eavesdroppy/`). Fixtures go in `Tests/EavesdroppyTests/Fixtures/`. They are JSON produced by running the Python functions, plus a generator script `tools/golden/*.py` so fixtures can be regenerated.
- **Personal vs Store build:** FluidAudio is linked only when `EAVESDROPPY_PERSONAL=1` is set at build time (Package.swift reads the environment), and code uses `#if canImport(FluidAudio)`. A Store build compiles without it and reports that transcription is unavailable, until D21 is answered.

## Phases

Each phase ends with `droppykit build` and `validate` green, plus its golden tests green.

1. **Library:** a Swift SQLite layer (writes, FTS5 search, migrations, mirror rendering), with parity tests against `library.py` on a copy of a real `library.db`.
2. **Pure logic:** `build_turns`, the bleed-residue rule, dedup, bleed detection (Accelerate), speaker assignment and voiceprint maths. Golden tests compare against the Python output.
3. **Providers:** the D24 provider protocol, notes and Ask prompts ported from `notes.py`, and a Settings picker with detection.
4. **MCP:** D25.
5. **Engine:** depends on the D21 answer. FluidAudio in-process, or the fallback.
6. **Echo:** the D27 A/B test.
7. **Cut-over:** remove Python from the runtime, write `CHANGELOG.md`, set `creator.gitlab`, run `droppykit submit`, and do a real-path test in Droppy before the merge request.

## Risks

- **D21 is the gate.** If the maintainers refuse and vendoring is unacceptable, accuracy (the user's top priority) depends on SpeechAnalyzer, which hasn't been measured.
- **Spawning the user's CLIs from Droppy's process** may draw review questions. This is asked in the maintainer request.
- **Crash and slowdown blast radius:** in-process processing means a crash in ASR, diarization or echo removal takes down all of Droppy, and heavy work can make the notch feel sluggish. Before cut-over, the processor must pass these checks:
  - process a 60-minute fixture while the notch and shelf are being used, with no visible hitching;
  - hold the work at `.utility` priority with a capped number of concurrent jobs;
  - show that a forced crash mid-job (debug flag) leaves the raw session to retry on the next launch.
  - Ask the maintainers whether droplets may run work out of process (an XPC service or a helper). Until the D21 answer, the personal build can keep the Python subprocess path as an opt-in fallback.
- **In-process ASR memory:** Parakeet is about 460 MB of CoreML models loaded into Droppy's process. The models must be unloaded after each meeting.

## Cut-over to-do (from the port reports)

- Done: Drive-offline delete. Python already caught it; the bug was Swift-only and is fixed in `StoreMirror.removePath`, with tests.
- Dispatch only the commands where `StoreCommands.handles(_:)` is true. Pass `outRoot` explicitly; otherwise `~/Documents/Eavesdroppy` gets created. `set-user-notes` takes its text through `stdin:`.
- Wire `ProviderSettingsSection` into `SettingsPages.swift`. The three hooks are in the notes area's report; summary: a `providerSettings` model on the droplet, a section in NotesPage, and a search entry.
- Before shipping each provider: a live test of Grok after `grok login`, and a live test of Codex once it's installed (check that its read-only sandbox has no network).
- De-duplicate after the merge: `StoreVoiceprint.update` and `Voiceprints.updatePrint` (keep one, the BLAS `cblas_sdot` version that matches numpy), and the `neutralizeFences` copies in Voiceprints and NotesPrompt.
- Callers must pass `people` in id order and `Person.name` as "" for NULL (Voiceprints contract).

## Engine finding (2026-10-13)

FluidAudio can't be a normal package dependency, even for the personal build:
- `droppykit build` compiles with `-enable-library-evolution`, and FluidAudio's streaming diarizer then fails on Swift 6.4 (`consume` errors).
- `build-droplet.sh` links only local targets.

The personal build instead vendors FluidAudio e560c64 with `tools/vendor_fluidaudio.sh` and `tools/fluidaudio-resilience.patch`, into the git-ignored `eavesdroppy/Vendor/`. The targets are added when `EAVESDROPPY_PERSONAL=1`.

Results on the 65 s real recording and a synthetic three-voice track: in-process output equals the CLI's exactly (WER 0, identical diarization). Validate passes in both modes. Loading the personal bundle in real Droppy is still untested.

This feeds D21: vendoring is also the likely Store route if the maintainers decline the other options.

## Cut-over (2026-10-13, branch port/processor)

Done: the processor, every subcommand and the routing are native; the Python pipeline remains as the oracle and, in the personal build only, an opt-in fallback.

| # | Decision | Why / alternative |
|---|---|---|
| D29 | `Port/Processor.swift` is `process_meeting.process()` stage for stage (same warning texts). `Pipeline.run` and `processSession` call it in-process; `Pipeline.usePython` ("Use Python pipeline (fallback)", personal build, default off) routes everything back to `process_meeting.py`. The Store build has no spawn code. | The seam from "Port mechanics" worked: the UI is unchanged. |
| D30 | A session is resumed on the next activation when its `.processing` marker says a run was interrupted (quit, or crash), at most twice (`maxAutoAttempts`); a deactivation cancel does not count. After that it shows as Failed for a manual Retry. | A job that crashes the process must not crash Droppy on every launch. The marker is the only state: it holds the number of starts that did not end cleanly. |
| D31 | The Output folder setting (D26) is `Prefs.outputFolder`; empty means this Mac's Drive meetings folder if its mount is there, else `~/Documents/Eavesdroppy`. It is passed to every command (`outRoot`), including the Python fallback. Existing meetings keep their folders. | |
| D32 | Notes, Ask and speaker naming use the provider chosen in Settings (D24). With no provider the naming step is skipped silently and the notes carry the status text, instead of Python's "Speaker naming failed: claude ..." warning. | Python hardcoded `claude -p`. |

Gate results are in the cut-over report (golden comparison, crash test, long-fixture measurements). Still open: D21 (FluidAudio in the Store build), D27 (Apple AEC vs LocalVQE in the Store build), D25 (MCP), live tests of Grok and Codex.

## Apple speech engine and meeting language (2026-10-14, after `stt-model-selection-2026-10-14.md`)

Two engines only: Parakeet (FluidAudio, personal build) and Apple's `SpeechTranscriber` (Speech framework, macOS 26 or later; a system framework, so it is in the Store build too and is its only engine). One engine per meeting, never word-level mixing.

| # | Decision | Why / alternative |
|---|---|---|
| D33 | Setting "Meeting language" (Settings › Recording, default Auto; per-recording override in the notes window, next to the template menu): Auto, English, Urdu/Hindi + English. English → Parakeet. Mixed → Apple `mul_IN` for every track. Auto → D34. If Apple is unavailable (macOS < 26): personal falls back to Parakeet (mixed adds a warning), Store fails the meeting with "Transcription needs macOS 26 or later". `Port/Language.swift` (`Routing`), `Processor.chooseEngine`. | User decision. "Re-transcribe as…" later is not built: it needs raw FLAC → session reconstruction and a DB replace, which is not cheap. |
| D34 | Auto = run Apple `mul_IN` on the first 180 s of speech (0.5 s windows above a tenth of the track's 90th-percentile level, joined) of each track that has signal, and score the share of tokens that are common romanized Urdu/Hindi function words (`LanguageDetector.functionWords`, 54 words; English-ambiguous ones such as "main", "to", "is" left out). Share ≥ **2 %** with ≥ 40 tokens → the whole meeting goes to Apple `mul_IN`, else English. Measured: English 0.00 % on three samples (435 words); the two real mixed sessions 15.5 to 34.5 % in all 14 of the 300 s windows that had speech (13 mic windows and one call-audio window) (first-180 s window: 18.4 % and 15.5 %). The threshold sits far below the lowest mixed window on purpose: a false "mixed" costs speed and vocab biasing, a false "English" costs the Urdu. Cost: about 4 to 7 s per track, once. | Unmeasured: a mostly-English meeting with a few Urdu words (3 to 10 %). It would be called mixed, which Apple handles fine. |
| D35 | Store build English engine: Apple `mul_IN` (not `en_US`). Against Parakeet as the reference, word disagreement on three English clips: `mul_IN` 1.3 / 14.3 / 3.2 %, `en_US` 4.0 / 20.8 / 2.7 %; the two Apple locales agree with each other at 4.1 / 8.7 / 2.3 %. Same speed (1.0 to 1.2 s for 65 to 73 s). One locale also means one asset and a detection pass that can be reused. | No ground truth: these are mutual distances. |
| D36 | Urdu/Hindi always comes out in Latin script: after transcription, every word with an Arabic-script (U+0600–06FF, 0750–077F, FB50–FDFF, FE70–FEFF) or Devanagari (U+0900–097F) character goes through `applyingTransform(.toLatin)` + `.stripDiacritics`, ICU leftovers (dotted circle, aspiration mark, Arabic punctuation) are cleaned, and the count is logged ("Roman script: N of M words transliterated"). Apple `mul_IN` produced Latin on every test clip (count 0 in all real runs), so this is a guarantee, not a path that runs. Perso-Arabic loses short vowels ("نہیں" → "nhy"). | `RomanScript` in `Port/Language.swift`. |

Details that are easy to get wrong:

- The meeting's engine and language are written into the **raw archive's** `meta.json` (`transcript_language`, `stt_engine`, `stt_locale`, `stt_reason`), never the session's. `notes.md` / `transcript.md` get `- **Language:** Urdu/Hindi + English (Apple)` or `English (Parakeet)` below the Setting line, read from the archive like the Setting line and carried forward from the old file once the raw audio expires. `import-drive` now drops the Setting and Language bullets from the imported notes text (library.py leaves them in).
- Apple assets: `AssetInventory.assetInstallationRequest(supporting:)` returns nil when installed and **reserves the locale as a side effect** (reservations are per executable and persist; max 5). Nothing calls `reserve` by hand and nothing releases. A missing asset is downloaded with "Downloading speech model… N %" in the processing row (639 MB for `mul_IN`, about 97 s on this Mac). With Auto as the default, every personal-build user downloads it on their first meeting.
- No `speech-recognition` capability and no permission call: `SpeechTranscriber` ran on this Mac with `SFSpeechRecognizer.authorizationStatus() == .notDetermined`, so on-device file analysis is not gated by that permission. Unverified inside Droppy.
- No diarizer in the Store build: each track is one speaker ("Me" / "Them", or "Room" for an in-person meeting). The processing log says so; there is no user-visible warning.
- Apple ignores the Droppy dictionary / attendee vocabulary (`hotwords`); Parakeet still uses them.
