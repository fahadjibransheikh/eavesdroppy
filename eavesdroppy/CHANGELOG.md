# Changelog

## [Unreleased]

- Urdu/Hindi mixed with English: a Meeting language setting (Auto, English, Urdu/Hindi + English). Auto listens to the start of each meeting; mixed meetings are transcribed with Apple's on-device speech recognition (macOS 26 or later), always in Latin letters. The notes header says which engine and language were used.
- A speaker named from a meeting introduction ("I'm Priya") shows "From introduction" in the Speakers tab with a "Save Priya's voice" button: one click creates the person (or links the one with that name), learns the voice, and later meetings name them automatically.

## [1.0.0] - 2026-10-12

- First release as Eavesdroppy (formerly the local "Meetings" droplet; new id `eavesdroppy`).
- Sessions and raw tracks in the old `meetings` container move across on first launch.
- Import recording: drop an audio/video file on the widget or use "Import recording…".
- Recording is safer: meta.json is written at start, device changes restart the mic, silent call audio and disk-full are reported, Failed rows can be deleted and show the pipeline's error.
