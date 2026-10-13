# Eavesdroppy: build plan and decision log

Started 2026-10-12. The user asked for autonomous build-out: plan, develop everything, make decisions, review at the end. Real-path tests (recordings in main Droppy) are deferred to that review. Scope: `v1-scope.md`.

## Architecture

- **Droplet (Swift, `eavesdroppy/`)** draws UI and captures audio. It runs inside Droppy's process, so it does no heavy work.
- **Pipeline (Python, repo root)** does everything else as subprocesses, and is the only writer of the library.
  - `process_meeting.py` is the CLI entry point. Subcommands are added for library writes: rename meeting, rename speaker, regenerate notes, ask, enroll, export action items.
  - Modules, one per concern so agents can work in parallel: `library.py` (SQLite), `speakers.py` (diarization, voiceprints), `echo.py` (bleed detection, AEC), `notes.py` (Claude prompts, templates, Ask), `mcp_server.py`.
- **Library:** `<container>/library.db`, SQLite in WAL mode with FTS5 (stdlib sqlite3; FTS5 verified present).
  - The droplet reads it with the system `SQLite3` C API, off the main thread, read-only.
  - Writes go through pipeline subcommands, so the logic lives in one tested place.
- **Drive mirror:** `<Drive>/<YYYY-MM-DD HHMM – Title>/` holds `notes.md`, `transcript.md` and `<folder name>.m4a`. The database is the source of truth. The mirror is re-rendered after every edit.

## Decisions (review these)

| # | Decision | Why / alternative |
|---|---|---|
| D1 | Python owns the schema and all writes; Swift reads only | One writer avoids lock fights and keeps logic testable. Alternative: Swift writes directly. |
| D2 | Diarize both tracks. "Me" = the cluster matching the enrolled voiceprint. Without enrollment, a recording's dominant mic cluster = Me and an import has no Me. | User asked for in-person support. |
| D3 | Voiceprint match on cosine: ≥0.75 auto-names, 0.60–0.75 suggests, <0.60 is a new person | Thresholds come from synthetic voices. Recalibrate on the first ~5 real meetings. |
| D4 | Voiceprints update as a running mean, only from no-bleed tracks, and only when the user confirms the name or the match is ≥0.75 | Echo must not pollute prints (pasrom quarantine pattern). |
| D5 | Enrollment: a 20–30 s read-aloud sample from settings, stored as person "Me" | User request. It improves over time via D4. |
| D6 | Echo removal is on by default, gated by the coherence bleed detector (threshold 0.02). Text dedup is only a fallback when the self-check fails. | Near-transparent on headphones in tests. A toggle is in settings. |
| D7 | Engine: FluidAudio CLI with Droppy's Parakeet model (symlink dir) and Droppy's dictionary | User request. No duplicate model, no own vocab. |
| D8 | Notes provenance: transcript turns are numbered for Claude, and each bullet cites `[T12]`, rendered as `[12:03]` links. In the UI, tapping one plays the audio from that point. | Granola-style provenance without a custom model. |
| D9 | Typed notes go in the shelf widget or the expanded surface (setting, default widget), saved live to `session/notes.txt` | User request. Survives crashes. |
| D10 | Templates are prompt presets in `notes.py`: General (default), 1:1, Standup, Sales, Interview, Custom (free text in settings). Regenerate via subcommand. | The user deferred template details, so these are defaults. |
| D11 | Calendar: EventKit through `host.permissions(.calendars)`. Notch prompt at T-1 min for events with a video link or attendees. Never auto-starts silently. | Granola pattern. Optional auto-start is a setting, default off. |
| D12 | Mic-in-use prompt: watch `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default input. Prompt once per mic session when no recording is running. Ignore Droppy's own dictation by checking process objects. | Catches ad-hoc calls. |
| D13 | Auto-stop: when no call app has had audio input running for 60 s, show a notch countdown, then stop (setting) | Avoids hour-long empty tails. |
| D14 | Ask: retrieve with FTS5 (top segments + notes), then `claude -p --tools ""`. The answer cites meeting and timestamp. | Local, no embeddings index needed for v1. |
| D15 | Reminders through EventKit in the droplet (`.reminders` permission), into a list called "Eavesdroppy" | No leader has this. List name is a setting. |
| D16 | Linear through a GraphQL API key entered in settings and stored in the Keychain. A team picker is shown on first export; it also asks each time unless a default is set. | The user said Linear "sounds good". No Composio dependency inside the product. |
| D17 | MCP as a stdlib-only stdio server, `mcp_server.py`, reading `library.db` read-only. Tools: `search_meetings`, `get_meeting`, `list_action_items`, `ask`. | The SDK's MCP surface isn't in v1.20.1. The user registers it with one `claude mcp add` command, given at review. |
| D18 | Accessibility speaker names: best effort for Zoom and Teams desktop via AX participant lists. Meet in a browser only if its AX tree exposes names. Names feed the D3 arbitration as candidates, never as ground truth. | Fragile by nature. Last phase. |
| D19 | Settings: one settings page per area (Recording, Speakers, Notes, Calendar, Output, Storage) via `SettingsPagesProviding` | User wants toggles for everything. |
| D20 | Audio retention: kept forever by default. Options are 30, 90 or 365 days; expiry deletes the m4a and raw FLACs, never the notes or transcript. | User OK'd. |

## Phases

Each phase ends with `droppykit build` and validate green and Python tests green. A real-path test happens at the final review.

0. **Running:** rename, review fixes, import (Swift); pipeline fixes, Droppy model and vocab (Python).
1. **Engine:** `speakers.py` (diarize both tracks, voiceprint store, enrollment, Me logic, Claude arbitration with attendees), `echo.py` (bleed detect, AEC, self-check).
2. **Library:** `library.py` schema, migration of existing Drive meetings (optional import), subcommands, re-render mirror. Swift browser in the expanded surface: list, search, meeting detail, speaker rename, audio playback from a line.
3. **Notes:** typed-notes editor (widget or expanded surface), enhanced notes with provenance, templates, regenerate.
4. **Calendar and auto:** event prompt, mic-in-use prompt, auto-stop, consent line, enrollment UI.
5. **Out:** Ask UI, Reminders, Linear, MCP server.
6. **Accessibility speakers.**
7. **Settings pages** for all of the above. Each phase adds its own settings; this phase just tidies them.

## Not doing without the user

- Posting the two feature requests to The Trench. They're drafted in the conversation.
- Deleting `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3` (461 MB duplicate). It'll be deleted once the pipeline is verified on Droppy's model during review.
- Installing the build into Droppy, and any real recordings.

## Pipeline CLI contract (Swift ⇄ Python)

Invocation: `.venv/bin/python process_meeting.py <args>` with cwd = repo. Env: `EAVESDROPPY_OUT_ROOT`, `EAVESDROPPY_CLAUDE_BIN`, `EAVESDROPPY_LINEAR_KEY` (Swift reads it from the Keychain and passes it only to Linear subcommands). Every command prints exactly one final stdout line of JSON on success (exit 0). On failure, it exits non-zero and the last stderr line is `ERROR: <reason>`. The library is at `<container>/library.db`. Every subcommand takes `--container <dir>`. Swift reads the db read-only and never writes it.

| Command | Result JSON |
|---|---|
| `<session_dir>` (process a recording or import) | `{"folder", "meeting_id", "warnings": []}` |
| `rename-meeting ID TITLE` | `{"ok": true}` |
| `rename-speaker SPEAKER_ID NAME [--person-id N] [--new-person]` (also confirms the voiceprint) | `{"meetings": [ids]}` |
| `regenerate ID [--template T] [--custom-text-file F]` | `{"ok": true, "warnings": []}` |
| `set-user-notes ID [--clear]` (text on stdin) | `{"ok": true}` |
| `ask QUESTION [--meeting-id N \| --person-id N]` | `{"answer": "..."}` |
| `delete ID` | `{"ok": true}` |
| `set-action-done ACTION_ID [--undone]` | `{"ok": true}` |
| `set-action-exported ACTION_ID TARGET EXTERNAL_ID` | `{"ok": true}` |
| `linear-teams` | `{"teams": [{"id", "name", "key"}]}` |
| `linear-export ACTION_ID --team TEAM_ID` | `{"id", "identifier", "url"}` (idempotent, see below) |
| `enroll WAV [--name=NAME]` | `{"person_id", "seconds"}` |
| `import-drive` | `{"imported", "skipped", "failed"}` |
| `expire-audio DAYS` | `{"deleted": n}` |

Session additions written by Swift: `notes.txt` (typed notes, saved live) and meta.json keys `template` and `user_notes_file`. Settings flow from Swift to Python through meta.json keys: `echo_removal` (bool), `template`, `retention_days`, `auto_naming` (bool), `participants` (call-app names read via Accessibility, used as naming candidates only), `user_name` (the "Your name" setting) and `custom_template_file`.

Implementation notes (pipeline, 2026-10-12): `--out-root DIR` is accepted by every command (default `$EAVESDROPPY_OUT_ROOT`). `<session_dir>` as the first argument is the same as `process <session_dir>`; `--container` defaults to `session/../..` there and is required elsewhere. `import-drive` also returns `ids` and `errors` next to the three counts. `--summary-only` is gone: `regenerate` replaces it. `rename-speaker` links a person only through `--person-id` / `--new-person`; with neither it relabels that one meeting's speaker and leaves any linked person alone. `regenerate` keeps the existing notes (and warns) when Claude fails on a meeting whose notes were fine; `--custom-text-file` must be passed on every regenerate with the custom template.

Review fixes (pipeline, 2026-10-12), contract changes for the Swift side:

- **User name.** meta.json `user_name`, or `--user-name NAME` on any command (the flag wins), replaces the built-in "Fahad" in notes and Ask prompts and in dropping the user from the naming candidates. `regenerate` and `ask` have no meta.json, so Swift must pass `--user-name` to them or they fall back to "Fahad". The user's own attendee entry is dropped only on a full-name or email match (or a bare first name), so set the full name: with only "Fahad" known, "Fahad Sheikh" stays a naming candidate.
- **Custom template.** meta `custom_template_file` (a path relative to the container, or absolute) is read when `custom_template` is absent. It must resolve inside the container; otherwise a warning is returned and General is used.
- **`set-user-notes ID`** refuses empty or whitespace stdin (and a tty) with `ERROR: no text on stdin`, so a caller bug cannot blank the notes. Pass `--clear` to empty them on purpose.
- **`enroll`** deletes the WAV after a successful enrollment only if it is under `<container>/enroll/` (kept on failure so the user can retry). Pass the name as `--name=NAME`: argparse reads `--name -x` as a flag and returns `ERROR: bad arguments`. The same applies to any positional that may start with "-" (`rename-speaker` NAME, `rename-meeting` TITLE): put `--` before the positionals, or the command fails with `ERROR: bad arguments`.
- **`linear-export`** is idempotent: if the action is already exported to Linear it makes no API call and returns the stored `{"id", "identifier", "url"}`. The Linear UUID is not stored, so on a repeat `id` equals `identifier`. `url` is `""` for items exported before schema v3. Swift only reads `identifier` and `url`.
- **Schema** is now v4. v3 adds `action_items.external_url` (the Linear issue URL; NULL for older rows and for Reminders). v4 adds `meetings.pending_folder` (internal to processing; readers ignore it). Both are additive and Swift's explicit column lists are unaffected.
- **Retention** (`retention_days`, `expire-audio`) counts from `meetings.created` (when the meeting was processed), not `start`, so an imported old recording keeps its audio for the full period, and the meeting processed in the current run is never expired. Files are deleted first and a database column is cleared only for a path that is gone; a failed delete (Drive offline, outside the safety roots) leaves the reference and a warning, and the next run retries. In a processing run any retention error (including a bad `retention_days`) is a warning in `warnings`, never a failed run.
- **`rename-speaker`** also replaces the old label by the new name in that meeting's `notes_md` and action-item owners (whole word, case-sensitive; no Claude call), and for `--person-id` in every other meeting where the person's speaker had a different label. `--person-id N` does not rename the person row; it only links the speaker, relabels the person's other speakers and teaches the voiceprint.
- **Processing** records the Drive folder it is about to rename into place; a retry after a kill reuses that folder instead of creating "(2)". Voiceprints learn only after the meeting is complete, so a failed and retried run never counts twice.
