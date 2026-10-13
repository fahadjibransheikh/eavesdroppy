# Commercial AI meeting note-takers: feature research for detta-meetings v1

Researched 2026-10-11 from live sources (vendor help centers, docs, changelogs, pricing pages, Apple developer docs, plus third-party reviews where flagged). Nothing here is from memory. Pricing and limits drift monthly; every price is "as seen 2026-10-11".

Conventions: **[V]** = vendor's own page; **[3P]** = third-party review (many are competitors' blogs and are slanted); **unverified** = no primary source found. Link citations are in the per-product evidence (section 3) and, for Granola, inline in section 2. Matrix cells are summaries of those cited claims.

Our app, for reference: personal, local-first macOS recorder; bot-free; mic + system audio; local ASR; Claude summaries; lives as a Droppy notch droplet.

---

## 1. Feature matrix

### 1a. Bot-free-first products

| Feature | **Granola** | **Jamie** | **Krisp** | **Bluedot** | **Notion AI Meeting Notes** |
|---|---|---|---|---|---|
| Bot vs bot-free | Bot-free only | Bot-free only (audio only) | Bot-free default; optional bot for Zoom/Meet/Teams | Bot-free (Chrome ext + desktop + mobile); optional Zoom bot | Bot-free (desktop app captures system audio + mic) |
| Platforms | macOS, Windows, iOS, Android (1 Jul 2026), Apple Watch (28 Jul 2026); web = view/edit only | macOS 14.4+, Windows, iPhone; no Android | Win/macOS, iOS/Android (in-person), browser ext | Chrome ext, Mac/Win desktop, iOS/Android, Apple Watch | Desktop (mic+system), browser/mobile (mic only) |
| Speaker ID without bot | Me/Them (mic vs system). Named "speaker tags" via macOS Accessibility reading the Zoom/Teams/Meet UI. No voiceprints documented | Post-meeting diarization; user names each voice; "Speaker Memory" voiceprints persist across meetings (disableable, GDPR biometric) | Labels + manual rename; calendar attendee suggestions; voiceprints unverified | Auto labels where capture allows (desktop: Meet/Teams/Zoom); generic "Speaker A/B" in groups per reviews | Names best in virtual 1:1 on desktop; Meet add-on adds group labels; English only |
| Live transcript | Yes (panel, grey/green bubbles) | No (processed after stop, ~5-10 min); "Sidekick" Q&A mid-meeting | Yes (CC on document page) | Disputed; reviewers say no | Unverified; summary generated on Stop |
| Note style | **User's typed notes + transcript + calendar -> "Enhanced" notes** | AI summary; separate Scratchpad for own notes (not merged into summary) | AI summary + live comments | AI summary; own comments/clips | AI summary; custom instructions |
| Templates | `/` menu in note; ~29 built-in (2024 changelog), custom, shareable | Custom, shareable, re-applicable after generation | 11 starters + custom | Custom (Pro+), gallery | Auto + built-in formats + custom default |
| Action items / integrations | Via Zapier/API/MCP; native Slack, Notion, Attio, HubSpot, Affinity (Salesforce Ent.) | Tasks tab pushes to HubSpot, Salesforce, Attio, Pipedrive, Notion, Asana, Linear, Slack | Salesforce, HubSpot, Pipedrive, Asana, Jira, monday, Slack, Zapier | Slack, Notion, Zapier, Make, HubSpot, Salesforce | Notion Custom Agents triggered by notes (31 Jul / 15 Sep 2026) |
| Calendar | Google/Outlook; notify 1 min before; click starts transcribing; mic-in-use ad-hoc "Meeting detected"; auto-start only if note already open | Auto-detect, mic "Start Jamie" prompt, calendar reminders, auto-start with countdown + AutoStop (Aug 2026) | Auto-record by calendar event | Bot route syncs calendar; desktop auto-recording (Jun 2026) | "Join and transcribe" 15 min before; consent click mandatory, no true auto-start |
| Cross-meeting chat/search | Granola Chat (Cmd+J) at meeting/folder/person/company/all scope; Recipes; inline citations | Ask AI (Cmd+J) with source meetings; People tab | AI Chat scoped to meeting/folder/all | Workspace-wide AI chat | Not described on help page |
| People / company pages | **Yes** (People, Companies from calendar attendees) | People tab | No | Unverified | No |
| Sharing | Link (invited/workspace/anyone), folders/spaces; web viewers get no transcript | Team workspace (paid), shared tags | Folders, per-meeting links | Collections, auto-share | Page permissions |
| Languages | 32 (changelog 2 Sep 2026; docs page says 31 desktop / 17 mobile) | 99-100+ | 16 (help center) | 100+ | 16 |
| Offline / local | Cloud ASR + cloud LLM; notes cached locally; offline read/edit; no audio kept | Cloud only (EU) | Cloud (English on-device per 3P, unreconciled) | Cloud only | Cloud |
| Screen / video | Shared-screen snapshots (Mac only); no audio/video retained | None | Audio or screen recording modes | Video via extension | None |
| MCP / API | MCP (4 Feb 2026) + REST API (Business+) | MCP + API (Pro+) | MCP (Core+) + API | MCP + webhooks (Basic+) | n/a |
| Pricing (2026-10-11) | Free (30-day history); $14 Business; $35 Ent. per user/mo | Free (10 notes/mo); Plus EUR 21; Pro EUR 39 (annual) | 7-day trial; $8 Core / $15 Adv (annual) | Free (5 lifetime); $14 / $20 / $32 (annual) | Business $20/member/mo |

### 1b. Bot-first products (with bot-free secondary modes)

| Feature | **Otter** | **Fireflies** | **Fathom** | **tl;dv** | **Read.ai** |
|---|---|---|---|---|---|
| Bot vs bot-free | Bot auto-joins (visible); botless Desktop app (Mac/Win) | Bot "Fred"; botless desktop "Take Notes" (system audio) | Bot; **Fathom 3.0 (15 Apr 2026)** bot-free on Mac only (transcript-only / audio-only; Zoom video beta) | Bot default; botless desktop app (audio only) | Bot ("web mode"); botless desktop (Feb 2026) + Meet Media API botless |
| Speaker ID without bot | Voice profiles from tagging; unknown = "Speaker N"; live names only for Zoom bot | "Speaker 1/2"; manual rename; BIPA suits allege voiceprints (3P) | Claims diarization w/o bot; mechanism undocumented | Numbers unless calendar-matched; voiceprint ID Business-only | Local mode reportedly none (3P quoting help center) vs vendor claims attributed; unresolved |
| Live transcript | Yes (Zoom Live Notes; AI Chat live) | Yes (Live Assist, Pro+) | Live summary + scratchpad in 3.0 | Unverified | Yes (desktop) |
| Note style | AI summary; own notes enhance: not documented | AI summary + Manual Notes tab | **Hybrid: scratchpad notes folded into summary** | AI summary | AI report |
| Templates | Meeting Type templates (all plans), auto-apply | 18+ built-in, custom from samples, AI Skills | ~15-17 + Meeting Types | Built-in/custom, smart prompts | Custom report templates, SPICED/BANT |
| Action items / integrations | Auto-assign; Slack, Salesforce, HubSpot, Zapier, Jira/Notion connectors | Linear, Jira, Asana, Trello, Notion, Slack, Salesforce, HubSpot, Zapier | Asana, Slack, Notion, HubSpot, Salesforce, Zapier, Make | Slack, CRM (HubSpot/Salesforce/Pipedrive), Notion, Trello, Asana, Zapier | Slack, SFDC, HubSpot, Jira, Notion, Asana, Linear, Zapier |
| Calendar | Auto-join; desktop mic detection: Off / Remind (default) / Record automatically (6 Aug 2026) | 4 auto-join modes; desktop reminders 10/5/2/0 min | Auto-capture rule: All / External / Internal / None | Auto-join; desktop prompts or auto-records | Joins all calendar meetings by default |
| Cross-meeting chat/search | Otter AI Chat | Global AskFred, Smart Search | Account-wide Ask Fathom, AI Search | Ask AI, AI Reports | Ask Read, Search Copilot |
| People / company pages | Companies (10 Sep 2026, paid) | None found | Auto company names; Deal View (Business) | None found | None found |
| Sharing | Roles, channels, folders | Channels, privacy defaults | Folders (Team), link sharing, playlists | Shared libraries (paid) | Shared folders, Workspaces, links |
| Languages | 6, one at a time | 100+ | EN + 38 (help center, 1 Oct 2026) | 30+ | 20+ (pages disagree) |
| Offline / local | Cloud | Cloud (no audio kept in desktop mode) | Cloud | Cloud; mobile queues offline recordings | Cloud |
| Screen / video | Slide capture; video Ent. | Video Pro+ | Video via bot | Bot video; botless audio only | Playback Ent. |
| MCP / API | MCP (30 Jul 2026) | MCP + GraphQL | MCP/connectors + API | MCP + API | MCP (beta) |
| Pricing | Free 300 min/mo; Pro $16.99 mo/$8.33 yr; Business $30/$19.99 | Free; Pro $18/$10; Business $29/$19 | Free; Premium $20/$16; Team $19/$15; Business $34/$25 | Free; Pro EUR 29/18; Business EUR 39/29 | Free; Pro $19.75/$15; Ent $29.75/$22.50 |

### 1c. Platform built-ins, Apple, and Mac-native local tools

| Feature | **Zoom My Notes** | **Teams Copilot** | **Google Meet Gemini** | **Apple (macOS 26/27)** | **Superwhisper** | **MacWhisper** |
|---|---|---|---|---|---|---|
| Capture | Bot-free; local device audio incl. 3rd-party/in-person | Native to Teams meetings only | Native to Meet only | Notes/Voice Memos record + transcribe on-device; Phone call recording incl. Mac (Tahoe) | System audio + mic recorded in a "mode" | Auto-detects meeting apps; system audio + mic |
| Speaker ID | Names in Zoom meetings; "Speaker 1/2" elsewhere | Native participant names | Not described | No diarization API found (absence of evidence) | Optional "Identify Speakers" (Nova cloud models); manual rename | Remote participants lumped as one speaker live; on-device speaker recognition for files |
| Live transcript | Yes | Yes (temporary or saved) | Notes during call | Yes in Notes | Realtime with some models | Unverified live |
| Note style | AI summary | AI recap | AI notes (Summary, Decisions, Next steps) | Apple Intelligence summary of transcript | "Meeting mode" minutes; custom modes | Summarize/Chat/custom prompts, BYO LLM |
| Local / offline | Cloud | Cloud | Cloud | **On-device** (SpeechAnalyzer) | **Local models** (Parakeet, Whisper, Cohere) | **Local** Whisper/Parakeet + Ollama/LM Studio |
| Calendar | Prompts on mic activity | Teams calendar | Calendar attach | n/a | None documented | None found |
| Languages | 12 (3rd-party/in-person); 46-49 in Zoom | n/a (unverified) | 8, one per meeting | ~10 in Notes | 14-24 local, more cloud | 100+ |
| Pricing | Basic: 3 AI uses/mo; paid from $8.33 (My Notes) / $14.16 (Workplace) annual | Needs Copilot license or Teams Premium | Workspace edition or Google AI plan | Free with OS | Free; Pro $8.49/mo, $84.99/yr, $249.99 lifetime | Free; Pro EUR 64 one-time |

---

## 2. Granola deep-dive (verified 2026-10-11 against docs.granola.ai, the changelog and the pricing page)

Source index for this section: help center `https://docs.granola.ai/help-center` (full page list at `https://docs.granola.ai/llms.txt`), changelog `https://www.granola.ai/updates`, pricing `https://www.granola.ai/pricing`. Page-level links are given inline. Every doc page cited was fetched 2026-10-11.

### 2.1 Capture model (bot-free, no audio kept)
- **No bot.** "There is no meeting bot — Granola runs only on your computer and uses your system audio and microphone." Desktop = macOS and Windows; mobile = iPhone and Android; web (notes.granola.ai) is view/edit only. [How transcription works](https://docs.granola.ai/help-center/taking-notes/transcription)
- **Two channels.** Transcript shows grey bubbles (left) for system audio, "usually other people", and green bubbles (right) for your mic. Labels default to **Me / Them**. Cannot isolate per-app audio: it takes the combined system stream (music playing during the meeting ends up in the transcript). [same page]
- **Audio is not stored.** Audio is streamed to a third-party transcription provider, temporarily cached "for transcription only", then deleted; "there's no way to access audio from your meetings". No import of pre-recorded files. [same page](https://docs.granola.ai/help-center/taking-notes/transcription), [Security/Privacy FAQ](https://docs.granola.ai/help-center/consent-security-privacy/security-privacy-data-faqs). So ASR is **cloud** (not local); the notes and transcripts live on AWS US and are also cached locally for offline reading/editing. [FAQ]
- **Start is manual-ish by design.** It transcribes only when you (a) click the "meeting starting" notification, (b) open a meeting note after its start time, (c) hit "New Note" for ad-hoc calls, or (d) were already inside an upcoming meeting's note when it starts (auto-start at scheduled time). "Granola does not automatically transcribe meetings without you having clicked into a note." [transcription page]
- **Auto-stop** on: call-ended detection (call app releases the mic + transcript length + calendar end time), 15 min of silence, or sleep. Known failure: back-to-back calls where Zoom keeps the mic open merge into one transcript. You can **Resume** a finished note and regenerate. [transcription page]
- **Stop/Resume, copy all, copy/delete chunk, transcript search** exist in the live transcript panel; 28 Jan 2026 changelog added deleting parts of a transcript. [changelog](https://www.granola.ai/updates)
- **Live meeting indicator**: floating widget (draggable) while another app is in front. [transcription page]
- **Shared-screen snapshots** (macOS 14+ only, not Windows): grabs snapshots of a screen *someone else* shares in Zoom desktop, Meet-in-Chrome, Teams; needs Accessibility + Screen Recording; stored in an "Images" stack on the note and used by the AI; shows a consent reminder. [Take snapshots of shared screens](https://docs.granola.ai/help-center/taking-notes/capture-shared-screens)

### 2.2 Speaker handling (the clever bit, relevant to us)
- Default is **Me / Them** from mic vs system channel. Granola says the AI "usually does a good job of inferring speakers from contextual clues", and you can correct a name in the note or via Chat. [speaker tags](https://docs.granola.ai/help-center/taking-notes/speaker-attribution)
- **"Speaker tags"** (named speakers) work for **Google Meet, Zoom, Microsoft Teams on macOS/Windows**. Mechanism, per docs: it reads the meeting app's own UI via **macOS Accessibility** (participant display names + active-speaker indicator); for Meet also a Chrome extension. It explicitly does not use Accessibility to capture screen/audio. Limits: people on a shared room device are one speaker, overlapping speech gets mis-assigned, only applies to live transcription (no backfill). [speaker tags](https://docs.granola.ai/help-center/taking-notes/speaker-attribution), per-app setup: [Zoom](https://docs.granola.ai/help-center/taking-notes/speaker-attribution-zoom), [Meet](https://docs.granola.ai/help-center/taking-notes/speaker-attribution-google-meet), [Teams](https://docs.granola.ai/help-center/taking-notes/speaker-attribution-teams)
- **No voiceprints** are mentioned anywhere in the docs reviewed (absence, not an explicit denial). Mobile in-person meetings "can recognize different speakers" (diarization, labels unspecified). [transcription page]
- Independent view (vendor-biased, Wispr Flow/Anarlog blogs): outside Meet/Zoom users still see just Me/Them. [search result: Anarlog](https://anarlog.so/blog/granola-ai-complaints/)

### 2.3 Notes: user's typed notes + AI enhancement (Granola's core idea)
- You type raw notes during the call in a blank editor: markdown headings (`# Agenda`), bullets, checkboxes, bold/italic, paste images. "Don't worry about typos and abbreviations". Notes are optional; with none, it works from transcript + calendar info. [Writing your own notes](https://docs.granola.ai/help-center/taking-notes/taking-notes-in-granola)
- When the call ends, it auto-generates **Enhanced notes** from three inputs: **transcript + your raw notes + calendar event info**. Your raw notes are shown in black text vs AI text in grey. A magnifier per bullet jumps to the source transcript line / raw note (provenance). Models: "a blend ... primarily OpenAI and Anthropic". [AI-enhanced notes](https://docs.granola.ai/help-center/taking-notes/ai-enhanced-notes)
- You can toggle between Raw and Enhanced tabs, edit either, **regenerate** (same template or a new one), or tell Chat "make the next steps more detailed" / select text and rewrite. Each meeting is processed independently (edits don't teach future notes). 24 Jul 2025 changelog: "Edit your meeting notes just by asking". [same page](https://docs.granola.ai/help-center/taking-notes/ai-enhanced-notes), [changelog](https://www.granola.ai/updates)
- Profile (job, context) feeds note quality. [Profile and preferences](https://docs.granola.ai/help-center/customising-granola/profile-and-preferences)
- **Templates**: type `/` in the note during the call to pick one; or switch afterwards (regenerates). Template = prompt + sections; best-practice is purpose/context + length/style + structure. Private by default, shareable to the company domain. Desktop-only editing. Built-in library: changelog (7 Oct 2024) says "29 meeting note templates"; the docs don't list names (third-party listing names 1-on-1, stand-up, discovery call, sprint planning, etc. - unverified). The shown set depends on the "user type" chosen at install. [Templates](https://docs.granola.ai/help-center/taking-notes/customise-notes-with-templates), [changelog](https://www.granola.ai/updates)
- **Custom jargon** boosts ASR: up to 30 personal terms, 50 workspace terms; no find/replace, no acronym expansion. [Customizing transcription](https://docs.granola.ai/help-center/customising-granola/customising-transcription)

### 2.4 Calendar, notifications, pre-/post-meeting
- Google Calendar or Outlook; primary calendar by default, extra calendars togglable; declined events, OOO/focus-time blocks hidden; "Coming up" list shows 5. Sign in with Google, Microsoft or SSO. [Syncing calendars](https://docs.granola.ai/help-center/getting-started/syncing-your-calendars)
- **Notification 1 minute before** a calendar event (events with 2+ attendees only); clicking opens the video-call URL, opens the note, and starts transcribing; window repositions beside the call. These are Granola's own pop-ups, not native macOS notifications. [Notifications](https://docs.granola.ai/help-center/taking-notes/notifications)
- **Ad-hoc detection**: it notices a non-calendar call by "your microphone is in use" and prompts "Meeting detected / Huddle detected (Slack) / Call detected (FaceTime, WhatsApp)" with a Take Notes button; if within 15 min of a scheduled event it assumes it is that event. Per-app notification toggles. [Notifications](https://docs.granola.ai/help-center/taking-notes/notifications)
- **Pre-meeting briefs** (20 May 2026; Business+, Google Calendar only): 2-3 bullet brief generated overnight for external meetings from past Granola notes with the same people/company, shared workspace notes, web (LinkedIn), the calendar event, and optionally Gmail. [Briefs](https://docs.granola.ai/help-center/taking-notes/pre-meeting-briefs), [changelog](https://www.granola.ai/updates)
- **Follow-up emails** (paid; Google sign-in + Gmail connected): auto-drafts for meetings with >=1 external guest and <=10 people, appears on home screen 1-2 min after notes finish, editable, send with ~10s undo. [Follow-up emails](https://docs.granola.ai/help-center/taking-notes/follow-up-emails)
- 12 Dec 2025: time remaining in meetings, smarter calendar suggestions. 4 Dec 2025: "Granola Crunched" yearly recap. [changelog](https://www.granola.ai/updates)

### 2.5 Chat ("Ask Granola"), recipes, search
- **Chat** (bottom bar, Cmd+J) works at 4 scopes: homepage (all notes), a single meeting (before/during/after), a folder, a People/Company record, or hand-picked meetings (checkboxes). 16 Jan 2025 "Ask Granola during a meeting" (e.g. what did I miss). Free plan sees only last 30 days; paid sees all. Chat history is private to the user even on shared notes. [Chatting with your meetings](https://docs.granola.ai/help-center/getting-more-from-your-notes/chatting-with-your-meetings)
- 21 Apr 2026 rebuild: agentic chat, inline citations to see who said what, tells you which notes it used; no actions yet ("over time" will help with prep and post-meeting actions). [blog](https://granola.ai/blog/granola-chat-just-got-smarter)
- **Models**: Auto (free); Business/Enterprise can pick standard or "thinking" models; the docs name "Fable 5" as an optional Anthropic thinking model with 30-day Anthropic log retention. [Model selection](https://docs.granola.ai/help-center/getting-more-from-your-notes/understanding-model-selection-in-granola-chat)
- **Recipes** (30 Sep 2025): saved slash-prompts (`/` in chat), static text (no variables), personal / workspace / shareable by link, optional model per recipe; defaults like `/Prep my day`, `/What did I just miss?`. [Recipes](https://docs.granola.ai/help-center/getting-more-from-your-notes/recipes), [Writing effective recipes](https://docs.granola.ai/help-center/getting-more-from-your-notes/writing-effective-recipes)
- Search: "lightning fast" search by person/company and works offline (16 Dec 2024); notes viewable/editable offline since 18 Dec 2024. [changelog](https://www.granola.ai/updates)

### 2.6 People & Companies, folders, sharing
- **People / Companies views** (8 Sep 2025): auto-built from calendar attendees when a note is created from an event, enriched with photo/title/company from "various data sources"; click one to see all notes with them and chat scoped to them. No manual add; only works for calendar-linked notes. [People and Companies](https://docs.granola.ai/help-center/people-and-companies)
- **Spaces & folders**: two spaces ("My notes" private, team space), admin-created custom spaces; folders with description (helps Chat), one level of subfolders, notes can live in many folders, **auto-add recurring-meeting instances to a folder**. [Spaces & Folders](https://docs.granola.ai/help-center/sharing/folders/spaces-and-folders)
- **Sharing**: a note is never shared with attendees automatically; share by link (invited only / workspace / anyone with link), roles Viewer/Collaborator, request-access flow; web viewers get summary but **not the transcript** (desktop collaborators in a shared folder do). Copy as markdown (Obsidian friendly), email via Gmail/Outlook draft. [Sharing notes](https://docs.granola.ai/help-center/sharing/sharing-notes), [Spaces & Folders](https://docs.granola.ai/help-center/sharing/folders/spaces-and-folders)
- Consent/transparency: optional auto chat message in Meet/Zoom/Teams announcing Granola, and a "watermark" feature; docs include a consent guide. [Transparency](https://docs.granola.ai/help-center/consent-security-privacy/transparency-solutions/introduction)

### 2.7 Integrations, MCP, API
- Slack (post link per note or per folder), Notion (one-way, one note at a time into a Granola-created DB, no auto-sync), Zapier (8,000+ apps, 28 Jul 2025), CRMs Attio / HubSpot / Affinity (match notes to person/company/deal), Salesforce listed as Enterprise "advanced". [Integrations](https://docs.granola.ai/help-center/sharing/integrations/integrations-with-granola), [Notion](https://docs.granola.ai/help-center/sharing/notion), [pricing](https://www.granola.ai/pricing)
- **MCP** (4 Feb 2026) at `https://mcp.granola.ai/mcp`, OAuth (+ enterprise EMA). Tools: `query_granola_meetings` (chat), `list_meeting_folders`, `list_meetings`, `get_meetings` (private notes + summary), `get_meeting_transcript` (paid), `get_account_info`. Free = last 30 days only. [MCP](https://docs.granola.ai/help-center/sharing/integrations/mcp)
- **REST API** (Business+): endpoints List Notes, Get Note, Get Transcript, List Folders, List Spaces, plus Webhooks, Audit API, Legal Holds; personal and workspace API keys with access scopes. [API](https://docs.granola.ai/help-center/sharing/integrations/granola-api), index [llms.txt](https://docs.granola.ai/llms.txt)
- Export: CSV of notes + summaries + transcripts emailed within hours (24h link), no admin-wide export. [Exporting](https://docs.granola.ai/help-center/sharing/exporting-notes). No action-item-specific integration (Linear/Jira/etc.) except via Zapier/API; the API page lists "create tasks in Linear, Jira, Todoist" as something you *can build*.

### 2.8 Mobile, watch, phone calls, languages
- iOS app 30 Apr 2025, Android 1 Jul 2026, Apple Watch app 28 Jul 2026 (watchOS 11+, records offline on the watch, chime on start/end that cannot be disabled). Mobile = in-person capture via mic; **iPhone outbound phone calls** via a Granola calling number (US/CA/EU etc.; inbound not supported); Chat on iPhone only; templates desktop only. [Getting started mobile](https://docs.granola.ai/help-center/ios/getting-started), [Phone calls](https://docs.granola.ai/help-center/ios/phone-calls), [Watch](https://docs.granola.ai/help-center/ios/apple-watch), [mobile transcription](https://docs.granola.ai/help-center/ios/transcription)
- Languages: 32 per 2 Sep 2026 changelog (docs page still says 31 desktop / 17 mobile - drift); desktop "multi-language" mode switches language mid-meeting; UI English-only. [Multi-language](https://docs.granola.ai/help-center/customising-granola/multi-language), [changelog](https://www.granola.ai/updates)

### 2.9 Privacy, storage, compliance
- Data on AWS US, encrypted at rest/in transit, no EU residency; notes+transcripts retained indefinitely unless configured; individual **transcript auto-delete** (1 day ... 1 year, 1-week cooldown). SOC 2 Type II (7 Jul 2025); HIPAA only on Enterprise. Free users' anonymized data may train Granola's models unless toggled off; third-party providers (OpenAI/Anthropic) may not train on it; no bring-your-own-model. [FAQ](https://docs.granola.ai/help-center/consent-security-privacy/security-privacy-data-faqs), [Models & training](https://docs.granola.ai/help-center/consent-security-privacy/model-training), [auto-deletion](https://docs.granola.ai/help-center/consent-security-privacy/transcript-auto-deletion)

### 2.10 Pricing (granola.ai/pricing, 2026-10-11, monthly shown, no annual shown)
Basic $0 (30-day history, AI chat auto-model only, templates, recipes, Slack, MCP last 30 days); Business $14/user/mo (unlimited history, model choice, briefs, follow-up emails, Notion/Zapier/HubSpot integrations, API, workspace dictionary); Enterprise $35/user/mo (SSO/SCIM, HIPAA, audit API, admin policies, Salesforce). [pricing](https://www.granola.ai/pricing) (page itself inconsistent on which CRM integrations are Business vs Enterprise.)

### 2.11 Known weaknesses (third-party, vendor-biased sources - treat as signals not facts)
Missed captures with no alert (~60% of calls reported by one founder), Me/Them only outside Meet/Zoom, accuracy on numbers/crosstalk, no audio to verify disputes, summaries can overstate decisions. Sources: [Anarlog](https://anarlog.so/blog/granola-ai-complaints/), [Jamie](https://www.meetjamie.ai/blog/granola-alternatives), [Medium review](https://medium.com/@trelvek/granola-review-2026-a-limitations-first-look-at-ai-meeting-notes-0bcd97d68bc4). Company moved toward "enterprise AI context layer" pitch (Series C $125M reported Mar 2026, unverified single-source).

---

## 3. Per-product evidence (links behind the matrix)

Granola's evidence is in section 2. Items below are what each source says; dates in brackets are the page's own stamp where visible.

### Otter
- Bot auto-joins Zoom/Meet/Teams, visible as "[Name]'s Notetaker": [help [Aug 21, 2026]](https://help.otter.ai/hc/en-us/articles/4425393298327-Otter-Notetaker-Overview). Botless Desktop app (Mac 12.3+/Win 10+, mic + system audio): [help [Oct 1, 2026]](https://help.otter.ai/hc/en-us/articles/35973988280215-Otter-Desktop-App-Mac-Windows).
- Desktop meeting detection Off / Remind me (default) / Record automatically, triggered by mic activity: [blog, Aug 6, 2026](https://otter.ai/blog/never-miss-the-conversation-introducing-automatic-recording-in-otter-desktop).
- Speaker ID learns from tagging; processing after recording; live names only for Notetaker on Zoom: [help [Apr 1, 2026]](https://help.otter.ai/hc/en-us/articles/21665587209367-Speaker-Identification-Overview). Mic-vs-system separation in the botless app: not documented.
- Languages: 6, one at a time: [help [May 6, 2026]](https://help.otter.ai/hc/en-us/articles/360047247414-Supported-languages). Templates: [Custom Meeting Type Templates](https://help.otter.ai/hc/en-us/articles/31402572907415-Custom-Meeting-Type-Templates). AI Chat: [overview](https://help.otter.ai/hc/en-us/articles/19682180167575-Otter-AI-Chat-Overview). MCP: [https://mcp.otter.ai/mcp [Jul 30, 2026]](https://help.otter.ai/hc/en-us/articles/35287607569687-Otter-MCP-Server). Companies pages: [blog, Sep 10, 2026](https://otter.ai/blog/every-customer-conversation-now-in-one-place).
- CRM: [Salesforce/HubSpot](https://help.otter.ai/hc/en-us/articles/29730579913751-CRM-Integration-Sync-Insights-to-Custom-Fields). Training on de-identified data: [privacy](https://otter.ai/privacy-security). Litigation: ruling on 13 Aug 2026 let Wiretap/CIPA/BIPA claims proceed (pleadings stage only): [UC Today](https://www.uctoday.com/productivity-automation/otter-ai-fails-to-dismiss-core-privacy-claims-in-u-s-court/).
- Pricing: [otter.ai/pricing](https://otter.ai/pricing) (no date; page also shows promo prices, unresolved).

### Fireflies
- Botless desktop "Take Notes" (system audio, no recording saved), auto-detects Zoom/Meet/Teams/WhatsApp/FaceTime/Discord/phone calls: [guide](https://guide.fireflies.ai/articles/6666374717-how-to-record-meetings-without-a-bot-on-the-fireflies-desktop-app). Plan gating conflicts between [Nov 2025 launch](https://fireflies.ai/blog/fireflies-launches-live-assist-and-desktop-app/) (Pro+) and [Jul 10, 2026 pricing post](https://fireflies.ai/blog/fireflies-pricing-which-plan-is-right-for-you/) (all plans).
- Speakers: "Speaker 1/2", rename manually: [guide](https://guide.fireflies.ai/articles/4994477228-how-to-edit-speaker-labels-or-names-in-a-transcript). Desktop reminders/auto-note: [guide](https://guide.fireflies.ai/articles/1208704416-getting-started-with-the-fireflies-desktop-app). Live Assist: [guide](https://guide.fireflies.ai/articles/6032274417-learn-about-fireflies-live-assist-get-real-time-suggestions-answers-and-notes-live-during-the-meeting).
- Templates: [custom summary templates](https://guide.fireflies.ai/articles/7796555530-how-to-create-and-manage-custom-summary-templates). Linear: [guide](https://guide.fireflies.ai/articles/8360629677-how-to-integrate-linear-with-fireflies). Global AskFred: [guide](https://guide.fireflies.ai/articles/1512776728-global-askfred-get-answers-from-past-meetings-connected-apps-and-web-search). MCP: [docs](https://docs.fireflies.ai/mcp-tools/overview). Languages: [guide](https://guide.fireflies.ai/articles/2973706448-learn-about-fireflies-supported-languages).
- Free-tier change (sign-ups from 1 Sep 2026: "unlimited" only with auto-join on): [guide](https://guide.fireflies.ai/articles/8632872350-unlock-unlimited-transcriptions-on-the-fireflies-free-plan). BIPA suits and auto-join complaints are [3P/competitor](https://www.happyscribe.com/blog/fireflies-ai-review), not court-verified.

### Fathom
- Fathom 3.0 (15 Apr 2026): modes Off / Transcript-only / Audio-only / Audio+Video(bot); Mac only; scratchpad notes folded into summary: [help](https://help.fathom.video/en/articles/11577345). Bot-free Zoom video beta: [what's new](https://www.fathom.ai/whats-new). Slack huddles bot-free [Jun 30, 2026]: [help](https://help.fathom.video/en/articles/11870465). Release notes: [help](https://help.fathom.video/en/articles/6220097).
- Speaker attribution claim w/o bot (mechanism undocumented): [Fathom learn page [Sep 4, 2026]](https://www.fathom.ai/learn/bot-free-note-taker). Languages EN+38 [Oct 1, 2026]: [overview](https://www.fathom.ai/overview) / help center. Auto-capture rules: [help](https://help.fathom.video/en/articles/449088). Folders: [help](https://help.fathom.video/en/articles/295808). Ask Fathom: [help](https://help.fathom.video/en/articles/3239425). Pricing: [fathom.ai/pricing](https://www.fathom.ai/pricing).

### tl;dv
- Botless desktop app, audio only, mic + system audio, no video: [desktop app [2026-07-09]](https://intercom.help/tldv/en/articles/14433922-desktop-app), [recording without a bot](https://intercom.help/tldv/en/articles/14433337-recording-without-a-bot). Bot-free speakers appear as numbers unless calendar-matched; voice ID Business-only: [tl;dv blog](https://tldv.io/blog/tldv-honest-review/). Mobile offline: [help](https://intercom.help/tldv/en/articles/8490450-mobile-app). Features: [AI minutes](https://tldv.io/features/ai-meeting-minutes), [conversational intelligence](https://tldv.io/features/conversational-intelligence). MCP: [blog 2025-04-11](https://tldv.io/blog/tldv-mcp-elevating-meeting-intelligence-with-ai-driven-contextualization/). Pricing (EUR render; USD per [3P Laxis](https://www.laxis.com/blog/tldv-review/)): [tldv.io/app/pricing](https://tldv.io/app/pricing/).

### Read.ai
- Desktop botless (Feb 2026): [read.ai/desktop](https://www.read.ai/desktop), [Feb 2026 post](https://www.read.ai/post/read-it-whats-new-at-read-ai----february-2026); Meet botless via Media API [2026-03-26]: [post](https://www.read.ai/post/read-ai-introduces-a-botless-integration-with-google-meet). Speaker-attribution conflict: [vendor comparison page](https://www.read.ai/read-ai-vs-granola-desktop-app-short) vs [3P quoting help center](https://parrotnotes.app/blog/read-ai-review) (help center returned 403). Templates [2026-07-22]: [post](https://www.read.ai/post/live-today-templates-tailored-for-sales-teams-and-beyond). Default joins all calendar meetings: [3P](https://wisprflow.ai/notetaker/read-ai-alternative). Pricing: [read.ai/pricing](https://www.read.ai/pricing) (footer (c) 2025, freshness unconfirmed).

### Krisp
- Bot-free via virtual mic/speaker; transcript-only / audio / screen modes; optional bot: [product](https://krisp.ai/ai-meeting-assistant/), [Krisp Bot](https://help.krisp.ai/hc/en-us/articles/12535172635804-Krisp-Bot). Live transcription window, 16 languages: [help](https://help.krisp.ai/hc/en-us/articles/30146816045980-Record-your-meetings-with-Krisp-AI-Note-Taker). Templates: [help](https://help.krisp.ai/hc/en-us/articles/26708055686044-Meeting-Notes-Templates). AI Chat: [help](https://help.krisp.ai/hc/en-us/articles/18440374735644-Get-meeting-insights-with-Krisp-AI-Chat). MCP: [help](https://help.krisp.ai/hc/en-us/articles/25416265429660-Krisp-MCP-Supported-tools). Pricing: [krisp.ai/pricing](https://krisp.ai/pricing/). On-device English ASR claim is [3P](https://makerstack.co/reviews/krisp-review/), unreconciled with Krisp's "no voice data to servers" marketing.

### Jamie (meetjamie.ai; jamie-ai.com is an unrelated product)
- Bot-free, audio only, macOS 14.4+/Windows/iPhone: [quickstart [2026-09-09]](https://docs.meetjamie.ai/getting-started/quickstart). Speaker naming + Speaker Memory voiceprints (biometric under GDPR, admin-disableable): [identify speaker](https://docs.meetjamie.ai/getting-started/identify-speaker), [admin setup](https://docs.meetjamie.ai/enterprise/admins/setup-essentials). No live transcript, 5-10 min processing: [summary doc](https://docs.meetjamie.ai/getting-started/summary). Changelog (Scratchpad, Tasks, auto-start/AutoStop 2026-08-16, Agentic Workflows 2026-09-30): [changelog](https://www.meetjamie.ai/changelog). Ask AI: [docs](https://docs.meetjamie.ai/getting-started/ask-ai). MCP: [docs](https://docs.meetjamie.ai/integrations/mcp). Data handling (audio deleted after transcription; Frankfurt): [docs](https://docs.meetjamie.ai/faqs-troubleshooting/data). Pricing: [meetjamie.ai/pricing](https://www.meetjamie.ai/pricing).

### Bluedot
- Bot-free Chrome ext/desktop/mobile/Watch: [extension](https://www.bluedothq.com/chrome-extension), [desktop FAQ](https://help.bluedothq.com/en/articles/12818713-bluedot-desktop-app-faq), [Bluedot 2.1, 2026-06-17](https://www.bluedothq.com/blog/bluedot-2-1) (auto-recording, workspace chat, MCP). Speaker recognition by platform [2026-08-12]: [help](https://help.bluedothq.com/en/articles/12731344-speaker-recognition-overview). Pricing: [bluedothq.com/pricing](https://www.bluedothq.com/pricing). Reviews: [3P](https://notechase.ai/reviews/bluedot-review/).

### Notion AI Meeting Notes
- Capture, speaker limits, consent-click, 16 languages, sub-processors, 10 h/day cap: [help page](https://www.notion.com/help/ai-meeting-notes) (undated). Pricing/"no bot needed": [notion.com/pricing](https://www.notion.com/pricing). Custom Agents triggers: [releases](https://www.notion.com/releases).

### Zoom / Teams / Meet
- Zoom My Notes whitepaper (local device audio, deleted after transcription, speakers only in Zoom meetings): [library.zoom.com](https://library.zoom.com/ai-whitepaper/my-notes.md); product page/pricing: [zoom.com](https://www.zoom.com/en/products/ai-assistant/features/ai-note-taking).
- Teams Copilot recap (license required) [ms.date 2026-08-11]: [Learn](https://learn.microsoft.com/en-us/microsoftteams/copilot-teams-transcription); recap without saved transcript (MC1275312, GA mid/late Oct 2026, garbled markup): [mc.merill.net](https://mc.merill.net/message/MC1275312/v/2026-04-09T16-07-13-85Z).
- Meet "Take notes for me": [Google blog 29 Jun 2026](https://blog.google/products-and-platforms/products/workspace/take-notes-for-me/), [help (8 languages)](https://support.google.com/meet/answer/14754931).

### Apple and platform APIs
- Notes on Mac transcribe (M1+): [Apple](https://support.apple.com/guide/notes/record-and-transcribe-audio-apdb5106e334/mac); Voice Memos: [Apple](https://support.apple.com/guide/voice-memos/view-a-transcription-of-a-recording-vm4a03609f0d/mac); Call recording on iPhone/iPad/Mac [2026-06-26]: [Apple](https://support.apple.com/en-us/121583). macOS 27 shipped 14 Sep 2026 with no new recording/transcription features listed: [Newsroom](https://www.apple.com/newsroom/2026/09/major-updates-for-apples-software-platforms-are-now-available/) (feature page not retrievable; absence not proven).
- Dev APIs: [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer.md) / [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber.md) (macOS 26+); no diarization API found, only an unanswered [forum thread](https://developer.apple.com/forums/thread/829621); [Core Audio process taps](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps.md) (14.2+, needs `NSAudioCaptureUsageDescription`); [ScreenCaptureKit audio](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturesaudio.md) (13+, mic capture 15+). Permission UI: [Apple](https://support.apple.com/guide/mac-help/control-access-screen-system-audio-recording-mchld6aa7d23/mac). Monthly re-prompt behaviour on Tahoe/27: unverified ([2024 Sequoia source](https://tidbits.com/2024/08/19/apple-reduces-excessive-sequoia-permission-requests-shifts-to-monthly)).

### Superwhisper / MacWhisper / Cluely / local-first projects
- Superwhisper: [meeting transcription](https://superwhisper.com/meeting-transcription), [speaker-separated](https://superwhisper.com/docs/modes/speaker-separated-meetings), [models](https://superwhisper.com/docs/models/voice.md), [plans](https://superwhisper.com/docs/billing/plans.md). No auto-detect or calendar in docs index ([llms.txt](https://superwhisper.com/docs/llms.txt)).
- MacWhisper: [record meetings](https://docs.macwhisper.com/article/30-record-meetings) (beta, direct-download build only, article 15 Jul 2025), [site](https://macwhisper.com).
- Cluely (live "assist" overlay; undetectability only on $149.99 tier): [pricing](https://cluely.com/pricing).
- Local-first reference designs: anarlog/Hyprnote (Tauri+Rust, SQLite canonical, Markdown export, MCP/CLI) [repo](https://github.com/fastrepl/hyprnote), [post 10 Apr 2026](https://anarlog.so/blog/local-ai-meeting-notes/); [Meetily](https://github.com/Zackriya-Solutions/meeting-minutes); [Shadow](https://www.shadow.do). Not researched: Pickle, Plaud, Notta, Superpowered.

---

## 4. Proposed v1 for detta-meetings

Framing: Granola is the benchmark and its core insight (type a few notes, AI merges them with the transcript) needs no cloud team features. Our edge is already built in: local ASR, no third-party audio upload, Claude as the summarizer, MCP-native. Most leaders are cloud-ASR (Granola, Jamie, Otter...); only Mac-native tools like MacWhisper/Superwhisper/anarlog run local.

### 4.1 Table stakes (every leader has it)

| Feature | Rationale | Evidence |
|---|---|---|
| Bot-free capture of mic + system audio, on a manual Start/Stop plus auto-stop | The category baseline; Granola, Jamie, Otter/Fireflies desktop, Krisp, tl;dv all do it | [Granola](https://docs.granola.ai/help-center/taking-notes/transcription) |
| Two-channel "Me / Them" labels from mic vs system audio | Free from the capture design; Granola's own default | [Granola](https://docs.granola.ai/help-center/taking-notes/speaker-attribution) |
| Auto-stop (call app releases mic, silence timeout, sleep) | Granola does all three; avoids runaway recordings | [Granola](https://docs.granola.ai/help-center/taking-notes/transcription) |
| Calendar read (title, attendees) and a "meeting starting" prompt | Granola, Fireflies, Fathom, Otter all key off the calendar | [Granola](https://docs.granola.ai/help-center/taking-notes/notifications) |
| AI summary with decisions and action items, editable, regenerable | Universal output | [Granola](https://docs.granola.ai/help-center/taking-notes/ai-enhanced-notes) |
| Templates: a few built-ins plus user-defined prompt+structure | Granola, Otter, Fireflies, Fathom, Krisp, Jamie, Read all have it | [Granola](https://docs.granola.ai/help-center/taking-notes/customise-notes-with-templates) |
| Full-text search plus "ask across meetings" chat with citations | Every product has it (Granola Chat, Ask Fathom, AskFred, Jamie Ask AI, Otter AI Chat) | [Granola](https://docs.granola.ai/help-center/getting-more-from-your-notes/chatting-with-your-meetings) |
| Export / copy as Markdown | Granola copies markdown; open formats avoid lock-in | [Granola](https://docs.granola.ai/help-center/sharing/sharing-notes) |
| Custom vocabulary / jargon list for ASR | Granola (30 personal terms); cheap accuracy win | [Granola](https://docs.granola.ai/help-center/customising-granola/customising-transcription) |
| Clear recording indicator and a consent reminder | Granola, Notion, Fathom all nudge toward consent; legal risk is real (Otter litigation) | [Otter ruling](https://www.uctoday.com/productivity-automation/otter-ai-fails-to-dismiss-core-privacy-claims-in-u-s-court/) |

### 4.2 Differentiators worth copying

| Feature | Why copy it | Evidence |
|---|---|---|
| **Typed notes + transcript -> enhanced notes**, your lines kept distinct from AI lines, with a per-bullet link to its transcript source | Granola's signature; nobody else except Fathom's scratchpad does it. Highest-value, low-cost with Claude | [Granola](https://docs.granola.ai/help-center/taking-notes/ai-enhanced-notes), [Fathom](https://help.fathom.video/en/articles/11577345) |
| `/` to pick a template mid-note; regenerate with a different template afterward | Cheap, keeps hands on the keyboard (fits a notch droplet) | [Granola](https://docs.granola.ai/help-center/taking-notes/customise-notes-with-templates) |
| Mic-in-use call detection prompt ("Meeting detected - take notes?") for non-calendar calls (Slack huddles, FaceTime) | Granola, Otter ("Remind me" default), Jamie, Fireflies; a droplet notch popover is a natural surface | [Granola](https://docs.granola.ai/help-center/taking-notes/notifications), [Otter](https://otter.ai/blog/never-miss-the-conversation-introducing-automatic-recording-in-otter-desktop) |
| Named speakers via macOS Accessibility reading the Zoom/Teams/Meet UI (active speaker + display names) | The only documented bot-free named-speaker method; macOS-only, local, no audio needed. Medium effort, fragile to UI changes | [Granola](https://docs.granola.ai/help-center/taking-notes/speaker-attribution), [Notion](https://www.notion.com/help/ai-meeting-notes) |
| Saved prompts ("recipes") runnable on one meeting, a folder or a person | Turns the chat box into reusable workflows; static text only is enough | [Granola](https://docs.granola.ai/help-center/getting-more-from-your-notes/recipes) |
| Ask-during-meeting ("what did I miss?") | Granola Chat live; easy with a streaming transcript + Claude | [Granola](https://www.granola.ai/updates) |
| People/Company views auto-built from calendar attendees | Cheap with the local store; makes cross-meeting recall useful | [Granola](https://docs.granola.ai/help-center/people-and-companies) |
| Pre-meeting brief from past notes with the same attendees | Fully local variant (skip web/Gmail); Granola ships it paid-only | [Granola](https://docs.granola.ai/help-center/taking-notes/pre-meeting-briefs) |
| MCP server over the local store (list/get meetings, transcript, search) | Granola, Otter, Fireflies, Jamie, tl;dv, Read, Krisp, Bluedot all ship MCP; for a Claude user this is the integration layer instead of Zapier/CRM | [Granola MCP](https://docs.granola.ai/help-center/sharing/integrations/mcp) |
| Local SQLite as source of truth, plain-file audio, Markdown export | Open-source local-first reference design | [anarlog](https://anarlog.so/blog/local-ai-meeting-notes/) |
| Transcript auto-delete period + optional local audio retention | Granola keeps no audio, which is a top complaint (can't verify disputes); local retention fixes that without a privacy cost | [Granola](https://docs.granola.ai/help-center/consent-security-privacy/transcript-auto-deletion), [3P](https://anarlog.so/blog/granola-ai-complaints/) |
| Reminders / calendar write-back for action items | None of the leaders document a Reminders integration (unverified for Otter, Fireflies, Fathom); an open slot, trivial on macOS via EventKit | see section 5 |
| Auto-add recurring meeting series to a folder/project | Small Granola touch that makes folders maintenance-free | [Granola](https://docs.granola.ai/help-center/sharing/folders/spaces-and-folders) |

### 4.3 Skip for v1

| Feature | One-line rationale |
|---|---|
| Voiceprint "Speaker Memory" (Jamie) | Local diarization has no Apple API found; add after Accessibility tags, and treat as biometric data. [Jamie](https://docs.meetjamie.ai/enterprise/admins/setup-essentials) |
| Team workspaces, folders sharing, link sharing, roles, request-access | Single-user product; Granola's largest surface area and ours has zero need. |
| CRM / Slack / Notion / Zapier / Attio / HubSpot integrations | MCP + Markdown files cover a personal workflow; revisit only for a specific tool. |
| Follow-up email drafts (Gmail) | Paid Granola feature requiring Gmail OAuth; out of scope for personal local tool. [Granola](https://docs.granola.ai/help-center/taking-notes/follow-up-emails) |
| iOS/Android/Watch/phone-call capture | Different capture stack entirely; Granola shipped iOS ~11 months and Android ~25 months after its May 2024 launch. [changelog](https://www.granola.ai/updates) |
| Video or screen recording; shared-screen snapshots | Heavy storage and consent burden; revisit snapshots (Granola does it on macOS 14+) as v2. [Granola](https://docs.granola.ai/help-center/taking-notes/capture-shared-screens) |
| Meeting bots, auto-join | Contradicts the product premise. |
| Enterprise (SSO, SCIM, HIPAA, audit/webhook APIs, MDM) | Not applicable to a personal tool. |
| Conversation analytics, coaching scores, deal intelligence | Sales-team features (Fireflies, Read, tl;dv); noise for a personal recorder. |
| Live suggestion overlays / undetectable assist (Cluely) | A different product category with ethical baggage. [Cluely](https://cluely.com/pricing) |
| Multi-language mid-meeting switching, UI localisation | Depends on the chosen local ASR; ship English plus the model's native set first. [Granola](https://docs.granola.ai/help-center/customising-granola/multi-language) |
| Watermark / auto chat message announcing recording | Granola enterprise transparency tooling; a consent reminder in-app is enough for v1. [Granola](https://docs.granola.ai/help-center/consent-security-privacy/transparency-solutions/introduction) |
| Web viewer, billing, referrals, workspace API keys | No server component planned. |

### 4.4 Technical implications for our stack (from Apple docs, verified 2026-10-11)
- System audio: Core Audio process taps (macOS 14.2+, `NSAudioCaptureUsageDescription`) or ScreenCaptureKit `capturesAudio` (13+) with `captureMicrophone` (15+). Process taps can target specific apps, which Granola says it cannot do (it mixes whole system audio). [Core Audio taps](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps.md)
- On-device ASR: Apple `SpeechAnalyzer`/`SpeechTranscriber` exist on macOS 26+ but expose no diarization that we could find; our existing local ASR pipeline stays. [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer.md)
- Per-app audio lets us attribute "Them" to a specific meeting app and reduce music/notification bleed, a documented Granola weakness. [Granola](https://docs.granola.ai/help-center/taking-notes/transcription)

---

## 5. Caveats and open items
- Granola docs are undated per-page; I used the changelog for dates. Docs/changelog disagree on language count (31 vs 32), and the pricing page is internally inconsistent about which CRM integrations are Business vs Enterprise.
- Granola's claim of 29 templates comes from a 2024 changelog; template names are not in the docs (third-party listings only).
- Read.ai local-mode speaker attribution and Fathom's bot-free diarization mechanism are unresolved: vendor marketing says yes, other evidence says unclear. Neither documents mic-vs-system channel use.
- Most "complaint" evidence is from competitors' blogs (Anarlog, HappyScribe, Jamie, Wispr, Laxis, tl;dv, MeetGeek). I did not read primary Reddit/G2 threads. Treat as hypotheses.
- Not found / unverified for all: a Reminders-app integration at Otter/Fireflies/Fathom; offline ASR at any bot-first vendor; tl;dv live transcript; Notion live transcript; Apple macOS 27 feature page (not retrievable) and Tahoe's monthly screen/audio re-prompt behaviour.
- Granola's docs name a model "Fable 5" for Business chat; copied as published, not independently confirmed.
- Pricing pages: several rendered in EUR, cached, or undated (tl;dv, Read, Jamie, Otter). Recheck before quoting.
- Not researched: Pickle, Plaud, Notta, Superpowered, Circleback beyond a homepage read, Fellow beyond pricing.
