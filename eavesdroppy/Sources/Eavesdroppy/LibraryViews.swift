import DroppyKit
import SwiftUI

// The expanded surface: Meetings (search + list) -> one meeting (notes, transcript, speakers, actions), plus Ask.
// Surfaces are dark; foregrounds come from AdaptiveColors, spacing from DroppySpacing, radii from DroppyRadius.

private let primary = AdaptiveColors.notchSurfacePrimaryText
private let secondary = AdaptiveColors.notchSurfaceSecondaryText
private let tertiary = AdaptiveColors.notchSurfaceTertiaryText
private let accent = AdaptiveColors.selectionBlueAuto

private extension View {
    /// The shelf takes key focus only when asked (see the widget's title field).
    func takesKeyboard(_ model: LibraryModel) -> some View { simultaneousGesture(TapGesture().onEnded { model.requestKeyboard() }) }

    func fieldBox() -> some View {
        padding(.horizontal, DroppySpacing.smd).padding(.vertical, DroppySpacing.xsm)
            .background(RoundedRectangle(cornerRadius: DroppyRadius.ms, style: .continuous).fill(AdaptiveColors.notchSurfaceCardFill))
    }

    func rowBox(_ highlighted: Bool = false) -> some View {
        padding(.horizontal, DroppySpacing.smd).padding(.vertical, DroppySpacing.xsm)
            .background(RoundedRectangle(cornerRadius: DroppyRadius.ms, style: .continuous)
                .fill(highlighted ? AdaptiveColors.notchSurfaceCardHoverFill : AdaptiveColors.notchSurfaceCardFill))
    }
}

struct LibrarySurface: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            // The list stays beside the open meeting, so moving between meetings is one click and never a back-and-forth.
            // Find on top of the list, ask at the bottom: one field never does two jobs.
            HStack(alignment: .top, spacing: DroppySpacing.xl) {
                MeetingList(model: model).frame(width: 236)
                Group {
                    if model.openID != nil {
                        MeetingDetailView(model: model).id(model.openID).transition(DroppyTransition.expandedContent)
                    } else if !model.meetings.isEmpty {
                        Text("Pick a meeting").font(.system(size: 12)).foregroundStyle(tertiary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .bottom) { banners }
            AskAnswer(model: model)
            AskBar(model: model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.openURL, OpenURLAction { model.handle($0) ? .handled : .systemAction })
        .onAppear { model.refresh() }
    }

    /// The team picker, the export link and the status line: one slot over the bottom edge of the list, not in the flow.
    private var banners: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xs) {
            if let pick = model.teamPick { TeamPicker(pick: pick).transition(DroppyTransition.element) }
            if let link = model.exportLink { ExportLinkRow(model: model, label: link.label, url: link.url).transition(DroppyTransition.element) }
            if let s = model.status {
                Text(s).font(.system(size: 11)).foregroundStyle(model.statusIsError ? StateColor.warning : secondary).lineLimit(2)
                    .padding(.horizontal, DroppySpacing.smd).padding(.vertical, DroppySpacing.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: DroppyRadius.ms, style: .continuous).fill(Color.black))  // the surface's own black, so the list does not show through
                    .transition(DroppyTransition.element)
            }
        }
    }
}

// MARK: - Linear export

/// "Which team?" for a Linear export with no default team. Shown once per export, with the option to keep the answer.
private struct TeamPicker: View {
    let pick: TeamPick
    @State private var remember = true

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xs) {
            HStack {
                Text("Which Linear team?").font(.system(size: 12, weight: .semibold)).foregroundStyle(primary)
                Spacer(minLength: 0)
                Button("Cancel") { pick.resolve(nil, false) }.buttonStyle(DroppyQuietButtonStyle(size: .small))
            }
            ScrollView {
                VStack(spacing: DroppySpacing.xs) {
                    ForEach(pick.teams) { t in
                        Button { pick.resolve(t, remember) } label: {
                            HStack {
                                Text(t.name).font(.system(size: 12)).foregroundStyle(primary)
                                Spacer(minLength: 0)
                                if !t.key.isEmpty { Text(t.key).font(.system(size: 11)).foregroundStyle(tertiary) }
                            }
                            .contentShape(Rectangle()).rowBox()
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 110)
            Toggle("Remember as default", isOn: $remember).toggleStyle(.checkbox).font(.system(size: 11)).foregroundStyle(secondary)
        }
        .fieldBox()
        .background(RoundedRectangle(cornerRadius: DroppyRadius.ms, style: .continuous).fill(Color.black))
    }
}

private struct ExportLinkRow: View {
    @ObservedObject var model: LibraryModel
    let label: String
    let url: URL

    var body: some View {
        HStack(spacing: DroppySpacing.sm) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(accent)
            Button(label) { model.openURL(url) }.buttonStyle(DroppyQuietButtonStyle(size: .small))
            Spacer(minLength: 0)
            Button { model.dismissExportLink() } label: { Image(systemName: "xmark") }
                .buttonStyle(DroppyCircleButtonStyle(size: 20)).accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, DroppySpacing.smd).padding(.vertical, DroppySpacing.xs)
        .background(RoundedRectangle(cornerRadius: DroppyRadius.ms, style: .continuous).fill(Color.black))
    }
}

// MARK: - Markdown

/// Notes and answers: headings, bullets, checkboxes and paragraphs, with `[03:41]` timestamps (and, in answers,
/// `[Title, date, 03:41]` citations) as links. `eav://` URLs are handled by the surface's openURL action.
struct MarkdownText: View {
    let md: String
    var citations = false
    var size: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(MdBlock.parse(md).enumerated()), id: \.offset) { _, b in block(b) }
        }
        .foregroundStyle(primary)
        .tint(accent)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func text(_ s: String) -> Text { Text(Md.inline(s, citations: citations)) }

    @ViewBuilder private func block(_ b: MdBlock) -> some View {
        switch b {
        case .heading(let level, let t):
            text(t).font(.system(size: level <= 1 ? size + 3 : size + 1, weight: .semibold)).padding(.top, DroppySpacing.xs)
        case .bullet(let indent, let t):
            HStack(alignment: .firstTextBaseline, spacing: DroppySpacing.xsm) {
                Text("•").foregroundStyle(tertiary)
                text(t).font(.system(size: size))
            }.padding(.leading, CGFloat(indent) * 14)
        case .check(let done, let indent, let t):
            HStack(alignment: .firstTextBaseline, spacing: DroppySpacing.xsm) {
                Image(systemName: done ? "checkmark.square" : "square").font(.system(size: size - 1)).foregroundStyle(tertiary)
                text(t).font(.system(size: size))
            }.padding(.leading, CGFloat(indent) * 14)
        case .paragraph(let t): text(t).font(.system(size: size))
        case .gap: Color.clear.frame(height: DroppySpacing.xs)
        }
    }
}

// MARK: - Ask

private struct AskBar: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        HStack(spacing: DroppySpacing.sm) {
            scopeMenu
            TextField("Ask \(model.askScope)…", text: $model.askText)
                .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(primary)
                .onSubmit { model.askQuestion() }
                .takesKeyboard(model)
            if case .running = model.ask {
                ProgressView().controlSize(.small)
                Button("Cancel") { model.cancelAsk() }.buttonStyle(DroppyQuietButtonStyle(size: .small))
            } else {
                Button("Ask") { model.askQuestion() }.buttonStyle(DroppyQuietButtonStyle(size: .small))
                    .disabled(model.askText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .fieldBox()
    }
}

private extension AskBar {
    /// Where Ask looks: this meeting (when one is open) or all of them, or everything about one person.
    var scopeMenu: some View {
        let all = model.openID == nil || model.askAll
        let auto = all ? "All meetings" : "This meeting"
        return Menu {
            if model.openID != nil {
                Button { model.setAskPerson(nil) } label: {
                    if model.askPerson == nil && !all { Label("This meeting", systemImage: "checkmark") } else { Text("This meeting") }
                }
            }
            Button { model.setAskPerson(nil); model.askAll = true } label: {
                if model.askPerson == nil && all { Label("All meetings", systemImage: "checkmark") } else { Text("All meetings") }
            }
            Menu("About a person…") {
                ForEach(model.people) { p in
                    Button { model.setAskPerson(p) } label: {
                        if model.askPerson?.id == p.id { Label(model.displayName(p), systemImage: "checkmark") } else { Text(model.displayName(p)) }
                    }
                }
            }
            .disabled(model.people.isEmpty)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: model.askPerson == nil ? "sparkles" : "person.fill").font(.system(size: 10))
                Text(model.askPerson.map { model.displayName($0) } ?? auto).font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
        }
        .menuStyle(.button).buttonStyle(DroppyQuietButtonStyle(size: .small)).fixedSize()
        .accessibilityLabel("Ask scope")
    }
}

private struct AskAnswer: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        switch model.ask {
        case .idle: EmptyView()
        case .running(let q):
            Text("Looking through \(model.askScope) for “\(q)”…").font(.system(size: 11)).foregroundStyle(secondary).lineLimit(1)
        case .answer(let q, let a):
            VStack(alignment: .leading, spacing: DroppySpacing.xs) {
                HStack(spacing: DroppySpacing.sm) {
                    Text(q).font(.system(size: 11, weight: .medium)).foregroundStyle(secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    Button { model.dismissAsk() } label: { Image(systemName: "xmark") }
                        .buttonStyle(DroppyCircleButtonStyle(size: 20)).accessibilityLabel("Dismiss answer")
                }
                ScrollView { MarkdownText(md: a, citations: true) }.frame(maxHeight: 150)
            }
            .rowBox()
            .transition(DroppyTransition.element)
        case .failed(let why):
            HStack(spacing: DroppySpacing.sm) {
                Text("Ask failed: \(why)").font(.system(size: 11)).foregroundStyle(StateColor.warning).lineLimit(3)
                Spacer(minLength: 0)
                Button { model.dismissAsk() } label: { Image(systemName: "xmark") }
                    .buttonStyle(DroppyCircleButtonStyle(size: 20)).accessibilityLabel("Dismiss")
            }
            .transition(DroppyTransition.element)
        }
    }
}

// MARK: - List

private struct MeetingList: View {
    @ObservedObject var model: LibraryModel

    /// Sections by day only when browsing; search results stay in relevance order.
    private var sections: [(title: String?, meetings: [MeetingSummary])] {
        guard model.query.isEmpty else { return [(nil, model.meetings)] }
        var out: [(title: String?, meetings: [MeetingSummary])] = []
        for m in model.meetings {
            let g = Fmt.group(m.start)
            if out.last?.title == g { out[out.count - 1].meetings.append(m) } else { out.append((g, [m])) }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            HStack(spacing: DroppySpacing.xsm) {
                Image(systemName: "waveform").font(.system(size: 12, weight: .medium))
                Text("Meetings").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                if model.loaded, model.query.isEmpty, !model.meetings.isEmpty {
                    Text("\(model.meetings.count)").font(.system(size: 11)).monospacedDigit().foregroundStyle(tertiary)
                }
            }
            .foregroundStyle(secondary)
            .padding(.horizontal, DroppySpacing.xs)
            HStack(spacing: DroppySpacing.sm) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(tertiary)
                TextField("Search meetings", text: $model.query)
                    .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(primary).takesKeyboard(model)
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(tertiary).accessibilityLabel("Clear search")
                }
            }
            .fieldBox()
            if let e = model.listError {
                Text("Can't read the library: \(e)").font(.system(size: 11)).foregroundStyle(StateColor.warning)
            } else if model.meetings.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(sections, id: \.title) { sec in
                            if let t = sec.title {
                                Text(t).font(.system(size: 11, weight: .medium)).foregroundStyle(tertiary)
                                    .padding(.top, DroppySpacing.sm).padding(.bottom, 2).padding(.leading, DroppySpacing.smd)
                            }
                            ForEach(sec.meetings) { m in
                                Button { model.open(m.id, tab: m.hitTurnIdx != nil ? .transcript : .notes, turn: m.hitTurnIdx) } label: {
                                    MeetingRow(m: m, selected: model.openID == m.id, dayShown: sec.title == "Today" || sec.title == "Yesterday")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
    }

    @ViewBuilder private var empty: some View {
        if !model.loaded {
            Text("Loading…").font(.system(size: 12)).foregroundStyle(secondary)
        } else if !model.query.isEmpty {
            Text("No meetings match “\(model.query)”.").font(.system(size: 12)).foregroundStyle(secondary)
        } else {
            VStack(alignment: .leading, spacing: DroppySpacing.sm) {
                Text("No meetings yet. Record one from the shelf, or import a recording.").font(.system(size: 12)).foregroundStyle(secondary)
                Button("Import recording…") { model.importRecording() }.buttonStyle(DroppyQuietButtonStyle(size: .small))
            }
        }
    }
}

private struct MeetingRow: View {
    let m: MeetingSummary
    let selected: Bool
    /// The section header already says "Today" or "Yesterday": the row then shows only the time.
    let dayShown: Bool
    @State private var hovering = false

    private var when: String {
        let w = Fmt.when(m.start)
        guard dayShown, let comma = w.range(of: ", ") else { return w }
        return String(w[comma.upperBound...])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: DroppySpacing.xsm) {
                Text(m.title).font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? primary : primary.opacity(0.88)).lineLimit(1)
                Spacer(minLength: DroppySpacing.xsm)
                if m.openActions > 0 {
                    Text("\(m.openActions)").font(.system(size: 10, weight: .semibold)).monospacedDigit().foregroundStyle(secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule(style: .continuous).fill(AdaptiveColors.notchSurfaceCardHoverFill))
                        .accessibilityLabel("\(m.openActions) open action\(m.openActions == 1 ? "" : "s")")
                }
            }
            Text("\(when) · \(m.duration > 0 ? Fmt.length(m.duration) : "No speech detected")\(m.summaryStatus == "failed" ? " · notes failed" : "")")
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(tertiary).lineLimit(1)
            if let s = m.snippet { snippet(s, ts: m.hitTS) }
        }
        .padding(.horizontal, DroppySpacing.smd).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DroppyRadius.ms, style: .continuous)
            .fill(selected ? AdaptiveColors.notchSurfaceCardHoverFill : (hovering ? AdaptiveColors.notchSurfaceCardFill : .clear)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func snippet(_ s: String, ts: String?) -> some View {
        var t = AttributedString(ts.map { "[\($0)] " } ?? "")
        t.foregroundColor = tertiary
        for r in snippetRuns(s) {
            var a = AttributedString(r.text)
            if r.hit { a.font = .system(size: 11, weight: .semibold); a.foregroundColor = primary } else { a.foregroundColor = secondary }
            t += a
        }
        return Text(t).font(.system(size: 11)).lineLimit(2)
    }
}

// MARK: - Detail

private struct MeetingDetailView: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        if let d = model.detail {
            VStack(alignment: .leading, spacing: DroppySpacing.md) {
                VStack(alignment: .leading, spacing: 3) {
                    TitleRow(model: model, d: d)
                    Text(meta(d)).font(.system(size: 11)).foregroundStyle(tertiary).lineLimit(1)
                }
                HStack(spacing: DroppySpacing.sm) {
                    TabStrip(model: model, d: d)
                    Spacer(minLength: DroppySpacing.sm)
                    if let b = model.busy {
                        ProgressView().controlSize(.small)
                        Text(b).font(.system(size: 11)).foregroundStyle(secondary).lineLimit(1)
                    }
                }
                Group {
                    switch model.tab {
                    case .notes, .mine: NotesTab(model: model, d: d)
                    case .transcript: TranscriptTab(model: model, d: d)
                    case .speakers: SpeakersTab(model: model, d: d)
                    case .actions: ActionsTab(model: model, d: d)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        } else if let e = model.detailError {
            Text("Can't read this meeting: \(e)").font(.system(size: 11)).foregroundStyle(StateColor.warning)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func meta(_ d: MeetingDetail) -> String {
        ([Fmt.when(d.summary.start)] + (d.summary.duration > 0 ? [Fmt.length(d.summary.duration)] : []) + (d.attendees.isEmpty ? [] : [d.attendees.joined(separator: ", ")]))
            .joined(separator: " · ")
    }
}

/// One row of tabs; the open one is a raised chip, the rest are plain labels. "My notes" appears only when there are some.
private struct TabStrip: View {
    @ObservedObject var model: LibraryModel
    let d: MeetingDetail

    private var tabs: [DetailTab] {
        DetailTab.allCases.filter { $0 != .mine || !d.userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs, id: \.self) { t in
                let on = model.tab == t || (t == .notes && model.tab == .mine && !tabs.contains(.mine))
                let n = t == .actions ? d.actions.filter { !$0.done }.count : 0
                Button { model.tab = t } label: {
                    HStack(spacing: 4) {
                        Text(t.rawValue).font(.system(size: 12, weight: on ? .semibold : .medium))
                        if n > 0 { Text("\(n)").font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(tertiary) }
                    }
                    .foregroundStyle(on ? primary : secondary)
                    .padding(.horizontal, DroppySpacing.smd).padding(.vertical, 5)
                    .background(Capsule(style: .continuous).fill(on ? AdaptiveColors.notchSurfaceCardHoverFill : .clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule(style: .continuous).fill(AdaptiveColors.notchSurfaceCardFill))
    }
}

private struct TitleRow: View {
    @ObservedObject var model: LibraryModel
    let d: MeetingDetail
    @State private var editing = false
    @State private var draft = ""

    private var title: String { d.summary.title }

    var body: some View {
        HStack(spacing: DroppySpacing.sm) {
            if editing {
                TextField("Title", text: $draft)
                    .textFieldStyle(.plain).font(.system(size: 17, weight: .semibold)).foregroundStyle(primary)
                    .onSubmit { commit() }.takesKeyboard(model).fieldBox()
                Button("Save") { commit() }.buttonStyle(DroppyAccentButtonStyle(size: .small))
                Button("Cancel") { editing = false }.buttonStyle(DroppyQuietButtonStyle(size: .small))
            } else {
                Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(primary).lineLimit(1)
                    .onTapGesture(count: 2) { startEditing() }
                    .help("Double-click to rename")
                Spacer(minLength: DroppySpacing.sm)
                // Two clicks stay (the delete is not undoable): "Delete" in the menu arms it, this button confirms for 4 s.
                if model.confirmingDelete {
                    Button("Confirm delete") { model.delete() }
                        .buttonStyle(DroppyQuietButtonStyle(size: .small, destructive: true)).transition(DroppyTransition.element)
                }
                PlayerControl(model: model, player: model.player, hasAudio: d.summary.audioPath != nil)
                Menu {
                    Button("Rename…") { startEditing() }
                    Menu("Rewrite notes as") {
                        ForEach(NoteTemplate.all, id: \.id) { t in
                            Button { model.regenTemplate = t.id; model.regenerate() } label: {
                                if d.summary.template == t.id { Label(t.name, systemImage: "checkmark") } else { Text(t.name) }
                            }
                        }
                    }
                    .disabled(model.busy != nil)
                    Divider()
                    Button("Show in Finder") { model.openInDrive() }
                    Button("Copy transcript") { model.copyTranscript() }
                    Divider()
                    Button("Delete", role: .destructive) { model.delete() }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.button).buttonStyle(DroppyCircleButtonStyle(size: 24)).fixedSize().accessibilityLabel("More")
            }
        }
        .droppyFlatGlassControls()
        .onChange(of: title) { _, _ in editing = false }
    }

    private func startEditing() { draft = title; editing = true; model.requestKeyboard() }
    private func commit() { model.rename(draft); editing = false }
}

private struct PlayerControl: View {
    let model: LibraryModel
    @ObservedObject var player: AudioPlayback
    let hasAudio: Bool

    var body: some View {
        HStack(spacing: DroppySpacing.xsm) {
            if !hasAudio {
                Text("Audio removed").font(.system(size: 11)).foregroundStyle(tertiary)
            } else {
                if player.duration > 0 {
                    Text("\(Timestamp.format(player.position)) / \(Timestamp.format(player.duration))")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(secondary)
                }
                if player.loading { ProgressView().controlSize(.small) }
                Button { model.togglePlayback() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill") }
                    .buttonStyle(DroppyCircleButtonStyle(size: 24)).accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            }
        }
        .onChange(of: player.failure) { _, f in if let f { model.flash(f) } }
    }
}

// MARK: Notes

/// The generated notes, or (the My notes tab) what the user typed during the meeting. Read like a document: one
/// comfortable column, never the full width of a wide surface.
private struct NotesTab: View {
    @ObservedObject var model: LibraryModel
    let d: MeetingDetail

    private var mine: Bool { model.tab == .mine && !d.userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        ScrollView {
            Group {
                if mine { MarkdownText(md: d.userNotes, size: 13) }
                else if d.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { emptyNotes }
                else { MarkdownText(md: d.notes, size: 13) }
            }
            .frame(maxWidth: 600, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, DroppySpacing.md)
        }
        .scrollIndicators(.never)
    }

    private var emptyNotes: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            Text(emptyText).font(.system(size: 12)).foregroundStyle(secondary)
            if d.summary.summaryStatus != "pending" {
                Button("Write notes") { model.regenTemplate = d.summary.template; model.regenerate() }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small)).disabled(model.busy != nil)
            }
        }
        .droppyFlatGlassControls()
    }

    private var emptyText: String {
        switch d.summary.summaryStatus {
        case "failed": return "Notes couldn't be written. Try again, pick another template from the ⋯ menu, or read the transcript."
        case "pending": return "Notes are still being written…"
        default: return "No notes yet. They can be written from the transcript."
        }
    }
}

// MARK: Transcript

private struct TranscriptGroup: Identifiable {
    var id: Int { turns.first?.idx ?? -1 }
    var speaker: String
    var turns: [TurnRow]

    static func group(_ turns: [TurnRow]) -> [TranscriptGroup] {
        var out: [TranscriptGroup] = []
        for t in turns {
            if let l = out.last, l.speaker == t.speaker, l.turns.last?.speakerID == t.speakerID { out[out.count - 1].turns.append(t) }
            else { out.append(TranscriptGroup(speaker: t.speaker, turns: [t])) }
        }
        return out
    }
}

private struct TranscriptTab: View {
    @ObservedObject var model: LibraryModel
    let d: MeetingDetail

    private func isMe(_ g: TranscriptGroup) -> Bool { d.speakers.first { $0.id == g.turns.first?.speakerID }?.kind == "me" }

    var body: some View {
        if d.turns.isEmpty {
            Text("No speech detected.").font(.system(size: 12)).foregroundStyle(secondary)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DroppySpacing.md) {
                        ForEach(TranscriptGroup.group(d.turns)) { g in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(g.speaker).font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(isMe(g) ? accent : secondary)
                                ForEach(g.turns) { t in
                                    Button { model.seek(safeInt(t.start)) } label: {
                                        HStack(alignment: .firstTextBaseline, spacing: DroppySpacing.sm) {
                                            Text(Timestamp.format(t.start)).font(.system(size: 11)).monospacedDigit().foregroundStyle(accent)
                                            Text(t.text).font(.system(size: 12)).foregroundStyle(primary)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .padding(.vertical, 1).contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain).id(t.idx)
                                    .background(model.focusTurn == t.idx ? AdaptiveColors.notchSurfaceCardHoverFill : .clear)
                                }
                            }
                        }
                    }
                }
                .onAppear { if let f = model.focusTurn { DispatchQueue.main.async { proxy.scrollTo(f, anchor: .top) } } }
            }
        }
    }
}

// MARK: Speakers

private struct SpeakersTab: View {
    @ObservedObject var model: LibraryModel
    let d: MeetingDetail
    @State private var editing: Int?
    @State private var draft = ""
    @State private var scope = RenameScope.newPerson

    var body: some View {
        if d.speakers.isEmpty {
            Text("No speakers were identified.").font(.system(size: 12)).foregroundStyle(secondary)
        } else {
            ScrollView {
                VStack(spacing: DroppySpacing.xs) {
                    ForEach(d.speakers) { s in row(s) }
                }
                .droppyFlatGlassControls()
            }
        }
    }

    private func stats(_ s: SpeakerRow) -> String {
        let mine = d.turns.filter { $0.speakerID == s.id }
        let talk = mine.reduce(0) { $0 + max($1.end - $1.start, 0) }
        let kind: String? = switch s.kind { case "me": "You"; case "known": "Known voice"; case "suggest": "Suggested voice"; case "new": "New voice"; case "intro": "From introduction"; case "room": "Room"; case let k?: k.capitalized; default: nil }
        return ([kind, "\(mine.count) turn\(mine.count == 1 ? "" : "s")"] + [talk >= 60 ? "\(safeInt(talk / 60)) min" : nil]).compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder private func row(_ s: SpeakerRow) -> some View {
        let suggestion = editing == s.id ? nil : model.suggestedPerson(for: s)  // a voiceprint match that was not sure enough to apply
        VStack(alignment: .leading, spacing: DroppySpacing.xsm) {
            HStack(spacing: DroppySpacing.sm) {
                if editing == s.id {
                    TextField("Name", text: $draft).textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(primary)
                        .onSubmit { save(s) }.takesKeyboard(model)
                    Button("Save") { save(s) }.buttonStyle(DroppyAccentButtonStyle(size: .small))
                    Button("Cancel") { editing = nil }.buttonStyle(DroppyQuietButtonStyle(size: .small))
                } else {
                    playButton(s)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(suggestion.map { "Is this \(model.displayName($0))?" } ?? s.label)
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(primary).lineLimit(1)
                        Text(suggestion == nil ? stats(s) : "\(s.label) · \(stats(s))").font(.system(size: 11)).foregroundStyle(tertiary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if let p = suggestion {  // the best action is the row's headline
                        Button("Yes") { model.assignSpeaker(s, to: p) }.buttonStyle(DroppyAccentButtonStyle(size: .small))
                        Button("Someone else") { startNaming(s, scope: .newPerson) }.buttonStyle(DroppyQuietButtonStyle(size: .small))
                    } else if model.isIntro(s) {  // the name is Claude's reading of an introduction: listen, then keep the voice
                        Button("Save \(firstName(s.label))\u{2019}s voice") { model.saveIntroVoice(s) }.buttonStyle(DroppyAccentButtonStyle(size: .small))
                        nameMenu(s)
                    } else if s.kind == "me" {
                        Button("Rename") { startNaming(s, scope: .plain) }.buttonStyle(DroppyQuietButtonStyle(size: .small))
                    } else {
                        nameMenu(s)
                    }
                }
            }
            if editing == s.id {
                Menu {
                    ForEach(options(s), id: \.0) { o in
                        Button { scope = o.0 } label: { if scope == o.0 { Label(o.1, systemImage: "checkmark") } else { Text(o.1) } }
                    }
                } label: { Text(options(s).first { $0.0 == scope }?.1 ?? "").font(.system(size: 11, weight: .medium)) }
                    .menuStyle(.button).buttonStyle(DroppyQuietButtonStyle(size: .small)).fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .rowBox()
    }

    private func firstName(_ label: String) -> String { label.split(separator: " ").first.map(String.init) ?? label }

    /// Plays from the speaker's first turn: hear the voice, then name it.
    @ViewBuilder private func playButton(_ s: SpeakerRow) -> some View {
        let first = d.turns.first { $0.speakerID == s.id }
        Button { if let t = first { model.seek(safeInt(t.start)) } } label: { Image(systemName: "play.fill") }
            .buttonStyle(DroppyCircleButtonStyle(size: 20))
            .disabled(first == nil || d.summary.audioPath == nil)
            .accessibilityLabel("Play \(s.label)")
    }

    /// People first, then a new person, then this meeting only. Replaces the "This is…" menu and the Rename button.
    private func nameMenu(_ s: SpeakerRow) -> some View {
        Menu {
            ForEach(model.people) { p in Button(model.displayName(p)) { model.assignSpeaker(s, to: p) } }
            if !model.people.isEmpty { Divider() }
            Button("New person…") { startNaming(s, scope: .newPerson) }
            Button("This meeting only…") { startNaming(s, scope: .plain) }
        } label: { Text(s.personID == nil ? "Name" : "Rename").font(.system(size: 11, weight: .medium)) }
            .menuStyle(.button).buttonStyle(DroppyQuietButtonStyle(size: .small)).fixedSize()
            .accessibilityLabel("Name this speaker")
    }

    private func startNaming(_ s: SpeakerRow, scope: RenameScope) {
        draft = s.personID == nil && s.label.hasPrefix("Speaker") ? "" : s.label
        self.scope = scope; editing = s.id; model.requestKeyboard()
    }

    private func options(_ s: SpeakerRow) -> [(RenameScope, String)] {
        // An unnamed speaker is a new person by default, so naming them once sticks for every later meeting.
        if s.personID == nil { return [(.newPerson, "Save as a new person"), (.plain, "Rename in this meeting only")] }
        return [(.plain, "Rename this speaker"), (.samePerson, "Same person in all meetings"), (.newPerson, "Different person")]
    }

    private func save(_ s: SpeakerRow) { model.renameSpeaker(s, to: draft, scope: scope); editing = nil }
}

// MARK: Actions

private struct ActionsTab: View {
    @ObservedObject var model: LibraryModel
    let d: MeetingDetail

    var body: some View {
        if d.actions.isEmpty {
            Text("No action items.").font(.system(size: 12)).foregroundStyle(secondary)
        } else {
            ScrollView {
                VStack(spacing: DroppySpacing.xs) { ForEach(d.actions) { a in row(a) } }.droppyFlatGlassControls()
            }
        }
    }

    private func row(_ a: ActionRow) -> some View {
        HStack(alignment: .top, spacing: DroppySpacing.sm) {
            Button { model.setDone(a, done: !a.done) } label: {
                Image(systemName: a.done ? "checkmark.circle.fill" : "circle").font(.system(size: 15))
                    .foregroundStyle(a.done ? accent : secondary)
            }
            .buttonStyle(.plain).accessibilityLabel(a.done ? "Mark not done" : "Mark done")
            VStack(alignment: .leading, spacing: 1) {
                Text(a.task).font(.system(size: 12)).strikethrough(a.done).foregroundStyle(a.done ? tertiary : primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                let sub = ([a.owner, a.due].filter { !$0.isEmpty } + (a.exportedTo.map { ["in \(ExportTarget(rawValue: $0)?.title ?? $0)"] } ?? [])).joined(separator: " · ")
                if !sub.isEmpty { Text(sub).font(.system(size: 11)).foregroundStyle(tertiary) }
            }
            if let ti = a.turnIdx, let t = d.turns.first(where: { $0.idx == ti }) {
                Button(Timestamp.format(t.start)) { model.seek(safeInt(t.start)) }
                    .buttonStyle(.plain).font(.system(size: 11)).monospacedDigit().foregroundStyle(accent)
            }
            Menu {
                ForEach(ExportTarget.allCases, id: \.self) { tgt in
                    if tgt == .linear, a.exportedTo == ExportTarget.linear.rawValue {  // never a second issue: open the first
                        Button("Open \(a.externalID ?? "in Linear")") { model.export(a, to: tgt) }
                    } else {
                        Button("Add to \(tgt.title)") { model.export(a, to: tgt) }
                    }
                }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.button).buttonStyle(DroppyCircleButtonStyle(size: 20)).fixedSize().accessibilityLabel("More")
        }
        .rowBox()
    }
}
