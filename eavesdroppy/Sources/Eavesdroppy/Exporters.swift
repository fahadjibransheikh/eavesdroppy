import DroppyKit
import EventKit
import Foundation

// D15 (Reminders through EventKit) and D16 (Linear through the pipeline's `linear-export`). Both ask for nothing at
// activation: Reminders asks Droppy for the permission the first time the user adds an item, Linear needs the key the
// user saved under Settings, Output.

struct ExportError: Error, CustomStringConvertible { let description: String; init(_ d: String) { description = d } }

/// Routes an export to the exporter for its target.
@MainActor final class Exporters: ActionExporter {
    let reminders: RemindersExporter
    let linear: LinearExporter

    init(droplet: EavesdroppyDroplet) {
        reminders = RemindersExporter(droplet: droplet)
        linear = LinearExporter(droplet: droplet)
    }

    func export(_ item: ExportItem, to target: ExportTarget, done: @escaping (Result<ExportOutcome, Error>) -> Void) {
        switch target {
        case .reminders: reminders.export(item, done: done)
        case .linear: linear.export(item, done: done)
        }
    }
}

// MARK: - Reminders

enum ReminderDue {
    private static let isoDay = try! NSRegularExpression(pattern: #"^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2}))?"#)
    private static let hasTime = try! NSRegularExpression(pattern: #"\d{1,2}:\d{2}|\b\d{1,2}\s*(am|pm)\b"#, options: .caseInsensitive)

    /// "2026-10-17" or "2026-10-17T15:00" exactly; otherwise whatever NSDataDetector reads as a date ("Friday", "next
    /// Tuesday", "Oct 20"). Date only unless the text names a time. nil when there is nothing to parse.
    static func components(_ text: String, calendar: Calendar = .current) -> DateComponents? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let range = NSRange(t.startIndex..., in: t)
        if let m = isoDay.firstMatch(in: t, range: range) {
            func n(_ i: Int) -> Int? { Range(m.range(at: i), in: t).flatMap { Int(t[$0]) } }
            guard let y = n(1), let mo = n(2), let d = n(3) else { return nil }
            var c = DateComponents(year: y, month: mo, day: d)
            if let h = n(4), let mi = n(5) { c.hour = h; c.minute = mi }
            guard let date = calendar.date(from: c), calendar.dateComponents([.year, .month, .day], from: date) == DateComponents(year: y, month: mo, day: d) else { return nil }  // 2026-13-45 is not a date
            return c
        }
        guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let date = det.firstMatch(in: t, range: range)?.date else { return nil }
        let withTime = hasTime.firstMatch(in: t, range: range) != nil
        return calendar.dateComponents(withTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day], from: date)
    }

    static func notes(_ item: ExportItem) -> String {
        var lines: [String] = []
        let who = [item.action.owner.isEmpty ? nil : "Owner: \(item.action.owner)", item.action.due.isEmpty ? nil : "Due: \(item.action.due)"].compactMap { $0 }
        if !who.isEmpty { lines.append(who.joined(separator: " · ")) }
        let day = Fmt.parseISO(item.meetingStart).map { dayFormatter.string(from: $0) } ?? String(item.meetingStart.prefix(10))
        lines.append("From meeting: \(item.meetingTitle) (\(day))")
        if let q = item.turnText?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty { lines.append("“\(q)”") }
        return lines.joined(separator: "\n")
    }

    private static let dayFormatter: DateFormatter = { let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f }()
}

@MainActor final class RemindersExporter {
    unowned let droplet: EavesdroppyDroplet
    private let queue = DispatchQueue(label: "eavesdroppy.reminders", qos: .userInitiated)

    init(droplet: EavesdroppyDroplet) { self.droplet = droplet }

    func export(_ item: ExportItem, done: @escaping (Result<ExportOutcome, Error>) -> Void) {
        guard let host = droplet.host else { done(.failure(ExportError("Eavesdroppy isn't active"))); return }
        let list = droplet.prefs.remindersList
        Task { @MainActor in
            var status = host.permissions.status(for: .reminders)
            if status == .notDetermined { status = await host.permissions.request(.reminders) }  // the user asked to add an item
            guard status == .granted else {
                done(.failure(ExportError(status == .unavailable ? "This Droppy build can't use Reminders"
                                                                 : "Reminders access is off for Droppy: allow it in System Settings, Privacy & Security")))
                return
            }
            self.queue.async {
                let r = Result { try Self.save(item, list: list) }
                DispatchQueue.main.async { MainActor.assumeIsolated { done(r.map { ExportOutcome(externalID: $0, label: "Open Reminders") }) } }
            }
        }
    }

    /// Off the main thread. Returns the reminder's calendarItemIdentifier.
    nonisolated private static func save(_ item: ExportItem, list: String) throws -> String {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { throw ExportError("Droppy doesn't have Reminders access") }
        let store = EKEventStore()
        // Exported before and still there: don't make a second one.
        if item.action.exportedTo == ExportTarget.reminders.rawValue, let id = item.action.externalID,
           let existing = store.calendarItem(withIdentifier: id) as? EKReminder { return existing.calendarItemIdentifier }

        let calendar: EKCalendar
        if let c = store.calendars(for: .reminder).first(where: { $0.title == list && $0.allowsContentModifications }) {
            calendar = c
        } else {
            let c = EKCalendar(for: .reminder, eventStore: store)
            c.title = list
            guard let source = store.defaultCalendarForNewReminders()?.source
                    ?? store.sources.first(where: { $0.sourceType == .local })
                    ?? store.sources.first else { throw ExportError("No account in Reminders can hold a new list") }
            c.source = source
            try store.saveCalendar(c, commit: true)
            calendar = c
        }
        let r = EKReminder(eventStore: store)
        r.calendar = calendar
        r.title = item.action.task
        r.notes = ReminderDue.notes(item)
        r.dueDateComponents = ReminderDue.components(item.action.due)
        try store.save(r, commit: true)
        return r.calendarItemIdentifier
    }
}

// MARK: - Linear

@MainActor final class LinearExporter {
    unowned let droplet: EavesdroppyDroplet
    private var picking = false

    init(droplet: EavesdroppyDroplet) { self.droplet = droplet }

    func export(_ item: ExportItem, done: @escaping (Result<ExportOutcome, Error>) -> Void) {
        guard !picking else { done(.failure(ExportError("Pick a team for the other export first"))); return }
        let ep = currentEpoch()
        DispatchQueue.global(qos: .userInitiated).async {  // the Keychain can prompt or stall
            let key = Keychain.read()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard ep == currentEpoch() else { return }
                    guard let key else { done(.failure(ExportError("No Linear API key: add one in Settings, Output"))); return }
                    let team = self.droplet.prefs.linearTeamID
                    if team.isEmpty { self.pickTeam(item, key: key, done: done) } else { self.run(item, key: key, team: team, done: done) }
                }
            }
        }
    }

    private func pickTeam(_ item: ExportItem, key: String, done: @escaping (Result<ExportOutcome, Error>) -> Void) {
        picking = true
        Pipeline.submit(["linear-teams"], env: ["EAVESDROPPY_LINEAR_KEY": key]) { r in
            MainActor.assumeIsolated {
                switch r {
                case .failure(let e): self.picking = false; done(.failure(ExportError(e.description)))
                case .success(let j):
                    let teams = (j["teams"] as? [[String: Any]] ?? []).compactMap { t -> LinearTeam? in
                        guard let id = t["id"] as? String, let name = t["name"] as? String else { return nil }
                        return LinearTeam(id: id, name: name, key: t["key"] as? String ?? "")
                    }
                    guard !teams.isEmpty else { self.picking = false; done(.failure(ExportError("This Linear key can't see any teams"))); return }
                    self.droplet.library.teamPick = TeamPick(teams: teams) { team, remember in
                        self.droplet.library.teamPick = nil
                        self.picking = false
                        guard let team else { done(.failure(ExportError("Export cancelled"))); return }
                        if remember { self.droplet.prefs.set(Prefs.Key.linearTeamID, team.id); self.droplet.prefs.set(Prefs.Key.linearTeamName, team.name) }
                        self.run(item, key: key, team: team.id, done: done)
                    }
                    self.droplet.openLibrary()  // the picker lives in the library surface
                }
            }
        }
    }

    private func run(_ item: ExportItem, key: String, team: String, done: @escaping (Result<ExportOutcome, Error>) -> Void) {
        Pipeline.submit(["linear-export", String(item.action.id), "--team", team], env: ["EAVESDROPPY_LINEAR_KEY": key]) { r in
            MainActor.assumeIsolated {
                switch r {
                case .failure(let e): done(.failure(ExportError(e.description)))
                case .success(let j):
                    guard let ident = (j["identifier"] as? String) ?? (j["id"] as? String) else {
                        done(.failure(ExportError("Linear created the issue but returned no identifier"))); return
                    }
                    done(.success(ExportOutcome(externalID: ident, url: (j["url"] as? String).flatMap(URL.init(string:)), label: "Open \(ident) in Linear")))
                }
            }
        }
    }
}

// MARK: - Droplet wiring

extension EavesdroppyDroplet {
    func exporterSetup() { library.exporter = Exporters(droplet: self) }

    /// Harness only: `EAVESDROPPY_HARNESS_DEMO=event,call,ending,teampicker,link` puts those on screen for the shots.
    func harnessDemo(_ list: String) {
        for what in list.split(separator: ",").map(String.init) {
            switch what {
            case "teampicker":
                library.teamPick = TeamPick(teams: [LinearTeam(id: "1", name: "Engineering", key: "ENG"), LinearTeam(id: "2", name: "Growth", key: "GRO"),
                                                    LinearTeam(id: "3", name: "Support", key: "SUP")]) { _, _ in }
            case "meetings", "empty":
                let now = Date()
                func m(_ i: Int, _ t: String, _ ago: TimeInterval, _ dur: Double, _ open: Int) -> MeetingSummary {
                    MeetingSummary(id: i, title: t, start: ISO8601DateFormatter().string(from: now.addingTimeInterval(-ago)), duration: dur, source: "record",
                                   template: "general", summaryStatus: "ok", folder: nil, audioPath: nil, openActions: open)
                }
                library.demoList(what == "empty" ? [] : [m(1, "Weekly sync", 3600, 3900, 2), m(2, "1:1 with Priya", 86_400 + 3600, 1500, 0), m(3, "Roadmap planning", 3 * 86_400, 2700, 1),
                                                         m(4, "Quarterly review", 20 * 86_400, 3300, 3), m(5, "Empty import", 25 * 86_400, 0, 0)],
                                 status: what == "empty" ? nil : ("Imported 3, skipped 0, failed 0", false))
                openLibrary()
            case "speakers", "askperson", "mynotes", "askme":
                let people = [PersonRow(id: 1, name: "Me", isMe: true), PersonRow(id: 2, name: "Priya Nair", isMe: false), PersonRow(id: 3, name: "Sam Lee", isMe: false)]
                let summary = MeetingSummary(id: 1, title: "Weekly sync", start: "2026-10-12T10:00:00+05:00", duration: 1860, source: "record", template: "general",
                                             summaryStatus: "ok", folder: nil, audioPath: nil, openActions: 1)
                let speakers = [what == "askme" ? SpeakerRow(id: 1, track: "mic", label: "Speaker 1", personID: nil, kind: "new")
                                                : SpeakerRow(id: 1, track: "mic", label: prefs.userName, personID: 1, kind: "me"),
                                SpeakerRow(id: 2, track: "system", label: "Speaker 2", personID: nil, kind: "suggest", suggestedPersonID: 2),
                                SpeakerRow(id: 3, track: "system", label: "Speaker 3", personID: nil, kind: "new"),
                                SpeakerRow(id: 4, track: "system", label: "Marcus Chen", personID: nil, kind: "intro")]
                let turns = (0..<6).map { TurnRow(idx: $0, speakerID: $0 % 4 + 1, speaker: speakers[$0 % 4].label, start: Double($0) * 40, end: Double($0) * 40 + 35, text: "Turn \($0)") }
                let detail = MeetingDetail(summary: summary, attendees: ["Priya Nair", "Sam Lee"], notes: "## Summary\n- Shipped the beta [00:40]\n- Priya owns the rollout plan",
                                           userNotes: what == "mynotes" ? "- Ask Priya about pricing\n- Rollout date: 3 Nov" : "", speakers: speakers, turns: turns, actions: [],
                                           bleed: what == "askme")
                library.demo(detail: detail, people: people, tab: what == "speakers" || what == "askme" ? .speakers : .notes, askPerson: what == "askperson" ? people[1] : nil)
                openLibrary()
            case "olddroplet": notify("Remove the old Meetings droplet", symbol: "exclamationmark.triangle.fill",
                                      detail: "In Settings › Store › Local droplets. Eavesdroppy replaces it, and two recorders would both offer to start.")
            case "voicenotice": showVoiceNotice()
            case "notesready": notify("Notes ready", symbol: "checkmark.circle.fill", detail: "Weekly sync · ⌥⌘N to open")
            case "stopped": notify("Recording stopped", symbol: "exclamationmark.triangle.fill", detail: "The disk is full. What was captured is saved under Failed.", priority: .high)
            case "consent": notify("Recording started", symbol: "mic.fill", detail: "Tell everyone on the call.")
            case "recording": demoRecording()
            case "inperson": demoRecording(inPerson: true)
            case "rows": demoRows()
            case "enrollconfirm": enrollment.demo(.confirm(match: 0.21))
            case "enrolldone": enrollment.demo(.done(seconds: 24, meetingMatch: 0.88))
            case "enrollmic": enrollment.demo(.failed(Enrollment.micChanged))
            case "enrollfew", "enrollother", "enrollquiet", "enrollloud", "enrollnoise":   // the refusal sentences, from the same function `enroll` uses
                var m = EnrollQuality.Metrics(dominant: "S1", clusters: 1, totalSpeech: 24, speech: 24, overallDB: -30, peakDB: -10, speechDB: -30, snrDB: 20)
                switch what {
                case "enrollfew": m.speech = 4.2; m.totalSpeech = 4.2
                case "enrollother": m.clusters = 2; m.otherShare = 0.38
                case "enrollquiet": m.speechDB = -52
                case "enrollloud": m.clipFraction = 0.034
                default: m.snrDB = 4
                }
                enrollment.demo(.failed(EnrollQuality.rejection(m, minSpeech: Voiceprints.minEnrollSpeech) ?? "OK"))
            case "link": library.exportLink = ("Open ENG-142 in Linear", URL(string: "https://linear.app/example/issue/ENG-142")!)
            default: automation.demo(what)
            }
        }
    }
}
