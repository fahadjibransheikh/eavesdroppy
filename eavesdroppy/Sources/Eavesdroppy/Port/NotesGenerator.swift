import Foundation

/// notes.generate_notes and notes.ask on top of a `NotesProvider`: build the prompt, run it, parse the reply.
/// The failure placeholders are Python's, word for word, because the library stores and shows them.
struct NotesMeeting {
    var header: String
    var turns: [NoteTurn]
    var userNotes = ""
    var template: String?
}

struct NotesOutcome: Equatable {
    enum Status: String { case ok, failed, none }  // library summary_status
    var notesMD: String
    var actions: [NoteAction]
    var error: String?
    var status: Status
}

enum NotesGenerator {
    /// Throws only for a bad template / empty custom text (Python's ValueError -> Fail) and for cancellation.
    /// A provider failure is an outcome with status `.failed`; no provider is an outcome with status `.none`.
    static func generate(meeting m: NotesMeeting, template: String? = nil, customText: String? = nil, namesHint: [String] = [],
                         userName: String, resolution: NotesProviders.Resolution) async throws -> NotesOutcome {
        if m.turns.isEmpty { return NotesOutcome(notesMD: "## Summary\n\n_No speech detected._", actions: [], error: nil, status: .ok) }
        let tpl = [template, m.template].compactMap { $0 }.first { !$0.isEmpty } ?? "general"
        let prompt = try NotesPrompt.buildNotesPrompt(header: m.header, turns: m.turns, userNotes: m.userNotes, template: tpl,
                                                      namesHint: namesHint, customText: customText, userName: userName)
        switch resolution {
        case .none(let status):
            return NotesOutcome(notesMD: "## Summary\n\n_\(status)_", actions: [], error: status, status: .none)
        case .provider(let p):
            do {
                let text = try await p.complete(prompt: prompt)
                let r = NotesPrompt.parseNotes(text, turns: m.turns)
                return NotesOutcome(notesMD: r.notes, actions: r.actions, error: nil, status: .ok)
            } catch NotesProviderError.cancelled { throw CancellationError() }
            catch {
                let why = error.localizedDescription
                return NotesOutcome(notesMD: "## Summary\n\n_Summary failed: \(why). Use Regenerate to retry._", actions: [], error: why, status: .failed)
            }
        }
    }

    enum AskError: Error, LocalizedError, Equatable {
        case emptyQuestion
        case noProvider(String)
        var errorDescription: String? {
            switch self { case .emptyQuestion: return "empty question"; case .noProvider(let s): return s }
        }
    }

    /// notes.ask minus retrieval (the library area runs the FTS query and passes its segments and notes in).
    static func ask(question: String, segments: [NotesPrompt.AskSegment], notes: [NotesPrompt.AskNote], userName: String,
                    resolution: NotesProviders.Resolution) async throws -> String {
        if question.pyStripped.isEmpty { throw AskError.emptyQuestion }
        guard case .provider(let p) = resolution else {
            if case .none(let s) = resolution { throw AskError.noProvider(s) }
            throw AskError.noProvider(NotesProviders.noProviderStatus)
        }
        do { return try await p.complete(prompt: NotesPrompt.buildAskPrompt(question: question, segments: segments, notes: notes, userName: userName)) }
        catch NotesProviderError.cancelled { throw CancellationError() }
    }
}
