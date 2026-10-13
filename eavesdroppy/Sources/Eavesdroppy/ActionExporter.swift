import Foundation

// Where action items go next. The library UI only knows this protocol: `RemindersExporter` and `LinearExporter`
// (Exporters.swift) are what `LibraryModel.exporter` runs. On success the model records the export through the
// `set-action-exported` subcommand, so an exporter just does its side and returns the target's id.

enum ExportTarget: String, CaseIterable {
    case reminders, linear

    var title: String { self == .reminders ? "Reminders" : "Linear" }
}

struct ExportItem {
    var action: ActionRow
    var meetingID: Int
    var meetingTitle: String
    var meetingStart: String
    /// The transcript line the action item cites, when it cites one.
    var turnText: String? = nil
}

/// What an exporter made: the id the library records, and where to look at it (Linear shows a link).
struct ExportOutcome {
    var externalID: String
    var url: URL? = nil
    var label: String? = nil
}

struct ExportUnavailable: Error, CustomStringConvertible {
    let target: ExportTarget
    var description: String { "Adding to \(target.title) isn't available yet" }
}

@MainActor protocol ActionExporter: AnyObject {
    /// Export one item. Call `done` exactly once on the main actor, with the target's id for the new item (Reminders
    /// calendar item identifier, Linear issue identifier) or the reason it failed.
    func export(_ item: ExportItem, to target: ExportTarget, done: @escaping (Result<ExportOutcome, Error>) -> Void)
}

/// The default until the real exporters land: does nothing, and says so.
@MainActor final class NoOpExporter: ActionExporter {
    func export(_ item: ExportItem, to target: ExportTarget, done: @escaping (Result<ExportOutcome, Error>) -> Void) {
        done(.failure(ExportUnavailable(target: target)))
    }
}
