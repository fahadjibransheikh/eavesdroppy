import Foundation

/// What the Settings picker stores (preference keys are plain strings, so the pipeline side never needs this type).
struct NotesProviderConfig: Equatable {
    var choice = "auto"                                  // "auto" or a provider id
    var vendor = APIKeyProvider.Vendor.anthropic
    var models: [String: String] = [:]                   // vendor raw value -> model id; empty = vendor default

    enum Key {
        static let choice = "notesProvider", vendor = "notesAPIVendor"
        static func model(_ v: APIKeyProvider.Vendor) -> String { "notesModel.\(v.rawValue)" }
    }

    /// Reads from any string store (Prefs in the droplet, a dictionary in tests).
    init(read: (String) -> String) {
        let c = read(Key.choice); if !c.isEmpty { choice = c }
        vendor = APIKeyProvider.Vendor(rawValue: read(Key.vendor)) ?? .anthropic
        for v in APIKeyProvider.Vendor.allCases { models[v.rawValue] = read(Key.model(v)) }
    }
    init() {}

    var model: String { models[vendor.rawValue] ?? "" }
}

enum NotesProviders {
    /// D24 order: the CLIs first (a subscription the user already pays for), then on-device, then a key.
    static let order = ["claude-code", "codex", "grok", "apple", "api"]

    static let noProviderStatus = "No AI provider is set up, so this meeting was saved with its transcript only. Choose one in Settings › Notes, then Regenerate."

    static func make(_ id: String, config: NotesProviderConfig = NotesProviderConfig(),
                     keyLookup: (@Sendable (APIKeyProvider.Vendor) -> String?)? = nil) -> (any NotesProvider)? {
        switch id {
        case "claude-code": return CLIProvider(kind: .claude)
        case "codex": return CLIProvider(kind: .codex)
        case "grok": return CLIProvider(kind: .grok)
        case "apple": return AppleIntelligenceProvider()
        case "api":
            var p = APIKeyProvider(vendor: config.vendor, model: config.model)
            if let k = keyLookup { p.keyLookup = k }
            return p
        default: return nil
        }
    }

    static func all(config: NotesProviderConfig = NotesProviderConfig()) -> [any NotesProvider] { order.compactMap { make($0, config: config) } }

    enum Resolution {
        case provider(any NotesProvider)
        case none(status: String)
    }

    /// "auto" = the first available in D24 order. A named provider that isn't available does not fall through to another one:
    /// the user chose it, and silently sending a meeting to a different service would be wrong.
    static func resolve(_ config: NotesProviderConfig, providers: [any NotesProvider]? = nil) async -> Resolution {
        let list = providers ?? all(config: config)
        if config.choice == "auto" {
            for p in list where await p.isAvailable() { return .provider(p) }
            return .none(status: noProviderStatus)
        }
        guard let p = list.first(where: { $0.id == config.choice }) else { return .none(status: noProviderStatus) }
        if await p.isAvailable() { return .provider(p) }
        let why = await p.availabilityDetail()
        return .none(status: "\(p.displayName) is selected in Settings › Notes but isn't available" + (why.isEmpty ? "." : ": \(why).")
                     + " This meeting was saved with its transcript only.")
    }
}
