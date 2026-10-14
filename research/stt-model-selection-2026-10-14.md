# STT model selection for Urdu/Hindi + English code-switching, 2026-10-14

Question: which on-device speech-to-text model should Eavesdroppy (meetings, 30 to 90 min) and Droppy dictation (5 to 15 s clips, about 1 s latency) use for a speaker who mixes Urdu/Hindi and English mid-sentence? Follow-up to `stt-comparison-2026-10-13.md` (Parakeet fails on Urdu; WhisperKit turbo with `--language ur` plus a romanized prompt was the only config that kept Latin script).

## 1. Bottom line

1. **Use Apple's `SpeechTranscriber` with locale `mul_IN` for anything that may contain Urdu/Hindi. Keep Parakeet for English-only calls.** On the user's real clips Apple `mul_IN` returned romanized Hinglish in Latin script for every clip, including the Urdu-heavy one (M3), at about 35x real time (2 s for a 90 s clip), 0.75 s fixed latency on 7 to 15 s clips, and a 5 to 8 MB process footprint (the model lives in a system service). It gives word-level timestamps. It is a system framework, so the Store's "DroppyKit only" rule does not block it.
2. **Accuracy is not the reason to pick it; fit is.** On Hindi/Urdu content, MOSS-Transcribe-Diarize, Qwen3-ASR 1.7B and Nemotron 3.5 are about as accurate as Apple on my read (several are cleaner on the Hindi stretches), but each emits Devanagari or Perso-Arabic for Hindi/Urdu words, and none can be linked into a Store droplet without vendoring MLX or CoreML glue. Apple is the only one that is simultaneously Latin-script, fast, small, timestamped and dependency-free.
3. **There is no ground truth.** I could not listen to the audio and there are no human transcripts. Every accuracy statement below is a reading of transcripts, not a WER. See section 9.
4. **Demote WhisperKit turbo.** About 6.6x real time here (versus 35x for Apple and 70x for Parakeet), occasional loops, noisier Urdu spelling. Omnilingual CTC (300M, 1B, 3B) is fast but garbled on this audio. Qwen3-ASR 0.6B loops. Fermion Phonon-2 is English only (not measured).
5. Biggest unknowns: Apple's model is OS-managed (can change with updates, needs a 639 MB OS asset download on first use, needs macOS 26 or later), and Apple's English-only accuracy against Parakeet is not quantified.

## 2. How this was run (and what to discount)

- Machine: the same Mac as the 2026-10-13 doc (Apple Silicon, 18 GB, macOS 27.0.1). Normal priority, one model at a time, no background-QoS flags. **Power:** the coordinator said AC. At one check mid-session `pmset` reported "Battery Power, 46%, discharging"; I did not re-check before every run, so I do not know the power state for each model's runs. After the session restart it reported AC. Load average was about 3.6 to 4.3 during runs (other apps: a terminal app at about 59% CPU, WindowServer). Treat timings as approximate; ordering is more reliable than absolute values.
- Clips: the same 12 clips as the 2026-10-13 doc (D1 to D8 dictation-length, C1 English control 73 s, M1/M2/M3 mixed meeting excerpts 90/70/67 s). Models with a 30 to 40 s limit (Omnilingual, Qwen3, Nemotron CLI, MOSS CLI, one process per chunk) were run on 4 long clips pre-cut into 3 to 4 chunks of 14 to 30 s at the quietest point; "infer" is the sum of each chunk's CLI-reported time. Apple and Parakeet got the whole file.
- Tools: `speech` CLI v0.0.28 (soniqo/speech-swift release, Apache-2.0) for Omnilingual, Qwen3-ASR, Nemotron and MOSS; a 40-line Swift script (SpeechAnalyzer + SpeechTranscriber) for Apple; `fluidaudiocli` for Parakeet; `whisperkit-cli` 1.1.1 for turbo. Memory is `/usr/bin/time -l` peak footprint and max RSS per process.
- Download workaround: the `speech` CLI's own downloader failed ("Refusing to write unsafe remote file name: config.json"), so I pre-populated its cache directory with `hf download`. Not a model problem.
- Scratch outputs (scratchpad `stt/` and `stt2/`) were wiped when the session restarted. Numbers and transcripts below are copied from what I saw during the run; items I cannot re-confirm are marked **(unconfirmed after wipe)**.
- Side effect on this Mac: installing Apple's `mul_IN` speech asset (639 MB, `com.apple.speech.asr.transcription.mul-IN`, took 96.6 s) is a system-wide change. Nothing under Droppy was touched.

## 3. Candidates

Status key: **M** = measured on the user's clips this session; **R** = research only.

| Model | Languages (ur/hi, code-switch) | Size | Reported accuracy (not on this data) | Apple Silicon runtime and speed evidence | Timestamps | License | Status |
|---|---|---|---|---|---|---|---|
| **Apple SpeechTranscriber `mul_IN`** (aliases `hi_IN`, `ur_IN` gave byte-identical text on the 9 clips I compared) | `SpeechTranscriber.supportedLocales` on this Mac lists 45, incl. `hi_IN`, `ur_IN`, `mul_IN`, `en_IN`. Output for Hindi/Urdu is Latin script. | OS asset 639 MB on disk, outside the app | None public for Urdu (GitHub issue 282, 2026-10-09). whispernotes (2026-09-01, macOS 27.0, FLEURS) scored it 101.5% on Hindi because it wrote Latin script against Devanagari references, so it was dropped from their ranking. That is a script mismatch, not a quality finding. | Native Swift, in-process API; model runs in a system service | Word-level via `audioTimeRange` (checked) | System component; no redistribution. Needs macOS 26+ per issue 282 (45 locales on macOS 26) | **M** |
| **MOSS-Transcribe-Diarize 0.9B** (OpenMOSS, released 2026-07-09) | "50+ languages" (card). Urdu appeared in my output (M3 in Perso-Arabic script), Hindi in Devanagari, English Latin. | 0.9B; MLX 5-bit 1.05 GB, INT8 CoreML 1.28 GB (aufklarer ports) | Open ASR leaderboard mean WER 5.17 (English only) | MLX or CoreML via speech-swift; 1 pass up to 90 min; vendor figure RTF 0.028 | Segment start/end in seconds plus anonymous speaker labels | Apache-2.0 | **M** |
| **Qwen3-ASR 1.7B and 0.6B** (Alibaba, 2026-01-29) | 30 languages + 22 Chinese dialects. Hindi yes, **Urdu not listed** (it still worked on this speaker because spoken Hindustani overlaps). | 0.6B: 0.7 GB (4-bit MLX), 180 MB CoreML INT8; 1.7B: 2.1 to 3.2 GB | Model card: FLEURS 8 extra languages incl. Hindi WER 10.37 (0.6B). whispernotes 2026-08-25: Hindi FLEURS 13.19 (1.7B MLX 8-bit) vs 29.64 (Whisper turbo) | MLX via speech-swift (1.7B); 0.6B also CoreML | None from the model. Forced aligner covers 11 languages, not Hindi/Urdu | Apache-2.0 | **M** |
| **Nemotron 3.5 ASR streaming 0.6B** (NVIDIA, 2026-06-04) | 40 locales; Hindi "transcription-ready", **Urdu not listed** | 0.6B; CoreML INT8 613 MB | Hindi FLEURS WER 8.13 (80 ms chunks) to 6.81 (1.12 s) with language ID given; 11.47 to 8.23 auto-detect | CoreML (speech-swift), NeMo, GGUF q8_0, ONNX int4 | Not in the CLI output | HF card: OpenMDW-1.1; the ONNX mirror says MIT (conflict, check before shipping) | **M** |
| **Omnilingual ASR CTC** 300M / 1B / 3B / 7B (Meta, 2025-11) | 1600+ languages incl. `urd_Arab`, `urd_Latn`, `urd_Deva`, `hin_Deva`. The speech-swift port has no language conditioning (shared 10,288-entry vocabulary). | 300M MLX 4-bit 194 MB; 1B 549 MB; 3B 1.7 GB; 7B 3.55 GB | 7B LLM-ASR CER: `urd_Arab` 3.5 (237.5 h training), `urd_Latn` 0.8 (20.3 h), `urd_Deva` 1.3, `hin_Deva` 3.6 (per-language CSV in the repo; read speech, not code-switch) | MLX or CoreML (300M only) via speech-swift; 40 s input cap | None | Apache-2.0 | **M** (300M, 1B, 3B) |
| **WhisperKit large-v3-v20240930 turbo** (baseline) | 99 languages; romanized output needs `--language ur` plus a prompt | 1.5 GB | Urdu conversational WER for "whisper-large" 18.30 (arXiv 2409.11252) | CoreML | Segment (word via option, not used) | MIT | **M** (re-run at normal priority) |
| **Parakeet TDT 0.6b v3** (current) | 25 European languages, no Hindi/Urdu | about 500 MB | Hindi/Urdu not applicable | CoreML via FluidAudio | Word timings | CC-BY-4.0 | **M** (re-run at normal priority) |
| Indic-Transcribe Flex / Core (Bodhan AI, 2026-09) | 27 / 25 languages incl. Urdu. Flex has native, mixed and **romanized** output; card says it handles Hinglish as spoken. | 1.2B, 4.6 GB fp16 | Voice of India WER: Flex Hindi 4.1, Urdu 13.1; Core Hindi 3.5, Urdu 11.4 | Muesli (2026-09-24 post) runs it with a CoreML encoder and an MLX Swift decoder; no speed figure | Not documented | Indic Open Model License v1.0: commercial use allowed with credit, same-license pass-through, "ask before hosting as a service", separate license above 500M MAU / USD 250M revenue. **Gated**. | **R**, not measured: gated, and I did not use the ungated third-party mirror (unknown remote code) |
| AI4Bharat IndicConformer 600M multilingual | 22 Indian languages incl. Urdu; native script; no code-switch claim | 600M | Hindi 13.2 on Vaani benchmark | NeMo; no Apple port found | n/a | MIT; gated | R |
| Qwen3-ASR Hinglish fine-tune "Srota" (moorlee) | Hindi + English; Devanagari and Latin | 0.78B | HiACC 24.73 to 15.85 vs base; trained on 95 h | PyTorch only on the card | none | Apache-2.0 (data CC-BY-4.0) | R, not run (Hindi data, no Urdu) |
| Whisper community fine-tunes | Urdu: kingabzpro turbo-urdu CV17 test WER 26.2; awaaz-se-alfaaz turbo LoRA FLEURS 24.07 to 16.86; emads large-v3-urdu-v2 FLEURS ur_pk 16.65. Hinglish: DKube 0.8B turbo, Trelis, Shunya (medium), smajji nemotron-hinglish-v6 | 0.8 to 1.5 GB | self-reported | WhisperKit-convertible | segment | various; not checked | R. Urdu fine-tunes are Perso-Arabic output on read speech; none addresses code-switching with romanized output |
| SeamlessM4T v2, MMS-1B | Urdu yes | large | arXiv 2409.11252: seamless-large best on read Urdu (ARL 23.97), worse on conversational (29.99); mms-1b 39.65 / 46.44 | no Apple port found | n/a | I believe non-commercial (CC-BY-NC) **(from memory, unverified)** | R, skipped |
| Fermion Phonon-2 (pip `fermion-research`, FluidInference CoreML port) | **English only**: HF model cards say "English"; FluidInference card: "Phonon-2 is English only; v3 covers 25 languages" | 164 MB | LibriSpeech test-clean 2.47 vs v3 2.27 | 174x on M5 Air (vendor) | word-level via `--json` | CC-BY-4.0 weights; CLI Apache-2.0 | R, **not measured: English only** |
| Cohere Transcribe 03-2026 | 14 languages, no Hindi/Urdu; no timestamps; inconsistent on code-switching (card) | 2B | English leaderboard 5.42 | MLX | none | Apache-2.0 | R, excluded |
| NVIDIA Canary-1b-v2 | 25 European, no Hindi/Urdu | 1B | n/a | NeMo | word and segment | CC-BY-4.0 | R, excluded |
| Voxtral Mini 3B, Moonshine, Gemma 3n | Voxtral: 8 languages; Moonshine ASR: no Hindi/Urdu; Gemma 3n: no Hindi/Urdu ASR evidence found | | | | | | R, excluded |
| Sarvam Saarika/Saaras v4 | Code-mixed, 23 languages, but API only; I found no open weights. Shuka v1 (Saaras v1 encoder + Llama3-8B, CC0 per AIKosh listing) not evaluated. | n/a | n/a | n/a | n/a | n/a | R |
| FluidAudio's own list | Parakeet v3, ultra, redux (all 25 European), v2 and Phonon-2 (English), EOU 120M, SenseVoice/Paraformer (Mandarin). **Nothing for Hindi/Urdu.** | | | | | Apache-2.0 | R |

Sources (all fetched 2026-10-14 unless dated otherwise):
- Apple: local `SpeechTranscriber.supportedLocales` probe (this Mac); <https://github.com/m2moiz/dekho-suno-jaano/issues/282> (2026-10-09); <https://whispernotes.app/blog/apple-speech-vs-whisper> (2026-09-01).
- MOSS: <https://huggingface.co/OpenMOSS-Team/MOSS-Transcribe-Diarize>; <https://soniqo.audio/guides/moss>.
- Qwen3-ASR: <https://huggingface.co/Qwen/Qwen3-ASR-0.6B>; <https://github.com/QwenLM/Qwen3-ASR>; <https://whispernotes.app/blog/qwen3-asr-vs-whisper> (2026-08-25); <https://huggingface.co/moorlee/qwen3-asr-0.6b-hinglish>.
- Nemotron: <https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b>; <https://huggingface.co/onnx-community/nemotron-3.5-asr-streaming-0.6b-onnx-int4>.
- Omnilingual: <https://github.com/facebookresearch/omnilingual-asr> (README and `per_language_results_table_7B_llm_asr.csv`); <https://arxiv.org/abs/2511.09690>; <https://soniqo.audio/guides/omnilingual>.
- speech-swift: <https://github.com/soniqo/speech-swift>; <https://soniqo.audio/cli>; models under <https://huggingface.co/aufklarer>.
- FluidAudio: <https://github.com/FluidInference/FluidAudio>; Phonon-2: <https://huggingface.co/FermionResearch/Phonon-2>, <https://huggingface.co/FluidInference/phonon-2-coreml>, <https://pypi.org/project/fermion-research/>.
- Indic: <https://huggingface.co/bodhan-ai/indic-transcribe-flex>; <https://www.analyticsvidhya.com/blog/2026/09/bodhan-ai-indic-models/>; <https://muesli.works/blog/hinglish-dictation-mac> (2026-09-24); <https://huggingface.co/ai4bharat/indic-conformer-600m-multilingual>.
- Urdu benchmark: <https://arxiv.org/html/2409.11252v1>. Whisper Urdu fine-tunes: <https://huggingface.co/kingabzpro/whisper-large-v3-turbo-urdu>, <https://friendli.ai/models/awaaz-se-alfaaz/whisper-turbo-v3-urdu>, <https://huggingface.co/emads/whisper-large-v3-urdu-v2>.
- Cohere: <https://huggingface.co/CohereLabs/cohere-transcribe-03-2026>; Canary: <https://huggingface.co/nvidia/canary-1b-v2>; Moonshine: <https://moonshine-voice.readthedocs.io/en/latest/>.
- Not fetched at the primary source: Whisper large-v3 per-language FLEURS Hindi/Urdu WER, SeamlessM4T/MMS licenses (from memory), Sarvam model weights status (docs search only), Gemma 3n Hindi/Urdu audio quality (no evidence found either way).

## 4. Measured results

### 4a. Speed and memory

Long clips C1 + M1 + M2 + M3 = 300 s of audio. "infer" is the tool's own inference time (Apple: time from file open to final result; Parakeet: `processingTimeSeconds`; Whisper: whole-process wall minus about 0.8 s load per clip). "60 min est." extrapolates the 300 s figure linearly; only Apple and Parakeet were run on a full meeting.

| model | infer, 300 s audio | RTF | real-time multiple | 60 min est. | dictation clips 7 to 15 s (infer) | peak footprint | max RSS | download |
|---|---|---|---|---|---|---|---|---|
| Parakeet v3 | 4.3 s | 0.014 | 71x | 0.8 min | 0.06 to 0.14 s | 83 to 125 MB (RSS) | 125 MB | about 500 MB |
| **Apple `mul_IN`** | 8.6 s | 0.029 | 35x | 1.7 min | 0.73 to 0.80 s | 5 to 8 MB | 19 to 21 MB | 639 MB OS asset |
| Omnilingual 300M MLX 4-bit | 3.5 s | 0.012 | 86x | 0.7 min | 0.08 to 0.17 s | 1.07 to 2.67 GB | 270 MB | 194 MB |
| Omnilingual 1B | 8.9 s | 0.030 | 34x | 1.8 min | 0.20 to 0.45 s | 1.9 to 3.6 GB | 618 MB | 549 MB |
| Omnilingual 3B | 24.4 s | 0.081 | 12x | 4.9 min | 0.58 to 1.23 s | 4.0 to 4.9 GB | 1.7 GB | 1.7 GB |
| Qwen3-ASR 0.6B MLX 4-bit | 12.7 s | 0.042 | 24x | 2.5 min | 0.20 to 2.20 s (loops inflate D3, D6) | 1.5 to 6.8 GB | 0.93 GB | 681 MB |
| Qwen3-ASR 1.7B MLX 4-bit | 23.2 s | 0.077 | 13x | 4.6 min | 0.41 to 1.37 s | 2.5 to 6.3 GB | 1.8 GB | 2.1 GB |
| Qwen3-ASR 1.7B MLX 8-bit | 40.6 s | 0.135 | 7.4x | 8.1 min | 0.58 to 1.81 s | 3.3 to 7.1 GB | 2.7 GB | 2.3 GB |
| MOSS 0.9B MLX 5-bit | 30.8 s | 0.103 | 9.8x | 6.2 min | 0.73 to 1.27 s | 1.93 to 1.98 GB | 1.2 GB | 1.0 GB |
| Nemotron 3.5 CoreML INT8 | 43.2 s | 0.144 | 6.9x | 8.6 min | 1.04 to 2.73 s | 245 to 283 MB | 1.25 GB | 613 MB |
| WhisperKit turbo, `ur` + prompt | about 45 s | 0.15 | 6.6x | 9.1 min | wall 2.8 to 8.8 s incl. about 0.8 s load | 204 to 381 MB (2026-10-13 doc) | 0.74 to 1.3 GB | 1.5 GB |

Notes:
- Per-process peak footprint for MLX models is mostly Metal activation buffers and grows with chunk length; it is far above the weight size.
- Apple's footprint is the app process only; the 639 MB model is resident in a system service that I did not measure. Apple also has a fixed cost of about 0.75 s per file regardless of length (a 7.5 s clip takes 0.77 s, a 90 s clip 2.04 s).
- Cold start: model loads for MLX and CoreML were 0.6 to 3 s per process after files were on disk. The first CoreML compile of Nemotron and the first Apple asset download (96.6 s) are one-time. I did not isolate a clean cold-vs-warm figure for each model.
- Full meeting (50.8 min mic track, 3,048 s): **Apple `mul_IN` 109.1 s (28x real time), peak footprint 7.7 MB, 8,686 words including timestamp tokens.** **Parakeet v3 16.7 s (182.7x), 3,943 words.** (Parakeet's word count is lower because it skips or drops the Urdu stretches; I did not verify that and it may also reflect different tokenisation.) MOSS, Qwen3 and Nemotron were not run on a full meeting. **(figures from run output, not re-confirmable after the wipe)**

### 4b. Script and failure behaviour (reading of outputs)

| model | script on mixed clips | English-only clips | failures seen |
|---|---|---|---|
| Parakeet v3 | Latin | correct | Hindi/Urdu turned into phonetic English junk; skips Urdu stretches (M2 start) |
| **Apple `mul_IN`** | **Latin (romanized Hinglish) on all clips, also M3 Urdu-heavy** | mostly correct; a few mis-hearings (D7 "as a song"/"token base willing" vs reference "as a scenario"/"token-based billing"; D4 "Hamara log jo hoga") | spelling variance in Urdu words; some Urdu words mangled ("healthy mein", "five nine" for "pipeline" in M2) |
| Apple `en_IN` (for contrast) | Latin | fine | collapses on Urdu: "Uska Matlabi, Agarham, US, Kjo, Rocks, Hongge" (M2) |
| MOSS | mixed: Devanagari for Hindi, Latin for English; D4/D5/D6 romanized; M3 in Urdu (Perso-Arabic) | correct | script flips within and across clips; tail of D4 cut ("huma-") |
| Qwen3-ASR 1.7B | Devanagari for Hindi, Latin for English (clean separation); D3 tail romanized | correct | a stray Cyrillic token in M1 (8-bit); no timestamps |
| Qwen3-ASR 0.6B | mixed | correct | repetition loops (D3 "m m m m...", D6 "a little bit go to market direction me..."); M2 start is Devanagari noise |
| Nemotron 3.5 | **Devanagari for everything incl. English words** ("आई कैन गो टेक समथिंग") | on English-only clip C1 it switches to Devanagari mid-clip; D7 Devanagari | language auto-detect per chunk flips script; I did not test the `--language` hint |
| Omnilingual CTC 300M/1B/3B | Devanagari + garbled Latin, characters mixed within words (D4: "वat नaक so youर missinग one पoint") | garbled (D7: "tat ouरs o i don सoकin dेs bilinग") | 1B and 3B return near-empty text on many chunks (M1 about 30 words vs about 200 to 230 for others; 3B M2 first chunk empty) |
| WhisperKit turbo `ur` + prompt | Latin | correct | Urdu spelling noise, stutter loops ("pe pe pe"), D4 took 8.8 s |

### 4c. Side-by-side transcripts (verbatim tool output, unedited). References are the approximate ones from the 2026-10-13 doc (section 4), not ground truth.

**D6 (14.5 s), reference: "Thirty, forty percent somewhere. Aur by the way, Q3 mein dekho, kuch cheezein reh gayi, again bottleneck mein tha, direction... go-to-market direction change, strategy change, go-to-market direction mein tactically, mein tactically [change]."**

- Parakeet v3 (2026-10-13): 30, 40% somewhere. Or by the way, huh? Q3 me they go put teaser head, eh? Again, my bottleneck method direction man go to market direction change strategic change. Go to market direction tactically tactically.
- WhisperKit turbo ur + prompt: 30-40% somewhere. By the way Q3 me, dhekho kuchh cheeze raha gahin again maha bottleneck me tha direction, mein ne thoda si go to market direction change kiri strategy changing go to market direction, mein ne tactically, mein ne tactically,
- **Apple `mul_IN`:** T thirty forty percent somewhere aur by the way haa q three mein dekho kuch cheejen reh gai again wahan bottleneck mein Tha direction maine thodi si go to market direction change ki study ki change ki go to market direction maine tactically maine
- MOSS: [0.08s-1.62s][S01] thirty forty percent somewhere / [1.73s-7.31s][S02] or by the way, huh, Q3 mein dekho kuchh cheeze reh gayi, again, mah bottle neck mein tha, direction maine / [7.68s-10.98s][S02] thodi si go to market direction change ki, strategic change / [11.48s-14.48s][S02] go to market direction maine tactically, maine tactically
- Qwen3-ASR 1.7B 8-bit: Thirty, forty percent somewhere. And by the way, hah, Q3 में देखो कुछ चीजें रह गईं. Again, वहाँ bottleneck में था direction मैंने थोड़ी सी go to market direction change की strategy change की. Go to market direction मैंने tactically मैंने tactically
- Qwen3-ASR 0.6B 4-bit: Thirty, forty percent somewhere. And by the way, huh? Q three me, look, what things are going on? Again, maha bottle neck me, the direction me, a little bit go to market direction change, Q three me, go to market direction me, a little bit go to market direction me, a little bit go to market direction me, ... (loops)
- Nemotron 3.5: थर्टी फोर्टी परसेंट समवे और बाय द वे हाँ क्यू थ्री में देखो कुछ चीजें रह गई अगेन वहाँ बोतलनेक मेथड डायरेक्शन मैंने थोड़ी सी गो टू मार्केट डायरेक्शन चेंज की स्ट्रेटेजिटी चेंज की गो टू मार्केट डायरेक्शन मैंने टैक्टिकली मैंने टैक्
- Omnilingual 300M: 4 ं सम और बायदवे हाँ क्यूफ्थ्री में देखो कुछ चीजे रहे गी अगेन वहाँ बॉटलनेक मैथा डिरेक्शन मैंने थोड़ी सी गो टु मा के डिरेक्शन चेंज की स्ट्रिजि चन गो टु मा के डिरेक्शन मैंने टैक्टिकलही मैंनेट; 1B: औरब हा क में देखो कुछ चीजरगअगे मा बॉट मा डरन मैे थोडी ोट माडरगोट माक डरकन मैे टैकटकल ै

**D3 (10.5 s), reference: "I can go take something that can be effective tomorrow on the show floor. I will ask for it, and I'm not listening to [Urdu tail: ~'Ayaz ki Asim bhai ... kaam karna wala']."**

- Apple `mul_IN`: pyaaj ki abhi do char Ghante laga ke I can go take something that can be effective tomorrow on the show floor / I will ask for it and I'm not listening to / I'm not listening to Ayaaz kiya Asim bhai aur elting mein kaam lena
- MOSS: कभी दो-चार घंटे लगा के, I can go take something that can be effective tomorrow on the show floor, I will ask for it and I'm not listening to, I'm not listening to Ayaas के आसिम भाई एल्टिन में काम करना है वाला कद्दू
- Qwen3 1.7B 8-bit: I ask that maybe two-three hours, I can go take something that can be effective tomorrow on the show floor. I will ask for it, and I'm not listening to I'm not listening to Ayaz ki ya Asim bhai ya editing me karna hai, kya?
- Nemotron: आज की कभी दो चार घंटे लगाकर आई कैन गो टेक समथिंग दैट कैन बी इफेक्टिव टुमॉरो ऑन द शो फ्लोर आई विल आस्क फॉर इट एंड आई एम नॉट लिस्टनिंग टू आई एम नॉट लिस्टनिंग टू आयाज के आसिम भाई एलटी में काम करने वाला
- Qwen3 0.6B 4-bit: ... I am not listening to. I ask him, 'Can I ask him by editing me a m m m m m ... (loop)
- Omnilingual 300M: याज की कभी दोचार घंटे ेला के आय थिं गो टेक समथिंग द कन भी एफफेक्टिव टो मॉर औ उन द शोफ्लोर ऐविल आसक फरड अं आम नत लि्निंग त आम नोत लिस्सनिंग तो आयाज की ा आसिंबाई लटिंग में काम करना ह

**D4 (7.2 s), reference: "[Nahin / next], so you're missing one point here. I agree with you, but partially. What you're missing is that, yes, hamara rock jo hoga, [hoga]..."**

- Apple `mul_IN`: But Nick, so you're missing one point here. / I agree with you, but partially. / What you're missing is that yes / Hamara log jo hoga
- MOSS: What, next, so you're missing one point here. I agree with you, but partially. What you're missing is that, yes, humara rok jhoga, wo huma-
- Qwen3 1.7B 8-bit: What? No. So you're missing one point here. I agree with you, but partially. What you're missing is that yes, हमारा rock जो होगा वो हमार
- Omnilingual 300M: wat नaक so youर missinग one पoint हar i aग्rीe with यoू बut partily what youर missinग is that यes हमारा रॉग जो होगा व

**M2 (70 s, mic, the user), start of clip. Parakeet skipped the first 20 to 35 s of Urdu in the 2026-10-13 run.**

- Apple `mul_IN` (first 63 s): kuch gaps hai unko aapne wahan pe se rehire karna hai engineering side pe bechna samajhta hoon ki ek log har sirf dekhna shuru kar dena chahiye aap logon ko sirf shuru karna chahiye pipeline ke kya Maamla Aata hai mei aap logon ko bata doonga to aap logon ko pata hua ki expect karna to delivery side pe bahut zyada I don't think hamen kuch shake up karne ki zaroorat hai / I think you finally found your feet and I think we should let you guys continue to build up your processes / Meanwhile, we have worked heavily and actively on building up the five nine for next year. / ... uska matlab ye hai ki hum agar to hum US Karte hain to fir Hamari jo EOS ke jo rocks honge vo vahi honge ...
- Nemotron: चाहे कुछ गैप्स हैं उनको आपने वापस से रिहायर करना है, इंजीनियरिंग साइट पर बीच में समझता हूँ कि एक दो लोग खली सिर्फ देखना शुरू कर देना चाहिए ... आई थिंक यू फाइनली फाउंड योर फीट एंड आई थिंक वी शुड लेट यू गाइस कंटिन्यू टू बिल्ड अप योर प्रोसेसेस Meanwhile, we have worked heavily and actively on building up the pipeline for next year ...
- Qwen3 1.7B 8-bit: दाहर है कुछ गैप्स हॅंड को आपने वापस से रिहायर करना हौं engineering साइट पे भी मैं समझता हों कि एक दो लोगों खाली सिर्फ देखना शुरू कर दिना चाहिए ... I think you finally found your feet and I think we should let you guys continue to build up your processes ...
- Omnilingual 3B (first 25 s chunk returned empty): "मन न ग इप न न समे गपस है इवन दो वो परफेक्ट नहीं होगी वह ऐसी ही लंगड़ी होगी ..."

**M1 (90 s)** all of Apple, MOSS, Qwen3 1.7B and Nemotron recovered the Urdu/Hindi content with similar fidelity (words and meaning), including the tail ("we should cut down the EOS to forty five minutes and we should only have ITS", MOSS and Apple). Apple, first 70 s: "on the contrary mei kya kah raha hoo usko bhi share karta hoo ya do options inke paas Ho. to aur I am thinking is A in the past three quarters rocks ko Banan ke usamen kuch directions ho gae rocks bilkul vaise mein healthy mein rocks agar complete ho bhi gae unke Baad Unka completion Unki ... closing properly nahin ki Jaari thik hai hum matrix is mein bhi agar hum baat karen to we are not getting something too much out of this because we are still building some of the processes in different teams ..." Numbers differ across systems for the same phrase ("Q1 of 2021" Qwen3 8-bit, "Q1 of 27" MOSS, "the queue one" Apple), so figures in notes from any of these need a human check.

**M3 (67 s, Urdu-heavy remote speaker via mic bleed)**: Apple `mul_IN` gave Latin throughout ("ji. Nah, say yes. A sare points I believe Jitne bhi bole hai vo sahi hai like complete hum ye rocks vagairah jo hai vaise ye bhi cheejen change ho rahi hai kafi ..."). MOSS wrote Perso-Arabic ("جی نہیں آ سہی ہے آ سارے points I believe ...") then switched to Devanagari mid-clip. WhisperKit turbo `ur` + prompt (normal priority run): "Jee, nahi, saai hai, saare points I believe, jitnou ne bhi bool hai, wou saai hai, like complete hum, ye rocks vokra johai ..." (noisier).

### 4d. Dictation latency view (7 to 15 s clips, resident model assumed except where noted)

- Parakeet: 0.06 to 0.14 s. Apple `mul_IN`: 0.73 to 0.80 s per call (includes SpeechAnalyzer setup per file; a streaming session may be cheaper, not tested). MOSS 0.73 to 1.27 s. Qwen3 1.7B 8-bit 0.58 to 1.81 s. Nemotron 1.04 to 2.73 s (streaming model; chunk-wise decoding would likely be faster in a live pipeline, not tested). WhisperKit turbo about 2 to 8 s decode.
- Only Parakeet, Apple, MOSS and Qwen3-1.7B (4-bit) meet "about 1 s" on these clips; Apple is the only one that does so in Latin script.

## 5. What people recommend (2025 to 2026 sweep)

Reddit pages, X posts, and the Open ASR Leaderboard multilingual tab could not be read with the tools available (the search tool blocks reddit.com; the leaderboard Space page returned only a header). This section is therefore HN threads, vendor and community blog posts, and app pages. Relative dates are as shown at fetch time.

- **Parakeet for English and European languages, Whisper for the rest, Qwen3-ASR and MOSS rising.** HN "Whisper is the wrong model to benchmark against" (<https://news.ycombinator.com/item?id=48895462>, about 3 months old): commenters name Parakeet V2/V3, Nemotron, Voxtral, Cohere Transcribe, MOSS-Transcribe-Diarize ("for multilingual and noisy audio"), Qwen ASR; some still prefer Whisper large-v3 turbo for noisy or accented audio. No Hindi, Urdu or code-switching mention. One commenter: Parakeet v3 "doesn't receive or output language id", detected Russian for Polish.
- HN thread on Apple's SpeechAnalyzer benchmark (<https://news.ycombinator.com/item?id=48894752>, about 3 months old): English-only comparisons; critics note it used small Whisper models; one user says it works well for Indian-accented English; no Hindi/Urdu discussion. Apple is described as lacking auto language detection.
- Show HN "Qwen Scribe" (<https://news.ycombinator.com/item?id=49098260>, about 76 days old): Qwen3-ASR on MLX, tested in English, German, French, Russian, Italian, Spanish; one commenter measured about 2x real time on an M1 versus about 60x for Parakeet via FluidAudio. Another says Qwen ASR is less supported in dictation apps than Parakeet or Whisper.
- Hindi numbers: <https://whispernotes.app/blog/qwen3-asr-vs-whisper> (2026-08-25, vendor blog, M5 Air, FLEURS read speech, about 150 sentences): Hindi Qwen3-ASR 1.7B 13.19 vs Whisper turbo 29.64. Same site (2026-09-01): Apple Speech returns South Asian languages in Latin script, so it is scored as failing against native-script references (Hindi 101.5).
- Apps and Hinglish: Muesli uses Bodhan Flex (CoreML encoder + MLX Swift decoder) for Hinglish dictation (2026-09-24 post; mixed-script output, no benchmarks stated). TapTalk advertises Nemotron for Hindi with romanized Hinglish output (marketing page, no numbers). Santa and Kahana Fusi (GitHub) run whisper.cpp large-v3-turbo with Hinglish modes and Ollama cleanup; no accuracy numbers. Superwhisper offers Whisper tiny to large-v3 turbo plus Parakeet V2/V3 (reviews, April 2026 changelog); VoiceInk is whisper.cpp; MacWhisper is Whisper (and per HN, can pick Parakeet).
- **Consensus:** the Mac community default for multilingual dictation is still Whisper turbo; for English it is Parakeet; for Hindi specifically the newer Qwen3-ASR, Nemotron 3.5 and Bodhan Flex are what vendors push. **I found no community source recommending Apple SpeechTranscriber for Hindi/Urdu/Hinglish**; my result for it is a first-hand measurement plus the whispernotes script observation. All accuracy claims in this section are vendor or individual reports, not controlled tests.
- Effect on the shortlist: it surfaced Bodhan Indic-Transcribe Flex (the only open model with explicit Urdu support and a romanized output mode, already used in a shipping Mac app). I could not measure it (gated), so it is the first thing to evaluate if Apple's output is not good enough.

## 6. Recommendation

**Meetings (30 to 90 min)**
- Language-flagged or unknown meetings: transcribe the full audio with **Apple `SpeechTranscriber(locale: mul_IN)`**. 51-min meeting took 109 s here. Use FluidAudio's diarizer (already embedded) for speakers and assign Apple's word timings to speaker turns. English-only calls: **Parakeet** (51 min in 17 s, word timings, 125 MB).
- Routing (cheapest that works): a per-meeting setting "Urdu/Hindi mix" defaulting to the last choice. An automatic variant: run Parakeet always (17 s for 51 min) and run Apple when more than a small fraction of Parakeet's words are low-confidence or the text contains phonetic junk. I did not test any auto-routing; Parakeet-only, Apple-only and "both then pick" all cost under 2.5 minutes per hour of audio on this Mac.

**Dictation (5 to 15 s)**
- English-only: Parakeet (about 0.1 s). Urdu/Hindi mix: Apple `mul_IN` (about 0.75 s per call, Latin output). Droppy would need two profiles or a language toggle.

**Why not the alternatives**
- MOSS-Transcribe-Diarize is the best technical fallback: Apache-2.0, 0.9B, timestamps and speaker labels in one pass, 90-min single pass, and the only model that wrote real Urdu script. But about 10x real time and MLX (see section 7), and script mixes Devanagari, Latin and Perso-Arabic.
- Qwen3-ASR 1.7B has the cleanest mixed-script output (Devanagari Hindi, Latin English) but 7 to 13x real time, 2 to 3 GB memory, no timestamps and Urdu is not an official language.
- Nemotron 3.5 CoreML is the easiest to integrate (CoreML only, 613 MB) and accurate on Hindustani, but writes English words in Devanagari unless language is forced, and Urdu is unsupported officially. License needs checking (OpenMDW-1.1 vs MIT conflict).
- If the notes LLM handles Devanagari and Perso-Arabic well (Claude does), script is a minor cost; then Qwen3-1.7B or MOSS become competitive and Apple's advantage shrinks to integration.

## 7. Integration into Swift and Store implications

- **Apple SpeechTranscriber:** `import Speech` (system framework, macOS 26+). Flow: `AssetInventory.assetInstallationRequest(supporting:)` then `downloadAndInstall()` (639 MB, 96.6 s here), `SpeechAnalyzer.analyzeSequence(from:)` for files, `.audioTimeRange` attribute for word times. No weights in the app bundle, no new package dependency. Open questions: whether Droppy's host app already carries the Speech-recognition privacy string and permission (my CLI tool ran without a prompt; a droplet inside Droppy's process may need one), and whether the Store review accepts a droplet triggering a 639 MB OS download. Neither was tested.
- **Parakeet:** unchanged (the D21 question to Droppy's maintainers about FluidAudio, in `swift-port-plan.md`, still applies for diarization and Parakeet).
- **MOSS / Qwen3 1.7B / Omnilingual (MLX):** need `mlx-swift` plus a built `mlx.metallib` (107 MB in the speech CLI release), neither of which fits "DroppyKit only". Possible only by vendoring source and shipping a binary resource; heavy.
- **Nemotron 3.5 and Qwen3 0.6B (CoreML):** CoreML runs through a system framework; the Swift glue (feature extraction, tokenizer, decode loop) would be vendored from speech-swift (Apache-2.0). Lighter than MLX, but you still own the glue.
- **Vendoring vs binary:** speech-swift is Apache-2.0 source, vendorable; the models are separate HF downloads with their own licenses (listed in section 3).

## 8. Disk and memory cost (what the user pays)

| option | extra disk | memory while running |
|---|---|---|
| Apple `mul_IN` | 639 MB OS asset | about 8 MB in-process, plus a system service (not measured) |
| Parakeet v3 (already present) | about 500 MB | 83 to 125 MB RSS |
| MOSS 5-bit MLX | 1.0 GB | 1.2 GB RSS, about 2 GB peak |
| Qwen3-ASR 1.7B 4-bit / 8-bit | 2.1 / 2.3 GB | 1.8 / 2.7 GB RSS, peaks 6 to 7 GB |
| Nemotron 3.5 CoreML | 613 MB | 1.25 GB RSS, 245 to 283 MB footprint |

## 9. What remains uncertain

1. **No ground truth.** All accuracy judgments are my reading of transcripts against references I (and the 2026-10-13 doc) inferred from model outputs. A 15-minute human correction of D3 to D6 and M1/M2 would turn this into WER.
2. **Apple vs Parakeet on English.** On D7 Apple made two errors that Parakeet and Whisper also made differently; I had no time to compute a WER on the 5 English clips. Whether to route English-only calls to Parakeet (my recommendation) rests on Parakeet's known English accuracy, not on a head-to-head here.
3. **Apple's model is OS-managed and unversioned.** Its output script, accuracy and availability can change with an OS update. `mul_IN`, `hi_IN` and `ur_IN` returning identical text is observed behaviour, not documented. Minimum OS is macOS 26 per a third-party issue (45 locales listed), not Apple documentation.
4. **Timing conditions.** Possibly on battery for some runs, load average about 4, per-process load overhead included in "wall" but not "infer". Full-meeting runs exist only for Apple and Parakeet.
5. **Bodhan Indic-Transcribe Flex not measured** (gated, license conditions). It may beat everything here on Urdu. It is the first follow-up.
6. Apple's `mul_IN` is untested for: multiple speakers talking over each other, noisy system-audio tap, 90-minute single call, and memory in the system service under long input.
7. The wipe of the scratchpad removed raw outputs; transcripts quoted above are copied from my session and are verbatim as seen, but cannot be re-diffed.
