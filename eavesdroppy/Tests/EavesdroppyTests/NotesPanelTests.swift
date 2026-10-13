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

    @Test func savedFrameIsKeptOnlyWhileReachable() {
        let screens = [NSRect(x: 0, y: 0, width: 1440, height: 900)]
        let ok = NotesPanelController.restoredFrame(NSStringFromRect(NSRect(x: 900, y: 500, width: 420, height: 340)), screens: screens)
        #expect(ok == NSRect(x: 900, y: 500, width: 420, height: 340))
        #expect(NotesPanelController.restoredFrame("", screens: screens) == nil)
        #expect(NotesPanelController.restoredFrame(NSStringFromRect(NSRect(x: 3000, y: 500, width: 420, height: 340)), screens: screens) == nil)  // unplugged display
        #expect(NotesPanelController.restoredFrame(NSStringFromRect(NSRect(x: 100, y: 100, width: 50, height: 50)), screens: screens) == nil)  // smaller than the minimum
        let d = NotesPanelController.defaultFrame(in: screens[0])
        #expect(d.maxX == 1440 - 16 && d.maxY == 900 - 16)
    }

    /// Renders the window's content to a PNG so it can be looked at (the harness cannot shoot a panel).
    /// EAVESDROPPY_PANEL_SHOT=<file.png> swift test --filter notesPanelContentShot
    @Test func notesPanelContentShot() throws {
        guard let out = ProcessInfo.processInfo.environment["EAVESDROPPY_PANEL_SHOT"] else { return }
        _ = NSApplication.shared
        let droplet = EavesdroppyDroplet()
        droplet.notesText = "## Agenda\n- Rollout plan\n- Pricing\n\nAction: Priya to send the deck"
        let size = NSSize(width: 420, height: 340)
        let view = NSHostingView(rootView: NotesPanelView(droplet: droplet).environment(\.colorScheme, .dark))
        view.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.08, alpha: 1)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: out))
    }
}
