# Request to Droppy maintainers (posted 2026-10-13: https://gitlab.com/droppyformac1/droppykit/-/work_items/3)

Posted as DroppyKit issue #3 on 2026-10-13.

---

**Title:** Speech-to-text and speaker separation for droplets: allow FluidAudio, or expose Droppy's Parakeet

I'm building Eavesdroppy, a bot-free meeting notes droplet. It records the mic and call audio, transcribes on-device, separates speakers, and writes notes. I'd like to publish it to the Store, but `Submitting.md` says `Package.swift` may depend on DroppyKit alone, and the transcription engine is the blocker.

Droppy already ships Parakeet TDT v3 for voice transcription. Two ways forward, in order of preference:

1. **A DroppyKit service over Droppy's own engine.** File transcription with word timings and custom vocabulary (the user's Droppy dictionary). Ideally speaker diarization (embeddings and clustering) as well. Droplets would then ship no models, and users wouldn't download a second copy of Parakeet.
2. **An exception for FluidAudio** (Apache-2.0, the library behind Parakeet on CoreML) as a reviewed dependency, or guidance on whether vendoring its source into the droplet folder is acceptable.

Two related questions:

- **CLI subprocesses.** Notes come from the user's own AI subscription, through the `claude`, `codex` or `grok` CLIs they already have installed, or through an API key. Is spawning those CLIs from a droplet acceptable for Store review?
- **C code for echo cancellation.** Is vendored C code acceptable (LocalVQE)? Or should I stick to Apple's voice-processing AEC?

I'm happy to contribute the service implementation if option 1 is welcome.
