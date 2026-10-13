import DroppyKit
import Foundation
import SwiftUI

// D25: Settings › "AI tools" (MCP server). Wired in EavesdroppyDroplet.activate/deactivate and NotesPage:
//   1. EavesdroppyDroplet gets `let mcp = MCPServerModel()`.
//   2. In activate(host:), after `prefs.attach(host.preferences)` and `containerDir = ...`:
//        mcp.attach(MCPPrefs(enabled: { [prefs] in prefs.pref(MCPServerModel.Key.enabled, false) },
//                            setEnabled: { [prefs] in prefs.set(MCPServerModel.Key.enabled, $0) },
//                            port: { [prefs] in prefs.pref(MCPServerModel.Key.port, MCPServerModel.defaultPort) },
//                            setPort: { [prefs] in prefs.set(MCPServerModel.Key.port, $0) }),
//                   container: containerDir,
//                   userName: { [prefs] in prefs.userName },
//                   providerConfig: { [prefs] in NotesProviderConfig(read: { prefs.pref($0, "") }) },
//                   copy: { [weak self] in self?.host?.workspace.copyToPasteboard($0) ?? false })
//      attach() starts the server only if the (default OFF) preference is on.
//   3. In deactivate(): `mcp.stop()` (closes the listener and every connection, cancels running tool calls).
//   4. A section on a settings page (e.g. NotesPage, after the provider section): `MCPSettingsSection(model: mcp)`, and in
//      settingsSearchEntries: SettingsSearchEntry(title: "AI tools (MCP)", keywords: ["mcp", "claude code", "cursor", "server", "token", "localhost"]).
//   5. droplet.json: capabilities "network-server" (the listener) and "clipboard-write" (the Copy buttons).

/// The droplet's preferences for this feature, as closures so this file does not depend on `Prefs`.
struct MCPPrefs {
    var enabled: () -> Bool
    var setEnabled: (Bool) -> Void
    var port: () -> Int
    var setPort: (Int) -> Void
}

@MainActor final class MCPServerModel: ObservableObject {
    enum Key { static let enabled = "mcpEnabled", port = "mcpPort" }
    /// Fixed, not ephemeral: the address is copied into other tools' configuration and must survive a relaunch.
    static let defaultPort = 47615

    @Published private(set) var enabled = false
    @Published private(set) var running = false
    @Published private(set) var port = MCPServerModel.defaultPort
    @Published private(set) var token: String?
    @Published private(set) var message: String?
    @Published var showToken = false

    private var prefs: MCPPrefs?
    private var container: URL?
    private var userName: (@MainActor () -> String)?
    private var providerConfig: (@MainActor () -> NotesProviderConfig)?
    private(set) var copy: (String) -> Bool = { _ in false }
    /// Keychain account of the token; tests use their own so they never touch the real one.
    var tokenAccount = MCPToken.account
    private var listener: MCPListener?
    private let tokenBox = MCPTokenBox()
    private var generation = 0  // bumped by stop(): an in-flight start() that finishes later discards itself

    func attach(_ p: MCPPrefs, container: URL, userName: @escaping @MainActor () -> String,
                providerConfig: @escaping @MainActor () -> NotesProviderConfig, copy: @escaping (String) -> Bool) {
        prefs = p; self.container = container; self.userName = userName; self.providerConfig = providerConfig; self.copy = copy
        enabled = p.enabled(); port = p.port()
        if enabled { start() }
    }

    var url: String { "http://127.0.0.1:\(port)/mcp" }

    /// Verified against `claude mcp add --help` (2.x): options after the URL are fine; --header takes "Name: value".
    func addCommand(token: String) -> String {
        "claude mcp add --transport http eavesdroppy \(url) --header \"Authorization: Bearer \(token)\""
    }

    func setEnabled(_ on: Bool) {
        prefs?.setEnabled(on); enabled = on
        if on { start() } else { stop() }
    }

    func setPort(_ p: Int) {
        guard (1024...65535).contains(p), p != port else { return }
        prefs?.setPort(p); port = p
        if enabled { stop(); start() }
    }

    func start() {
        guard listener == nil, let container, let userName, let providerConfig else { return }
        generation += 1
        let gen = generation, port = UInt16(self.port)
        message = nil
        let server = MCPServer(
            container: container,
            userName: { await userName() },
            resolve: { await NotesProviders.resolve(await providerConfig()) })
        let handler = MCPHandler(server: server, token: tokenBox)
        let l = MCPListener(handler: handler)
        listener = l
        l.onFailure = { [weak self] e in Task { @MainActor in self?.failed("The server stopped: \(e.localizedDescription)") } }
        Task { [weak self, tokenBox, account = tokenAccount] in
            // Keychain can prompt or stall: off the main thread.
            let t = await Task.detached { MCPToken.loadOrCreate(account: account) }.value
            guard let t else { self?.fail(gen, l, "Couldn't read or create the access token in your Keychain."); return }
            tokenBox.value = t
            do {
                let bound = try await l.start(port: port)
                self?.started(gen, l, bound, t)
            } catch {
                self?.fail(gen, l, Self.bindMessage(error, port: Int(port)))
            }
        }
    }

    private func started(_ gen: Int, _ l: MCPListener, _ bound: UInt16, _ t: String) {
        guard gen == generation, listener === l else { l.stop(); return }
        running = true; token = t
    }

    private func fail(_ gen: Int, _ l: MCPListener, _ why: String) {
        guard gen == generation, listener === l else { return }
        l.stop(); listener = nil; running = false; message = why
    }

    private func failed(_ why: String) { running = false; message = why }

    private static func bindMessage(_ e: Error, port: Int) -> String {
        "Couldn't listen on port \(port): \(e.localizedDescription). Pick another port."
    }

    /// Closes the listener and every connection. Safe to call twice, and while a start is still in flight.
    func stop() {
        generation += 1
        listener?.stop(); listener = nil
        tokenBox.value = nil
        running = false; token = nil; showToken = false
    }

    /// New token: everything registered with the old one stops working at once.
    func regenerateToken() {
        Task { [weak self, tokenBox, account = tokenAccount] in
            let t = await Task.detached { MCPToken.regenerate(account: account) }.value
            guard let self else { return }
            guard let t else { self.message = "Couldn't save the new token to your Keychain."; return }
            if self.running { tokenBox.value = t; self.token = t }
        }
    }
}

struct MCPSettingsSection: View {
    @ObservedObject var model: MCPServerModel
    @State private var portDraft = ""
    @State private var copied: String?

    var body: some View {
        DropletSettingsSection {
            settingsSectionHeader("AI tools")
        } content: {
            DropletSettingsCard {
                DropletToggleRow(title: "Let other AI tools read your meetings",
                                 subtitle: "Runs a local server so Claude Code, Cursor and other MCP clients can search your notes, read transcripts, list action items and ask questions. Only this Mac can connect, and only with the access token below. Ask sends the matching excerpts to your AI provider.",
                                 isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) }))
                if model.enabled {
                    DropletControlRow(title: "Status") {
                        HStack(spacing: DroppySpacing.xs) {
                            Image(systemName: model.running ? "checkmark.circle.fill" : "circle.dashed")
                                .foregroundStyle(model.running ? Color.green : Color.secondary)
                            Text(verbatim: model.running ? "Running" : (model.message ?? "Starting…")).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    DropletControlRow(title: "Port", infoTip: "The address below uses this port. Change it only if something else is using it.") {
                        TextField("", text: $portDraft, prompt: Text(verbatim: "\(model.port)"))
                            .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 90)
                            .onSubmit { if let p = Int(portDraft) { model.setPort(p) }; portDraft = "" }
                    }
                }
            }
            if model.enabled, model.running, let token = model.token {
                DropletSettingsCard {
                    DropletControlRow(title: "Address") {
                        Text(verbatim: model.url).textSelection(.enabled).foregroundStyle(.secondary)
                    }
                    DropletControlRow(title: "Access token", infoTip: "Anyone with this token can read your meetings from this Mac. It is stored in your Keychain.") {
                        HStack(spacing: DroppySpacing.sm) {
                            Text(verbatim: model.showToken ? token : String(repeating: "•", count: 16)).textSelection(.enabled)
                                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Button(model.showToken ? "Hide" : "Show") { model.showToken.toggle() }
                            Button("Copy") { flash("token", model.copy(token)) }
                        }
                    }
                    DropletControlRow(title: "Add to Claude Code", infoTip: "Run this in a terminal. It contains the token, so don't share it.") {
                        Button(copied == "command" ? "Copied" : "Copy command") { flash("command", model.copy(model.addCommand(token: token))) }
                    }
                    DropletControlRow(title: "New token", infoTip: "Tools you already connected stop working until you add them again with the new token.") {
                        Button("Generate", role: .destructive) { model.regenerateToken() }
                    }
                }
            }
            if let m = model.message, model.enabled, model.running {
                DropletSettingsCard { DropletControlRow(title: m) { EmptyView() } }
            }
        }
    }

    private func flash(_ what: String, _ ok: Bool) {
        guard ok else { return }
        copied = what
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copied == what { copied = nil } }
    }
}
