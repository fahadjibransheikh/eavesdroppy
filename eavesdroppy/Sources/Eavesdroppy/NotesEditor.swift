import DroppyKit
import SwiftUI

/// Typed notes during a meeting (D9). The text is saved live by the droplet (debounced, atomic) to
/// `<session>/notes.txt`; this view is the body of the floating notes window (NotesPanel.swift).
struct TypedNotes: View {
    @ObservedObject var droplet: EavesdroppyDroplet

    var body: some View {
        DroppyMarkdownEditor(
            text: $droplet.notesText,
            context: DroppyMarkdownEditorContext(
                documentID: droplet.session?.dir.path,
                placeholder: "Type notes while you talk…"))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
