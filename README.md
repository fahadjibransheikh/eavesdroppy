# Eavesdroppy

Bot-free meeting notes for Mac, built as a [Droppy](https://getdroppy.app) droplet. It records your microphone and the call's audio, transcribes on-device, works out who spoke, and writes notes with the AI you already use. No bot joins the call, and audio never leaves your Mac unless your chosen notes provider is a cloud one.

## What it does

- **Record** from the shelf widget, the menu bar item, or the ⌥⌘N "Open Eavesdroppy" shortcut. It also offers to record before calendar events and when a call app starts using the microphone. A live activity shows the timer in the notch.
- **Type your own notes** while you talk, in the notch or the menu bar. They are merged into the generated notes and marked "(from your notes)".
- **Transcribe locally** with Parakeet (via [FluidAudio](https://github.com/FluidInference/FluidAudio)), reusing Droppy's own model and custom dictionary.
- **Remove speaker echo** when you're on speakers instead of headphones (LocalVQE), so the call isn't transcribed twice.
- **Separate and name speakers.** Teach it your voice once, rename "Speaker 2" once, and it recognises that person in later meetings.
- **Write notes** from a template (General, 1:1, Standup, Sales, Interview, or Custom with your own instructions) with summary, decisions, action items and open questions, each linked to a timestamp.
- **Browse and search** every meeting, play audio from any line, and ask questions across meetings.
- **Send action items** to Reminders or Linear.
- **Mirror** each meeting as `notes.md`, `transcript.md` and an `.m4a` into an output folder you choose (a Google Drive folder works).
- **MCP server** (off by default) so Claude Code or Cursor can search your meetings: localhost only, with a bearer token.

## Notes providers

Picked in Settings › Notes › AI provider. "Automatic" uses the first one available, in this order:

1. Claude Code CLI (`claude -p`)
2. OpenAI Codex CLI (`codex exec`)
3. Grok Build CLI (`grok`)
4. Apple Intelligence (on-device)
5. An API key for Anthropic, OpenAI or xAI, kept in the Keychain

If you pick a specific provider and it isn't available, the meeting is saved with its transcript only. Meeting text never goes to a provider you didn't choose.

## Status

| Part | State |
|---|---|
| v1 (Python pipeline driven by the droplet) | Working; used daily |
| Swift port of the whole pipeline | Merged; golden-tested against Python; first real-meeting test pending |
| Droppy Store release | Blocked on [DroppyKit #3](https://gitlab.com/droppyformac1/droppykit/-/work_items/3): Store droplets may depend on DroppyKit alone, so FluidAudio needs the maintainers' approval |

## Repository layout

| Path | What it is |
|---|---|
| `eavesdroppy/` | The droplet: a Swift package built with DroppyKit. The native pipeline is in `Sources/Eavesdroppy/Port/`. |
| `process_meeting.py`, `echo.py`, `speakers.py`, `library.py`, `notes.py`, `mcp_server.py` | The v1 Python pipeline. It is now the fallback (Settings › Storage › Use Python pipeline) and the reference the Swift golden tests compare against. |
| `tools/` | Build scripts for FluidAudio and LocalVQE, the FluidAudio vendoring script, and `golden/` fixture generators. |
| `research/` | Plans and decisions: `build-plan.md` (D1–D20), `swift-port-plan.md` (D21 onward), reviews and market notes. |

## Building

Requirements: macOS with Xcode's Swift toolchain, Droppy 15.3 or later, and a [DroppyKit](https://getdroppy.app/docs/droppykit) checkout for the `droppykit` command.

**Personal build** (FluidAudio compiled in, so transcription works):

```bash
tools/vendor_fluidaudio.sh                  # fills eavesdroppy/Vendor/ (git-ignored)
cd eavesdroppy
EAVESDROPPY_PERSONAL=1 droppykit build      # writes .build/Eavesdroppy.droplet
EAVESDROPPY_PERSONAL=1 droppykit validate
```

Install it from Droppy › Settings › Store › Local droplets.

**Store build** (no FluidAudio; transcription reports as unavailable until DroppyKit #3 is resolved):

```bash
cd eavesdroppy && droppykit build && droppykit validate
```

Echo removal needs the LocalVQE binary: `tools/build_localvqe.sh`.

## Testing

```bash
cd eavesdroppy
swift test                                  # Store mode
EAVESDROPPY_PERSONAL=1 swift test           # personal mode, includes engine equivalence (~5 min)
```

Switching between the two modes in one build directory can leave a stale module cache ("unable to resolve module dependency: 'FastClusterWrapper'"). Use `--scratch-path` for one of them.

The Python pipeline has its own suites, run from the repo root with the project virtualenv (`requirements.lock`):

```bash
.venv/bin/python test_process_meeting.py
.venv/bin/python test_library_notes.py
.venv/bin/python test_speakers_echo.py
```

Golden fixtures are regenerated from the Python reference with the scripts in `tools/golden/`.

## Data

Everything lives in the droplet's container (`~/Library/Application Support/Droppy/Droplets/eavesdroppy/Container`): `library.db` (SQLite, schema v4, with full-text search), raw sessions while they're processed, and the audio cache. Raw audio is kept until processing succeeds, so a crash never loses a recording.
