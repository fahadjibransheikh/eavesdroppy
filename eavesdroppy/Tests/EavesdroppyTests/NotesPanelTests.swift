import AppKit
import SwiftUI
import Testing
@testable import Eavesdroppy

@Suite @MainActor struct NotesPanelTests {
    @Test func callAudioWarnsOnlyAfterAFullMinuteOfNothing() {
        #expect(!callAudioMissing(elapsed: 15, frames: 0))
        #expect(!callAudioMissing(elapsed: 59, frames: 0))
        #expect(callAudioMissing(elapsed: 60, frames: 0))
        #expect(!callAudioMissing(elapsed: 300, frames: 1))  // the tap woke up late and recorded fine
    }

    @Test func noCallAudioWarningNeedsACallApp() {
        #expect(!shouldWarnNoCallAudio(callApps: [], elapsed: 600, frames: 0))  // in person: nothing plays, nothing to warn about
        #expect(!shouldWarnNoCallAudio(callApps: ["Zoom"], elapsed: 59, frames: 0))
        #expect(shouldWarnNoCallAudio(callApps: ["Zoom"], elapsed: 60, frames: 0))
        #expect(!shouldWarnNoCallAudio(callApps: ["Zoom"], elapsed: 600, frames: 48_000))
    }

    @Test func settingIsCallOnlyWithACallAppOrSustainedSignal() {
        #expect(recordingSetting(callApps: ["Zoom"], systemSignalSeconds: 0, duration: 3000) == "call")
        // Today's in-person recordings: 156 s and 34 s of notification blips and clips in ~50 and ~65 minutes.
        #expect(recordingSetting(callApps: [], systemSignalSeconds: 156, duration: 3048) == "in_person")
        #expect(recordingSetting(callApps: [], systemSignalSeconds: 34, duration: 3932) == "in_person")
        #expect(recordingSetting(callApps: [], systemSignalSeconds: 0, duration: 3000) == "in_person")
        #expect(recordingSetting(callApps: [], systemSignalSeconds: 900, duration: 3000) == "call")  // a call the app list missed
        #expect(recordingSetting(callApps: [], systemSignalSeconds: 40, duration: 100) == "call")   // short call: a fifth of it, over 30 s
        #expect(recordingSetting(callApps: [], systemSignalSeconds: 20, duration: 60) == "in_person")
    }

    @Test func voiceNoticeOnlyAfterAnInPersonMeetingWithoutAVoiceprintOncePerDay() {
        let day = 86_400.0, now = 1_800_000_000.0
        #expect(shouldShowVoiceNotice(inPerson: true, meSamples: 0, lastShown: 0, now: now))
        #expect(!shouldShowVoiceNotice(inPerson: false, meSamples: 0, lastShown: 0, now: now))  // a call: the mic is the user alone
        #expect(!shouldShowVoiceNotice(inPerson: true, meSamples: 1, lastShown: 0, now: now))   // already enrolled
        #expect(!shouldShowVoiceNotice(inPerson: true, meSamples: 0, lastShown: now - day + 1, now: now))
        #expect(shouldShowVoiceNotice(inPerson: true, meSamples: 0, lastShown: now - day, now: now))
    }

    @Test func savedFrameIsKeptOnlyWhileReachable() {
        let screens = [NSRect(x: 0, y: 0, width: 1440, height: 900)]
        let ok = NotesPanelController.restoredFrame(NSStringFromRect(NSRect(x: 900, y: 500, width: 420, height: 340)), screens: screens)
        #expect(ok == NSRect(x: 900, y: 500, width: 420, height: 340))
        #expect(NotesPanelController.restoredFrame("", screens: screens) == nil)
        #expect(NotesPanelController.restoredFrame(NSStringFromRect(NSRect(x: 3000, y: 500, width: 420, height: 340)), screens: screens) == nil)  // unplugged display
        #expect(NotesPanelController.restoredFrame(NSStringFromRect(NSRect(x: 100, y: 100, width: 50, height: 50)), screens: screens) == nil)  // smaller than the minimum
        let d = NotesPanelController.defaultFrame(in: screens[0])
        #expect(d.maxX == 1440 - 16 && d.minY == 16)  // bottom right, above the Dock
    }

    /// Renders the window's content to a PNG so it can be looked at (the harness cannot shoot a panel).
    /// EAVESDROPPY_PANEL_SHOT=<file.png> swift test --filter notesPanelContentShot
    @Test func notesPanelContentShot() throws {
        guard let out = ProcessInfo.processInfo.environment["EAVESDROPPY_PANEL_SHOT"] else { return }
        _ = NSApplication.shared
        let droplet = EavesdroppyDroplet()
        droplet.notesText = "## Agenda\n- Rollout plan\n- Pricing\n\nAction: Priya to send the deck"
        if ProcessInfo.processInfo.environment["EAVESDROPPY_PANEL_NO_WARNING"] == nil { droplet.demoRecording() }  // after the text: no recording is writing notes.txt
        // The real window (style mask, transparent title bar), so the title bar and traffic lights are in the picture.
        let controller = NotesPanelController(content: { AnyView(NotesPanelView(droplet: droplet)) }, loadFrame: { "" }, saveFrame: { _ in })
        let window = controller.makePanel()
        window.title = "Weekly sync"
        window.setFrame(NSRect(origin: .zero, size: NotesPanelController.defaultSize), display: false)
        let frameView = try #require(window.contentView?.superview)
        frameView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let view = frameView
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: out))
    }
}

@Suite struct ClockAndHeightTests {
    @Test func clockShowsHoursPastAnHour() {
        #expect(clockText(0) == "0:00")
        #expect(clockText(754) == "12:34")
        #expect(clockText(3599) == "59:59")
        #expect(clockText(3600) == "1:00:00")
        #expect(clockText(4512) == "1:15:12")  // was "75:12"
        #expect(clockText(-5) == "0:00")
    }

    @Test func widgetHeightGrowsWithRowsAndStaysUnderTheCap() {
        let idle = shelfWidgetHeight(recording: false, attendees: false, warning: false, permissionProblem: false, rows: 0)
        let three = shelfWidgetHeight(recording: false, attendees: false, warning: false, permissionProblem: false, rows: 3)
        #expect(three > idle && three <= 170)
        #expect(shelfWidgetHeight(recording: false, attendees: false, warning: false, permissionProblem: true, rows: 40) == 170)
        let rec = shelfWidgetHeight(recording: true, attendees: false, warning: false, permissionProblem: false, rows: 9)
        #expect(rec == shelfWidgetHeight(recording: true, attendees: false, warning: false, permissionProblem: false, rows: 0))  // jobs are not listed while recording
        #expect(shelfWidgetHeight(recording: true, attendees: true, warning: true, permissionProblem: false, rows: 0) > rec)
    }

    @Test func whenIsRelativeAndLocaleAware() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Fmt.parseISO("2026-10-13T12:00:00Z")!
        let us = Locale(identifier: "en_US"), gb = Locale(identifier: "en_GB")
        #expect(Fmt.when("2026-10-13T09:30:00Z", now: now, calendar: cal, locale: us).hasPrefix("Today, 9:30"))
        #expect(Fmt.when("2026-10-12T23:30:00Z", now: now, calendar: cal, locale: gb) == "Yesterday, 23:30")
        #expect(Fmt.when("2026-10-09T09:30:00Z", now: now, calendar: cal, locale: gb).hasPrefix("Fri, "))  // three days back: the weekday
        #expect(Fmt.when("2026-09-01T09:30:00Z", now: now, calendar: cal, locale: gb).hasPrefix("1 Sep"))   // older: the date, no year
        #expect(!Fmt.when("2026-10-13T21:30:00Z", now: Fmt.parseISO("2026-10-13T23:00:00Z")!, calendar: cal, locale: gb).contains("PM"))
        #expect(Fmt.when("2025-09-01T09:30:00Z", now: now, calendar: cal, locale: gb).contains("2025"))
        #expect(Fmt.when("not a date") == "not a date")
    }
}

@Suite struct LibraryListTests {
    @Test func groupsByDay() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Fmt.parseISO("2026-10-13T12:00:00Z")!
        #expect(Fmt.group("2026-10-13T01:00:00Z", now: now, calendar: cal) == "Today")
        #expect(Fmt.group("2026-10-12T23:59:00Z", now: now, calendar: cal) == "Yesterday")
        #expect(Fmt.group("2026-10-08T12:00:00Z", now: now, calendar: cal) == "This week")
        #expect(Fmt.group("2026-10-06T12:00:00Z", now: now, calendar: cal) == "Earlier")
        #expect(Fmt.group("garbage", now: now, calendar: cal) == "Earlier")
    }

    @Test func transcriptTextIsOneLinePerTurn() {
        let t = [TurnRow(idx: 0, speakerID: 1, speaker: "Me", start: 0, end: 5, text: "Hi"), TurnRow(idx: 1, speakerID: 2, speaker: "Priya", start: 3725, end: 3730, text: "Hello")]
        #expect(LibraryModel.transcriptText(t) == "Me [00:00]: Hi\nPriya [1:02:05]: Hello")
    }
}

@Suite struct StageAndCallTests {
    @Test func stageFollowsTheLastFinishedStage() {
        #expect(processingStage(afterLog: "stage track prep done at +0.4 s") == "Cleaning up audio")
        #expect(processingStage(afterLog: "stage echo done at +1.0 s") == "Transcribing")
        #expect(processingStage(afterLog: "stage transcription done at +30.2 s") == "Finding speakers")
        #expect(processingStage(afterLog: "stage diarization done at +40.0 s") == "Naming speakers")
        #expect(processingStage(afterLog: "stage naming done at +41.0 s") == "Writing notes")
        #expect(processingStage(afterLog: "stage notes and folder done at +60.0 s") == nil)  // finished: the job leaves the list
        #expect(processingStage(afterLog: "WARNING: something") == nil)
    }

    @Test func nearestEventIsTheOneStartingClosestToNow() {
        let now = Date()
        func ev(_ k: String, _ off: TimeInterval) -> CallEvent { CallEvent(key: k, title: k, start: now.addingTimeInterval(off), attendees: [], hasLink: true) }
        #expect(CallEventFilter.nearest([ev("late", 600), ev("started", -120), ev("earlier", -1500)], now: now)?.key == "started")
        #expect(CallEventFilter.nearest([], now: now) == nil)
    }
}
