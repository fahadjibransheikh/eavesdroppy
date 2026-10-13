import DroppyKit
import SwiftUI

// D19: one settings page per area under the droplet's page in Droppy's Settings. Rows are the SDK's own; choices are
// native pop-up buttons and text fields, as the design guidelines ask of settings.

private enum PageID {
    static let recording = "recording", speakers = "speakers", notes = "notes", providers = "providers", calendar = "calendar", output = "output", storage = "storage"
}

extension EavesdroppyDroplet: SettingsPagesProviding {
    public func makeSettingsPane(context: SettingsPaneContext) -> AnyView {
        // Harness only: EAVESDROPPY_HARNESS_PAGE=calendar shows that page in the settings-pane shot.
        if host?.environment.isHarness == true, let id = ProcessInfo.processInfo.environment["EAVESDROPPY_HARNESS_PAGE"],
           let page = makeSettingsPage(id: id, context: context) { return page }
        return AnyView(SettingsRoot())
    }

    public func makeSettingsPage(id: String, context: SettingsPaneContext) -> AnyView? {
        switch id {
        case PageID.recording: return AnyView(RecordingPage(prefs: prefs))
        case PageID.speakers: return AnyView(SpeakersPage(droplet: self))
        case PageID.notes: return AnyView(NotesPage(prefs: prefs, providerSettings: providerSettings, mcp: mcp))
        case PageID.providers: return AnyView(ProvidersPage(model: providerSettings))
        case PageID.calendar: return AnyView(CalendarPage(droplet: self))
        case PageID.output: return AnyView(OutputPage(prefs: prefs, linear: linear))
        case PageID.storage: return AnyView(StoragePage(droplet: self))
        default: return nil
        }
    }

    public var settingsSearchEntries: [SettingsSearchEntry] {
        [SettingsSearchEntry(title: "Echo removal", keywords: ["microphone", "recording", "speakers"]),
         SettingsSearchEntry(title: "Consent reminder", keywords: ["recording"]),
         SettingsSearchEntry(title: "Open the notes window when recording starts", keywords: ["recording", "typed notes", "window"]),
         SettingsSearchEntry(title: "Auto-stop", keywords: ["recording", "call ends"]),
         SettingsSearchEntry(title: "Offer to record when a call starts", keywords: ["microphone", "prompt", "zoom", "teams", "meet"]),
         SettingsSearchEntry(title: "Read participant names", keywords: ["accessibility", "zoom", "teams", "meet", "speakers"]),
         SettingsSearchEntry(title: "Teach Eavesdroppy your voice", keywords: ["record your voice", "voiceprint", "enroll", "speakers"]),
         SettingsSearchEntry(title: "Default template", keywords: ["notes", "standup", "sales", "interview"]),
         SettingsSearchEntry(title: "AI provider", keywords: ["claude", "codex", "grok", "apple intelligence", "api key", "openai", "anthropic", "xai", "model"]),
         SettingsSearchEntry(title: "AI tools (MCP)", keywords: ["mcp", "claude code", "cursor", "server", "token", "localhost"]),
         SettingsSearchEntry(title: "Calendar prompts", keywords: ["events", "meetings"]),
         SettingsSearchEntry(title: "Reminders list", keywords: ["action items"]),
         SettingsSearchEntry(title: "Linear", keywords: ["api key", "team", "action items"]),
         SettingsSearchEntry(title: "Audio retention", keywords: ["storage", "delete", "expire"]),
         SettingsSearchEntry(title: "Output folder", keywords: ["storage", "drive", "documents", "mirror", "notes", "audio"]),
         SettingsSearchEntry(title: "Import existing Drive meetings", keywords: ["storage", "library"])]
        + pythonSearchEntries
    }
}

extension EavesdroppyDroplet {
    fileprivate var pythonSearchEntries: [SettingsSearchEntry] {
        #if EAVESDROPPY_PERSONAL
        [SettingsSearchEntry(title: "Use Python pipeline (fallback)", keywords: ["storage", "process_meeting", "legacy"])]
        #else
        []
        #endif
    }
}

private struct SettingsRoot: View {
    var body: some View {
        DropletSettingsPane {
            DropletSettingsCard {
                link("Recording", "Echo removal, consent reminder, auto-stop", PageID.recording, "mic.fill", .red)
                link("Speakers", "Your voice and automatic naming", PageID.speakers, "person.wave.2.fill", .blue)
                link("Notes", "The default template and AI provider", PageID.notes, "note.text", .orange)
                link("Calendar", "Prompts before events", PageID.calendar, "calendar", .pink)
                link("Output", "Reminders and Linear", PageID.output, "checklist", .green)
                link("Storage", "Audio retention, import, folders", PageID.storage, "externaldrive.fill", .gray)
            }
        }
    }

    private func link(_ title: String, _ subtitle: String, _ id: String, _ symbol: String, _ color: Color) -> some View {
        DropletSettingsPageLink(title, subtitle: subtitle, page: id) {
            RoundedRectangle(cornerRadius: DroppyRadius.sm, style: .continuous).fill(color)
                .overlay(Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white))
        }
    }
}

// MARK: - Recording

private struct RecordingPage: View {
    @ObservedObject var prefs: Prefs

    var body: some View {
        DropletSettingsPage {
            DropletSettingsCard {
                DropletToggleRow(title: "Remove echo from your microphone",
                                 subtitle: "Cancels call audio that leaks from your speakers into the mic. Turn it off if your own voice sounds clipped.",
                                 isOn: prefs.binding(Prefs.Key.echoRemoval, true))
                DropletToggleRow(title: "Show a consent reminder",
                                 subtitle: "A one-line reminder to tell people you're recording, when a recording starts.",
                                 isOn: prefs.binding(Prefs.Key.consentLine, true))
                DropletToggleRow(title: "Open the notes window when recording starts",
                                 subtitle: "A small window for typing notes while you talk. It never takes the keyboard from your meeting app, and you can open it any time from the shelf or with the shortcut.",
                                 isOn: prefs.binding(Prefs.Key.openNotesOnRecord, true))
                DropletToggleRow(title: "Stop when the call ends",
                                 subtitle: "Counts down and stops the recording a minute after the call app stops using the microphone. Recordings that never had a call app, like in-person meetings, are left alone.",
                                 isOn: prefs.binding(Prefs.Key.autoStop, true))
                DropletToggleRow(title: "Offer to record when a call starts",
                                 subtitle: "When Zoom, Teams, Meet or another call app starts using the microphone, a notch prompt asks whether to record. Only watches which app is using the microphone.",
                                 isOn: prefs.binding(Prefs.Key.micPrompt, true))
            }
        }
    }
}

// MARK: - Speakers

private struct SpeakersPage: View {
    @ObservedObject var droplet: EavesdroppyDroplet
    @ObservedObject var prefs: Prefs
    @ObservedObject var enrollment: Enrollment
    @ObservedObject var library: LibraryModel
    @ObservedObject var automation: Automation

    init(droplet: EavesdroppyDroplet) {
        self.droplet = droplet; prefs = droplet.prefs; enrollment = droplet.enrollment; library = droplet.library; automation = droplet.automation
    }

    var body: some View {
        DropletSettingsPage {
            DropletSettingsCard {
                DropletControlRow(title: "Your name", infoTip: "How you're labelled in transcripts and notes.") {
                    TextField("", text: prefs.binding(Prefs.Key.userName, "Me"), prompt: Text("Me")).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 180)
                }
                DropletToggleRow(title: "Name speakers automatically",
                                 subtitle: "Label voices that match someone you've already named. Anything unsure stays unnamed.",
                                 isOn: prefs.binding(Prefs.Key.voiceprintNaming, true))
                DropletToggleRow(title: "Read participant names from Zoom, Teams and Meet",
                                 subtitle: "While recording, reads the names on screen as extra hints for naming speakers. Needs Accessibility access for Droppy. Best effort: it never overrides a voice match.",
                                 isOn: Binding(get: { prefs.participantNames },
                                               set: { prefs.set(Prefs.Key.participantNames, $0); automation.participantNamesToggled($0) }))
                if prefs.participantNames && !automation.accessibilityTrusted {
                    DropletControlRow(title: "Droppy doesn't have Accessibility access yet") {
                        Button("Open System Settings") { automation.openAccessibilitySettings() }
                    }
                }
            }
            DropletSettingsSection {
                settingsSectionHeader("Your voice")
            } content: {
                DropletSettingsCard {
                    DropletControlRow(title: "Voice sample") {
                        HStack(spacing: DroppySpacing.sm) {
                            Text(enrolledText).foregroundStyle(.secondary)
                            Button(library.me == nil ? "Record your voice" : "Re-record") { start() }
                                .disabled(enrollment.active || droplet.recording || droplet.busy)
                        }
                    }
                    if enrollment.state != .idle { progress }
                }
            }
        }
        .onAppear { library.reloadMe(); automation.refreshPermissions() }
    }

    private var enrolledText: String {
        guard let me = library.me else { return "Not recorded" }
        return "Enrolled as \(me.name)"
    }

    private func start() {
        guard let host = droplet.host else { return }
        enrollment.start(host: host, name: prefs.userName) { library.reloadMe() }
    }

    @ViewBuilder private var progress: some View {
        DropletStackedRow(title: stateTitle) {
            VStack(alignment: .leading, spacing: DroppySpacing.sm) {
                switch enrollment.state {
                case .recording:
                    Text(Enrollment.passage).font(.body).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: DroppySpacing.sm) {
                        ProgressView(value: Double(enrollment.level)).frame(maxWidth: .infinity)
                        Text("\(Int(enrollment.remaining.rounded(.up))) s").monospacedDigit().foregroundStyle(.secondary)
                        Button("Cancel") { enrollment.cancel() }
                    }
                case .processing: HStack { ProgressView().controlSize(.small); Text("Learning your voice…").foregroundStyle(.secondary) }
                case .done(let s): Text("Done: \(String(format: "%.0f", s)) seconds of speech used.").foregroundStyle(.secondary)
                case .failed(let why): Text(why).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                case .idle: EmptyView()
                }
            }
        }
    }

    private var stateTitle: String {
        switch enrollment.state {
        case .recording: return "Read this aloud"
        case .processing: return "Processing"
        case .done: return "Voice saved"
        case .failed: return "Couldn't save your voice"
        case .idle: return ""
        }
    }
}

// MARK: - Notes

private struct NotesPage: View {
    @ObservedObject var prefs: Prefs
    @ObservedObject var providerSettings: ProviderSettingsModel
    let mcp: MCPServerModel

    var body: some View {
        DropletSettingsPage {
            DropletSettingsCard {
                DropletGroupedPickerRow(title: "Default template", subtitle: "How notes are written. You can switch per meeting and regenerate later.") {
                    Picker("", selection: prefs.binding(Prefs.Key.defaultTemplate, "general")) {
                        ForEach(NoteTemplate.all, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden().pickerStyle(.menu)
                }
            }
            if prefs.defaultTemplate == "custom" {  // nothing to edit until Custom is the template
                DropletSettingsSection {
                    settingsSectionHeader("Custom template")
                } content: {
                    DropletSettingsCard {
                        DropletStackedRow(title: "Instructions", infoTip: "Used when a meeting's template is Custom. Say what sections you want and how to write them.") {
                            TextEditor(text: Binding(get: { prefs.customTemplate },
                                                     set: { prefs.set(Prefs.Key.customTemplate, $0); prefs.writeCustomTemplateFile() }))
                                .font(.body).frame(minHeight: 110)
                        }
                        if prefs.customTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            DropletControlRow(title: "Start from an example") {
                                Button("Insert example") { prefs.set(Prefs.Key.customTemplate, Self.starter); prefs.writeCustomTemplateFile() }
                            }
                        }
                    }
                }
            }
            ProviderSummarySection(model: providerSettings)
            MCPSettingsSection(model: mcp)
        }
    }
}

private extension NotesPage {
    static let starter = """
        Sections: Summary, Decisions, Action items, Open questions.
        Write the summary in three sentences at most. List each decision on its own line. Give every action item an owner and a due date when the meeting names one.
        """
}

private struct ProvidersPage: View {
    @ObservedObject var model: ProviderSettingsModel
    var body: some View { DropletSettingsPage { ProviderSettingsSection(model: model) } }
}

// MARK: - Calendar

private struct CalendarPage: View {
    @ObservedObject var prefs: Prefs
    @ObservedObject var automation: Automation

    init(droplet: EavesdroppyDroplet) { prefs = droplet.prefs; automation = droplet.automation }

    var body: some View {
        DropletSettingsPage {
            DropletSettingsCard {
                DropletToggleRow(title: "Prompt before events",
                                 subtitle: "A notch prompt a minute before a meeting with a video link or attendees, with Record ready. Turning it on asks Droppy for Calendar access.",
                                 isOn: Binding(get: { prefs.calendarPrompt },
                                               set: { prefs.set(Prefs.Key.calendarPrompt, $0); if $0 { automation.connectCalendar() } }))
                DropletControlRow(title: "Calendar access") {
                    switch automation.calendarStatus {
                    case .granted: DropletValuePill(text: "Connected")
                    case .denied: Button("Open System Settings") { automation.openCalendarSettings() }
                    case .notDetermined: Button("Connect calendar") { automation.connectCalendar() }
                    default: DropletValuePill(text: "Unavailable")
                    }
                }
                if let m = automation.message { DropletControlRow(title: m) { EmptyView() } }
                DropletToggleRow(title: "Start recording automatically",
                                 subtitle: "Starts when the event begins, without asking. The notch reminds everyone they're being recorded.",
                                 isOn: prefs.binding(Prefs.Key.calendarAutoStart, false))
                    .disabled(!prefs.calendarPrompt)
            }
        }
        .onAppear { automation.refreshPermissions() }
    }
}

// MARK: - Output

private struct OutputPage: View {
    @ObservedObject var prefs: Prefs
    @ObservedObject var linear: LinearSettings
    @State private var keyDraft = ""

    var body: some View {
        DropletSettingsPage {
            DropletSettingsSection {
                settingsSectionHeader("Reminders")
            } content: {
                DropletSettingsCard {
                    DropletControlRow(title: "List name", infoTip: "Action items go into this list in Reminders.") {
                        TextField("", text: prefs.binding(Prefs.Key.remindersList, "Eavesdroppy"), prompt: Text("Eavesdroppy"))
                            .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 200)
                    }
                }
            }
            DropletSettingsSection {
                settingsSectionHeader("Linear")
            } content: {
                DropletSettingsCard {
                    DropletControlRow(title: "API key", infoTip: "Stored in your Keychain, never in preferences. Create one in Linear under Settings, API.") {
                        HStack(spacing: DroppySpacing.sm) {
                            SecureField("", text: $keyDraft, prompt: Text(linear.hasKey == true ? "Saved in Keychain" : "lin_api_…"))
                                .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 180)
                            Button("Save") { linear.save(keyDraft); keyDraft = "" }
                                .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                            if linear.hasKey == true { Button("Remove", role: .destructive) { linear.remove() } }
                        }
                    }
                    DropletControlRow(title: "Default team", infoTip: "New issues go to this team. Leave unset to be asked each time.") {
                        HStack(spacing: DroppySpacing.sm) {
                            Text(teamText).foregroundStyle(.secondary).lineLimit(1)
                            teamMenu
                        }
                    }
                    if let m = linear.message { DropletControlRow(title: m) { EmptyView() } }
                }
            }
        }
        .onAppear { linear.refresh() }
    }

    private var teamText: String {
        switch linear.teams {
        case .loading: return "Loading…"
        case .failed(let why): return why
        default: return prefs.pref(Prefs.Key.linearTeamName, "").isEmpty ? "None" : prefs.pref(Prefs.Key.linearTeamName, "")
        }
    }

    @ViewBuilder private var teamMenu: some View {
        if case .loaded(let teams) = linear.teams {
            Menu("Choose team") {
                ForEach(teams) { t in
                    Button("\(t.name)\(t.key.isEmpty ? "" : " (\(t.key))")") {
                        prefs.set(Prefs.Key.linearTeamID, t.id); prefs.set(Prefs.Key.linearTeamName, t.name)
                    }
                }
                Divider()
                Button("None") { prefs.set(Prefs.Key.linearTeamID, ""); prefs.set(Prefs.Key.linearTeamName, "") }
            }
            .fixedSize()
        } else {
            Button("Load teams") { linear.loadTeams() }.disabled(linear.hasKey != true || linear.teams == .loading)
        }
    }
}

// MARK: - Storage

private struct StoragePage: View {
    @ObservedObject var droplet: EavesdroppyDroplet
    @ObservedObject var prefs: Prefs
    @ObservedObject var library: LibraryModel
    @State private var automatic = ""   // the default folder, resolved off the main thread (a Drive stat can stall)

    init(droplet: EavesdroppyDroplet) { self.droplet = droplet; prefs = droplet.prefs; library = droplet.library }

    private var folderText: String {
        (prefs.outputFolder.isEmpty ? (automatic.isEmpty ? "…" : automatic) : prefs.outputFolder).replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    var body: some View {
        DropletSettingsPage {
            DropletSettingsCard {
                DropletGroupedPickerRow(title: "Audio retention",
                                        subtitle: "Older recordings are deleted. Notes and transcripts are always kept.") {
                    Picker("", selection: prefs.binding(Prefs.Key.retentionDays, 0)) {
                        Text("Keep forever").tag(0)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                        Text("1 year").tag(365)
                    }
                    .labelsHidden().pickerStyle(.menu)
                }
            }
            DropletSettingsCard {
                DropletControlRow(title: "Output folder",
                                  infoTip: "Notes, transcripts and audio are saved here, one folder per meeting. Meetings already saved stay where they are. Empty uses your Google Drive meetings folder if this Mac has one, else Documents/Eavesdroppy.") {
                    HStack(spacing: DroppySpacing.sm) {
                        Text(folderText)
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).frame(maxWidth: 220, alignment: .trailing)
                        Button("Choose…") { droplet.chooseOutputFolder() }
                        if !prefs.outputFolder.isEmpty { Button("Use default") { prefs.set(Prefs.Key.outputFolder, "") } }
                        Button("Show") { droplet.openFolder() }
                    }
                }
                #if EAVESDROPPY_PERSONAL
                DropletToggleRow(title: "Use Python pipeline (fallback)",
                                 subtitle: "Personal build only. Runs process_meeting.py instead of the built-in pipeline, as before the port. Turn it off again once the new one has proved itself.",
                                 isOn: prefs.binding(Prefs.Key.usePython, false))
                #endif
                DropletControlRow(title: "Import existing Drive meetings",
                                  infoTip: "Adds meetings already saved in the Drive folder to the library. Safe to run again.") {
                    HStack(spacing: DroppySpacing.sm) {
                        if library.busy != nil { ProgressView().controlSize(.small) }
                        Button("Import") { droplet.importDriveMeetings() }.disabled(library.busy != nil)
                    }
                }
                if let s = library.status { DropletControlRow(title: s) { EmptyView() } }
            }
        }
        .onAppear { DispatchQueue.global(qos: .utility).async { let p = automaticOutputRoot(); DispatchQueue.main.async { automatic = p } } }
    }
}
