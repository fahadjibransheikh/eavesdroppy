import DroppyKit
import SwiftUI

/// Everything that starts or stops a recording on its own, plus the prompt that asks first: the calendar prompt
/// (D11), the mic-in-use prompt (D12), the auto-stop countdown (D13) and the Accessibility name reader (D18).
/// Host citizenship: nothing here asks for a permission (the settings pages do, when the user reaches for it), every
/// timer and listener is owned here and stopped in `deactivate()`, and nothing blocks the main thread.
@MainActor final class Automation: ObservableObject {
    unowned let droplet: EavesdroppyDroplet
    let prompt = PromptModel()

    @Published private(set) var calendarStatus: DropletPermissionStatus = .notDetermined
    @Published private(set) var accessibilityTrusted = false
    @Published private(set) var message: String?

    private let calendar = CalendarWatcher()
    private let mic = MicWatcher()
    private var calendarTimer: Timer?
    private var micOn = false
    private var prompted = Set<String>()                    // event keys already offered (or skipped): never twice
    private var micSessionActive = false, micPrompted = false
    private var micWork: DispatchWorkItem?
    private var promptTimeout: DispatchWorkItem?
    private var autoStartWork: DispatchWorkItem?
    private let callQ = DispatchQueue(label: "eavesdroppy.callaudio", qos: .utility)
    private let axQ = DispatchQueue(label: "eavesdroppy.ax", qos: .utility)

    // Per recording.
    private var armed = false              // a call app has been seen using the mic: only then can "the call ended" be true
    private var lastCall = Date()
    private var keepRecording = false      // the user said "Keep recording": no more countdowns this recording
    private var countdownEnd: Date?
    private var sampling = false, scanning = false
    private var participants: [String] = []

    private var prefs: Prefs { droplet.prefs }
    private var host: DropletHost? { droplet.host }

    init(droplet: EavesdroppyDroplet) { self.droplet = droplet }

    // MARK: lifecycle

    func activate() {
        refreshPermissions()
        reconcile()
    }

    func deactivate() {
        stopCalendar(); stopMic()
        autoStartWork?.cancel(); autoStartWork = nil
        dismissPrompt()
        countdownEnd = nil
    }

    /// Prefs changed: start or stop the watchers to match.
    func reconcile() {
        if prefs.calendarPrompt && calendarStatus == .granted { startCalendar() } else { stopCalendar() }
        if prefs.micPrompt { startMic() } else { stopMic() }
    }

    func refreshPermissions() {
        guard let host else { return }
        calendarStatus = host.permissions.status(for: .calendars)
        accessibilityTrusted = AXReader.trusted
    }

    // MARK: permissions (only from a setting the user touched)

    /// The Calendar page's toggle and "Connect calendar" button. Asks Droppy to ask macOS the first time.
    func connectCalendar() {
        guard let host else { return }
        message = nil
        switch host.permissions.status(for: .calendars) {
        case .granted: calendarStatus = .granted; calendar.reset(); reconcile()
        case .notDetermined:
            Task { @MainActor in
                let s = await host.permissions.request(.calendars)
                guard self.droplet.host != nil else { return }
                self.calendarStatus = s; self.calendar.reset(); self.reconcile()
                if s != .granted { self.message = Self.calendarProblem(s) }
            }
        case let s: calendarStatus = s; message = Self.calendarProblem(s)
        }
    }

    private static func calendarProblem(_ s: DropletPermissionStatus) -> String {
        s == .unavailable ? "This Droppy build can't read calendars" : "Calendar access is off for Droppy"
    }

    func openCalendarSettings() { host?.permissions.openSystemSettings(for: .calendars) }

    /// Settings, Speakers: the user turned on name reading. We never prompt; if Droppy isn't trusted we open the pane.
    func participantNamesToggled(_ on: Bool) {
        accessibilityTrusted = AXReader.trusted
        if on && !accessibilityTrusted { openAccessibilitySettings() }
    }

    func openAccessibilitySettings() { host?.permissions.openSystemSettings(for: .accessibility) }

    // MARK: calendar prompt (D11)

    private func startCalendar() {
        guard calendarTimer == nil else { return }
        let t = Timer(timeInterval: 30, repeats: true) { _ in MainActor.assumeIsolated { self.pollCalendar() } }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        calendarTimer = t
        pollCalendar()
    }

    private func stopCalendar() {
        calendarTimer?.invalidate(); calendarTimer = nil
        autoStartWork?.cancel(); autoStartWork = nil
    }

    private func pollCalendar() {
        let ep = currentEpoch()
        calendar.upcoming { [weak self] events in
            MainActor.assumeIsolated {
                guard let self, ep == currentEpoch(), self.droplet.host != nil, self.prefs.calendarPrompt else { return }
                self.offer(events.filter { !self.prompted.contains($0.key) })
            }
        }
    }

    /// `events` are call events in the offer window that were never offered. One at a time.
    private func offer(_ events: [CallEvent]) {
        guard let ev = events.first else { return }
        if droplet.recording || droplet.busy { events.forEach { prompted.insert($0.key) }; return }  // never while recording
        if prefs.calendarAutoStart {
            prompted.insert(ev.key)
            scheduleAutoStart(ev)
        } else if !prompt.active {
            prompted.insert(ev.key)
            showEventPrompt(ev)
        }
    }

    private func scheduleAutoStart(_ ev: CallEvent) {
        autoStartWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.droplet.host != nil, self.prefs.calendarAutoStart, !self.droplet.recording, !self.droplet.busy else { return }
                self.droplet.startRecording(title: ev.title, attendees: ev.attendees, autoStarted: true)
            }
        }
        autoStartWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, ev.start.timeIntervalSinceNow), execute: w)
    }

    private func showEventPrompt(_ ev: CallEvent) {
        let secs = safeInt(ev.start.timeIntervalSinceNow)
        let when = secs > 15 ? "Starts in \(max(1, (secs + 30) / 60)) min" : (secs > -60 ? "Starting now" : "Started \(-secs / 60) min ago")
        prompt.show(.event, title: "Record “\(ev.title)”?", subtitle: "\(when) · \(ev.subtitle)", primary: "Record", secondary: "Dismiss",
                    symbol: "calendar.badge.clock",
                    onPrimary: { [weak self] in
                        self?.dismissPrompt()
                        self?.droplet.startRecording(title: ev.title, attendees: ev.attendees, autoStarted: false)
                    }, onSecondary: { [weak self] in self?.dismissPrompt() })
        present(duration: 60, priority: .normal, label: "Record \(ev.title)? \(when)")
    }

    // MARK: mic-in-use prompt (D12)

    private func startMic() {
        guard !micOn else { return }
        micOn = true
        let ep = currentEpoch()
        mic.start { [weak self] running in
            DispatchQueue.main.async { MainActor.assumeIsolated { if ep == currentEpoch() { self?.micChanged(running) } } }
        }
    }

    private func stopMic() {
        guard micOn else { return }
        micOn = false; micSessionActive = false; micPrompted = false
        micWork?.cancel(); micWork = nil
        mic.stop()
    }

    private func micChanged(_ running: Bool) {
        guard micOn else { return }
        if !running { micSessionActive = false; micPrompted = false; micWork?.cancel(); return }
        guard !micSessionActive else { return }
        micSessionActive = true; micPrompted = droplet.recording || droplet.busy  // a recording that began the session covers it
        scheduleMicCheck(after: 3, attempt: 0)
    }

    private func scheduleMicCheck(after s: TimeInterval, attempt: Int) {
        micWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.checkMic(attempt: attempt) } }
        micWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: w)
    }

    private func checkMic(attempt: Int) {
        guard micOn, micSessionActive, !micPrompted, prefs.micPrompt, droplet.host != nil else { return }
        if droplet.recording || droplet.busy || prompt.active { micPrompted = true; return }  // one prompt per call
        let ep = currentEpoch()
        callQ.async {
            let running = CallAudio.defaultInputRunning()
            let apps = running ? CallAudio.callAppsRunningInput() : []  // never this process: Droppy's recorder and dictation
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard ep == currentEpoch(), self.micOn, self.micSessionActive, !self.micPrompted else { return }
                    guard let app = apps.first else {
                        if running && attempt == 0 { self.scheduleMicCheck(after: 7, attempt: 1) }  // the app may take a moment to open its input
                        return
                    }
                    guard !self.droplet.recording, !self.droplet.busy, !self.prompt.active else { self.micPrompted = true; return }
                    self.micPrompted = true
                    self.eventForCall { ev in
                        guard self.droplet.host != nil, !self.droplet.recording, !self.droplet.busy, !self.prompt.active else { return }
                        self.showCallPrompt(app, event: ev)
                    }
                }
            }
        }
    }

    /// A calendar event starting within 15 minutes (or begun in the last 30) names the call and brings its attendees.
    /// Only with Calendar access and the calendar setting on: nothing here reads the calendar for a user who has not asked.
    private func eventForCall(_ done: @escaping @MainActor (CallEvent?) -> Void) {
        guard prefs.calendarPrompt, calendarStatus == .granted else { done(nil); return }
        let ep = currentEpoch()
        let now = Date()
        calendar.upcoming(now: now, lead: 15 * 60, grace: 30 * 60) { events in
            MainActor.assumeIsolated { done(ep == currentEpoch() ? CallEventFilter.nearest(events, now: now) : nil) }
        }
    }

    private func showCallPrompt(_ app: String, event ev: CallEvent? = nil) {
        if let ev { prompted.insert(ev.key) }  // the event prompt must not ask again for this meeting
        let title = ev.map { "Record “\($0.title)”?" } ?? "Record this \(app) call?"
        let subtitle = ev.map { "\(app) · \($0.subtitle)" } ?? "\(app) is using your microphone"
        prompt.show(.call, title: title, subtitle: subtitle, primary: "Record", secondary: "Dismiss",
                    symbol: "mic.fill",
                    onPrimary: { [weak self] in
                        self?.dismissPrompt()
                        self?.droplet.startRecording(title: ev?.title ?? "\(app) call", attendees: ev?.attendees ?? [], autoStarted: false)
                    }, onSecondary: { [weak self] in self?.dismissPrompt() })
        present(duration: 20, priority: .normal, label: "\(title) \(subtitle)")
    }

    // MARK: recording hooks (called by the droplet)

    func recordingStarted() {
        armed = false; lastCall = Date(); keepRecording = false; countdownEnd = nil; sampling = false; scanning = false
        participants = []
        if micSessionActive { micPrompted = true }
        if prompt.active { dismissPrompt() }
    }

    func recordingEnded() {
        if prompt.kind == .ending { dismissPrompt() }
        countdownEnd = nil; armed = false
    }

    /// The names the Accessibility reader has collected during this recording.
    var participantSnapshot: [String] { participants }

    /// Once a second while recording.
    func tick(elapsed: Int) {
        if let end = countdownEnd {
            let left = safeInt(end.timeIntervalSinceNow.rounded(.up))
            if left <= 0 { endCall() } else { prompt.update(subtitle: "Stopping in \(left) s") }
        }
        if elapsed % 5 == 2 { sampleCallAudio() }
        if elapsed % 15 == 5, prefs.participantNames { scanParticipants() }
    }

    // MARK: auto-stop (D13)

    private func sampleCallAudio() {
        guard !sampling else { return }
        sampling = true
        let ep = currentEpoch()
        callQ.async {
            let apps = CallAudio.callAppsRunningInput()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.sampling = false
                    if ep == currentEpoch() { self.sampled(apps) }
                }
            }
        }
    }

    private func sampled(_ apps: [String]) {
        guard droplet.recording else { return }
        if !apps.isEmpty {
            armed = true; lastCall = Date()
            if countdownEnd != nil { cancelCountdown() }  // the call is back
            return
        }
        // Armed only after a call app was seen: an in-person recording never has one and must never auto-stop.
        guard armed, prefs.autoStop, !keepRecording, countdownEnd == nil, !prompt.active,
              Date().timeIntervalSince(lastCall) >= 60 else { return }
        startCountdown()
    }

    private func startCountdown() {
        countdownEnd = Date().addingTimeInterval(15)
        prompt.show(.ending, title: "Call ended?", subtitle: "Stopping in 15 s", primary: "Keep recording", secondary: "Stop now",
                    symbol: "phone.down.fill",
                    onPrimary: { [weak self] in self?.keepRecording = true; self?.cancelCountdown() },
                    onSecondary: { [weak self] in self?.endCall() })
        // Never stop silently: the countdown on screen is the warning. If the notch refused it, try again at the next sample.
        if !present(duration: 16, priority: .high, label: "Call ended? Recording stops in 15 seconds") {
            countdownEnd = nil
            log("auto-stop countdown refused by the host HUD; recording continues")
        }
    }

    private func cancelCountdown() { countdownEnd = nil; dismissPrompt() }

    private func endCall() {
        countdownEnd = nil; dismissPrompt()
        droplet.stopRecording(process: true)
    }

    // MARK: participant names (D18)

    private func scanParticipants() {
        guard !scanning, AXReader.trusted else { return }
        scanning = true
        let ep = currentEpoch()
        axQ.async {
            let names = AXReader.scan()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.scanning = false
                    guard ep == currentEpoch(), self.droplet.recording else { return }
                    for n in names where !self.participants.contains(where: { $0.caseInsensitiveCompare(n) == .orderedSame }) { self.participants.append(n) }
                }
            }
        }
    }

    // MARK: the HUD card

    @discardableResult
    private func present(duration: TimeInterval, priority: DropletHUDPriority, label: String) -> Bool {
        guard let host else { return false }
        let m = prompt
        promptTimeout?.cancel()
        let shown = host.hud.present(DropletHUDRequest(
            id: PromptModel.hudID, duration: duration, priority: priority, accessibilityLabel: label,
            isExpanded: true, expandedContentHeight: PromptModel.cardHeight,
            content: { PromptStrip(model: m) }, expanded: { PromptCard(model: m) }))
        if !shown { prompt.clear(); return false }  // the notch is owned by something higher: the moment has passed
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.dismissPrompt() } }
        promptTimeout = w
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.5, execute: w)
        return true
    }

    func dismissPrompt() {
        promptTimeout?.cancel(); promptTimeout = nil
        if prompt.active { host?.hud.dismiss(id: PromptModel.hudID) }
        prompt.clear()
    }

    // MARK: harness demo

    /// Harness only (`host.environment.isHarness`): puts a prompt on the HUD so its shot can be looked at.
    func demo(_ which: String) {
        switch which {
        case "event": showEventPrompt(CallEvent(key: "demo", title: "Weekly sync", start: Date().addingTimeInterval(45), attendees: ["Priya Nair", "Sam Lee", "Dana Cruz"], hasLink: true))
        case "call": showCallPrompt("Zoom")
        case "callevent": showCallPrompt("Zoom", event: CallEvent(key: "demo", title: "Weekly sync", start: Date().addingTimeInterval(-120), attendees: ["Priya Nair", "Sam Lee", "Dana Cruz"], hasLink: true))
        case "ending":
            countdownEnd = Date().addingTimeInterval(11); startCountdown(); prompt.update(subtitle: "Stopping in 11 s")
        default: break
        }
    }
}
