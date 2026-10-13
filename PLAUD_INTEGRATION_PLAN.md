# Plaud Note Pro → Detta: Integration Plans

Researched 2026-10-07. Goal: use the Plaud Note Pro (hand-me-down from boss) to record in-person meetings, transcribe with Detta, then run the usual Detta flow.

## Step 0 — before either plan

- [ ] **Confirm the model.** Check the label on the back or the device name in the Plaud app. Must be **Note Pro** (or NotePin S) for Plan A. Plaud's Embedded SDK does **not** support the original Note or NotePin. Plan B works with any Plaud device.
- [ ] **Get the device off the boss's account.** He unbinds it in the Plaud app. Plan A needs it fully unbound; Plan B needs it bound to *your* Plaud account.
- [ ] **Consent.** Recording in-person meetings may require everyone's consent depending on jurisdiction.

---

## Plan A — Own app, no Plaud app (Plaud Embedded SDK)

The device talks directly to your own phone app over BLE or WiFi; audio lands on the phone and goes to Detta. Plaud's transcription is not used.

### How it works
- Embedded SDK (iOS, Android, React Native, Flutter) connects to the device over BLE.
- Low-level methods (iOS names; Android equivalents exist):
  - Connect: `connectBleDevice(...)`, `disconnect()`, `depair(clear:)`
  - Record: `startRecord(_:)`, `stopRecord()`, `pauseRecord(_:)`, `resumeRecord(_:)`
  - List files: `getFileList(...)` (BLE) / `appGetFileList(...)` (WiFi)
  - Download: `syncFile(...)` (BLE) / `appSyncFile(...)` (WiFi Fast Transfer, ~10x faster)
  - Delete: `deleteFile(sessionId:)` / `appDeleteFile(...)`
- High-level `PlaudDeviceAgent.exportAudio(...)` outputs opus, mp3, wav or pcm.

### Steps
1. Sign up at the Plaud developer platform (dev.plaud.ai); get client ID + secret.
2. Start from the iOS or Android starter app in the docs.
3. Auth: Partner Token → User Token (tied to your user ID).
4. Bind: local BLE bind via SDK + `POST /sdk/bind`. The SDK cannot override an existing binding — `GET /sdk/binding` returns `is_bind: true` if still on the boss's account.
5. Pull recordings to the phone (prefer WiFi Fast Transfer; iOS needs the HotSpot entitlement).
6. Export as WAV, send the file to the Mac (or to a Detta endpoint), run Detta.
7. Optionally delete the file from the device after a successful transfer.

### Cost
- Free: 50 connected devices + 300 transcription hours (transcription not needed here).
- After that: $15/device/month, $0.28/hour transcribed.

### Risks / unknowns
- A phone app is mandatory; the SDK does not run on macOS.
- Firmware protocol V20+ needs Plaud backend calls (`sn-sign`, `gen-key`) to connect, and E2EE files need the `gen-key` private key. So setup is not fully offline, though the audio transfers device → phone directly.
- Docs are inconsistent on the local-vs-cloud bind order — test both.
- Not verified hands-on yet; all of this is from the docs.

---

## Plan B — Plaud app records, Detta transcribes

Keep the Plaud app only as the recorder/sync tool. Take the audio out and run it through Detta.

### B1 — Manual export (zero code)
1. In the Plaud app, open the recording, tap the top-right icon, then **Export as file → Audio → WAV** (or MP3).
2. AirDrop to the Mac.
3. Run Detta on the file.

WAV is only available in the mobile app; Plaud Web exports MP3 only.

### B2 — Automatic via the official Plaud CLI (recommended start)
```bash
npm install -g @plaud-ai/cli   # Node >= 20
plaud login                     # browser sign-in, tokens saved automatically
plaud recent --days 1           # list recent recordings
plaud audio <id>                # prints a download URL valid for 24h
curl -o meeting.mp3 "<url>"
```
Then: a small script that polls `plaud recent`, downloads any recording not yet processed, and hands it to Detta. Track processed IDs in a local file.

### Risks / unknowns
- Audio passes through Plaud's cloud.
- Docs imply a normal consumer account works with the CLI, but this is unverified — run `plaud login` first to confirm.
- Audio format/extension from `plaud audio` is not documented — check the response headers or the downloaded file.

---

## Recommendation

Start with **B2**: works today with almost no code. Move to **Plan A** later if you want to drop Plaud's app and cloud entirely.

## Sources
- [Supported devices](https://docs.plaud.ai/plaud-embedded/devices.md)
- [How Plaud Embedded works](https://docs.plaud.ai/plaud-embedded/how-plaud-embedded-works.md)
- [Low-level iOS SDK methods](https://docs.plaud.ai/plaud-embedded/advanced-ios-sdk.md)
- [Device binding](https://docs.plaud.ai/plaud-embedded/device-binding-api-overview.md)
- [Billing](https://docs.plaud.ai/plaud-embedded/billing.md)
- [SDK changelog](https://docs.plaud.ai/plaud-embedded/changelog.md)
- [Plaud CLI](https://docs.plaud.ai/plaud-mcp-cli/cli.md)
- [Export files (Plaud support)](https://support.plaud.ai/hc/en-us/articles/50835453223705-Export-files)
- [Docs index](https://docs.plaud.ai/llms.txt)
