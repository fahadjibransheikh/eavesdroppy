# Eavesdroppy droplet: v1 scope

Status: signed off 2026-10-11; revised 2026-10-12 (name, items 5, 8, 10, 11, settings). Sources: `commercial-notetakers.md`, `oss-meeting-recorders.md`, plus the diarization and ASR benchmarks run this session (scratchpad; numbers summarized below).

## Engine decisions (measured)

| Decision | Evidence |
|---|---|
| ASR: FluidAudio CLI + Parakeet TDT v3, replacing `fermion` | Meeting-like WER 15.9% vs 22.7% (fermion drops sentences in 30 s windows); 9.5 s vs 48 s on 37 min; ~0.3 GB vs ~14 GB peak. Same model Droppy dictation uses, already cached. |
| Name spelling: FluidAudio custom vocab, flags `--vocab-disable-spotter-rescue --vocab-min-similarity 0.6` | Names exact 29/66 → 53/66, 2 false positives in 20 min of no-name audio. `fermion --hotwords` is a silent no-op today. Default vocab flags are unsafe (+7 pt WER). |
| Diarization + voiceprints: FluidAudio offline VBx, `--min-segment-duration 0.3` | Correct speaker count 4/4 fixtures, DER 1.3–9.2%, RTF ~0.006. Cross-meeting same-speaker cosine 0.97+, different ≤0.48 (synthetic voices; calibrate on real audio). |
| Echo: raw mic capture (no VPIO) → bleed detector → LocalVQE v1.4-AEC post-hoc with system.wav as reference → self-check; text dedup only as fallback; no mic voiceprints from bleed meetings | pasrom/meeting-transcriber design; VPIO conflicts with the process tap and ducks other apps. Unproven: A/B on our own recordings before enabling by default. |

One engine (FluidAudio, Apache-2.0; diarization models CC-BY-4.0, needs attribution) covers ASR, vocab, diarization and embeddings.

## v1 features

Your picks are marked ★.

**Capture**
1. Bot-free mic + system audio, manual start/stop, auto-stop when the call app releases audio.
2. Echo fix (above), with an option to keep raw tracks.
3. ★ Calendar: notch prompt 1 min before an event with Record; title and attendees prefilled. Plus a mic-in-use prompt for unscheduled calls (Granola's pattern; no silent auto-start).
4. Consent reminder (one line when recording starts).

**Speakers**
5. ★ Diarization on both tracks. "Me" is whoever matches the user's enrolled voiceprint, not the mic track, so in-person meetings work. Enrollment: record a short voice sample in settings; the print improves from later clean (no-bleed) meetings.
6. ★ Voiceprint memory: auto-name known people; name a new speaker once in the library and it sticks. Claude arbitrates with calendar attendees (Biscotti pattern).
7. Named speakers from Zoom/Meet/Teams participant UI via Accessibility (Granola's method). Fragile across app updates; last v1 phase.

**Notes**
8. Typed notes during the meeting (where they live is a setting: persistent shelf widget like Droppy's media widget, or the notch expanded surface), merged with the transcript into enhanced notes; every bullet links to its transcript timestamp (Granola's core feature).
9. Templates (1:1, standup, sales, interview, custom), switchable and regenerable after the call.
10. No separate vocabulary: read Droppy live transcribe's dictionary (`voiceTranscribe_customVocabulary` in `iordv.Droppy` defaults, `canonical` + `variants` map to FluidAudio `Term: alias`). Reuse its Parakeet model (`Droppy/Extensions/voiceTranscribe/models/parakeet/parakeet-tdt-0.6b-v3`, path in `runtime-state.json`) via `--local-model-dir`; verified identical output on AMI 2026-10-12. Download only if live transcribe isn't installed. Diarization (21 MB) and vocab CTC (98 MB) models aren't in Droppy and still download.

**Library**
11. ★ Local library: SQLite + FTS5 in the droplet container as source of truth; Markdown + m4a mirrored to the Drive folder. Audio kept by default, retention is a setting; files named after the meeting.
12. ★ Browse/search in an expanded surface; rename meetings, fix speaker names (re-renders notes and updates voiceprints), play audio from a transcript line.

**Out**
13. ★ Ask: Claude across all meetings, one meeting, or a person, with citations to meetings and timestamps.
14. ★ Action items to Reminders (no leader has this) and Linear.
16. Settings for every behaviour above (notes location, calendar prompts, retention, echo removal, auto-stop, consent line, Linear target).
15. MCP tools (search, get meeting, list action items), so Claude Code and other agents can query meetings. Every leader ships MCP. `MCPToolProviding` is in the online docs (1.21.0) but not in the latest SDK release (v1.20.1, checked 2026-10-11); until it ships, a small standalone MCP server over the SQLite library.

## Roadmap (after v1)

Live transcript, screen recording, pre-meeting brief, people/company pages, follow-up email drafts. Skipped: bots, team sharing, CRM, mobile, sales analytics.

## Build order

Each phase ends with a real-path test in main Droppy.

1. **Pipeline engine:** FluidAudio ASR + vocab, diarization, voiceprint store, echo pipeline with A/B harness. Python and offline-testable. Needs 2 raw recordings from you (speakers and headphones).
2. **Library:** SQLite schema, Drive mirror, expanded-surface browser, search, speaker rename.
3. **Notes:** in-meeting typed notes, enhanced notes with provenance, templates, regenerate.
4. **Calendar and auto:** event prompt, mic-in-use prompt, auto-stop, consent line.
5. **Out:** Ask, Reminders, Linear, MCP tools.
6. **Accessibility speakers.**

## Risks

- Typing notes in a notch surface may feel cramped. The expanded surface is the fallback; test early in phase 3.
- Echo cancellation may hurt your own voice (heed measured that with WebRTC AEC3). The A/B gates the default.
- Voiceprint thresholds come from synthetic voices. Calibrate on your first ~5 real meetings before auto-naming without confirmation.
- Droppy runs droplets in-process, so a crash takes Droppy down. Heavy work stays in the subprocess pipeline.
