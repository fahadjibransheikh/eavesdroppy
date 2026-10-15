import AppKit
import DroppyKit
import SwiftUI

/// The floating window typed notes live in while a recording runs. Owned by the droplet: created on first use,
/// torn down when the recording ends and in deactivate(). Droppy's own surfaces cannot host it (it refuses the
/// droplet's expanded surface for approved local builds), and the shelf closes whenever the pointer leaves it.
@MainActor
final class NotesPanelController: NSObject, NSWindowDelegate {
    static let defaultSize = NSSize(width: 420, height: 340)
    static let minSize = NSSize(width: 300, height: 180)

    private let content: () -> AnyView
    private let loadFrame: () -> String
    private let saveFrame: (String) -> Void
    private var panel: NotesPanel?
    private var saveWork: DispatchWorkItem?
    /// The meetings library reuses this window (Droppy refuses its expanded surface too): larger, centred, not floating.
    private let library: Bool

    init(content: @escaping () -> AnyView, loadFrame: @escaping () -> String, saveFrame: @escaping (String) -> Void, library: Bool = false) {
        self.content = content; self.loadFrame = loadFrame; self.saveFrame = saveFrame; self.library = library
    }

    static let librarySize = NSSize(width: 900, height: 620), libraryMinSize = NSSize(width: 680, height: 420)

    private func firstFrame() -> NSRect {
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
        guard library, let s = screen else { return Self.defaultFrame(in: screen) }
        let size = NSSize(width: min(Self.librarySize.width, s.width), height: min(Self.librarySize.height, s.height))
        return NSRect(x: s.midX - size.width / 2, y: s.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// `focus`: take keyboard focus (the user asked for the window). An automatic open at the start of a recording
    /// must not: the meeting app keeps the keyboard.
    func show(title: String, focus: Bool) {
        let p = panel ?? makePanel()
        p.title = title
        if library {  // asked for from the menu bar or a shortcut while another app is in front: come forward with Droppy
            NSApp.activate(ignoringOtherApps: true)
            p.makeKeyAndOrderFront(nil); p.orderFrontRegardless()
        } else if focus {
            p.makeKeyAndOrderFront(nil)
            p.focusEditor()
            DispatchQueue.main.async { [weak p] in p?.focusEditor() }  // the editor may not be in the view tree yet on a first open
        } else {
            p.orderFrontRegardless()
        }
    }

    /// Closes the window for good and releases its view (which holds the droplet).
    func teardown() {
        saveWork?.cancel(); saveWork = nil
        guard let p = panel else { return }
        panel = nil
        saveFrame(NSStringFromRect(p.frame))
        p.delegate = nil; p.contentView = nil; p.orderOut(nil)
    }

    func makePanel() -> NotesPanel {  // internal: the panel shot test builds the real window
        let p = NotesPanel(contentRect: Self.restoredFrame(loadFrame(), screens: NSScreen.screens.map(\.visibleFrame)) ?? firstFrame(),
                           // The library's content stays out of the title bar: with .fullSizeContentView, AppKit's drag-region pass
                           // trapped inside SwiftUI's scroll clip view when a meeting was switched (Droppy crash 2026-10-15 12:41).
                           styleMask: library ? [.titled, .closable, .resizable, .miniaturizable]
                                              : [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        p.level = library ? .normal : .floating
        p.focusesEditorOnKey = !library
        p.animationBehavior = .none  // shown from a keyboard shortcut or by the recording starting: no show or close animation
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false  // Droppy is a background app: the default would hide the panel at once
        p.isReleasedWhenClosed = false
        p.titlebarAppearsTransparent = !library
        p.isOpaque = false; p.backgroundColor = .clear
        p.appearance = NSAppearance(named: .darkAqua)
        p.minSize = library ? Self.libraryMinSize : Self.minSize
        p.delegate = self
        let hosting = NSHostingView(rootView: content())
        hosting.sizingOptions = []  // the window's size is the user's, not the content's
        p.contentView = hosting
        panel = p
        return p
    }

    /// The saved frame if it is still reachable on a connected screen, else nil.
    static func restoredFrame(_ saved: String, screens: [NSRect]) -> NSRect? {
        guard !saved.isEmpty else { return nil }
        let r = NSRectFromString(saved)
        guard r.width >= minSize.width, r.height >= minSize.height else { return nil }
        return screens.contains { let i = $0.intersection(r); return i.width >= 100 && i.height >= 40 } ? r : nil
    }

    /// Bottom right of the screen, above the Dock: the top right is where a call's gallery, participants and chat sit.
    static func defaultFrame(in screen: NSRect?) -> NSRect {
        guard let s = screen else { return NSRect(origin: NSPoint(x: 100, y: 100), size: defaultSize) }
        let size = NSSize(width: min(defaultSize.width, s.width), height: min(defaultSize.height, s.height))
        return NSRect(x: s.maxX - size.width - 16, y: s.minY + 16, width: size.width, height: size.height)
    }

    // MARK: NSWindowDelegate

    func windowDidMove(_ notification: Notification) { scheduleSave() }
    func windowDidEndLiveResize(_ notification: Notification) { scheduleSave() }
    func windowWillClose(_ notification: Notification) {
        if let p = notification.object as? NSWindow { saveFrame(NSStringFromRect(p.frame)) }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { if let p = self?.panel { self?.saveFrame(NSStringFromRect(p.frame)) } }
        }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }
}

/// Non-activating (typing and clicking never pull Droppy to the front of the meeting app) but able to become key,
/// which is what lets the editor take keystrokes.
final class NotesPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var focusesEditorOnKey = true

    /// A click anywhere in the panel, header included, leaves the cursor in the notes.
    override func becomeKey() {
        super.becomeKey()
        if focusesEditorOnKey, !(firstResponder is NSTextView) { focusEditor() }
    }

    func focusEditor() {
        contentView?.layoutSubtreeIfNeeded()
        if let tv = contentView.flatMap(Self.textView(in:)) { makeFirstResponder(tv) }
    }

    private static func textView(in view: NSView) -> NSTextView? {
        if let tv = view as? NSTextView, tv.isEditable { return tv }
        for sub in view.subviews { if let tv = textView(in: sub) { return tv } }
        return nil
    }
}

/// What the window shows: a slim header (clock, template, Stop), the audio warning when there is one, and the notes
/// editor. Stop is here because during a call this window is where the user is looking, not the shelf.
struct NotesPanelView: View {
    @ObservedObject var droplet: EavesdroppyDroplet

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            HStack(spacing: DroppySpacing.xsm) {
                Image(systemName: "record.circle.fill").font(.system(size: 12, weight: .medium)).foregroundStyle(StateColor.destructive)
                Text(droplet.clock).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                Spacer(minLength: 0)
                LanguageMenu(droplet: droplet)
                TemplateMenu(droplet: droplet)
                Button("Stop") { droplet.stopRecording(process: true) }
                    .buttonStyle(DroppyAccentButtonStyle(color: StateColor.destructive, size: .small))
                    .disabled(droplet.busy)
            }
            if !droplet.warnings.isEmpty { WarningRow(droplet: droplet).transition(DroppyTransition.element) }
            TypedNotes(droplet: droplet)
        }
        .padding(DroppySpacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DroppyPanelSurface(cornerRadius: 0).ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}
