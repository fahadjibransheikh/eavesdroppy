# Changelog

## [1.0.0] - 2026-10-12

- First release as Eavesdroppy (formerly the local "Meetings" droplet; new id `eavesdroppy`).
- Sessions and raw tracks in the old `meetings` container move across on first launch.
- Import recording: drop an audio/video file on the widget or use "Import recording…".
- Recording is safer: meta.json is written at start, device changes restart the mic, silent call audio and disk-full are reported, Failed rows can be deleted and show the pipeline's error.
