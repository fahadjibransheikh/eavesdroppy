import DroppyKit
import Foundation
import Security
import SwiftUI

// D24: Settings › Notes › "AI provider". Wiring (done at cut-over, not here), in SettingsPages.swift:
//   1. EavesdroppyDroplet gets `let providerSettings = ProviderSettingsModel()`; where prefs are attached (`prefs.attach(store)`),
//      call `providerSettings.attach(ProviderPrefs(get: { prefs.pref($0, "") }, set: { prefs.set($0, $1) }))`.
//   2. NotesPage takes `droplet.providerSettings` and adds `ProviderSettingsSection(model: providerSettings)` after the template card.
//   3. settingsSearchEntries gets: SettingsSearchEntry(title: "AI provider", keywords: ["claude", "codex", "grok", "apple intelligence", "api key", "openai", "anthropic", "xai", "model"]).

/// The droplet's string preferences, as two closures so this file doesn't depend on `Prefs` (and tests can fake it).
struct ProviderPrefs {
    var get: (String) -> String
    var set: (String, String) -> Void
}

/// State behind the picker. Detection and Keychain calls run off the main thread (the Keychain can prompt or stall).
@MainActor final class ProviderSettingsModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        let id: String
        let name: String
        var available: Bool?   // nil until detection has answered
        var detail: String
    }

    @Published private(set) var config = NotesProviderConfig()
    @Published private(set) var rows: [Row] = NotesProviders.order.map { Row(id: $0, name: ProviderSettingsModel.name($0), available: nil, detail: "") }
    @Published private(set) var message: String?
    private var store: ProviderPrefs?
    private let queue = DispatchQueue(label: "eavesdroppy.providers", qos: .userInitiated)

    nonisolated static func name(_ id: String) -> String {
        switch id {
        case "claude-code": return "Claude Code"
        case "codex": return "OpenAI Codex"
        case "grok": return "Grok Build"
        case "apple": return "Apple Intelligence"
        default: return "API key"
        }
    }

    func attach(_ s: ProviderPrefs) { store = s; config = NotesProviderConfig(read: s.get); refresh() }

    func setChoice(_ id: String) { store?.set(NotesProviderConfig.Key.choice, id); config.choice = id }
    func setVendor(_ v: APIKeyProvider.Vendor) { store?.set(NotesProviderConfig.Key.vendor, v.rawValue); config.vendor = v; refresh() }
    func setModel(_ m: String) {
        store?.set(NotesProviderConfig.Key.model(config.vendor), m); config.models[config.vendor.rawValue] = m
    }

    /// Re-runs detection for every provider. Cheap: path checks, one Keychain read, one availability query.
    func refresh() {
        let cfg = config
        Task.detached(priority: .userInitiated) {
            var out: [Row] = []
            for id in NotesProviders.order {
                guard let p = NotesProviders.make(id, config: cfg) else { continue }
                let ok = await p.isAvailable()
                var detail = await p.availabilityDetail()
                if id == "api" { detail = cfg.vendor.title + " · " + detail }
                out.append(Row(id: id, name: Self.name(id), available: ok, detail: detail))
            }
            let rows = out
            await MainActor.run { self.rows = rows }
        }
    }

    func saveKey(_ key: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines), v = config.vendor
        guard !k.isEmpty else { return }
        queue.async {
            let st = ProviderKeychain.write(k, vendor: v.rawValue)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.message = st == errSecSuccess ? "Saved to your Keychain" : "Couldn't save to the Keychain (error \(st))"
                    self.refresh()
                }
            }
        }
    }

    func removeKey() {
        let v = config.vendor
        queue.async {
            ProviderKeychain.delete(v.rawValue)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.message = "Removed"; self.refresh() } }
        }
    }

    var hasKey: Bool { rows.first { $0.id == "api" }?.available == true }
}

/// A section for the Notes page: the picker, what was found, and the API-key fields.
struct ProviderSettingsSection: View {
    @ObservedObject var model: ProviderSettingsModel
    @State private var keyDraft = ""

    var body: some View {
        DropletSettingsSection {
            settingsSectionHeader("AI provider")
        } content: {
            DropletSettingsCard {
                DropletGroupedPickerRow(title: "Write notes with",
                                        subtitle: "Used for notes and for Ask. Automatic picks the first one found, in this order. If none is available, meetings are saved with their transcript only.") {
                    Picker("", selection: Binding(get: { model.config.choice }, set: { model.setChoice($0) })) {
                        Text("Automatic").tag("auto")
                        ForEach(model.rows) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden().pickerStyle(.menu)
                }
                ForEach(model.rows) { row in
                    DropletControlRow(title: row.name) {
                        HStack(spacing: DroppySpacing.xs) {
                            Image(systemName: row.available == true ? "checkmark.circle.fill" : "circle.dashed")
                                .foregroundStyle(row.available == true ? Color.green : Color.secondary)
                            Text(verbatim: row.available == nil ? "Checking…" : row.detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
            }
            DropletSettingsCard {
                DropletGroupedPickerRow(title: "API provider", subtitle: "Used when \"API key\" is chosen above.") {
                    Picker("", selection: Binding(get: { model.config.vendor }, set: { model.setVendor($0) })) {
                        ForEach(APIKeyProvider.Vendor.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu)
                }
                DropletControlRow(title: "API key", infoTip: "Stored in your Keychain, never in preferences. Notes and Ask send the meeting text to this provider.") {
                    HStack(spacing: DroppySpacing.sm) {
                        SecureField("", text: $keyDraft, prompt: Text(model.hasKey ? "Saved in Keychain" : model.config.vendor.keyHint))
                            .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 180)
                        Button("Save") { model.saveKey(keyDraft); keyDraft = "" }
                            .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        if model.hasKey { Button("Remove", role: .destructive) { model.removeKey() } }
                    }
                }
                DropletControlRow(title: "Model", infoTip: "Leave empty for the default.") {
                    TextField("", text: Binding(get: { model.config.model }, set: { model.setModel($0) }),
                              prompt: Text(model.config.vendor.defaultModel))
                        .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 200)
                }
                if let m = model.message { DropletControlRow(title: m) { EmptyView() } }
            }
        }
        .onAppear { model.refresh() }
    }
}
