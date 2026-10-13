//
//  EavesdroppyDroplet.swift
//  Eavesdroppy
//

import AppKit
import Combine
import DroppyKit
import SwiftUI
import UniformTypeIdentifiers

/// The class Droppy's loader instantiates, named in the bundle's
/// `NSPrincipalClass`. Keep it empty: it runs before the host is ready.
@objc(EavesdroppyPrincipal)
public final class EavesdroppyPrincipal: NSObject, DropletPrincipal {
    public override init() { super.init() }

    @MainActor public func makeDroplet() -> AnyObject { EavesdroppyDroplet() }
}

struct Job: Identifiable { let dir: URL; let title: String; var id: URL { dir } }
struct FailedJob: Identifiable { let dir: URL; let title: String; let reason: String?; var id: URL { dir } }

private enum Phase { case idle, starting, recording, stopping }

/// Hop from a background queue to the main actor.
private func onMain(_ f: @escaping @MainActor () -> Void) { DispatchQueue.main.async { MainActor.assumeIsolated { f() } } }

/// Typed notes are written here, in order, never on the main or audio queue.
private let notesQ = DispatchQueue(label: "eavesdroppy.notes", qos: .utility)

/// The one wording for "the system-audio tap gave nothing": the widget, the notes window and the live activity all key off it.
let noCallAudio = "No call audio. Allow Droppy in Screen & System Audio Recording."

/// Seconds without a single call-audio sample before the permission warning. The system tap can take ~40 s to
/// deliver its first buffer and then record fine, so anything shorter is a false alarm.
private let silentCallAudioGrace = 60
func callAudioMissing(elapsed: Int, frames: Int64) -> Bool { elapsed >= silentCallAudioGrace && frames == 0 }

/// "12:34", and "1:15:12" from one hour on (the wing and the shelf header both show it).
func clockText(_ seconds: Int) -> String {
    let s = max(seconds, 0), h = s / 3600, m = s % 3600 / 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s % 60) : String(format: "%d:%02d", m, s % 60)
}

/// The shelf widget's height from what it shows. Every composition (solo and paired) lays out to the same rows, so
/// one number serves both. 16 is the content insets, 20 the header, 8 the gap between rows, 30 a button or field row.
func shelfWidgetHeight(recording: Bool, attendees: Bool, warning: Bool, permissionProblem: Bool, rows: Int) -> CGFloat {
    var h: CGFloat = 16 + 20 + 8
    if recording {
        h += 17 + 8 + 30                    // title, buttons
        if attendees { h += 8 + 15 }
        if warning { h += 8 + 30 }
    } else {
        h += 30                             // title field and Record
        if permissionProblem { h += 8 + 30 }
        if rows > 0 { h += 8 + CGFloat(rows) * 22 + 10 }  // the scroll view needs 8 beyond its rows (+2 was clipped in the notch shot, +10 fits)
    }
    return min(h, 170)
}

/// Card content height for a HUD: one title line is 52, a second title line, a detail (up to three lines) and one
/// button row each add what they need. The estimate counts characters; it only has to be generous enough not to clip.
func hudCardHeight(title: String, detail: String?, hasAction: Bool) -> CGFloat {
    func lines(_ s: String, perLine: Int, atMost: Int) -> CGFloat { CGFloat(min(atMost, max(1, (s.count + perLine - 1) / perLine))) }
    var h: CGFloat = 52 + (lines(title, perLine: 36, atMost: 2) - 1) * 17
    if let detail { h += 24 + (lines(detail, perLine: 52, atMost: 3) - 1) * 14 }
    return h + (hasAction ? 34 : 0)
}

/// Records mic + call audio, then hands the session to process_meeting.py.
@MainActor
public final class EavesdroppyDroplet: NSObject, ObservableObject, Droplet {
    public nonisolated static let id: DropletID = "eavesdroppy"

    static let widgetID: ShelfWidgetID = "eavesdroppy"
    static let surfaceID: ExpandedSurfaceID = "library"

    private(set) var host: DropletHost?
    let prefs = Prefs()
    let library = LibraryModel(container: containerDir)
    let enrollment = Enrollment()
    let linear = LinearSettings()
    let providerSettings = ProviderSettingsModel()
    let mcp = MCPServerModel()
    private(set) lazy var automation = Automation(droplet: self)
    var presentation: ExpandedSurfacePresentation?
    private let work = DispatchQueue(label: "pipeline")  // serial: one meeting processed at a time
    private let copyQueue = DispatchQueue(label: "eavesdroppy.import", qos: .utility)  // never behind a running pipeline
    private let fsQueue = DispatchQueue(label: "eavesdroppy.fs", qos: .utility)  // directory scans, deletes, Drive checks
    private var recorder: Recorder?
    private var activeDir: URL?  // being created/recorded: not a failed session
    private var timer: Timer?
    private var confirmTimer: Timer?
    private var importPanel: NSOpenPanel?  // open while the import picker is up; it holds the shelf open
    private var permissionTask: Task<Void, Never>?
    private var systemChecked = false
    private var notesPanel: NotesPanelController?  // lazy: created by the first showNotes, gone when the recording ends
    private let activitySubject = CurrentValueSubject<LiveActivityState?, Never>(nil)
    private var declaredHeight: CGFloat = 0  // what widgetDescriptors last told the host
    private var heightSub: AnyCancellable?

    @Published private var phase: Phase = .idle
    @Published private(set) var session: (dir: URL, title: String, attendees: [String], start: Date)?
    @Published private(set) var elapsed = 0
    @Published private(set) var warnings: [String] = []
    @Published private(set) var pending: [Job] = []  // running + queued (+ importing)
    @Published private(set) var failed: [FailedJob] = []
    @Published private(set) var permissionProblem: String?
    @Published var titleDraft = ""  // empty shows the placeholder; startRecording falls back to "Meeting"
    @Published var confirmingDiscard = false
    @Published var confirmingDelete: URL?
    /// Typed notes for the recording in progress; saved to <session>/notes.txt 1 s after the last keystroke.
    @Published var notesText = "" { didSet { if notesText != oldValue { notesEdited() } } }
    @Published var recordingTemplate = "general"
    /// Set by startRecording for the next didStart: the consent line is shown for an automatic start whatever the setting.
    private var startedAutomatically = false
    /// Folder -> library id of meetings processed this session, so a Recent row opens the meeting in the library.
    private var recentMeetingIDs: [String: Int] = [:]
    private var notesWork: DispatchWorkItem?

    var recording: Bool { phase == .recording }
    var callAudioProblem: Bool { warnings.contains(noCallAudio) }

    var busy: Bool { phase == .starting || phase == .stopping }
    var starting: Bool { phase == .starting }

    public func activate(host: DropletHost) throws {
        self.host = host
        let hostLog = host.log
        logSink = { msg in DispatchQueue.main.async { MainActor.assumeIsolated { hostLog.info(msg) } } }
        let droplets = host.environment.containerDirectory.deletingLastPathComponent().deletingLastPathComponent()
        let newContainer = host.environment.containerDirectory
        fsQueue.async {  // before refreshFailed below on the same queue, so migrated sessions show up as Failed rows to retry
            for line in migrateContainer(from: droplets.appendingPathComponent("meetings/Container"), to: newContainer) { log(line) }
        }
        sessionsDir = host.environment.containerDirectory.appendingPathComponent("sessions")
        containerDir = host.environment.containerDirectory
        heightSub = Publishers.Merge(objectWillChange.map { _ in () }, library.objectWillChange.map { _ in () })
            .receive(on: DispatchQueue.main).sink { [weak self] in self?.reconcileHeight() }
        prefs.onChange = { [weak self] in self?.prefsChanged() }
        prefs.attach(host.preferences)
        providerSettings.attach(ProviderPrefs(get: { [prefs] in prefs.pref($0, "") }, set: { [prefs] in prefs.set($0, $1) }))
        mcp.attach(MCPPrefs(enabled: { [prefs] in prefs.pref(MCPServerModel.Key.enabled, false) },
                            setEnabled: { [prefs] in prefs.set(MCPServerModel.Key.enabled, $0) },
                            port: { [prefs] in prefs.pref(MCPServerModel.Key.port, MCPServerModel.defaultPort) },
                            setPort: { [prefs] in prefs.set(MCPServerModel.Key.port, $0) }),
                   container: containerDir,
                   userName: { [prefs] in prefs.userName },
                   providerConfig: { [prefs] in NotesProviderConfig(read: { prefs.pref($0, "") }) },
                   copy: { [weak self] in self?.host?.workspace.copyToPasteboard($0) ?? false })
        prefs.writeCustomTemplateFile()
        library.setContainer(containerDir)
        library.userName = { [weak self] in self?.prefs.userName ?? "" }
        library.requestKeyboard = { [weak self] in self?.focusTitle() }
        library.reveal = { [weak self] url in self?.host?.workspace.revealInFinder(url) }
        library.openURL = { [weak self] url in _ = self?.host?.workspace.open(url) }
        library.refresh()
        scheduleExpiry()
        scheduleOldDropletNotice(droplets: droplets)
        refreshFailed(clearMarkers: true)  // nothing can be processing at activation
        exporterSetup()
        automation.activate()  // reads permission status only; nothing is requested until the user reaches for a feature
        if host.environment.isHarness, let demo = ProcessInfo.processInfo.environment["EAVESDROPPY_HARNESS_DEMO"] { harnessDemo(demo) }
        // Needs `global-shortcuts`; a host without it refuses and the droplet carries on. 45 = kVK_ANSI_N.
        host.shortcuts.register(
            id: "show-notes", title: "Show meeting notes",
            defaultShortcut: DropletKeyboardShortcut(keyCode: 45, modifiers: NSEvent.ModifierFlags([.option, .command]).rawValue)
        ) { [weak self] in
            guard let self else { return }
            if self.recording { self.showNotes() } else { self.openLibrary() }
        }
        log("Eavesdroppy activated, sessions at \(sessionsDir.path)")
    }

    /// Stops the audio on the audio queue (never blocks the main thread) and writes the final meta.json. If this
    /// runs because of a deactivation the recording is saved and shows up under Failed for retry.
    private func finishRecording(_ rec: Recorder, _ s: (dir: URL, title: String, attendees: [String], start: Date), then done: (@MainActor (RecResult) -> Void)? = nil) {
        notesWork?.cancel(); notesWork = nil
        let notes = notesText, template = recordingTemplate, names = automation.participantSnapshot
        let autoNaming = prefs.autoNaming, customText = prefs.customTemplate
        audioQ.async {
            let r = rec.stop()
            // meta.json learns the chosen template and the typed notes file (queued debounced writes land first).
            var extra: [String: Any] = ["template": template]
            if template == "custom" { extra["custom_template_file"] = Prefs.customTemplateFile.path; extra["custom_template"] = customText }
            extra["auto_naming"] = autoNaming
            if !names.isEmpty { extra["participants"] = names }  // Accessibility reader (D18): naming candidates beside the attendees
            notesQ.sync { writeNotes(notes, in: s.dir) }
            if !notes.isEmpty { extra["user_notes_file"] = "notes.txt" }
            do { try writeMeta(dir: s.dir, title: s.title, start: s.start, attendees: s.attendees, source: "record", offsets: r.offsets, extra: extra) }
            catch { log("ERROR writing meta.json at stop: \(error)") }
            log("recording saved: \(s.dir.lastPathComponent) offsets=\(r.offsets)")
            if let done { onMain { done(r) } }
        }
    }

    /// Inert afterwards: queued jobs and in-flight callbacks are invalidated by the epoch bump, the pipeline's whole
    /// process group is SIGTERMed, timers and the pending permission request are cancelled. A recording being made
    /// is stopped asynchronously (deactivate must not block Droppy's UI) and recovers under Failed on the next launch.
    public func deactivate() {
        let rec = recorder, s = session
        cancelPipeline()
        mcp.stop()
        if let rec, let s { finishRecording(rec, s) }
        automation.deactivate()
        permissionTask?.cancel(); permissionTask = nil
        timer?.invalidate(); timer = nil
        confirmTimer?.invalidate(); confirmTimer = nil
        heightSub = nil
        library.surfaceClosed(); enrollment.cancel()
        notesPanel?.teardown(); notesPanel = nil
        if let panel = importPanel { importPanel = nil; _ = host?.shelf.setHoldsOpen(false); panel.cancel(nil) }
        recorder = nil; session = nil; activeDir = nil; phase = .idle; warnings = []; notesText = ""
        confirmingDiscard = false; confirmingDelete = nil
        pending = []
        activitySubject.send(nil)
        log("Eavesdroppy deactivated")
        logSink = { print($0) }
        prefs.detach(); presentation = nil
        host = nil
    }

    /// Veto removal while a recording is being made or processed.
    public func prepareForRemoval() -> Bool {
        let ok = phase == .idle && pending.isEmpty
        if !ok { notify("Can't remove while recording or processing", symbol: "exclamationmark.triangle.fill") }
        return ok
    }

    // MARK: recording

    func startRecording() {
        let t = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        startRecording(title: t.isEmpty ? "Meeting" : t, attendees: [], autoStarted: false)
    }

    /// `attendees` (calendar names or emails) go into meta.json from the first write. `autoStarted`: nobody clicked.
    func startRecording(title: String, attendees: [String], autoStarted: Bool) {
        guard phase == .idle, let host else { return }
        permissionProblem = nil
        phase = .starting
        startedAutomatically = autoStarted
        switch host.permissions.status(for: .microphone) {
        case .granted: begin(title: title, attendees: attendees)
        case .notDetermined:
            permissionTask = Task {
                let s = await host.permissions.request(.microphone)
                guard !Task.isCancelled, self.host != nil else { return }
                if s == .granted { self.begin(title: title, attendees: attendees) } else { self.micProblem(s) }
            }
        case let s: micProblem(s)
        }
    }

    private func micProblem(_ s: DropletPermissionStatus) {
        log("microphone permission: \(s)")
        phase = .idle
        permissionProblem = s == .unavailable ? "This Droppy build can't record the microphone"
                                              : "Microphone access is off for Droppy"
    }

    func openMicSettings() { host?.permissions.openSystemSettings(for: .microphone) }

    /// workspace.open refuses the System Settings URL scheme (only http, https, mailto and file), so this goes through the
    /// permissions service, which knows the Screen & System Audio Recording pane.
    func openScreenAudioSettings() { host?.permissions.openSystemSettings(for: .screenCapture) }

    private func begin(title: String, attendees: [String]) {
        guard host != nil, phase == .starting else { return }
        let start = Date(), dir = newSessionDir(start), epoch = currentEpoch()
        let rec = Recorder(dir: dir)
        rec.onWarning = { msg in onMain { self.addWarning(msg) } }
        rec.onFatal = { msg in onMain { self.recordingBroke(msg) } }
        activeDir = dir
        audioQ.async {
            var failure: Error?
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                // meta.json first: if Droppy crashes mid-recording the session still recovers with its title and start.
                try writeMeta(dir: dir, title: title, start: start, attendees: attendees, source: "record")
                try rec.start()
            } catch {
                failure = error
                _ = rec.stop(); try? FileManager.default.removeItem(at: dir)
            }
            let err = failure
            onMain { self.didStart(rec, dir: dir, title: title, attendees: attendees, start: start, error: err, epoch: epoch) }
        }
    }

    private func didStart(_ rec: Recorder, dir: URL, title: String, attendees: [String], start: Date, error: Error?, epoch: Int) {
        guard epoch == currentEpoch(), host != nil else {  // deactivated while starting
            if error == nil { audioQ.async { _ = rec.stop() } }  // the session dir stays and recovers under Failed
            return
        }
        if let error {
            log("ERROR start failed: \(error)")
            activeDir = nil; phase = .idle
            notify("Couldn't start recording", symbol: "exclamationmark.triangle.fill",
                   detail: "Eavesdroppy couldn't open the audio. Check the microphone and the disk, then try again.")  // the raw error is logged above
            return
        }
        recorder = rec
        notesText = ""; recordingTemplate = prefs.defaultTemplate
        session = (dir, title, attendees, start)
        phase = .recording
        elapsed = 0; systemChecked = false
        warnings = rec.systemWarning == nil ? [] : [noCallAudio]
        log("recording started: \(title) -> \(dir.path)")
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { self.tick() } }
        publishActivity()
        automation.recordingStarted()
        if prefs.consentLine || startedAutomatically {  // nobody clicked an automatic start, so it always says so
            notify("Recording started", symbol: "mic.fill", detail: "Tell everyone on the call.")
        }
        startedAutomatically = false
        if prefs.openNotesOnRecord { showNotes(focus: false) }  // opens by itself, but the meeting app keeps the keyboard
    }

    private func tick() {
        guard let s = session else { return }
        elapsed = Int(Date().timeIntervalSince(s.start))
        // No call audio at all after a full minute: the permission is almost certainly off.
        if !systemChecked, let st = recorder?.system, callAudioMissing(elapsed: elapsed, frames: st.frames) {
            systemChecked = true
            addWarning(noCallAudio)
        }
        automation.tick(elapsed: elapsed)
    }

    private func addWarning(_ w: String) {
        guard session != nil, !warnings.contains(w) else { return }
        warnings.append(w)
        publishActivity()  // the wing's glyph and its spoken title follow the problem
        if w == noCallAudio { notify("No call audio", symbol: "exclamationmark.triangle.fill", detail: "Allow Droppy in Screen & System Audio Recording.") }
        else { notify("Recording problem", symbol: "exclamationmark.triangle.fill", detail: w) }
    }

    /// A track can't be written (disk full): stop with what we have rather than record into the void.
    private func recordingBroke(_ why: String) {
        guard phase == .recording else { return }
        // The one `.high`: the recording itself is at risk. (`.high` is documented as "the user acted on it", so nothing else claims it.)
        notify("Recording stopped", symbol: "exclamationmark.triangle.fill", detail: "\(why). What was captured is saved under Failed.", priority: .high)
        stopRecording(process: false)
    }

    /// Stops, writes meta.json, and (unless `process` is false) queues processing.
    func stopRecording(process: Bool) {
        guard phase == .recording, let rec = recorder, let s = session else { return }
        phase = .stopping
        timer?.invalidate(); timer = nil
        let epoch = currentEpoch()
        finishRecording(rec, s) { r in
            guard epoch == currentEpoch() else { return }
            let sysDown = rec.systemWarning != nil
            self.endSession()
            if r.systemSilent && !sysDown {
                self.notify("No call audio was recorded", symbol: "exclamationmark.triangle.fill", detail: "Allow Droppy in Screen & System Audio Recording, then record again.")
            }
            if process { self.enqueue(s.dir, title: s.title) } else { self.refreshFailed() }
        }
    }

    func discard() {
        guard phase == .recording else { return }
        guard confirmingDiscard else { confirmingDiscard = true; armConfirm(); return }
        guard let rec = recorder, let s = session else { return }
        phase = .stopping
        timer?.invalidate(); timer = nil
        notesWork?.cancel(); notesWork = nil
        let epoch = currentEpoch()
        audioQ.async {
            _ = rec.stop(); try? FileManager.default.removeItem(at: s.dir)
            log("recording discarded: \(s.dir.lastPathComponent)")
            onMain { if epoch == currentEpoch() { self.endSession() } }
        }
    }

    /// A confirm button ("Confirm discard", "Confirm delete") disarms itself after 4 s.
    private func armConfirm() {
        confirmTimer?.invalidate()
        confirmTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { _ in
            MainActor.assumeIsolated { self.confirmingDiscard = false; self.confirmingDelete = nil }
        }
    }

    private func endSession() {
        recorder = nil; session = nil; activeDir = nil; warnings = []; phase = .idle
        automation.recordingEnded()
        confirmingDiscard = false
        timer?.invalidate(); timer = nil
        activitySubject.send(nil)
        notesWork?.cancel(); notesWork = nil; notesText = ""
        notesPanel?.teardown(); notesPanel = nil
    }

    // MARK: typed notes

    private func notesEdited() {
        guard phase == .recording, let dir = session?.dir else { return }
        notesWork?.cancel()
        let text = notesText
        let w = DispatchWorkItem { notesQ.async { writeNotes(text, in: dir) } }
        notesWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: w)
    }

    /// Opens (or brings forward) the floating notes window; with no recording it opens the library instead.
    /// The window can be closed and reopened during a recording; the text lives here, not in the window.
    func showNotes(focus: Bool = true) {
        guard recording, let s = session else { openLibrary(); return }
        if notesPanel == nil {
            notesPanel = NotesPanelController(
                content: { [unowned self] in AnyView(NotesPanelView(droplet: self)) },
                loadFrame: { [weak self] in self?.host?.preferences.value(forKey: Self.notesFrameKey, default: "") ?? "" },
                saveFrame: { [weak self] in self?.host?.preferences.setValue($0, forKey: Self.notesFrameKey) })
        }
        notesPanel?.show(title: s.title, focus: focus)
    }
    private static let notesFrameKey = "notesPanelFrame"

    // MARK: library surface and settings

    func openLibrary() {
        presentation = host?.notchSurface.presentExpandedSurface(ExpandedSurfacePresentationRequest(surfaceID: Self.surfaceID))
        // Droppy refuses the surface for some approved local builds ("does not publish a surface with that id"): the
        // shelf is the nearest thing, with the recent meetings in it.
        if presentation == nil { _ = host?.shelf.open(revealing: Self.widgetID) }
    }

    /// Settings -> Storage: adds meetings already in the Drive folder to the library (idempotent on the Python side).
    func importDriveMeetings() {
        func count(_ v: Any?) -> Int { (v as? Int) ?? (v as? [Any])?.count ?? 0 }
        library.command(["import-drive"], serial: false, busy: "Importing…", failure: "Import failed") { [weak library] r in
            if case .success(let j) = r {
                library?.flash("Imported \(count(j["imported"])), skipped \(count(j["skipped"])), failed \(count(j["failed"]))")
            }
        }
    }

    private func prefsChanged() {
        objectWillChange.send()
        automation.reconcile()
    }

    /// D20: once a day at most, shortly after activation, delete audio older than the retention setting.
    private func scheduleExpiry() {
        let days = prefs.retentionDays
        guard days > 0, Date().timeIntervalSince1970 - prefs.pref(Prefs.Key.lastExpire, 0.0) >= 86_400 else { return }
        let epoch = currentEpoch()
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.host != nil, epoch == currentEpoch() else { return }
                Pipeline.submit(["expire-audio", String(days)]) { r in
                    MainActor.assumeIsolated {
                        switch r {
                        case .success(let j):
                            self.prefs.set(Prefs.Key.lastExpire, Date().timeIntervalSince1970)
                            log("expired audio older than \(days) days: \(j["deleted"] ?? 0) deleted")
                        case .failure(let e): log("ERROR expire-audio: \(e)")
                        }
                        self.library.refresh()
                    }
                }
            }
        }
    }

    /// Once: the old "meetings" droplet is still installed, and both would offer to record. We never remove it ourselves.
    private func scheduleOldDropletNotice(droplets: URL) {
        if let host, host.preferences.value(forKey: "oldDropletNoticed", default: false) { return }
        let epoch = currentEpoch()
        fsQueue.async {
            guard oldMeetingsDropletInstalled(droplets: droplets) else { return }
            onMain {
                // After the host has settled, and only once the HUD actually showed it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    MainActor.assumeIsolated {
                        guard epoch == currentEpoch(), let host = self.host else { return }
                        if self.notify("Remove the old Meetings droplet", symbol: "exclamationmark.triangle.fill",
                                       detail: "In Settings › Store › Local droplets. Eavesdroppy replaces it, and two recorders would both offer to start.") {
                            host.preferences.setValue(true, forKey: "oldDropletNoticed")
                        }
                    }
                }
            }
        }
    }

    // MARK: processing

    private func enqueue(_ dir: URL, title: String) {
        guard host != nil else { return }
        if !pending.contains(where: { $0.dir == dir }) { pending.append(Job(dir: dir, title: title)) }
        refreshFailed()
        let epoch = currentEpoch()
        work.async {
            guard currentEpoch() == epoch else { return }  // deactivated while queued
            let r = processSession(dir, epoch: epoch)
            onMain { self.finished(dir, title, r, epoch) }
        }
    }

    private func finished(_ dir: URL, _ title: String, _ r: Outcome, _ epoch: Int) {
        guard epoch == currentEpoch(), host != nil else { return }  // deactivated meanwhile
        pending.removeAll { $0.dir == dir }
        switch r {
        case .ok(let folder, let warnings, let meetingID):
            if let meetingID { recentMeetingIDs[folder] = meetingID }
            library.refresh()
            notify("Notes ready", symbol: warnings.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                   detail: warnings.isEmpty ? title : "\(title). \(warnings.joined(separator: " "))",
                   action: ("Open", { [weak self] in self?.openNotes(folder) }))
        case .failed(let why):
            // The shelf keeps its own Retry for this; a HUD button is unverified in a real Droppy.
            notify("Couldn't write notes", symbol: "exclamationmark.triangle.fill", detail: "\(title): \(why)",
                   action: ("Retry", { [weak self] in self?.retry(dir) }))
        }
        refreshFailed()
    }

    func retry(_ d: URL) {
        guard !pending.contains(where: { $0.dir == d }) else { return }  // already queued or running
        enqueue(d, title: failed.first { $0.dir == d }?.title ?? metaTitle(d) ?? d.lastPathComponent)
    }

    /// Failed rows are removed only after a second click within 4 s.
    func deleteFailed(_ d: URL) {
        guard !pending.contains(where: { $0.dir == d }),
              d.deletingLastPathComponent().standardizedFileURL == sessionsDir.standardizedFileURL else { return }
        guard confirmingDelete == d else { confirmingDelete = d; armConfirm(); return }
        confirmingDelete = nil
        failed.removeAll { $0.dir == d }
        fsQueue.async {
            do { try FileManager.default.removeItem(at: d); log("deleted failed session \(d.lastPathComponent)") }
            catch { log("ERROR deleting \(d.path): \(error)") }
            onMain { self.refreshFailed() }
        }
    }

    /// Session dirs with audio that are neither being processed nor being recorded. The scan runs off the main thread.
    /// `clearMarkers` (activation only) first deletes every .processing marker: nothing can be processing yet.
    private func refreshFailed(clearMarkers: Bool = false) {
        let skip = Set(pending.map(\.dir)), active = activeDir, root = sessionsDir, epoch = currentEpoch()
        fsQueue.async {
            let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            let c = classifySessions(dirs, skip: skip, active: active, clearMarkers: clearMarkers)
            let list = c.failed.map { FailedJob(dir: $0, title: metaTitle($0) ?? $0.lastPathComponent, reason: lastErrorLine($0)) }
            let resumed = c.resume
            onMain {
                guard epoch == currentEpoch() else { return }
                self.failed = list
                for d in resumed where !self.pending.contains(where: { $0.dir == d }) {
                    log("resuming interrupted session \(d.lastPathComponent)")
                    self.enqueue(d, title: metaTitle(d) ?? d.lastPathComponent)
                }
            }
        }
    }

    func openNotes(_ folder: String) {
        if let id = recentMeetingIDs[folder] { library.open(id); openLibrary(); return }
        _ = host?.workspace.open(URL(fileURLWithPath: folder + "/notes.md"))
    }

    func openFolder() {
        fsQueue.async {  // the Drive mount can stall a stat
            let root = outputRoot(), fm = FileManager.default
            do {
                try StoreMirror.checkOutRoot(root)  // never mkdir -p into a Drive path whose mount is not there
                try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
            } catch {
                log("ERROR output folder: \(error)")
                onMain { self.notify("Output folder not available", symbol: "exclamationmark.triangle.fill",
                                     detail: "Droppy can't reach the meetings folder. Check the drive is connected, or choose another folder in Settings.") }; return
            }
            onMain { _ = self.host?.workspace.open(URL(fileURLWithPath: root)) }
        }
    }

    /// D26: picks the folder meetings are written to. Same panel handling as `chooseImport`.
    func chooseOutputFolder() {
        guard importPanel == nil, host != nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose where meeting notes, transcripts and audio are saved"
        importPanel = panel
        _ = host?.shelf.setHoldsOpen(true)
        panel.begin { [weak self] resp in
            MainActor.assumeIsolated {
                guard let self, self.importPanel === panel else { return }
                self.importPanel = nil
                _ = self.host?.shelf.setHoldsOpen(false)
                if resp == .OK, let url = panel.url { self.prefs.set(Prefs.Key.outputFolder, url.path) }
            }
        }
    }

    // MARK: import

    private static func isMedia(_ url: URL) -> Bool {
        guard let t = UTType(filenameExtension: url.pathExtension) else { return false }
        return t.conforms(to: .audio) || t.conforms(to: .movie)
    }

    /// Copies each audio/video file into a new session (off the main thread; files can be large) and queues it
    /// like a recording. It shows as processing from the moment it is dropped.
    func importFiles(_ urls: [URL]) {
        guard host != nil else { return }
        let media = urls.filter { $0.isFileURL && Self.isMedia($0) }
        if media.count < urls.count { notify("Not an audio or video file", symbol: "exclamationmark.triangle.fill") }
        let typed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let custom = media.count == 1 && !typed.isEmpty ? typed : nil
        let epoch = currentEpoch()
        for url in media {
            let title = custom ?? url.deletingPathExtension().lastPathComponent
            let dir = newSessionDir()
            pending.append(Job(dir: dir, title: title))
            copyQueue.async {
                do {
                    try importFile(url, into: dir, title: title)
                    log("imported \(url.lastPathComponent) -> \(dir.lastPathComponent)")
                    onMain { if epoch == currentEpoch() { self.enqueue(dir, title: title) } }
                } catch {
                    log("ERROR import \(url.path): \(error)")
                    onMain {
                        guard epoch == currentEpoch() else { return }
                        self.pending.removeAll { $0.dir == dir }
                        self.notify("Import failed", symbol: "exclamationmark.triangle.fill", detail: "\(title): \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    /// No host file-picker service exists, so this is an AppKit open panel; the shelf is held open under it.
    /// The hold is released by the panel's completion handler, which AppKit calls on OK, Cancel and `cancel(nil)` alike,
    /// and by deactivate() (after which the handler can no longer reach the host).
    func chooseImport() {
        guard importPanel == nil, host != nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose a recording to turn into notes"
        importPanel = panel
        _ = host?.shelf.setHoldsOpen(true)
        panel.begin { [weak self] resp in
            MainActor.assumeIsolated {
                guard let self, self.importPanel === panel else { return }  // deactivate() already released the hold
                self.importPanel = nil
                _ = self.host?.shelf.setHoldsOpen(false)
                if resp == .OK { self.importFiles(panel.urls) }
            }
        }
    }

    func focusTitle() { _ = host?.shelf.requestKeyboardFocus() }

    /// Always a card: a strip puts its content across the camera housing, and a sentence does not fit in the two
    /// wings. The strip form a request must also carry is the glyph alone, at the far left. `action` is one quiet
    /// button on the card (it also dismisses the card).
    @discardableResult
    func notify(_ title: String, symbol: String, detail: String? = nil, priority: DropletHUDPriority = .normal,
                action: (label: String, run: @MainActor () -> Void)? = nil) -> Bool {
        log("notify: \(title)\(detail.map { " (\($0))" } ?? "")")
        let id = "eavesdroppy.notice"
        return host?.hud.present(DropletHUDRequest(
            id: id, duration: action == nil ? 8 : 10, priority: priority,
            accessibilityLabel: [title, detail].compactMap { $0 }.joined(separator: ". "),
            isExpanded: true, expandedContentHeight: hudCardHeight(title: title, detail: detail, hasAction: action != nil),
            content: {
                // The glyph at the far left; the middle of a strip is the camera housing and each wing holds a glyph, not words.
                HStack(spacing: 0) {
                    Image(systemName: symbol).font(.system(size: DroppyLiveActivityMetrics.iconSize, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            },
            expanded: { [weak self] in
                VStack(alignment: .leading, spacing: DroppySpacing.xs) {
                    HStack(alignment: .top, spacing: DroppySpacing.sm) {
                        Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                        Text(verbatim: title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    }
                    if let detail {
                        Text(verbatim: detail).font(.system(size: 11)).lineLimit(3)
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    }
                    if let action {
                        HStack {
                            Spacer(minLength: 0)
                            Button(action.label) { self?.host?.hud.dismiss(id: id); action.run() }
                                .buttonStyle(DroppyQuietButtonStyle(size: .small))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            })) ?? false
    }

    var clock: String { clockText(elapsed) }

    /// Harness only (EAVESDROPPY_HARNESS_DEMO=rows): a job being written, a failed one and three recent meetings.
    func demoRows() {
        pending = [Job(dir: sessionsDir.appendingPathComponent("demo-a"), title: "Design review")]
        failed = [FailedJob(dir: sessionsDir.appendingPathComponent("demo-b"), title: "Customer call", reason: "The notes tool is not installed")]
        let now = Date()
        func iso(_ ago: TimeInterval) -> String { ISO8601DateFormatter().string(from: now.addingTimeInterval(-ago)) }
        func m(_ i: Int, _ t: String, _ ago: TimeInterval, _ open: Int) -> MeetingSummary {
            MeetingSummary(id: i, title: t, start: iso(ago), duration: 1860, source: "record", template: "general", summaryStatus: "ok", folder: nil, audioPath: nil, openActions: open)
        }
        library.demoRecents([m(1, "Weekly sync", 3600, 2), m(2, "1:1 with Priya", 86_400 + 3600, 0), m(3, "Roadmap planning", 4 * 86_400, 1)])
    }

    /// Harness only (EAVESDROPPY_HARNESS_DEMO=recording): a recording on screen with no audio behind it.
    func demoRecording() {
        session = (sessionsDir.appendingPathComponent("demo"), "Weekly sync", ["Priya Nair", "Sam Lee"], Date().addingTimeInterval(-754))
        phase = .recording; elapsed = 754
        warnings = [noCallAudio]
    }
}

// MARK: - Shelf widget

extension EavesdroppyDroplet {
    /// Rows the idle widget lists: running and queued jobs, failed sessions, and the recent meetings.
    private var listRows: Int { pending.count + failed.count + library.recents.count }

    var widgetHeight: CGFloat {
        shelfWidgetHeight(recording: session != nil, attendees: !(session?.attendees.isEmpty ?? true), warning: !warnings.isEmpty,
                          permissionProblem: permissionProblem != nil, rows: listRows)
    }

    /// Asks the host to re-measure only when the declared height changed: never per tick, never per keystroke.
    func reconcileHeight() {
        guard host != nil, widgetHeight != declaredHeight else { return }
        host?.shelf.invalidateLayout(for: Self.widgetID)
    }
}

extension EavesdroppyDroplet: ShelfWidgetProviding {
    public var widgetDescriptors: [ShelfWidgetDescriptor] {
        declaredHeight = widgetHeight
        return [
            ShelfWidgetDescriptor(
                id: "eavesdroppy",
                title: "Eavesdroppy",
                systemImage: "waveform",
                layoutTraits: ShelfWidgetLayoutTraits(
                    preferredSoloWidth: 420,
                    preferredPairedWidth: 210,
                    contentHeight: .fixed(declaredHeight)  // from what it shows: see shelfWidgetHeight
                ),
                focusPolicy: .keyboardFocusable
            )
        ]
    }

    public func makeWidgetView(_ id: ShelfWidgetID, context: ShelfWidgetContext) -> AnyView {
        AnyView(EavesdroppyWidget(droplet: self, library: library, context: context))
    }

    public func makeWidgetSettingsPopover(_ id: ShelfWidgetID) -> AnyView? { nil }
}

/// The audio problem, as one row. The button opens the privacy pane only for the missing call audio.
struct WarningRow: View {
    @ObservedObject var droplet: EavesdroppyDroplet
    var compact = false

    var body: some View {
        HStack(spacing: DroppySpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(StateColor.warning)
            Text(compact && droplet.callAudioProblem ? "No call audio" : droplet.warnings.joined(separator: " "))
                .font(.system(size: 11)).foregroundStyle(StateColor.warning).lineLimit(2)
            Spacer(minLength: 0)
            if droplet.callAudioProblem {
                Button(compact ? "Settings" : "Open System Settings") { droplet.openScreenAudioSettings() }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small))
            }
        }
    }
}

private struct EavesdroppyWidget: View {
    @ObservedObject var droplet: EavesdroppyDroplet
    @ObservedObject var library: LibraryModel
    let context: ShelfWidgetContext

    private var recording: Bool { droplet.session != nil }
    private var working: Bool { !droplet.pending.isEmpty || droplet.starting }

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            header
            if let s = droplet.session { recordingBody(s) } else { idleBody }
            Spacer(minLength: 0)
        }
        .padding(context.contentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Droppy's shelf may claim the drag itself (its file tray); "Import recording…" in the menu always works.
        .dropDestination(for: URL.self) { urls, _ in droplet.importFiles(urls); return !urls.isEmpty }
    }

    private var header: some View {
        HStack(spacing: DroppySpacing.xsm) {
            let glyph = recording ? "record.circle.fill" : (working ? "hourglass" : "waveform")
            Image(systemName: glyph)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(recording ? StateColor.destructive : AdaptiveColors.notchSurfaceSecondaryText)
                .id(glyph).transition(DroppyTransition.element)
            Text("Eavesdroppy").font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 0)
            if recording {
                Text(droplet.clock).font(.system(size: context.isCompact ? 13 : 12, weight: context.isCompact ? .medium : .semibold)).monospacedDigit()
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .transition(DroppyTransition.element)
            } else if !context.isCompact {
                Button { droplet.openLibrary() } label: { Image(systemName: "books.vertical") }
                    .buttonStyle(DroppyCircleButtonStyle(size: 20)).accessibilityLabel("Open meetings")
            }
            overflow
        }
        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
    }

    private var overflow: some View {
        Menu {
            Button("Open meetings") { droplet.openLibrary() }
            Button("Import recording…") { droplet.chooseImport() }
            Button("Open meetings folder") { droplet.openFolder() }
        } label: { Image(systemName: "ellipsis") }
            .menuStyle(.button).buttonStyle(DroppyCircleButtonStyle(size: 20)).fixedSize().accessibilityLabel("More")
    }

    @ViewBuilder private var primaryButton: some View {
        if recording {
            Button("Stop") { droplet.stopRecording(process: true) }
                .buttonStyle(DroppyAccentButtonStyle(color: StateColor.destructive, size: .small))
                .disabled(droplet.busy)
                .transition(DroppyTransition.element)
        } else {
            Button("Record") { droplet.startRecording() }
                .buttonStyle(DroppyAccentButtonStyle(size: .small))
                .disabled(droplet.busy)
                .transition(DroppyTransition.element)
        }
    }

    // MARK: idle

    private var idleBody: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            if context.isCompact {
                primaryButton
            } else {
                HStack(spacing: DroppySpacing.sm) {
                    TextField("Meeting title", text: $droplet.titleDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                        .onTapGesture { droplet.focusTitle() }
                        .onSubmit { droplet.startRecording() }
                        .padding(.horizontal, DroppySpacing.smd).padding(.vertical, DroppySpacing.xsm)
                        .background(RoundedRectangle(cornerRadius: DroppyRadius.ms, style: .continuous).fill(AdaptiveColors.notchSurfaceCardFill))
                    primaryButton
                }
            }
            if let p = droplet.permissionProblem {
                HStack(spacing: DroppySpacing.sm) {
                    Text(p).font(.system(size: 11)).foregroundStyle(StateColor.warning).lineLimit(1)
                    Spacer(minLength: 0)
                    Button(context.isCompact ? "Settings" : "Open System Settings") { droplet.openMicSettings() }
                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                }
            }
            rows
        }
    }

    private var rows: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(droplet.pending) { j in
                    row("hourglass", "Writing notes · \(j.title)")
                }
                ForEach(droplet.failed) { f in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: DroppySpacing.xsm) {
                            row("exclamationmark.triangle", "Couldn't process \(f.title)")
                            Button("Retry") { droplet.retry(f.dir) }.buttonStyle(DroppyQuietButtonStyle(size: .small))
                            Button(droplet.confirmingDelete == f.dir ? "Confirm delete" : "Delete") { droplet.deleteFailed(f.dir) }
                                .buttonStyle(DroppyQuietButtonStyle(size: .small, destructive: droplet.confirmingDelete == f.dir))
                                .frame(width: 96)  // the confirm label must not move its neighbours
                        }
                        if let why = f.reason {
                            Text(why).font(.system(size: 11)).foregroundStyle(StateColor.warning).lineLimit(2).padding(.leading, 14 + DroppySpacing.xsm)
                        }
                    }
                }
                ForEach(library.recents) { m in
                    Button { library.open(m.id); droplet.openLibrary() } label: { recentRow(m) }
                        .buttonStyle(.plain)
                }
            }
        }
        .droppyFlatGlassControls()
    }

    private func recentRow(_ m: MeetingSummary) -> some View {
        HStack(spacing: DroppySpacing.xsm) {
            Image(systemName: "doc.text").font(.system(size: 11)).frame(width: 14)
            Text(m.title).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: DroppySpacing.sm)
            if !context.isCompact {
                Text(m.openActions > 0 ? "\(m.openActions) action\(m.openActions == 1 ? "" : "s")" : Fmt.when(m.start))
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText).lineLimit(1)
            }
        }
        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
        .frame(height: 20)
        .contentShape(Rectangle())
    }

    private func row(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: DroppySpacing.xsm) {
            Image(systemName: symbol).font(.system(size: 11)).frame(width: 14)
            Text(text).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
        .frame(height: 20)
        .contentShape(Rectangle())
    }

    // MARK: recording

    /// The call's details; the notes themselves are in the floating window ("Open notes"). Solo and paired are the
    /// same rows, so the shelf declares one height for both.
    private func recordingBody(_ s: (dir: URL, title: String, attendees: [String], start: Date)) -> some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            Text(s.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            if !s.attendees.isEmpty {
                Text("With " + s.attendees.joined(separator: ", ")).font(.system(size: 11)).lineLimit(1)
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            }
            if !droplet.warnings.isEmpty {
                WarningRow(droplet: droplet, compact: context.isCompact).transition(DroppyTransition.element)
            }
            HStack(spacing: DroppySpacing.sm) {
                Button("Open notes") { droplet.showNotes() }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small))
                Spacer(minLength: 0)
                if !context.isCompact {
                    Button(droplet.confirmingDiscard ? "Confirm discard" : "Discard") { droplet.discard() }
                        .buttonStyle(DroppyQuietButtonStyle(size: .small, destructive: droplet.confirmingDiscard))
                        .frame(width: 104)  // the confirm label must not push Stop around
                        .disabled(droplet.busy)
                }
                primaryButton
            }
        }
    }
}

// MARK: - Menu bar

extension EavesdroppyDroplet: MenuBarExtraProviding {
    /// Always offered. The host re-reads this after its state broadcasts; the content view observes the droplet itself.
    public func makeMenuBarExtra() -> MenuBarExtraDescriptor? {
        MenuBarExtraDescriptor(title: "Eavesdroppy", systemImage: recording ? "record.circle.fill" : "waveform") {
            AnyView(MenuBarContent(droplet: self))
        }
    }
}

private struct MenuBarContent: View {
    @ObservedObject var droplet: EavesdroppyDroplet

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            if let s = droplet.session {
                Text("\(s.title) · \(droplet.clock)").font(.system(size: 11)).monospacedDigit().lineLimit(1)
                    .foregroundStyle(AdaptiveColors.primaryTextAuto.opacity(0.7))
                    .padding(.horizontal, DroppySpacing.xs)
                Button { droplet.showNotes() } label: { row("Open notes") }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small))
                Button { droplet.stopRecording(process: true) } label: { row("Stop") }
                    .buttonStyle(DroppyAccentButtonStyle(color: StateColor.destructive, size: .small))
                    .disabled(droplet.busy)
                Button { droplet.discard() } label: { row(droplet.confirmingDiscard ? "Confirm discard" : "Discard") }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small, destructive: droplet.confirmingDiscard))
                    .disabled(droplet.busy)
            } else {
                Button { droplet.startRecording() } label: { row("Record") }
                    .buttonStyle(DroppyAccentButtonStyle(size: .small))
                    .disabled(droplet.busy)
                Button { droplet.openLibrary() } label: { row("Open meetings") }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small))
                if let status {
                    Text(status.text).font(.system(size: 11)).lineLimit(1)
                        .foregroundStyle(status.warn ? StateColor.warning : AdaptiveColors.primaryTextAuto.opacity(0.7))
                        .padding(.horizontal, DroppySpacing.xs)
                }
            }
        }
        .foregroundStyle(AdaptiveColors.primaryTextAuto)
        .padding(.vertical, DroppySpacing.xs)
        // Droppy sizes the menu once, at mount, and never re-measures: both states must share one size or one gets clipped.
        // The taller state (recording: a status line and three buttons) sets the height.
        .frame(width: 220, height: 128, alignment: .topLeading)
    }

    /// The whole row is the hit target, not the shrink-wrapped label.
    private func row(_ title: String) -> some View { Text(title).frame(maxWidth: .infinity, alignment: .leading) }

    private var status: (text: String, warn: Bool)? {
        if let p = droplet.permissionProblem { return (p, true) }
        if droplet.starting { return ("Starting…", false) }
        if !droplet.pending.isEmpty { return ("Processing \(droplet.pending.count)…", false) }
        if !droplet.failed.isEmpty { return ("\(droplet.failed.count) failed — open meetings to retry", true) }
        return nil
    }
}

// MARK: - Live activity

extension EavesdroppyDroplet: LiveActivityProviding {
    public var liveActivityState: AnyPublisher<LiveActivityState?, Never> {
        activitySubject.eraseToAnyPublisher()
    }

    public func makeCompactLeading() -> AnyView { AnyView(RecordingGlyph(droplet: self)) }

    public func makeCompactTrailing() -> AnyView { AnyView(ClockLabel(droplet: self)) }

    /// Not mounted by Droppy (hovering opens the shelf); kept to satisfy the protocol.
    public func makeExpanded(context: LiveActivityContext) -> AnyView {
        AnyView(ClockLabel(droplet: self).frame(width: context.availableWidth, height: DroppyLiveActivityMetrics.cardContentHeight))
    }

    /// Published once per recording, not per second: the visible timer is ClockLabel, which redraws from `elapsed`.
    /// So the accessibility title no longer carries the running time. A recording indicator should survive the
    /// notch being owned by another activity, hence the persistent set.
    private func publishActivity() {
        guard let s = session else { activitySubject.send(nil); return }
        // One stable state: priority and set membership never change mid-recording, only the spoken title when a problem appears.
        let problem = callAudioProblem ? ", no call audio" : ""
        activitySubject.send(LiveActivityState(priority: 300, accessibilityTitle: "Recording \(s.title)\(problem)", joinsPersistentActivitySet: true))
    }
}

/// The wing's glyph: the red ring, or an orange triangle while call audio is missing (nothing else in the notch would say so).
private struct RecordingGlyph: View {
    @ObservedObject var droplet: EavesdroppyDroplet
    var body: some View {
        let problem = droplet.callAudioProblem
        Image(systemName: problem ? "exclamationmark.triangle.fill" : "record.circle.fill")
            .font(.system(size: DroppyLiveActivityMetrics.iconSize, weight: .medium))
            .foregroundStyle(problem ? StateColor.warning : StateColor.destructive)
            .id(problem).transition(DroppyTransition.compactContent)
    }
}

private struct ClockLabel: View {
    @ObservedObject var droplet: EavesdroppyDroplet
    var body: some View {
        Text(droplet.clock)
            .font(.system(size: DroppyLiveActivityMetrics.labelFontSize, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
    }
}
