# STT comparison for Urdu/Hindi + English code-switching, 2026-10-13

Question: which speech-to-text setup handles this user's mixed Urdu/Hindi/English speech best, for Eavesdroppy meeting notes and for Droppy dictation?

## 1. Bottom line

1. **Parakeet TDT 0.6b v3 (current) is the fastest by far and fine for English, but it cannot do Urdu/Hindi.** It drops many Urdu stretches or turns them into phonetic English junk ("rocks ko banan kiffer", "Kerneka era Rada Neta"). On M2 it appears to skip the first 20 to 35 s of speech (an Urdu passage about hiring and the engineering side, which turbo `ur` recovered; by my reading of the outputs).
2. **WhisperKit `large-v3-v20240930_turbo` with `--language ur` plus a short romanized-Hinglish `--prompt` gave the most complete and readable Latin-script notes** on the mixed clips (M1, M2, D3 to D6). It is the only config that kept the Urdu in Latin script: unprompted `ur` and `hi` kept it in Perso-Arabic or Devanagari, while `en`, `auto` and `translate` dropped or rewrote it. Costs: spelling noise on Urdu words, occasional stutter loops ("pe pe pe pe"), one fabricated number in translate mode, and one clip (M3, heavy Urdu) where the output drifted back into Perso-Arabic and Devanagari mid-text even with the prompt.
3. **Do not force `--language en`**: it silently deletes or garbles code-switched stretches (M3 en lost most of the Urdu). **Do not use `--task translate`**: it produced fluent but wrong English (M2 turned "you've finally found your feet" into "I don't think we've finally found your feet"; M1 invented "Q1 of 2017").
4. **Plain `auto` picks a script per chunk**, so output flips between Latin, Devanagari and Perso-Arabic within one transcript (M3: 4/53/43 % Latin/Arabic/Devanagari; D6 and M2 contain Devanagari). `--language hi` is worse than `ur` for this speaker: Devanagari gibberish on D4 and D5, and nonsense at the start of M2.
5. **Timing is unreliable in absolute terms** (section 3). In the same conditions Parakeet needed 0.2 to 0.7 s of inference for 7 to 15 s dictation clips, and Whisper turbo needed roughly 19 to 34 s. At normal priority, 3 clips ran 4x or more faster than at background priority, so the Whisper numbers below are heavily inflated.

Recommendation, short form:
- **Eavesdroppy:** keep Parakeet as the default and for English-only calls; for meetings with Urdu/Hindi, run WhisperKit turbo with `--language ur --prompt "<romanized Hinglish sentence>"` (not translate, not en). Details in section 8.
- **Droppy dictation (do not change settings now):** keep `parakeet` for English-dominant dictation. For Urdu-heavy dictation use `whisper` with language `ur` (or `auto`). Droppy has only `openai_whisper-large-v3` installed (not turbo) and I could not test its prompt support. Details in section 8.

## 2. Setup

- Machine: Mac15,7, 12 cores, 18 GB. All runs happened **during a live call**, with Droppy's own transcription and `localvqe` (about 80 % CPU) running (load average about 10).
- Priority: every heavy command ran under `nice -n 19 taskpolicy -b`, one model at a time. **Exception:** after a coordinator message said the Mac was on AC power, I started a queue at normal priority. It ran 3 clips (turbo en M2 and M3, turbo ur M1; table 6d) before a tool-permission check blocked a related wait command. I stopped it and went back to background priority for everything else. I did not treat the coordinator message as user approval.
- Parakeet: `bin/fluidaudiocli transcribe <wav> --output-json ... --model-version v3 --local-model-dir <scratch>/models/parakeet-tdt-0.6b-v3`. That directory is a set of symlinks to Droppy's `Extensions/voiceTranscribe/models/parakeet/parakeet-tdt-0.6b-v3`, with `JointDecision.mlmodelc` also linked as `JointDecisionv3.mlmodelc` (same approach as `link_droppy_model` in `process_meeting.py`). Read-only.
- WhisperKit: `brew install whisperkit-cli` (1.1.1). Droppy embeds its own WhisperKit; its version is unknown, so CLI results are a proxy. Models: turbo downloaded from Hugging Face into scratch (1.5 GB). `openai_whisper-large-v3` copied (read-only copy) from Droppy's model dir into scratch (2.9 GB). Tokenizer downloaded to scratch. Nothing was written under `~/Library/Application Support/Droppy` and Droppy was not touched. Brew install is the only thing outside scratch.
- Audio: the two flac tracks converted to 16 kHz mono 16-bit wav with `afconvert`, excerpts cut with Python `wave`. Excerpt times are on the mic clock (the track offsets differ by only 0.04 s). Each WhisperKit invocation is one clip, one config, default decoding (temperature fallback on, no VAD chunking, `--verbose` for timings, `/usr/bin/time -l` for memory).
- Scripts and raw JSON: `/private/tmp/claude-501/-Users-fahad-code-eavesdroppy/a96c790b-eebe-46bc-a0f9-2a7feb2e87ae/scratchpad/stt/{scripts,out}`.
- Not run (per lead's request to go faster): `openai_whisper-large-v3_turbo`; large-v3 on the 3 meeting excerpts; turbo hi/ur/translate on English-only clips; hi + translate.

### Important finding about the recording itself

`system.flac` is **digital silence for almost the whole meeting**. Measured by 5 s windows, only about 105 s of 3047 s have real signal (RMS above 800), essentially one stretch at 705 to 775 s (Speaker 1). Every other remote speaker, including Speaker 2 in the 03:25 to 04:55 stretch, is only audible on `mic.flac` (bleed through speakers). So in this meeting the "remote" audio Eavesdroppy transcribes is mostly mic bleed. I did not investigate why (unverified cause: the call app may route audio away from the system tap). It is worth a separate look.

Because of this, only M3 is a true system-track clip. M1 and C1 are the remote voice as picked up by the microphone.

### Clips

| id | source | mic-clock range | length | content |
|---|---|---|---|---|
| M1_mic_spk2_mixed | mic track (remote Speaker 2 bleed) | 03:25 to 04:55 | 90 s | English with Urdu/Hindi phrases ("rocks ko banane ki...") |
| M2_mic_me_mixed | mic track, the user | 02:15 to 03:25 | 70 s | English plus Urdu stretch at the start and "EOS karte hain" later |
| M3_sys_spk1_mixed | **system track**, Speaker 1 | 11:44 to 12:51 | 67 s | Heavy Urdu/Hindi with English words |
| C1_mic_spk2_english | mic track (remote Speaker 2 bleed) | 14:08 to 15:21 | 73 s | English-only control |
| D1, D2, D7, D8 | mic track, the user | various, 7 to 15 s | English dictation-like |
| D3, D4, D5, D6 | mic track, the user | various, 7 to 15 s | English with Urdu/Hindi mid-sentence |

Dictation clips were cut on pauses found from Parakeet word timings, restricted to stretches the merged transcript labels "Me". The mic track has other speakers' bleed, so I picked the clips by hand against that transcript. I did not listen to audio; my reading of what was said is from the model outputs.

## 3. Timing and memory

**Read this caveat first.** All timings were taken on a loaded machine, in background QoS. Absolute numbers are inflated, and the inflation is not uniform (Parakeet vs Whisper hit differently). Use ratios and ordering only. Evidence of how large the inflation is: the same turbo en M3 clip (67 s) took 51 s wall at background priority and 12.7 s at normal priority (decode about 11.8 s, 0.18 s per audio second); turbo en M2 (70 s) took 44.7 s vs 10.2 s. I did not repeat the short dictation clips at normal priority, so true dictation latency for Whisper on an idle machine is **not measured**; the 4x speedup suggests a few seconds for a 10 s clip on turbo, but that is an inference.

- **First-run CoreML compile** (turbo, background QoS, includes the ANE encoder compile): model load 150.7 s (encoder 126.6 s). Warm model load afterwards: 3 to 7 s (0.8 s at normal priority). The 491 s wall time of that first command also included the 1.5 GB download.
- large-v3 from my scratch copy: first-run load only 32.7 s, then 1 to 3 s. I do not know why this was fast (possibly a shared compile cache with Droppy, unverified).
- Parakeet on the full 51 min mic track: 114.6 s wall, 87.5 s CLI processing (RTFx 34.8), max RSS 379 MB, peak footprint 85 MB.
- Memory (`/usr/bin/time -l`): Parakeet peak footprint 38 to 68 MB (max RSS 83 to 125 MB). Whisper turbo peak footprint 204 MB for short clips and 319 to 381 MB for the 67 to 90 s clips, max RSS 0.74 to 1.3 GB. large-v3 peak footprint 336 to 337 MB, max RSS 1.7 to 2.0 GB. Footprint under-counts weights held by CoreML/ANE, so treat RSS as the safer number.

Tables follow in section 6. Dictation latency (end of audio to text) for a resident model is the "decode s" column.

Summary of dictation clips (D1 to D8, 7 to 15 s), background QoS:
- Parakeet: inference 0.23 to 0.70 s, whole process 0.9 to 1.4 s including model load.
- Whisper turbo auto: decode 19 to 34 s (wall minus load; 1.2 to 3.8 s per audio second).
- large-v3 auto: decode 193 to 334 s (about 23 to 30 s per audio second), i.e. roughly 7 to 16x slower than turbo in the same conditions.

## 4. Approximate references (short mixed clips)

These are **my best guess, not ground truth**. I built them from where Parakeet, turbo auto/en/ur/hi/prompt and large-v3 agree, plus judgment; I did not hear the audio. Romanized Urdu spelling is arbitrary. `[...]` marks a stretch I could not resolve.

- **D3**: "I can go take something that can be effective tomorrow on the show floor. I will ask for it, and I'm not listening to [Urdu tail: something like "aisa ki Asim bhai ... kaam karna wala", unresolved]."
- **D4**: "[Nahin / next], so you're missing one point here. I agree with you, but partially. What you're missing is that, yes, hamara rock jo hoga, [hoga]..."
- **D6**: "Thirty, forty percent somewhere. Aur by the way, Q3 mein dekho, kuch cheezein reh gayi, again bottleneck mein tha, direction... go-to-market direction change, strategy change, go-to-market direction mein tactically, mein tactically [change]."

Scoring against these (qualitative, no WER):
- D3: all configs got the English half right. Only turbo ur/hi and the prompted run and large-v3 attempted the Urdu tail at all; turbo auto/en stopped at "Ayaz.." and translate gave "Ayaz." Prompted turbo gave "Ayaz ki Aasim bhai editing ho kaam karna wala", closest to my guess. Parakeet gave "I ask the asimbay el thing".
- D4: large-v3 auto stopped at "yes, our love" (dropped the Urdu tail); turbo auto/en: "humara wrong jooga"; prompted ur: "humara raun johoga" (best); hi: Devanagari gibberish; Parakeet: "Hamara Rogjova".
- D6: Parakeet and prompted turbo are the only Latin-script outputs with Urdu words kept ("Q3 me", "dhekho kuchh cheeze"). Auto/hi gave Devanagari. en turned the Urdu into English guesses ("I had a bottleneck I had a little go to market direction"). large-v3 auto translated the Urdu into English prose ("I changed the direction a little bit").


## 5. Output script (share of letters: Latin / Perso-Arabic / Devanagari, %)

| config | M1 | M2 | M3 | D3 | D4 | D5 | D6 |
|---|---|---|---|---|---|---|---|
| Parakeet v3 | 100/0/0 | 100/0/0 | 100/0/0 | 100/0/0 | 100/0/0 | 100/0/0 | 100/0/0 |
| turbo auto | 100/0/0 | 72/0/28 | 4/53/43 | 100/0/0 | 100/0/0 | 100/0/0 | 62/0/38 |
| turbo en | 100/0/0 | 100/0/0 | 100/0/0 | 100/0/0 | 100/0/0 | 100/0/0 | 100/0/0 |
| turbo ur | 42/58/0 | 18/82/0 | 0/100/0 | 82/18/0 | 70/30/0 | 79/21/0 | 52/48/0 |
| turbo hi | 73/0/27 | 21/0/79 | 5/0/95 | 64/0/36 | 0/0/100 | 0/0/100 | 60/0/40 |
| turbo ur + romanized prompt | 100/0/0 | 100/0/0 | 44/40/16 | 100/0/0 | 100/0/0 | 100/0/0 | 100/0/0 |
| turbo auto, task=translate | 100/0/0 | 100/0/0 | 100/0/0 | 100/0/0 | 100/0/0 | 100/0/0 | 100/0/0 |
| large-v3 auto | - | - | - | 100/0/0 | 100/0/0 | - | 100/0/0 |

## 6. Timing

### 6a. Parakeet TDT v3 via fluidaudiocli (background QoS, warm; includes ~0.7 s process + model load per call)

| clip | audio s | wall s | inference s (CLI) | RTFx (audio/inference) | peak footprint MB | max RSS MB |
|---|---|---|---|---|---|---|
| M1_mic_spk2_mixed | 90.0 | 7.28 | 6.39 | 14x | 68 | 117 |
| M2_mic_me_mixed | 70.0 | 7.03 | 5.96 | 12x | 67 | 120 |
| M3_sys_spk1_mixed | 67.0 | 6.76 | 5.99 | 11x | 67 | 125 |
| C1_mic_spk2_english | 73.0 | 2.43 | 1.64 | 45x | 66 | 124 |
| D1_en | 7.5 | 1.03 | 0.29 | 26x | 39 | 84 |
| D2_en | 15.4 | 1.40 | 0.66 | 23x | 52 | 101 |
| D3_mixed | 10.5 | 1.10 | 0.39 | 27x | 39 | 84 |
| D4_mixed | 7.2 | 0.91 | 0.25 | 28x | 38 | 83 |
| D5_mixed | 15.2 | 1.37 | 0.70 | 22x | 53 | 102 |
| D6_mixed | 14.5 | 1.26 | 0.48 | 30x | 40 | 83 |
| D7_en | 7.8 | 0.99 | 0.27 | 29x | 39 | 83 |
| D8_en | 8.1 | 0.90 | 0.23 | 35x | 38 | 83 |

### 6b. WhisperKit large-v3-v20240930_turbo, language=auto, task=transcribe (background QoS, warm CoreML cache)

`wall` = whole `whisperkit-cli` process. `model load` = WhisperKit-reported load (warm, 3-7 s). `decode s` = wall - load. Dictation latency = decode s (a resident model, as in Droppy, pays no load).

| clip | audio s | wall s | model load s | decode s | decode/audio | peak footprint MB | max RSS MB |
|---|---|---|---|---|---|---|---|
| M1_mic_spk2_mixed | 90.0 | 56.5 | 5.4 | 51.1 | 0.57 | 381 | 778 |
| M2_mic_me_mixed | 70.0 | 74.5 | 4.8 | 69.7 | 1.00 | 322 | 1128 |
| M3_sys_spk1_mixed | 67.0 | 74.9 | 5.8 | 69.0 | 1.03 | 319 | 1050 |
| C1_mic_spk2_english | 73.0 | 49.2 | 5.1 | 44.2 | 0.60 | 326 | 1272 |
| D1_en | 7.5 | 35.7 | 6.9 | 28.8 | 3.84 | 204 | 752 |
| D2_en | 15.4 | 23.8 | 4.9 | 19.0 | 1.23 | 204 | 791 |
| D3_mixed | 10.5 | 39.3 | 5.3 | 34.0 | 3.24 | 204 | 741 |
| D4_mixed | 7.2 | 33.9 | 7.1 | 26.7 | 3.71 | 204 | 944 |
| D5_mixed | 15.2 | 34.3 | 7.2 | 27.2 | 1.79 | 204 | 843 |
| D6_mixed | 14.5 | 28.3 | 7.1 | 21.2 | 1.46 | 204 | 942 |
| D7_en | 7.8 | 28.7 | 5.6 | 23.1 | 2.97 | 204 | 957 |
| D8_en | 8.1 | 27.3 | 6.0 | 21.4 | 2.64 | 204 | 1090 |

### 6c. WhisperKit large-v3 (Droppy's installed variant), language=auto (background QoS)

| clip | audio s | wall s | model load s | decode s | decode/audio | peak footprint MB | max RSS MB |
|---|---|---|---|---|---|---|---|
| D3_mixed | 10.5 | 274.9 | 32.7 | 242.2 | 23.1 | 336 | 1965 |
| D4_mixed | 7.2 | 196.1 | 2.7 | 193.4 | 26.9 | 337 | 1724 |
| D6_mixed | 14.5 | 334.9 | 1.0 | 333.9 | 23.0 | 337 | 1921 |
| D1_en | 7.5 | 231.2 | 2.3 | 228.9 | 30.5 | 337 | 1928 |

### 6d. Normal-priority datapoints (3 clips ran before I reverted to background QoS; see caveat)

| config | clip | audio s | wall s | model load s | decode s |
|---|---|---|---|---|---|
| turbo_en_transcribe_normal | M2_mic_me_mixed | 70 | 10.2 | 0.88 | 9.3 |
| turbo_en_transcribe_normal | M3_sys_spk1_mixed | 67 | 12.7 | 0.86 | 11.9 |
| turbo_ur_transcribe_normal | M1_mic_spk2_mixed | 90 | 7.7 | 0.84 | 6.9 |

## 7. Side-by-side transcripts (verbatim tool output, unedited)

### M1_mic_spk2_mixed (90 s)

- **Parakeet v3** [100/0/0]: On the contrary, okay. So what I am thinking is uh in the past three quarters rocks ko banan kiffer, directions changes. Rocks will be rocks complete. Unki bad review, unka completion, unki closing properly nahi chari. Um matrix is maybe a part kind of we are not getting something too much out of this because we are still building some of the processes in different teams taken. So my thought is let's hold all these things for a quarter. And with that direction, it changed. So let's a quarter can give it a time to settle it down and we can resurface it in the Q1 of 20. So what I'm thinking is we should cut down the EOS to forty-five minutes and we should only have ITS for Q4. Different direction.

- **turbo auto** [100/0/0]: On the contrary, I would say I would share it with two options? Okay. So what I am thinking is, in the past three quarters, rocks have been made by the direction changes. Rocks are completely different. Rocks are completely completely gone, after their review, their completion, their closing is not done properly. If we talk about metrics, we are not getting something too much out of this because we are still building some of the processes in different ways. We are not going in a different direction. Let's go ahead and clarify your story. I will clarify this, we are in different directions

- **turbo en** [100/0/0]: On the contrary, I would say I would share it with two options? Okay. So what I am thinking is, in the past three quarters, rocks have been made by the direction changes. Rocks are completely different. Rocks are completely completely gone, after their review, their completion, their closing is not done properly. If we talk about metrics, we are not getting something too much out of this because we are still building some of the processes in different ways. We are not going in a different direction. Let's go ahead and clarify your story. I will clarify this, we are in different directions

- **turbo ur** [42/58/0]: اور دیکھنے میں کیا کہہ رہا ہوں اس کو بھی شیر کرتوں یا دو آپشن کے پاس ہو تو وٹ آئیم مجھے ہیں آہ ان دے پاس 3/4 روکس کو بنا کے اس میں کچھ ڈیریکشن چینجے ہو گئے راکس بلکل بیسے نکردے دیں راکس اگر کمپیٹ ہو بھی کئے ان کے باعت ان کا ریو ان کا کمپیشن ان کی کلوزنگ پروپلی نہیں کی جانے ہم میٹریکس میں بھی اگر ہم بات کریں تو we are not getting something too much out of this because we are still building some of the processes in different ways ہم ہم درہنٹ ڈیرکشن میں ہی رہے ہیں چل تو اپنی بات مکمل کرنے میں اس کو جرا خلائفہ کروں So what I am thinking is we should cut down the EOS to 45 minutes and we should only have ITS for Q4 Okay, I will clarify this. We are in different directions

- **turbo hi** [73/0/27]: on the contrary, मैं कया कह रहा हां, उसको भी अच्छी कटू हाऊ यह 2 औप्शन उनके पास हो so, what I am thinking is In the past three quarters, rocks को बनांके किसमें कछ डेर्चिन्स चेंज़ हो गए rocks is completely different rocks if it is complete, after the review and completion it is not done properly if we are talking about the metrics we are not getting something too much out of this because we are still building some of the processes in different ways हम इस दिरेक्शन में जारहे हैं, चल्ड बनी बाद में अगमल करने में इसको जरा क्लारफाएगा है So what I am thinking is we should cut down the EOS to 45 minutes and we should only have ITS for Q4 Okay, I will clarify that, we are in different directions

- **turbo ur + romanized prompt** [100/0/0]: On the contrary, mein kya kya raho, us ko bhi share kart hoon, yaa 2 options in ke paas ho? Haan, kai. So, what I am thinking is, in the past 3 quarters, rocks ko bana ke, us mein kuch directions changes ho gayi. Rocks bilkul vaisi nekarte hai ni. Rocks agar complete ho bhi kai, unke baad unka review, unka completion, unki closing properly nahi ki jali. Aum metrics is maybe agar hum baat karen to we are not getting something too much out of this because we are still building some of the processes in different things. Okay. So my thought is, let's hold all these things for a quarter. Thode si abhi in events se hamari chizai wapre is time raunne, hum log eek different direction mein aiz a business chaare hain, and with that direction kaafi chizai hamari change ho raigay hain. So let's, a quarter can give it a time to settle it down, and we can resurface it in the Q1 of 27th. We are not going in different direction mein hi hain. Chal do upni baad mokamal karni hai, maiz ka jara clarify kare ho. So what I'm thinking is we should cut down the EOS to 45 minutes and we should only have ITS for Q4. Hmm. Okay, mein is baat o clarifier tu. Different direction mein diya hain.

- **turbo auto, task=translate** [100/0/0]: On the contrary, I would say I would share it or have two options? Okay So what I am thinking is In the past three quarters, rocks could be made by the direction changes If we are not getting something too much out of this because we are still building some of the processes in different ways. So my thought is, let's hold all these things for a quarter. In events, we are starting to change a different direction as a business, and with that direction, a lot of things are changing. So a quarter can give it a time to settle it down, and we can resurface it in the Q1 of 2017. We are not going in a different direction. Let's do our conversation, I will clarify it. So what I am thinking is we should cut down the EOS to 45 minutes and we should only have ITS for Q4. Okay, I will clarify that. We are going to different directions.

### M2_mic_me_mixed (70 s)

- **Parakeet v3** [100/0/0]: I think you finally found your feet. And I think we should let you guys continue to build up your processes. Meanwhile, we work heavily and actively on building up the pipeline for next year. But as we build up the pipeline for next year, we have to use the After EOS Karth, Hamari EOS K jo Rocks Hong Kong Messi is the same So EOS carte even though gaps, even though perfect as he is quarter B just quarters chili, Barthes. thoughts.

- **turbo auto** [72/0/28]: I think you've finally found your feet and I think we should let you guys continue to build up your processes meanwhile we work heavily and actively on building of the pipeline for next year but as we build up the pipeline for next year that means that if we do EOS then then our EOS rocks will be the ones that we will be able to do in the score queue 4 तो मैं यह समाज ताओं कि यह इस करते रहनी करते हैं इवन दो पर्फेक्ट नहीं वह एसी ही लंगड़ी होगी इस प्सक्रेकर जलिए तब भी वह करते हैं कि था थाउट्स

- **turbo en** [100/0/0]: I think you've finally found your feet and I think we should let you guys continue to build up your processes Meanwhile we work heavily and actively on building of the pipeline for next year But as we build up the pipeline for next year That means that if we do EOS, then the EOS rocks will be the ones that we will be able to do in the score of Q4 so, I should say that EOS should do this even though yeah, there is gaps even though it is just not perfect but it will be like a long time this quarter has also been as we did this but, when you do not want to do this Thoughts?

- **turbo ur** [18/82/0]: کچھ گپس ہیں ان کو آپ نے واپس سے ہی ہائر کرنا ہے انجنیرنگ سائٹ پہ بھی میں سمجھتا ہوں کہ ایک دو لوگوں کو خالی صرف دیکھنا شروع کردنا چاہیے آپ لوگوں کو شروع کردنا چاہیے پائٹلائن کے کیا معاملات ہوں میں آپ لوگ کو بتا دوں گا تو آپ لوگ کو پتا ہوا ہے کہ ایکشپیک کرنا ہے تو دلیوری سائٹ پہ بہت زیادہ ہی ہمیں کچھ شیک اپ کرنے کی ضرورت ہے میں جانتے ہیں کہ آپ نے جانتے ہیں اور میں آپ کو دیکھیں آپ کو دیکھیں آپ کو دیکھیں گ meanwhile we work heavily and actively on building of the pipeline for next year but as we build up the pipeline for next year اس کا مطلب یہ ہے کہ ہم اگر تو ہم EOS کرتے ہیں تو پھر ہماری جو EOS کے جو rocks ہوں گے وہ ہی ہوں گے ہم ایسے بھی اس کو اس کوئی ورمے کرنے والے ہیں تو میں یہ سمجھتا ہوں کہ EOS کرتے رہنی چاہیے ایون دو ہاں اس میں گیپس ہیں ایون دو وہ پرفیکٹ نہیں ہوگی ایسی ہی لنگڑی ہوگی اس قوارٹر بھی جیسی پسٹلے قوارٹر چلی ہے لیکن تب بھی وہ EOS کرتے رہنی چاہیے تھوٹس

- **turbo hi** [21/0/79]: प्रिफ ने रही कार रहा नोग आपके लापके हैं एगलोगें साइटेंड नहीं कि अब देखनें निग्राइब के लिए पारण दाहीं स्थावार कि यह पार्णाव को अपने प्रिफ यहां पूंड को पता हूं आपके हैं दिलिव बखाने पर बाँ बाँ से ल meanwhile we work heavily and actively on building of the pipeline for next year but as we build up the pipeline for next year उसका मतलब यह है कि हम अगर को हम EOS करते हैं तो फिर हमारी जो EOS के जो रॉक्स होंगे वो ही होंगे जो हम वैसे भी स्कोर की उपफोर में तड़ने वाले हैं सो तो मैं समझता हूं के करते रहनी चाहिए इवन दो हाँ उसमें से इवें दो वो पर्फेक्ट नहीं होगी वह एसी ही लंगड़ी होगी स्कौर्टर भी जैसी पिस्ले पार्टर चलिए हैं लिकिन तब भी वह युए करते रहें चाहिए है थाउट्स

- **turbo ur + romanized prompt** [100/0/0]: taher hai kuch gap sa in ko aap ne vaapese re-hire harina hai, engineering side pe pe pe pe s'mashto aum ke eek do lo go khani sarip na shuru gargana chahehi haap lo go. Sirip shuru gargana chahehi hai. Pairpline ke kia maamilata hai maan baataha ho na aap logo ko bata doon aap logo kko bata hoa hoa hain ka ekspet kerna. Toh delivery side pe pe pe baah dada i don't think ke humain kuch shake up krnay kishe rote hai. I think you finally found your feet and I think we should let you guys continue to build up your processes. meanwhile we work heavily and actively on building up the pipeline for next year. But as we build up the pipeline for next year, us ka matlab ye hai ke hum, agar ta hum EOS karte hai toh phir humari joh EOS ke joh rocks honge, wohi honge joh hum wese bhi score Q4 mein tarnay wale hai. toh mahi yeh samahtta hoon ke EOS karte rheni chahiye even though haan us mein gaps hai even though woh perfect nahi hooghi woh aise hi langdhi hooghi is quarter bhi jaisi pishly quarters chalhi hai lakin tab bhi woh EOS karte rheni chahiye. thoughts

- **turbo auto, task=translate** [100/0/0]: I don't think we've finally found your feet and I think we should let you guys continue to build up your processes. Meanwhile we work heavily and actively on building of the pipeline for next year. But as we build up the pipeline for next year, that means that if we do EOS, then the EOS rocks will be the ones that we will be able to do in the score queue 4. I just think we need to do that even though it has gaps in it is perfect. It will have to be a long line in this quarter as it was the same time, but then we need that gap in it.

### M3_sys_spk1_mixed (67 s)

- **Parakeet v3** [100/0/0]: I believe Jitnonavi Bula was saying like complete um yeah rock so yeah cheese a change hour cheese a change in terms of case just events events but rock Hoya Kocho or Peramos bypass, yeah, hold Kurke or Chizota. So The vochi is vesi chalery, already Puras Ali Chalia, so Hamosko Vesi like a child, or yeah, ideas uh type short meeting hoja. Just message ideas, or because she's a discussion with short meeting majors cover hoja. Or because Because scorecard hatad, yeah, ko information up key events related up near the sales key koi cheese hair koy ko ya lag like

- **turbo auto** [4/53/43]: जी नहीं सही है सारे पॉइंट साइब जितनों ने भी बोले हैं वह सही है लाइक कंप्लीट हम यह रॉक्स वगरा जो है वैसी यह चीजे चेंज हो रही है काफी چیزیں چینج ہیں ترم سوکے جیسے اوینٹس ہیں اچھے ہوا سے اوینٹس ہوں اس میں کام اچھے ہوا سا آ سکتا ہے تو بنظرک کہ ہم وہی پریکٹس کریں کہ ڈاک ہو یا کچھ ہے اور پھر ہم اسے بائے پاس یا ہولڈ کر کے کوئی اور چیز اٹھاتا ہے تو وہ چیز ہیسی چل رہی ہے ہماری پورے سالہ ہی چلی ہے تو ہم اس کو ویسی لے کے چلتے رہتے ہیں اور یہ ایڈی ایس ٹائپ کی کوئی شورٹ میٹنگ ہو جائے جس میں صرف ای और बीकुछ चीज़ें से स्कोर कार्ड हटा दिये और कोई information आपके बास है वेंड से आपने दे रही सेल्स की कोई चीज है कोई कोई लग अई इडेस से हटके कोई information वो चीज प्रवाइड कर दिये

- **turbo en** [100/0/0]: - Yeah, I mean, it's true. I believe that everything you have said is true. Like, the rocks are completely changing things. In terms of cases, events like the case are good events so we can come out. We practice that we can rock or something like that and then bypass us or hold on and we have to do that. We've already played it like this, and this was the whole year. So, we've got that idea type. Or, this idea type of short meeting, which we don't even discuss or discuss about the same thing. But the short meetings are covered in short meeting. and

- **turbo ur** [0/100/0]: جی نہیں صحیح ہے سارے پوائنٹس جتنے بھی بولے ہیں یہ روکس وغیرہ چیزیں چینج ہو رہی ہیں کافی چیزیں چینج ان ٹرمس آف کے جیسے ایونٹس ہیں تو اچھے خاصے ایونٹس ہوں اس میں کام اچھا خاصہ آ سکتا ہے تو بنیزبت کہ ہم وہی پریکٹس کریں کہ راک ہو یا کچھ ہو اور پھر ہم اسے بائے پاس یا ہولڈ کر کے کوئی اور چیز اٹھاتے ہیں تو وہ چیز ویسی چل رہی ہے ہماری پورے سال ہی چلی ہے تو ہم اس کو ویسی لے کے چلتے رہتے ہیں اور یہ ایڈی ایس ٹائپ کی کوئی جو ایک شورٹ میٹنگ ہو جائے جس میں صرف ا اور بھی کچھ چیزیں جیسے سکور کارڈ ہٹا دیئے یا کوئی انفرمیشن آپ کے پاس ہے ایونٹ سے ریلیٹڈ آپ نے دی ری سہیے سیلز کی کوئی چیز ہے کوئی کوئی الگ لائک آئیڈیس سے ہٹ کے کوئی انفرمیشن ہے وہ چیز پروائیڈ کر دی

- **turbo hi** [5/0/95]: जी नहीं सही है सारे पॉइंट साइब जितनों ने भी बोले हैं वह सही है लाइक कंप्लीट हम यह रॉक्स वगरा जो है वैसी यह चीजे चेंज हो रही है काफी चीजेएचे इंडर आफ के जैसे विन्ट से तो अच्छेखाए वैंट से विंट उसमें काम अच्छा खासब आ सकता है तो बनिस्बत हम वहीं प्रैक्टिस्करेंग कि कुछ और फिर रमसे बाइपास या होलड करके को और चीज उठाते हैं वहीं चाल रही है। मिल्� और भी कुछ चीजें जैसे स्कोर्कार्ड हटा दिए या कोई information आपके बास है इविंट से आपने डेरी साइश की कोई चीज है कोई कोई इस लग लाइक अई दिर से हटके कोई information और वो सब्सक्राइब करें

- **turbo ur + romanized prompt** [44/40/16]: Jee, nahi, saai hai, saare points I believe, jitnou ne bhi bool hai, wou saai hai, like complete hum, ye rocks vokra johai, waisi ye bhi, cheezhe change ho rhi hai kaafi. ھو اچھے خواہ سے events ہوں اس میں کام اچھا خواہ سے آ سکتا ہے تو بنسبت کہ ہم وہی practice کریں کہ rock ہو یا کچھ ہو اور پھر ہم اسے bypass یا hold کر کے کوئی اور چیز اٹھاتے ہیں تو وہ چیز ویسی چل رہی ہے ہماری پورے سال ہی چلی ہے تو ہم اس کو ویسی لے کے چلتے رہتے ہیں اور یہ ideas type کی کوئی جو ایک short meeting ہو جائے جس میں صرف ideas نہیں اور بھی کچھ چیزیں discuss ہو جائے لیکن وہ ایک short meeting میں ج और भी कुछ चीजें जैसे score card हटा दिये, या कोई information आपके बास है events related आपने दी, सही है sales की कोई चीज है, कोई अलग like idea से हटके कोई information है, वो चीज प्रोवाइट कर दी.

- **turbo auto, task=translate** [100/0/0]: Yes. No, it's true. I believe all the points I said, they're right. Like completely rocks, etc. So, these things are changing. So we can practice that rock or something and then we can pass or hold or something else. So we can do it. So we can do it like this. And then, I would like to add an idea to a specific type of product.

### C1_mic_spk2_english (73 s)

- **Parakeet v3** [100/0/0]: because there has been a lot of changes every L10 to L10. We were not able to carry the rocks we as we as in we have intended. We have not been able to carry the matrix as we invented. And we still need some more time to settle these things. And we have a lot of load from for the events discorder. There were two to three options. One option is carry the L10 as it is. It's giving a great value, carry it should be done the way it is been happening. Second option stop L10 entirely for Q third option let's keep matrixes and rocks and to do's aside and have forty-five to sixty minutes of just ideas and discussion and talk. This group this group will talk around different issues, projects, whatever to bring on everyone on the same page. Okay but these are the three options we have.

- **turbo auto** [100/0/0]: because there has been a lot of changes every L10 to L10. We were not able to carry the rocks as we have intended. We have not been able to carry the matrix as we intended. and we still need some more time to settle these things and we have a lot of load for the events this quarter. There were two to three options. One option is carry the L10 as it is. It's giving a great value, carry, it should be done the way it has been happening. Second option, stop L10 entirely for Q. for third option let's keep metrics and rocks and to do's aside and have 45 to 60 minutes of just ideas and discussion and talk this group this group will talk around different issues projects whatever to bring on everyone on the same page these are the three options

- **turbo en** [100/0/0]: because there has been a lot of changes every L10 to L10. We were not able to carry the rocks as we have intended. We have not been able to carry the matrix as we intended. and we still need some more time to settle these things and we have a lot of load for the events this quarter. There were two to three options. One option is carry the L10 as it is. It's giving a great value, carry, it should be done the way it has been happening. Second option, stop L10 entirely for Q. for third option let's keep metrics and rocks and to do's aside and have 45 to 60 minutes of just ideas and discussion and talk this group this group will talk around different issues projects whatever to bring on everyone on the same page these are the three options

### D1_en (8 s)

- **Parakeet v3** [100/0/0]: Add new functions or AI. It's I think it's a very similar thing and it will take some getting used to to get it right. So

- **turbo auto** [100/0/0]: Add new functions or AI. I think it's a very similar thing. It takes some getting used to to get it right.

- **turbo en** [100/0/0]: Add new functions or AI. I think it's a very similar thing. It takes some getting used to to get it right.

- **large-v3 auto** [100/0/0]: add new functions or AI. I think it's a very similar thing. It will take some getting used to to get it right.

### D2_en (15 s)

- **Parakeet v3** [100/0/0]: but probably sessions. I actually don't think that's a bad thing. I think that's a good thing. I genuinely believe that's a good thing. So that Adam can get more face time with you all and Adam can run things with you.

- **turbo auto** [100/0/0]: probably in the sessions. Actually, I don't think that's a bad thing. I think that's a good thing. I genuinely believe that's a good thing. So that Adam can get more face time with you all and Adam can run things with you.

- **turbo en** [100/0/0]: probably in the sessions. Actually, I don't think that's a bad thing. I think that's a good thing. I genuinely believe that's a good thing. So that Adam can get more face time with you all and Adam can run things with you.

### D3_mixed (10 s)

- **Parakeet v3** [100/0/0]: I can go take something that can be effective tomorrow on the show floor, I will ask for it and I'm not listening to I'm not listening to I ask the asimbay el thing.

- **turbo auto** [100/0/0]: I ask that I can go take something that can be effective tomorrow on the show floor. I will ask for it. And I'm not listening to Ayaz..

- **turbo en** [100/0/0]: I ask that I can go take something that can be effective tomorrow on the show floor. I will ask for it. And I'm not listening to Ayaz..

- **turbo ur** [82/18/0]: اے آسیم بھائے کے لئے دو چار گھنٹے لے رہے کے I can go take something that can be effective tomorrow on this show floor I will ask for that and I am not listening to I am not listening to I am not listening to I am not listening to

- **turbo hi** [64/0/36]: आपक्राना थार्टेवारा थो चांका थाड़ा कि I can go take something that can be effective tomorrow on the show floor, I will ask for it and I'm not listening to I Am not listening to Ayaz कि आप आसे भाई अधाए लिटेमना काम घरना हुआ

- **turbo ur + romanized prompt** [100/0/0]: I can go take something that can be effective tomorrow on the show floor. I will ask for it and I'm not listening to Ayaz ki Aasim bhai editing ho kaam karna wala.

- **turbo auto, task=translate** [100/0/0]: I can go take something that can be effective tomorrow on the show floor. I will ask for it and I'm not listening to Ayaz.

- **large-v3 auto** [100/0/0]: I can go take something that can be effective tomorrow on the show floor. I will ask for it and I'm not listening to Ayaz's Asim bhai or Elton's work.

### D4_mixed (7 s)

- **Parakeet v3** [100/0/0]: What Nick, so you're missing one point here. I agree with you, but partially. What you're missing is that yes, Hamara Rogjova.

- **turbo auto** [100/0/0]: but Nick, so you're missing one point here. I agree with you, but partially. What you're missing is that yes, humara wrong jooga,

- **turbo en** [100/0/0]: but Nick, so you're missing one point here. I agree with you, but partially. What you're missing is that yes, humara wrong jooga,

- **turbo ur** [70/30/0]: نہیں so you're missing one point here I agree with you but partially what you're missing is that yes ہمارا راک جو ہوا وہ ہمارا راک جو ہوا

- **turbo hi** [0/0/100]: निएवाद रुट रुट रूट सकताव है

- **turbo ur + romanized prompt** [100/0/0]: What? Nik, so you're missing one point here. I agree with you, but partially. What you're missing is that, yes, humara raun johoga hoa humara raun johoga.

- **turbo auto, task=translate** [100/0/0]: What you're missing is that yes, our wrong,

- **large-v3 auto** [100/0/0]: No, so you are missing one point here. I agree with you but partially. What you are missing is that yes, our love

### D5_mixed (15 s)

- **Parakeet v3** [100/0/0]: to be honest better than most. Even in with all of the trials and tribulations that we have been going through, we're still better than most EMGs dikraya. Because I've been talking to so many people, agencies, travel pay, customers, etc.

- **turbo auto** [100/0/0]: To be honest, better than most hain. Even with all of the trials and tribulations that we have been going through, we are still better than most. Yeh mujhe chiz dik rahi hai. Because I have been talking to so many people, agencies, travel pay, customers, etc.

- **turbo en** [100/0/0]: To be honest, better than most hain. Even with all of the trials and tribulations that we have been going through, we are still better than most. Yeh mujhe chiz dik rahi hai. Because I have been talking to so many people, agencies, travel pay, customers, etc.

- **turbo ur** [79/21/0]: تو بھی ہونست بہتر دن موست ہیں even in with all of the trials and tribulations that we have been going through we are still better than most یہ مجھے چیز دکھ رہے ہیں because I have being talking to so many people agencies, travel pay customers etc

- **turbo hi** [0/0/100]: तोब्या हमें थे कि बहना से थे कि को तरहें से रहे हैं। तुम्हे रहे हूं के बेहने हैं। यह मजगे हैं था दिख्रही है। तक्तार काई में तो कि अज़ा के सुछारी थे हैं।

- **turbo ur + romanized prompt** [100/0/0]: To be honest, better than most hain. Even with all of the trials and tribulations that we have been going through, we are still better than most. Yeh mujhe chiz dikh rahi hai. Because I have been talking to so many people, agencies, travel pay, customers, etc.

- **turbo auto, task=translate** [100/0/0]: To be honest, better than most hain. Even with all of the trials and tribulations that we have been going through, we are still better than most. Yeh mujhe chiz dik rahi hai. Because I have been talking to so many people, agencies, travel pay, customers, etc.

### D6_mixed (14 s)

- **Parakeet v3** [100/0/0]: 30, 40% somewhere. Or by the way, huh? Q3 me they go put teaser head, eh? Again, my bottleneck method direction man go to market direction change strategic change. Go to market direction tactically tactically.

- **turbo auto** [62/0/38]: 30-40% somewhere by the way Q3 में कुछ चीज़े रहे गहीं again महां बॉटलनेक में था direction मैंने थोड़ी सी go to market direction change की go to market direction मैंने tactically मैंने tactically

- **turbo en** [100/0/0]: 30-40% somewhere and by the way Q3 again I had a bottleneck I had a little go to market direction go to market direction I had a tactical

- **turbo ur** [52/48/0]: 30 40% somewhere اور بائی دو ہاں Q3 میں دیکھو کچھ چیزیں رہ گئیں اگر مہا بوٹلنک میں تھا direction میں نے تھوڑی سی go to market direction change go to market direction میں نے tactically میں نے tactical

- **turbo hi** [60/0/40]: 30-40% somewhere और by the way Q3 में देखो कुछ चीज़े रहे गहीं again महां बॉटलनेक में था direction मैंने थोड़ी सी go to market direction change की go to market direction मैंने tactically मैंने tactically

- **turbo ur + romanized prompt** [100/0/0]: 30-40% somewhere. By the way Q3 me, dhekho kuchh cheeze raha gahin again maha bottleneck me tha direction, mein ne thoda si go to market direction change kiri strategy changing go to market direction, mein ne tactically, mein ne tactically,

- **turbo auto, task=translate** [100/0/0]: 3, I have to change the direction of the market and I have to change the strategy and I have to change the direction.

- **large-v3 auto** [100/0/0]: 40% somewhere. And by the way, yes, in Q3, some things were left, again, I was in the bottleneck, I changed the direction a little bit, I changed the go-to-market direction, I changed the strategy

### D7_en (8 s)

- **Parakeet v3** [100/0/0]: Okay, so that's ours. So I don't see that as it's not the token-based billing, that is absolutely fucking evil, bye.

- **turbo auto** [100/0/0]: So that's ours. So I don't see that as a scenario. But token-based billing, that is absolutely fucking evil, bhai.

- **turbo en** [100/0/0]: So that's ours. So I don't see that as a scenario. But token-based billing, that is absolutely fucking evil, bhai.

### D8_en (8 s)

- **Parakeet v3** [100/0/0]: We know that we go in expecting that. We still set the rock as we understand it today, but then we still let ourselves.

- **turbo auto** [100/0/0]: we know that, we go in expecting that, we still set the rock as we understand it today, but then we still let ourselves

- **turbo en** [100/0/0]: we know that, we go in expecting that, we still set the rock as we understand it today, but then we still let ourselves


## 8. Recommendation

### (a) Eavesdroppy meeting transcription

- **English-only meetings:** Parakeet (as now). It was accurate on the English control (C1), 11 to 45x faster than real time in these conditions (RTFx 11 to 14 on the code-switched meeting clips, 22 to 45 on the others), and uses about 40 to 70 MB peak footprint (84 to 125 MB RSS).
- **Meetings with Urdu/Hindi:** add a WhisperKit pass with `large-v3-v20240930_turbo`, `--language ur`, and a one-sentence romanized Hinglish `--prompt` (the one I used: "Haan bhai, meeting mein hum Q4 ke rocks aur EOS discuss kar rahe hain, lekin mujhe lagta hai ke direction change ho gayi hai."). This is the only config that kept the Urdu content in Latin script across M1, M2 and D3 to D6. Do not use `--language en`, `--language hi` or `--task translate`. Do not use plain `auto` unless a script-mixed transcript is acceptable.
- Caveats on that setup: (1) M3, the heaviest Urdu clip, still drifted into Perso-Arabic and Devanagari in the second half even with the prompt; a post-step that transliterates, or letting the notes LLM read mixed scripts, is needed. (2) Repetition loops appear ("pe pe pe pe", "mein ne tactically, mein ne tactically"); the existing word-level cleanup (`MAX_WORD_S`, dedupe) would need a repeat filter. (3) Urdu spellings are noisy; meaning is readable, exact words are not. (4) Whisper gives segment timestamps only by default; Eavesdroppy's pipeline uses Parakeet word timings for speaker alignment, so a hybrid (Parakeet for timing and English, Whisper text for Urdu stretches) needs real integration work. I did not test word timestamps.
- Cost: in these conditions turbo took roughly 0.5 to 1.0 s per audio second at background priority and about 0.15 to 0.2 at normal priority (3 clips), so a 51-minute meeting would be an estimated 8 to 50 minutes depending on priority. Estimate only; I did not run a full meeting.
- Cheapest way to scope it: only run Whisper on stretches where Parakeet confidence is low or the text looks like phonetic junk, rather than the whole meeting. Not tested.
- Also fix or investigate the empty `system.flac` (section 2) before tuning models: for most of this meeting the remote side only exists as mic bleed.

### (b) Droppy dictation (recommendation only, settings untouched)

- Current: `voiceTranscribeBackend=parakeet`, `fluid_parakeet-tdt-v3`, `auto`. For English and English-heavy dictation this is the right choice: D1, D2, D7, D8 were all correct, in under a second.
- For Urdu-heavy dictation: `voiceTranscribeBackend=whisper` with language `ur`. Plain Whisper `auto` mostly gave readable Latin output on short clips (D3, D4, D5), but flipped to Devanagari on D6 and in M2/M3. `hi` was worse than `ur` on this speaker.
- Model: `runtime-state.json` shows Droppy has only `openai_whisper-large-v3` installed. Whether `large-v3-v20240930_turbo` can be selected in Droppy is **unverified**. If it can, prefer turbo: large-v3 was roughly 7 to 16x slower than turbo in the same conditions (decode 193 to 334 s vs 19 to 34 s for 8 to 15 s clips at background priority), though I did not measure large-v3 on an idle machine.
- Droppy's prompt support (needed for the romanized-output trick) is unknown. Without it, expect Urdu words in Perso-Arabic script when language is `ur`.
- A single setting that is best for both does not exist; the practical choice is two profiles (parakeet/auto for daily English, whisper/ur for Urdu dictation), if Droppy lets you switch quickly.

## 9. Uncertainties and limits

- No ground truth. Quality statements are qualitative, based on agreement between models and my reading; the references in section 4 are approximate and were built from model outputs, not from listening.
- Timings are contended and mostly at background priority; dictation latency for Whisper on an idle machine is not measured. large-v3 was measured only on 4 short clips.
- Single meeting, two speakers (the user plus one remote voice) on the mixed clips. The remote clips are mic bleed, so they are noisier than a clean system tap.
- WhisperKit CLI 1.1.1 may differ from the version embedded in Droppy (default decoding options, chunking, prompt handling).
- The prompt was one hand-written sentence; I did not tune it. The result shows the idea works, not that it is optimal. The prompt also shapes vocabulary ("EOS", "rocks", "Q4" appear in it and in this meeting), so its effect on unrelated content is untested.
- Parakeet vocab boosting (`--custom-vocab`) was not used.
- 3 clips ran at normal priority before I reverted (see section 2).
