import DroppyKit
import SwiftUI

/// Template ids are the pipeline's (notes.py); names are what the pickers show.
enum NoteTemplate {
    static let all: [(id: String, name: String)] = [("general", "General"), ("one_on_one", "1:1"), ("standup", "Standup"),
                                                    ("sales", "Sales"), ("interview", "Interview"), ("custom", "Custom")]
    static func name(_ id: String) -> String { all.first { $0.id == id }?.name ?? id.capitalized }
}

/// Typed access to the droplet's preferences (D19). Everything goes through host.preferences, so keys are namespaced
/// to this droplet. Settings the pipeline needs travel in meta.json (D-contract): `metaExtras` is mirrored into
/// Support.swift's snapshot on every change, because meta.json is written from background queues.
@MainActor final class Prefs: ObservableObject {
    private var store: (any DropletPreferencesService)?
    /// Called after any change (the droplet re-reads what depends on prefs: widget height, meta snapshot).
    var onChange: () -> Void = {}

    func attach(_ store: any DropletPreferencesService) { self.store = store; sync() }
    func detach() { store = nil }

    func pref<T: Codable>(_ key: String, _ fallback: T) -> T { store?.value(forKey: key, default: fallback) ?? fallback }

    func set<T: Codable>(_ key: String, _ value: T) {
        store?.setValue(value, forKey: key)
        objectWillChange.send(); sync(); onChange()
    }

    func binding<T: Codable>(_ key: String, _ fallback: T) -> Binding<T> {
        Binding(get: { self.pref(key, fallback) }, set: { self.set(key, $0) })
    }

    // Recording
    var echoRemoval: Bool { pref(Key.echoRemoval, true) }
    var consentLine: Bool { pref(Key.consentLine, true) }
    var autoStop: Bool { pref(Key.autoStop, true) }
    var micPrompt: Bool { pref(Key.micPrompt, true) }
    // Speakers
    var autoNaming: Bool { pref(Key.voiceprintNaming, true) }
    var participantNames: Bool { pref(Key.participantNames, false) }
    var userName: String { let n = pref(Key.userName, "Me").trimmingCharacters(in: .whitespacesAndNewlines); return n.isEmpty ? "Me" : n }
    // Notes
    var defaultTemplate: String { pref(Key.defaultTemplate, "general") }
    var customTemplate: String { pref(Key.customTemplate, "") }
    // Calendar. Off until the user turns it on: turning it on is what asks for Calendar access.
    var calendarPrompt: Bool { pref(Key.calendarPrompt, false) }
    var calendarAutoStart: Bool { pref(Key.calendarAutoStart, false) }
    // Output
    var remindersList: String { let n = pref(Key.remindersList, "Eavesdroppy").trimmingCharacters(in: .whitespacesAndNewlines); return n.isEmpty ? "Eavesdroppy" : n }
    var linearTeamID: String { pref(Key.linearTeamID, "") }
    // Storage
    var retentionDays: Int { pref(Key.retentionDays, 0) }   // 0 = keep forever
    /// D26: where meeting folders are written. Empty = automatic (this Mac's Drive folder if it is there, else ~/Documents/Eavesdroppy).
    var outputFolder: String { pref(Key.outputFolder, "") }
    #if EAVESDROPPY_PERSONAL
    /// Personal build only: route every command through process_meeting.py instead of the in-process pipeline.
    var usePython: Bool { pref(Key.usePython, false) }
    #endif

    enum Key {
        static let echoRemoval = "echoRemoval", consentLine = "consentLine", autoStop = "autoStop"
        static let userName = "userName", voiceprintNaming = "voiceprintNaming"
        static let defaultTemplate = "defaultTemplate", customTemplate = "customTemplate"
        static let calendarPrompt = "calendarPrompt", calendarAutoStart = "calendarAutoStart"
        static let micPrompt = "micPrompt", participantNames = "participantNames"
        static let remindersList = "remindersList", linearTeamID = "linearTeamID", linearTeamName = "linearTeamName"
        static let retentionDays = "retentionDays", lastExpire = "lastExpire", outputFolder = "outputFolder", usePython = "usePythonPipeline"
    }

    /// meta.json keys the pipeline reads (contract: echo_removal, template, retention_days, auto_naming, user_name).
    var metaExtras: [String: Any] {
        var m: [String: Any] = ["echo_removal": echoRemoval, "template": defaultTemplate, "retention_days": retentionDays,
                                "auto_naming": autoNaming, "user_name": userName]  // "Your name": the pipeline writes it into prompts and naming
        if defaultTemplate == "custom" {
            m["custom_template_file"] = Self.customTemplateFile.path
            m["custom_template"] = customTemplate  // process_meeting.py reads the inline text, not the file (integration check, 2026-10-12)
        }
        return m
    }

    private func sync() {
        setMetaExtras(metaExtras)
        setOutputFolderSetting(outputFolder)
        NativeConfig.provider = NotesProviderConfig(read: { self.pref($0, "") })   // notes, Ask and naming read it from any thread
        #if EAVESDROPPY_PERSONAL
        Pipeline.usePython = usePython
        #endif
    }

    // The custom template text lives in prefs; the pipeline reads it from a file (`regenerate --custom-text-file`).
    nonisolated static var customTemplateFile: URL { containerDir.appendingPathComponent("custom_template.txt") }
    private static let writeQueue = DispatchQueue(label: "eavesdroppy.prefs.write", qos: .utility)

    /// Atomic, off the main thread. Safe to call as often as the text changes.
    func writeCustomTemplateFile() {
        let text = customTemplate, url = Self.customTemplateFile
        Self.writeQueue.async {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url, options: .atomic)
            } catch { log("ERROR writing custom template: \(error)") }
        }
    }
}
