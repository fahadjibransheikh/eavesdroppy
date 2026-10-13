import Foundation
import Security

/// API keys for the key-based providers. Same shape as `Keychain` in Linear.swift (generic password), but keyed by
/// vendor, because that helper is hard-wired to the Linear item. Keys never go in preferences.
enum ProviderKeychain {
    static let service = "app.eavesdroppy.notes-provider"

    private static func query(_ vendor: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: vendor]
    }

    /// Can prompt or stall: call off the main thread.
    static func read(_ vendor: String) -> String? {
        var q = query(vendor)
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    @discardableResult static func write(_ key: String, vendor: String) -> OSStatus {
        let data = Data(key.utf8)
        let status = SecItemUpdate(query(vendor) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status != errSecItemNotFound { return status }
        var add = query(vendor); add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil)
    }

    @discardableResult static func delete(_ vendor: String) -> OSStatus { SecItemDelete(query(vendor) as CFDictionary) }
}

/// Anthropic Messages, OpenAI Responses and xAI Responses, non-streaming, one user message, no tools.
/// Request shapes were checked against each vendor's docs on 2026-10-13 (see `Vendor`); none was exercised live
/// (no key was available in this environment).
struct APIKeyProvider: NotesProvider {
    enum Vendor: String, CaseIterable {
        case anthropic, openai, xai

        var title: String { switch self { case .anthropic: return "Anthropic"; case .openai: return "OpenAI"; case .xai: return "xAI" } }
        /// Default model ids; the model is a setting. Anthropic's is the one this app was specified with; the other two
        /// come from each vendor's models page (2026-10-13).
        var defaultModel: String { switch self { case .anthropic: return "claude-sonnet-5-5"; case .openai: return "gpt-6.1-sol"; case .xai: return "grok-4.7" } }
        var keyHint: String { switch self { case .anthropic: return "sk-ant-…"; case .openai: return "sk-…"; case .xai: return "xai-…" } }
        var endpoint: URL {
            switch self {
            case .anthropic: return URL(string: "https://api.anthropic.com/v1/messages")!
            case .openai: return URL(string: "https://api.openai.com/v1/responses")!
            case .xai: return URL(string: "https://api.x.ai/v1/responses")!
            }
        }
    }

    /// Anthropic requires max_tokens. 8192 holds long notes; the Messages API wants streaming only for much larger outputs.
    static let anthropicMaxTokens = 8192

    let vendor: Vendor
    var model: String = ""                       // empty = the vendor default
    var timeout: TimeInterval = 600
    var session: URLSession = .shared
    /// Where the key comes from; tests and env-based harnesses override it.
    var keyLookup: @Sendable (Vendor) -> String? = { ProviderKeychain.read($0.rawValue) }

    var id: String { "api" }
    var displayName: String { "\(vendor.title) API key" }
    var effectiveModel: String { let m = model.trimmingCharacters(in: .whitespacesAndNewlines); return m.isEmpty ? vendor.defaultModel : m }

    func isAvailable() async -> Bool { !(key ?? "").isEmpty }
    func availabilityDetail() async -> String { (key ?? "").isEmpty ? "No \(vendor.title) key saved" : "\(vendor.title) key saved · \(effectiveModel)" }
    private var key: String? { keyLookup(vendor)?.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: Request / response (pure, so tests can pin them)

    func request(prompt: String, key: String) throws -> URLRequest {
        var r = URLRequest(url: vendor.endpoint, timeoutInterval: timeout)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any]
        switch vendor {
        case .anthropic:
            r.setValue(key, forHTTPHeaderField: "x-api-key")
            r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = ["model": effectiveModel, "max_tokens": Self.anthropicMaxTokens, "messages": [["role": "user", "content": prompt]]]
        case .openai, .xai:
            r.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
            body = ["model": effectiveModel, "input": prompt, "store": false]  // a meeting is not something to keep server-side
        }
        r.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return r
    }

    /// Anthropic: `content[]` blocks of type "text". OpenAI and xAI Responses: `output[]` messages whose `content[]` parts have type "output_text".
    func text(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var parts: [String] = []
        switch vendor {
        case .anthropic:
            for b in obj["content"] as? [[String: Any]] ?? [] where b["type"] as? String == "text" { parts.append(b["text"] as? String ?? "") }
        case .openai, .xai:
            for item in obj["output"] as? [[String: Any]] ?? [] where item["type"] as? String == "message" {
                for c in item["content"] as? [[String: Any]] ?? [] where c["type"] as? String == "output_text" { parts.append(c["text"] as? String ?? "") }
            }
        }
        return parts.isEmpty ? nil : parts.joined()
    }

    static func errorMessage(from data: Data) -> String {
        if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let e = o["error"] as? [String: Any], let m = e["message"] as? String { return String(m.prefix(300)) }
            if let e = o["error"] as? String { return String(e.prefix(300)) }
        }
        return String((String(data: data, encoding: .utf8) ?? "").pyStripped.prefix(300))
    }

    func complete(prompt: String) async throws -> String {
        guard let key, !key.isEmpty else { throw NotesProviderError.notConfigured("No \(vendor.title) API key saved. Add one in Settings › Notes.") }
        let req = try request(prompt: prompt, key: key)
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch is CancellationError { throw NotesProviderError.cancelled }
        catch let e as URLError where e.code == .cancelled { throw NotesProviderError.cancelled }
        catch let e as URLError where e.code == .timedOut { throw NotesProviderError.timedOut(vendor.title, Int(timeout)) }
        catch { throw NotesProviderError.couldNotRun(vendor.title, error.localizedDescription) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw NotesProviderError.http(vendor.title, code, Self.errorMessage(from: data)) }
        guard let t = text(from: data) else { throw NotesProviderError.unreadable(vendor.title) }
        let out = t.pyStripped
        if out.isEmpty { throw NotesProviderError.empty(vendor.title) }
        return out
    }
}
