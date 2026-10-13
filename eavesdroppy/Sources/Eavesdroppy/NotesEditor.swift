import DroppyKit
import SwiftUI

/// Typed notes during a meeting (D9). The text is saved live by the droplet (debounced, atomic) to
/// `<session>/notes.txt`; this view is the same in the shelf widget and the expanded surface.
struct TypedNotes: View {
    @ObservedObject var droplet: EavesdroppyDroplet
    /// In the menu bar there is no shelf to hold open or to ask for key focus.
    var inMenu = false

    var body: some View {
        DroppyMarkdownEditor(
            text: $droplet.notesText,
            context: DroppyMarkdownEditorContext(
                documentID: droplet.session?.dir.path,
                placeholder: "Type notes while you talk…",
                onFocusChange: { if !inMenu { droplet.notesFocusChanged($0) } }))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The shelf takes key focus only when asked, as for the title field.
            .simultaneousGesture(TapGesture().onEnded { if !inMenu { droplet.focusTitle() } })
    }
}

/// Which template this meeting's notes use; defaults to the setting, switchable while recording.
struct TemplateMenu: View {
    @ObservedObject var droplet: EavesdroppyDroplet

    var body: some View {
        Menu {
            ForEach(NoteTemplate.all, id: \.id) { t in
                Button { droplet.recordingTemplate = t.id } label: {
                    if droplet.recordingTemplate == t.id { Label(t.name, systemImage: "checkmark") } else { Text(t.name) }
                }
            }
        } label: {
            Text(NoteTemplate.name(droplet.recordingTemplate)).font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.button).buttonStyle(DroppyQuietButtonStyle(size: .small)).fixedSize()
        .accessibilityLabel("Notes template")
    }
}
