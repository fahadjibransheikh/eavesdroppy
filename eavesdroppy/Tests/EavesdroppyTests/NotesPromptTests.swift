import Foundation
import Testing
@testable import Eavesdroppy

/// Golden tests: Python's notes.py (via tools/golden/notes_cases.py) is the oracle.
private struct Golden: Decodable {
    struct Turn: Decodable { let idx: Int; let speaker: String?; let start: Double; let text: String? }
    struct Prompt: Decodable {
        let name: String; let header: String; let turns: [Turn]; let user_notes: String; let template: String
        let names_hint: [String]; let custom_text: String?; let user_name: String; let expected: String
    }
    struct PromptError: Decodable { let name: String; let template: String; let custom_text: String?; let message: String }
    struct Action: Decodable { let owner: String; let task: String; let due: String; let done: Int; let turn_idx: Int? }
    struct Parse: Decodable { let name: String; let markdown: String; let turns: [Turn]; let expected_notes: String; let expected_actions: [Action] }
    struct TurnAt: Decodable { let ts: String?; let seconds: Double?; let turns_empty: Bool?; let expected: Int? }
    struct Seg: Decodable { let title: String; let date: String; let ts: String; let speaker: String; let text: String }
    struct Note: Decodable { let title: String; let date: String; let notes: String }
    struct Ask: Decodable { let name: String; let question: String; let segments: [Seg]; let notes: [Note]; let user_name: String; let expected: String }
    struct Fmt: Decodable { let sec: Double; let expected: String }
    let prompt: [Prompt]; let prompt_errors: [PromptError]; let parse: [Parse]; let turn_at: [TurnAt]; let ask: [Ask]; let fmt_ts: [Fmt]
}

private let golden: Golden = {
    let url = Bundle.module.url(forResource: "notes_golden", withExtension: "json", subdirectory: "Fixtures/notes")!
    return try! JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
}()

private func turns(_ g: [Golden.Turn]) -> [NoteTurn] { g.map { NoteTurn(idx: $0.idx, speaker: $0.speaker ?? "", start: $0.start, text: $0.text ?? "") } }

@Test func notesPromptsAreByteIdenticalToPython() throws {
    #expect(golden.prompt.count >= 12)
    for c in golden.prompt {
        let got = try NotesPrompt.buildNotesPrompt(header: c.header, turns: turns(c.turns), userNotes: c.user_notes, template: c.template,
                                                   namesHint: c.names_hint, customText: c.custom_text, userName: c.user_name)
        #expect(got == c.expected, "prompt case \(c.name)")
    }
}

@Test func promptErrorsMatchPythonMessages() {
    for c in golden.prompt_errors {
        do {
            _ = try NotesPrompt.buildNotesPrompt(header: "h", turns: [], template: c.template, customText: c.custom_text, userName: "x")
            Issue.record("\(c.name): expected a throw")
        } catch { #expect(error.localizedDescription == c.message, "\(c.name)") }
    }
}

@Test func parseNotesMatchesPython() {
    for c in golden.parse {
        let r = NotesPrompt.parseNotes(c.markdown, turns: turns(c.turns))
        #expect(r.notes == c.expected_notes, "notes of \(c.name)")
        let want = c.expected_actions.map { NoteAction(owner: $0.owner, task: $0.task, due: $0.due, done: $0.done, turnIdx: $0.turn_idx) }
        #expect(r.actions == want, "actions of \(c.name)")
    }
}

@Test func turnAtMatchesPython() {
    let t = [NoteTurn(idx: 0, speaker: "", start: 1, text: ""), NoteTurn(idx: 1, speaker: "", start: 75, text: ""),
             NoteTurn(idx: 3, speaker: "", start: 3600, text: ""), NoteTurn(idx: 4, speaker: "", start: 3725.9, text: ""),
             NoteTurn(idx: 7, speaker: "", start: 59.99, text: "")]
    for c in golden.turn_at {
        let tt = c.turns_empty == true ? [] : t
        let got = c.ts.map { NotesPrompt.turnAt(tt, timestamp: $0) } ?? NotesPrompt.turnAt(tt, seconds: c.seconds!)
        #expect(got == c.expected, "turn_at \(c.ts ?? String(c.seconds ?? -1))")
    }
}

@Test func askPromptsAreByteIdenticalToPython() {
    for c in golden.ask {
        let got = NotesPrompt.buildAskPrompt(question: c.question, segments: c.segments.map { .init(title: $0.title, date: $0.date, ts: $0.ts, speaker: $0.speaker, text: $0.text) },
                                             notes: c.notes.map { .init(title: $0.title, date: $0.date, notes: $0.notes) }, userName: c.user_name)
        #expect(got == c.expected, "ask case \(c.name)")
    }
}

@Test func timestampFormattingMatchesPython() {
    for c in golden.fmt_ts { #expect(notesFormatTimestamp(c.sec) == c.expected, "fmt_ts \(c.sec)") }
}
