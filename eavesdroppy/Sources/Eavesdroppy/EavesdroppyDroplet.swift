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

private let silentCallAudio = "Call audio was silent — check Screen & System Audio Recording permission for Droppy"

/// Seconds without a single call-audio sample before the permission warning. The system tap can take ~40 s to
/// deliver its first buffer and then record fine, so anything shorter is a false alarm.
private let silentCallAudioGrace = 60
func callAudioMissing(elapsed: Int, frames: Int64) -> Bool { elapsed >= silentCallAudioGrace && frames == 0 }

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
    private let activitySubject = CurrentValueSubject<LiveActivityState?, Never>(nil)

    @Published private var phase: Phase = .idle
    @Published private(set) var session: (dir: URL, title: String, attendees: [String], start: Date)?
    @Published private(set) var elapsed = 0
    @Published private(set) var warnings: [String] = []
    @Published private(set) var pending: [Job] = []  // running + queued (+ importing)
    @Published private(set) var recent: [String] = []
    @Published private(set) var failed: [FailedJob] = []
    @Published private(set) var permissionProblem: String?
    @Published var titleDraft = "Meeting"
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
    private(set) var notesFocused = false

    var recording: Bool { phase == .recording }
    /// Droppy can refuse the library surface ("does not publish a surface with that id", seen with approved local
    /// builds); the notes then live in the shelf widget instead, whatever the setting says.
    @Published private(set) var surfaceRefused = false
    var notesInNotch: Bool { prefs.notesInNotch && !surfaceRefused }

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
        recent = host.preferences.value(forKey: "recent", default: [String]())
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
            if self.recording { self.showNotesInNotch() } else { self.openLibrary() }
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
        library.surfaceClosed(); enrollment.cancel()
        if notesFocused { _ = host?.shelf.setHoldsOpen(false); notesFocused = false }
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
            notify("Could not start recording", symbol: "exclamationmark.triangle.fill", detail: "\(error)")
            return
        }
        recorder = rec
        notesText = ""; recordingTemplate = prefs.defaultTemplate
        session = (dir, title, attendees, start)
        phase = .recording
        elapsed = 0; systemChecked = false
        warnings = rec.systemWarning == nil ? [] : ["Call audio unavailable: allow Droppy under Screen & System Audio Recording"]
        log("recording started: \(title) -> \(dir.path)")
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { self.tick() } }
        publishActivity()
        automation.recordingStarted()
        if prefs.consentLine || startedAutomatically {  // nobody clicked an automatic start, so it always says so
            notify("Recording — let everyone know they're being recorded.", symbol: "mic.fill")
        }
        startedAutomatically = false
        _ = host?.shelf.invalidateLayout(for: Self.widgetID)  // the widget grows a notes field while recording
        if notesInNotch { showNotesInNotch() }
    }

    private func tick() {
        guard let s = session else { return }
        elapsed = Int(Date().timeIntervalSince(s.start))
        // No call audio at all after a full minute: the permission is almost certainly off.
        if !systemChecked, let st = recorder?.system, callAudioMissing(elapsed: elapsed, frames: st.frames) {
            systemChecked = true
            addWarning(silentCallAudio)
        }
        automation.tick(elapsed: elapsed)
    }

    private func addWarning(_ w: String) {
        guard session != nil, !warnings.contains(w) else { return }
        warnings.append(w)
        notify(w, symbol: "exclamationmark.triangle.fill")
    }

    /// A track can't be written (disk full): stop with what we have rather than record into the void.
    private func recordingBroke(_ why: String) {
        guard phase == .recording else { return }
        notify("Recording stopped", symbol: "exclamationmark.triangle.fill", detail: "\(why). What was captured is saved under Failed.")
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
            if r.systemSilent && !sysDown { self.notify(silentCallAudio, symbol: "exclamationmark.triangle.fill") }
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
        if notesFocused { notesFocused = false; _ = host?.shelf.setHoldsOpen(false) }
        host?.shelf.invalidateLayout(for: Self.widgetID)
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

    /// The shelf closes when the pointer leaves it; hold it open while the user is typing.
    func notesFocusChanged(_ focused: Bool) {
        guard focused != notesFocused else { return }
        notesFocused = focused
        _ = host?.shelf.setHoldsOpen(focused)
    }

    // MARK: library surface and settings

    func presentLibrary() {
        presentation = host?.notchSurface.presentExpandedSurface(ExpandedSurfacePresentationRequest(surfaceID: Self.surfaceID))
        guard presentation == nil, let host else { return }
        if !surfaceRefused { surfaceRefused = true; host.shelf.invalidateLayout(for: Self.widgetID) }
        _ = host.shelf.open(revealing: Self.widgetID)
        _ = host.shelf.requestKeyboardFocus()
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

    func openLibrary() { library.browsing = true; presentLibrary() }

    /// The live notes view in the expanded surface; the way to type notes when the widget is compact or the menu bar is closed.
    func showNotesInNotch() { library.browsing = false; presentLibrary() }

    private func prefsChanged() {
        objectWillChange.send()
        automation.reconcile()
        if phase == .recording { _ = host?.shelf.invalidateLayout(for: Self.widgetID) }  // the notes location may have moved
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
                        if self.notify("Remove the old Meetings droplet in Settings › Store › Local droplets", symbol: "exclamationmark.triangle.fill",
                                       detail: "It is replaced by Eavesdroppy, and two recorders would both offer to start.") {
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
            recent = Array(([folder] + recent.filter { $0 != folder }).prefix(5))
            host?.preferences.setValue(recent, forKey: "recent")
            library.refresh()
            notify("Notes ready: \(title)", symbol: warnings.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                   detail: warnings.isEmpty ? nil : warnings.joined(separator: " "))
        case .failed(let why):
            notify("Processing failed: \(title)", symbol: "exclamationmark.triangle.fill", detail: why)
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
        if let id = recentMeetingIDs[folder] { library.browsing = true; library.open(id); presentLibrary(); return }
        _ = host?.workspace.open(URL(fileURLWithPath: folder + "/notes.md"))
    }

    func openFolder() {
        fsQueue.async {  // the Drive mount can stall a stat
            let root = outputRoot(), fm = FileManager.default
            do {
                try StoreMirror.checkOutRoot(root)  // never mkdir -p into a Drive path whose mount is not there
                try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
            } catch {
                onMain { self.notify("Output folder not available", symbol: "exclamationmark.triangle.fill", detail: "\(error)") }; return
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
        let custom = media.count == 1 && !typed.isEmpty && typed != "Meeting" ? typed : nil
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
                        self.notify("Import failed: \(title)", symbol: "exclamationmark.triangle.fill", detail: error.localizedDescription)
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

    /// A strip for short text; a card (title + wrapped detail) when there is detail or the text is long.
    @discardableResult
    func notify(_ text: String, symbol: String, detail: String? = nil) -> Bool {
        log("notify: \(text)\(detail.map { " (\($0))" } ?? "")")
        let card = detail != nil || text.count > 34
        return host?.hud.present(DropletHUDRequest(
            id: "eavesdroppy.notice", duration: card ? 8 : 4,
            accessibilityLabel: [text, detail].compactMap { $0 }.joined(separator: ". "),
            isExpanded: card, expandedContentHeight: detail == nil ? 52 : 76,
            content: {
                // Glyph at the far left, text at the far right: the middle of a strip is the camera housing.
                HStack(spacing: 0) {
                    Image(systemName: symbol)
                        .font(.system(size: DroppyLiveActivityMetrics.iconSize, weight: .semibold))
                    Spacer(minLength: 0)
                    Text(verbatim: text)
                        .font(.system(size: DroppyLiveActivityMetrics.labelFontSize, weight: .semibold))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            },
            expanded: {
                VStack(alignment: .leading, spacing: DroppySpacing.xs) {
                    HStack(alignment: .top, spacing: DroppySpacing.sm) {
                        Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                        Text(verbatim: text).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    }
                    if let detail {
                        Text(verbatim: detail).font(.system(size: 11)).lineLimit(3)
                            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            })) ?? false
    }

    var clock: String { String(format: "%d:%02d", elapsed / 60, elapsed % 60) }
}

// MARK: - Shelf widget

extension EavesdroppyDroplet: ShelfWidgetProviding {
    public var widgetDescriptors: [ShelfWidgetDescriptor] {
        [
            ShelfWidgetDescriptor(
                id: "eavesdroppy",
                title: "Eavesdroppy",
                systemImage: "waveform",
                layoutTraits: ShelfWidgetLayoutTraits(
                    preferredSoloWidth: 420,
                    preferredPairedWidth: 210,
                    contentHeight: .fixed(recording && !notesInNotch ? 300 : 170)  // room for typed notes
                ),
                focusPolicy: .keyboardFocusable
            )
        ]
    }

    public func makeWidgetView(_ id: ShelfWidgetID, context: ShelfWidgetContext) -> AnyView {
        AnyView(EavesdroppyWidget(droplet: self, context: context))
    }

    public func makeWidgetSettingsPopover(_ id: ShelfWidgetID) -> AnyView? { nil }
}

private struct EavesdroppyWidget: View {
    @ObservedObject var droplet: EavesdroppyDroplet
    let context: ShelfWidgetContext

    private var recording: Bool { droplet.session != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            header
            if context.isCompact { compactBody } else { soloBody }
            Spacer(minLength: 0)
        }
        .padding(context.contentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Droppy's shelf may claim the drag itself (its file tray); the Import row below always works.
        .dropDestination(for: URL.self) { urls, _ in droplet.importFiles(urls); return !urls.isEmpty }
    }

    private var header: some View {
        HStack(spacing: DroppySpacing.xsm) {
            Image(systemName: recording ? "record.circle.fill" : (droplet.pending.isEmpty && !droplet.starting ? "waveform" : "hourglass"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(recording ? Color.red : AdaptiveColors.notchSurfaceSecondaryText)
            Text("Eavesdroppy")
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 0)
            if recording {
                if !droplet.notesInNotch && !context.isCompact { TemplateMenu(droplet: droplet) }
                Text(droplet.clock).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            }
            Button { droplet.openLibrary() } label: { Image(systemName: "books.vertical") }
                .buttonStyle(DroppyCircleButtonStyle(size: 20)).accessibilityLabel("Open meeting library")
        }
        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
    }

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            Text(droplet.session?.title ?? (droplet.starting ? "Starting…" : (droplet.pending.isEmpty ? "Ready" : "Processing \(droplet.pending.count)…")))
                .font(.system(size: 13, weight: .medium)).lineLimit(1)
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            primaryButton
            if recording {
                Button("Notes") { droplet.showNotesInNotch() }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small))
            }
        }
    }

    @ViewBuilder private var primaryButton: some View {
        if recording {
            Button("Stop & save") { droplet.stopRecording(process: true) }
                .buttonStyle(DroppyAccentButtonStyle(color: .red, size: .small))
                .disabled(droplet.busy)
        } else {
            Button("Record") { droplet.startRecording() }
                .buttonStyle(DroppyAccentButtonStyle(size: .small))
                .disabled(droplet.busy)
        }
    }

    private var soloBody: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            if let s = droplet.session {
                HStack(spacing: DroppySpacing.sm) {
                    Text(s.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    Spacer(minLength: 0)
                    Button(droplet.confirmingDiscard ? "Confirm discard" : "Discard") { droplet.discard() }
                        .buttonStyle(DroppyQuietButtonStyle(size: .small, destructive: droplet.confirmingDiscard))
                        .disabled(droplet.busy)
                    primaryButton
                }
                if !droplet.warnings.isEmpty {
                    Text(droplet.warnings.joined(separator: " ")).font(.system(size: 11)).foregroundStyle(Color.orange).lineLimit(2)
                }
            } else {
                HStack(spacing: DroppySpacing.sm) {
                    TextField("Meeting title", text: $droplet.titleDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                        .onTapGesture { droplet.focusTitle() }
                        .onSubmit { droplet.startRecording() }
                    primaryButton
                }
                if let p = droplet.permissionProblem {
                    HStack(spacing: DroppySpacing.sm) {
                        Text(p).font(.system(size: 11)).foregroundStyle(Color.orange).lineLimit(1)
                        Spacer(minLength: 0)
                        Button("Open Settings") { droplet.openMicSettings() }
                            .buttonStyle(DroppyQuietButtonStyle(size: .small))
                    }
                }
            }
            if recording && !droplet.notesInNotch {
                TypedNotes(droplet: droplet)
            } else {
            ScrollView {
                VStack(alignment: .leading, spacing: DroppySpacing.xs) {
                    ForEach(droplet.pending) { j in
                        row("hourglass", "Processing: \(j.title)…")
                    }
                    ForEach(droplet.failed) { f in
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: DroppySpacing.xsm) {
                                row("exclamationmark.triangle", "Failed: \(f.title)")
                                Button("Retry") { droplet.retry(f.dir) }.buttonStyle(DroppyQuietButtonStyle(size: .small))
                                Button(droplet.confirmingDelete == f.dir ? "Confirm delete" : "Delete") { droplet.deleteFailed(f.dir) }
                                    .buttonStyle(DroppyQuietButtonStyle(size: .small, destructive: droplet.confirmingDelete == f.dir))
                            }
                            if let why = f.reason {
                                Text(why).font(.system(size: 11)).foregroundStyle(Color.orange).lineLimit(2).padding(.leading, 14 + DroppySpacing.xsm)
                            }
                        }
                    }
                    ForEach(droplet.recent, id: \.self) { path in
                        Button { droplet.openNotes(path) } label: {
                            row("doc.text", (path as NSString).lastPathComponent)
                        }
                        .buttonStyle(.plain)
                    }
                    Button { droplet.chooseImport() } label: { row("square.and.arrow.down", "Import recording…") }
                        .buttonStyle(.plain)
                    Button { droplet.openFolder() } label: { row("folder", "Open meetings folder") }
                        .buttonStyle(.plain)
                }
            }
            .droppyFlatGlassControls()
            }
        }
    }

    private func row(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: DroppySpacing.xsm) {
            Image(systemName: symbol).font(.system(size: 11)).frame(width: 14)
            Text(text).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
        .contentShape(Rectangle())
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
                HStack(spacing: DroppySpacing.sm) {
                    Text(s.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(droplet.clock).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                }
                HStack(spacing: DroppySpacing.sm) {
                    Button("Notes") { droplet.showNotesInNotch() }
                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                    Button(droplet.confirmingDiscard ? "Confirm discard" : "Discard") { droplet.discard() }
                        .buttonStyle(DroppyQuietButtonStyle(size: .small, destructive: droplet.confirmingDiscard))
                        .disabled(droplet.busy)
                    Spacer(minLength: 0)
                    Button("Stop & save") { droplet.stopRecording(process: true) }
                        .buttonStyle(DroppyAccentButtonStyle(color: .red, size: .small))
                        .disabled(droplet.busy)
                }
            } else {
                Button("Record") { droplet.startRecording() }
                    .buttonStyle(DroppyAccentButtonStyle(size: .small))
                    .disabled(droplet.busy)
                if let status {
                    Text(status.text).font(.system(size: 11)).lineLimit(1)
                        .foregroundStyle(status.warn ? Color.orange : AdaptiveColors.primaryTextAuto.opacity(0.7))
                }
                Button("Open library") { droplet.openLibrary() }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small))
            }
        }
        .foregroundStyle(AdaptiveColors.primaryTextAuto)
        .padding(.vertical, DroppySpacing.xs)
        // Droppy sizes the menu once, at mount, and never re-measures: both states must share one size or one gets clipped.
        .frame(width: 280, height: 96, alignment: .topLeading)
    }

    private var status: (text: String, warn: Bool)? {
        if let p = droplet.permissionProblem { return (p, true) }
        if droplet.starting { return ("Starting…", false) }
        if !droplet.pending.isEmpty { return ("Processing \(droplet.pending.count)…", false) }
        if !droplet.failed.isEmpty { return ("\(droplet.failed.count) failed — open the library to retry", true) }
        return nil
    }
}

// MARK: - Live activity

extension EavesdroppyDroplet: LiveActivityProviding {
    public var liveActivityState: AnyPublisher<LiveActivityState?, Never> {
        activitySubject.eraseToAnyPublisher()
    }

    public func makeCompactLeading() -> AnyView {
        AnyView(
            Image(systemName: "record.circle.fill")
                .font(.system(size: DroppyLiveActivityMetrics.iconSize, weight: .medium))
                .foregroundStyle(Color.red)
        )
    }

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
        activitySubject.send(LiveActivityState(priority: 300, accessibilityTitle: "Recording \(s.title)", joinsPersistentActivitySet: true))
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
