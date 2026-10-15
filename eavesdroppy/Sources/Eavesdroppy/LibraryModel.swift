import Combine
import Foundation

enum DetailTab: String, CaseIterable { case notes = "Notes", mine = "My notes", transcript = "Transcript", speakers = "Speakers", actions = "Actions" }

enum AskState: Equatable { case idle, running(String), answer(String, String), failed(String) }

/// What a speaker rename means: a plain relabel, "the same person in every meeting" (--person-id), or a different person.
enum RenameScope: String, CaseIterable { case plain, samePerson, newPerson }

/// State of the library UI (list, search, one open meeting, Ask) and the commands it issues. Reads go through
/// LibraryReader (read-only SQLite, off main); every change goes through a pipeline subcommand (D1) and is followed
/// by a refresh, so the UI always shows what the database says.
@MainActor final class LibraryModel: ObservableObject {
    let reader: LibraryReader
    let player = AudioPlayback()
    var exporter: ActionExporter = NoOpExporter()
    /// Wired by the droplet: shelf.requestKeyboardFocus, and workspace.revealInFinder.
    var requestKeyboard: () -> Void = {}
    var reveal: (URL) -> Void = { _ in }
    var openURL: (URL) -> Void = { _ in }
    var copyText: (String) -> Bool = { _ in false }
    /// The empty state's "Import recording…" (the droplet's open panel).
    var importRecording: () -> Void = {}
    /// The "Your name" setting; passed to the pipeline as --user-name (empty = let the pipeline use its default).
    var userName: @MainActor () -> String = { "" }

    @Published var query = "" { didSet { if query != oldValue { scheduleSearch() } } }
    @Published private(set) var meetings: [MeetingSummary] = []
    /// The newest meetings whatever the search says, for the shelf widget's Recent rows.
    @Published private(set) var recents: [MeetingSummary] = []
    @Published private(set) var loaded = false
    @Published private(set) var listError: String?
    @Published private(set) var openID: Int?
    @Published private(set) var detail: MeetingDetail?
    @Published private(set) var detailError: String?
    @Published var tab: DetailTab = .notes
    @Published var focusTurn: Int?
    @Published var status: String?
    /// A problem is orange; information (an import count, "copied") is not.
    @Published private(set) var statusIsError = true
    @Published private(set) var busy: String?
    @Published var regenTemplate = "general"
    @Published var confirmingDelete = false
    @Published var askText = ""
    @Published private(set) var ask: AskState = .idle
    @Published private(set) var me: PersonMe?
    /// Known people (the people table), for "This is…" and "Ask about a person".
    @Published private(set) var people: [PersonRow] = []
    /// Ask scope "About a person…": `ask QUESTION --person-id N`. nil = this meeting when one is open, else all meetings.
    @Published private(set) var askPerson: PersonRow?
    /// Ask across every meeting even while one is open (the list and the meeting are on screen together).
    @Published var askAll = false
    /// After an export that has somewhere to look at (a Linear issue): shown as a link under the header.
    @Published var exportLink: (label: String, url: URL)?
    /// A Linear export is waiting for the user to pick a team (see LinearExporter).
    @Published var teamPick: TeamPick?

    private var listGen = 0, detailGen = 0
    private var searchWork: DispatchWorkItem?
    private var statusWork: DispatchWorkItem?
    private var confirmWork: DispatchWorkItem?
    private var askCall: PipelineCall?
    private var pendingSeek: Int?
    /// Action ids with an export in flight: a second click while one runs must not start a second export (two Linear issues).
    private var exporting = Set<Int>()
    /// Harness only: a demo meeting is on screen and there is no database to refresh it from.
    private var demoMode = false

    init(container: URL) { reader = LibraryReader(container: container) }

    func setContainer(_ c: URL) { reader.setContainer(c) }

    // MARK: reading

    /// After any pipeline command, and when a meeting finishes processing.
    func refresh() {
        guard !demoMode else { return }
        reloadList()
        reloadMe()
        reloadPeople()
        if openID != nil { reloadDetail() }
    }

    private func scheduleSearch() {
        searchWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.reloadList() } }
        searchWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    private func reloadList() {
        listGen += 1
        let gen = listGen, q = query
        reader.read(empty: [MeetingSummary](), { try $0.listMeetings(query: q) }) { [weak self] r in
            MainActor.assumeIsolated {
                guard let self, gen == self.listGen, !self.demoMode else { return }  // demo: a read queued before it must not overwrite it
                self.loaded = true
                switch r {
                case .success(let m):
                    self.meetings = m; self.listError = nil
                    if q.isEmpty { self.recents = Array(m.prefix(3)) }
                    // The list and one meeting share the surface: with nothing open, the newest meeting is.
                    if self.openID == nil, q.isEmpty, let first = m.first { self.open(first.id) }
                case .failure(let e): self.listError = "\(e)"
                }
            }
        }
    }

    func reloadMe() {
        reader.read(empty: nil as PersonMe?, { try $0.me() }) { [weak self] r in
            MainActor.assumeIsolated { if case .success(let m) = r { self?.me = m } }
        }
    }

    func reloadPeople() {
        reader.read(empty: [PersonRow](), { try $0.people() }) { [weak self] r in
            MainActor.assumeIsolated {
                guard let self, !self.demoMode, case .success(let p) = r else { return }  // demo: a read queued before it must not overwrite it
                self.people = p
                if let a = self.askPerson, !p.contains(where: { $0.id == a.id }) { self.askPerson = nil }  // deleted meanwhile
            }
        }
    }

    /// The name a person is shown and filed under. The enrolled user is shown as the "Your name" setting.
    func displayName(_ p: PersonRow) -> String {
        let n = userName().trimmingCharacters(in: .whitespacesAndNewlines)
        return p.isMe && !n.isEmpty ? n : p.name
    }

    private func reloadDetail() {
        guard let id = openID else { return }
        detailGen += 1
        let gen = detailGen
        reader.read(empty: nil as MeetingDetail?, { try $0.meeting(id: id) }) { [weak self] r in
            MainActor.assumeIsolated {
                guard let self, gen == self.detailGen, self.openID == id else { return }
                switch r {
                case .success(let d?):
                    if self.detail == nil { self.regenTemplate = d.summary.template }
                    self.detail = d; self.detailError = nil
                    if let s = self.pendingSeek { self.pendingSeek = nil; self.seek(s) }
                case .success(nil): self.back(); self.flash("That meeting no longer exists", isError: false)  // deleted elsewhere
                case .failure(let e): self.detailError = "\(e)"
                }
            }
        }
    }

    // MARK: navigation

    func open(_ id: Int, tab: DetailTab = .notes, turn: Int? = nil, seek: Int? = nil) {
        if openID != id { detail = nil; player.stop(); confirmingDelete = false }
        openID = id; self.tab = tab; focusTurn = turn; pendingSeek = seek; detailError = nil
        reloadDetail()
    }

    func back() {
        openID = nil; detail = nil; detailGen += 1; confirmingDelete = false; focusTurn = nil; pendingSeek = nil
        player.stop()
        if case .running = ask {} else { ask = .idle }
    }

    /// Harness only (EAVESDROPPY_HARNESS_DEMO): a meeting on screen without a database behind it.
    func demo(detail d: MeetingDetail, people p: [PersonRow], tab t: DetailTab, askPerson a: PersonRow? = nil) {
        demoMode = true
        if !meetings.contains(where: { $0.id == d.summary.id }) { meetings = [d.summary] + meetings }
        recents = Array(meetings.prefix(3)); loaded = true; openID = d.summary.id; detail = d; people = p; tab = t; askPerson = a
    }

    /// Harness only: a list on screen (no meetings = the empty state), with an optional status line.
    func demoList(_ m: [MeetingSummary], status s: (String, Bool)? = nil) {
        demoMode = true; meetings = m; recents = Array(m.prefix(3)); loaded = true
        if let s { flash(s.0, isError: s.1) }
    }

    /// Harness only: Recent rows for the widget's shot.
    func demoRecents(_ r: [MeetingSummary]) { demoMode = true; recents = r }

    /// Leaving the surface (dismissed, or the droplet deactivating): playback must not outlive it.
    func surfaceClosed() { player.stop() }

    // MARK: playback and links

    func seek(_ seconds: Int) {
        guard let path = detail?.summary.audioPath else { flash("This meeting's audio has been removed"); return }
        player.play(path: path, from: Double(seconds))
    }

    func togglePlayback() {
        if player.isPlaying || player.duration > 0 { player.toggle() }
        else if let path = detail?.summary.audioPath { player.play(path: path, from: 0) }
        else { flash("This meeting's audio has been removed") }
    }

    /// Taps on `eav://` links in notes and answers.
    func handle(_ url: URL) -> Bool {
        switch DeepLink(url) {
        case .seek(let s)?: if openID != nil { seek(s) }
        case .cite(let title, let date, let s)?: openCitation(title: title, date: date, seconds: s)
        case nil: return false
        }
        return true
    }

    private func openCitation(title: String, date: String, seconds: Int) {
        reader.read(empty: nil as Int?, { try $0.findMeeting(title: title, date: date) }) { [weak self] r in
            MainActor.assumeIsolated {
                if case .success(let id?) = r { self?.open(id, seek: seconds) } else { self?.flash("Couldn't find “\(title)” in the library") }
            }
        }
    }

    // MARK: commands

    func flash(_ text: String, isError: Bool = true) {
        status = text; statusIsError = isError
        statusWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.status = nil } }
        statusWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: w)
    }

    /// Runs a contract subcommand (library edits serialised, off main), reports a failure in the status line, and
    /// refreshes either way so the UI never shows state the database doesn't have.
    func command(_ args: [String], serial: Bool = true, busy label: String? = nil, call: PipelineCall = PipelineCall(),
                 failure what: String, then: ((Result<[String: Any], PipelineError>) -> Void)? = nil) {
        if let label { busy = label }
        Pipeline.submit(args, serial: serial, call: call) { [weak self] r in
            MainActor.assumeIsolated {
                guard let self else { return }
                if label != nil { self.busy = nil }
                if case .failure(let e) = r, e.description != "cancelled" { self.flash("\(what): \(e.description)") }
                then?(r)
                self.refresh()
            }
        }
    }

    func rename(_ title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = openID, !t.isEmpty, t != detail?.summary.title else { return }
        command(["rename-meeting", "--", String(id), t], failure: "Couldn't rename")  // "--": a title may start with "-"
    }

    /// `--user-name=NAME` as one token, so a name starting with "-" is a value, never an option. Empty when unset.
    private var userNameArgs: [String] {
        let n = userName().trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? [] : ["--user-name=\(n)"]
    }

    /// `--` before the positionals: a name may start with "-".
    private func renameCommand(_ s: SpeakerRow, _ name: String, _ options: [String]) {
        command(["rename-speaker"] + options + ["--", String(s.id), name], failure: "Couldn't rename the speaker")
    }

    func renameSpeaker(_ s: SpeakerRow, to name: String, scope: RenameScope) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        switch scope {
        case .plain: renameCommand(s, n, [])
        case .samePerson: renameCommand(s, n, s.personID.map { ["--person-id", String($0)] } ?? [])
        case .newPerson: renameCommand(s, n, ["--new-person"])
        }
    }

    /// "This is…": the speaker is this known person (links the speaker, relabels the person's other speakers, teaches the voiceprint).
    func assignSpeaker(_ s: SpeakerRow, to p: PersonRow) {
        renameCommand(s, displayName(p), ["--person-id", String(p.id)])
    }

    /// A speaker the transcript's own introductions named ("I'm Priya"): kind "intro" until its voice is saved or it is renamed.
    func isIntro(_ s: SpeakerRow) -> Bool { s.kind == "intro" && s.personID == nil }

    /// "Save Priya's voice": the speaker becomes the person already called that, else a new person with this voice.
    /// Either way the print learns from it and the speaker's other meetings relabel (the rename-speaker path).
    func saveIntroVoice(_ s: SpeakerRow) {
        let name = s.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if let p = Self.person(called: name, in: people, display: displayName) { assignSpeaker(s, to: p) }
        else { renameSpeaker(s, to: name, scope: .newPerson) }
    }

    /// The person whose shown name is exactly `name` (case aside); nil when nobody is, so a new person is made.
    nonisolated static func person(called name: String, in people: [PersonRow], display: (PersonRow) -> String) -> PersonRow? {
        people.first { display($0).caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The person a voiceprint match suggested for this speaker, while the speaker is still unlinked.
    func suggestedPerson(for s: SpeakerRow) -> PersonRow? {
        guard s.personID == nil, let id = s.suggestedPersonID else { return nil }
        return people.first { $0.id == id }
    }

    func setDone(_ a: ActionRow, done: Bool) {
        if var d = detail, let i = d.actions.firstIndex(where: { $0.id == a.id }) { d.actions[i].done = done; detail = d }  // optimistic; refresh corrects
        command(["set-action-done", String(a.id)] + (done ? [] : ["--undone"]), failure: "Couldn't update the action item")
    }

    /// The Linear issue of an action already exported there: the stored URL (schema v3), else Linear's own issue redirect.
    func linearURL(for a: ActionRow) -> URL? {
        if let u = a.externalURL, !u.isEmpty, let url = URL(string: u) { return url }
        guard let id = a.externalID?.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), !id.isEmpty else { return nil }
        return URL(string: "https://linear.app/issue/\(id)")  // unverified for rows exported before schema v3
    }

    func export(_ a: ActionRow, to target: ExportTarget) {
        if target == .linear, a.exportedTo == ExportTarget.linear.rawValue {  // already there: show it, never create a second issue
            if let url = linearURL(for: a) { openURL(url) } else { flash("This item is already in Linear", isError: false) }
            return
        }
        guard let d = detail, exporting.insert(a.id).inserted else { return }
        let turn = a.turnIdx.flatMap { ti in d.turns.first { $0.idx == ti }?.text }
        let item = ExportItem(action: a, meetingID: d.summary.id, meetingTitle: d.summary.title, meetingStart: d.summary.start, turnText: turn)
        exporter.export(item, to: target) { [weak self] r in
            guard let self else { return }
            self.exporting.remove(a.id)
            switch r {
            case .failure(let e): self.flash("\(e)")
            case .success(let out):
                self.command(["set-action-exported", String(a.id), target.rawValue, out.externalID], failure: "Couldn't record the export") { r in
                    guard case .success = r else { return }
                    self.flash("Added to \(target.title)", isError: false)
                    if let url = out.url { self.exportLink = (out.label ?? "Open in \(target.title)", url) }
                }
            }
        }
    }

    func dismissExportLink() { exportLink = nil }

    func regenerate() {
        guard let id = openID, busy == nil else { return }
        var args = ["regenerate", String(id), "--template", regenTemplate]
        if regenTemplate == "custom" { args += ["--custom-text-file", Prefs.customTemplateFile.path] }
        args += userNameArgs
        command(args, serial: false, busy: "Regenerating notes…", failure: "Couldn't regenerate") { [weak self] r in
            if case .success(let j) = r, let w = j["warnings"] as? [String], !w.isEmpty { self?.flash(w.joined(separator: " ")) }
        }
    }

    /// Two clicks within 4 s, like the Failed rows in the widget.
    func delete() {
        guard let id = openID else { return }
        guard confirmingDelete else {
            confirmingDelete = true
            confirmWork?.cancel()
            let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.confirmingDelete = false } }
            confirmWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: w)
            return
        }
        confirmingDelete = false
        command(["delete", String(id)], failure: "Couldn't delete") { [weak self] r in
            if case .success = r { self?.back() }
        }
    }

    /// "Speaker  03:41\ntext" per turn, in order; what "Copy transcript" puts on the pasteboard.
    nonisolated static func transcriptText(_ turns: [TurnRow]) -> String {
        turns.map { "\($0.speaker) [\(Timestamp.format($0.start))]: \($0.text)" }.joined(separator: "\n")
    }

    func copyTranscript() {
        guard let d = detail, !d.turns.isEmpty else { flash("There is no transcript to copy"); return }
        if copyText(Self.transcriptText(d.turns)) { flash("Transcript copied", isError: false) } else { flash("Couldn't copy to the clipboard") }
    }

    func openInDrive() {
        guard let folder = detail?.summary.folder else { flash("This meeting has no folder"); return }
        DispatchQueue.global(qos: .utility).async {  // the Drive mount can stall a stat
            let exists = FileManager.default.fileExists(atPath: folder)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { if exists { self.reveal(URL(fileURLWithPath: folder)) } else { self.flash("Folder not found: \(folder)") } }
            }
        }
    }

    // MARK: Ask

    var askScope: String { askPerson.map { "about \(displayName($0))" } ?? (openID == nil || askAll ? "all meetings" : "this meeting") }

    /// nil: back to the automatic scope.
    func setAskPerson(_ p: PersonRow?) { askPerson = p; askAll = false }

    func askQuestion() {
        let q = askText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        if case .running = ask { return }
        // argparse would read a leading "-" as an option
        var args = ["ask", q.hasPrefix("-") ? "Question: " + q : q]
        if let p = askPerson { args += ["--person-id", String(p.id)] }  // the CLI rejects both scopes at once
        else if let id = openID, !askAll { args += ["--meeting-id", String(id)] }
        args += userNameArgs
        let call = PipelineCall()
        askCall = call; ask = .running(q)
        Pipeline.submit(args, call: call) { [weak self] r in
            MainActor.assumeIsolated {
                guard let self, self.askCall === call else { return }
                self.askCall = nil
                switch r {
                case .success(let j):
                    let a = (j["answer"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    self.ask = a.isEmpty ? .failed("No answer came back") : .answer(q, a)
                case .failure(let e): self.ask = e.description == "cancelled" ? .idle : .failed(e.description)
                }
                self.refresh()
            }
        }
    }

    /// Kills the ask process group (python and the claude it spawned).
    func cancelAsk() { askCall?.cancel(); askCall = nil; ask = .idle }

    func dismissAsk() { ask = .idle }
}
