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

    init(content: @escaping () -> AnyView, loadFrame: @escaping () -> String, saveFrame: @escaping (String) -> Void) {
        self.content = content; self.loadFrame = loadFrame; self.saveFrame = saveFrame
    }

    /// `focus`: take keyboard focus (the user asked for the window). An automatic open at the start of a recording
    /// must not: the meeting app keeps the keyboard.
    func show(title: String, focus: Bool) {
        let p = panel ?? makePanel()
        p.title = title
        if focus {
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

    private func makePanel() -> NotesPanel {
        let p = NotesPanel(contentRect: Self.restoredFrame(loadFrame(), screens: NSScreen.screens.map(\.visibleFrame))
                                        ?? Self.defaultFrame(in: (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame),
                           styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false  // Droppy is a background app: the default would hide the panel at once
        p.isReleasedWhenClosed = false
        p.titlebarAppearsTransparent = true
        p.isOpaque = false; p.backgroundColor = .clear
        p.appearance = NSAppearance(named: .darkAqua)
        p.minSize = Self.minSize
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

    /// Top right of the screen, clear of the menu bar.
    static func defaultFrame(in screen: NSRect?) -> NSRect {
        guard let s = screen else { return NSRect(origin: NSPoint(x: 100, y: 100), size: defaultSize) }
        let size = NSSize(width: min(defaultSize.width, s.width), height: min(defaultSize.height, s.height))
        return NSRect(x: s.maxX - size.width - 16, y: s.maxY - size.height - 16, width: size.width, height: size.height)
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

    /// A click anywhere in the panel, header included, leaves the cursor in the notes.
    override func becomeKey() {
        super.becomeKey()
        if !(firstResponder is NSTextView) { focusEditor() }
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

/// What the window shows: a slim header (clock, template) over the notes editor.
struct NotesPanelView: View {
    @ObservedObject var droplet: EavesdroppyDroplet

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            HStack(spacing: DroppySpacing.xsm) {
                Image(systemName: "record.circle.fill").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.red)
                Text(droplet.clock).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                Spacer(minLength: 0)
                TemplateMenu(droplet: droplet)
            }
            TypedNotes(droplet: droplet)
        }
        .padding(DroppySpacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DroppyPanelSurface(cornerRadius: 0).ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}
