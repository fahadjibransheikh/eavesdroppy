import Foundation
import Security

/// The Linear API key (D16) lives only here, never in preferences. Generic password, service "app.eavesdroppy.linear".
enum Keychain {
    static let service = "app.eavesdroppy.linear"
    private static let account = "api-key"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// Adds or replaces. Returns the OSStatus on failure.
    @discardableResult static func write(_ key: String) -> OSStatus {
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status != errSecItemNotFound { return status }
        var add = query; add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil)
    }

    @discardableResult static func delete() -> OSStatus { SecItemDelete(query as CFDictionary) }
}

struct LinearTeam: Identifiable, Hashable { let id: String; let name: String; let key: String }

/// A Linear export waiting on the user: the surface shows the teams, `resolve` takes the pick (nil = cancel) and
/// whether to remember it as the default.
struct TeamPick {
    let teams: [LinearTeam]
    let resolve: (LinearTeam?, Bool) -> Void
}

/// State behind the Output page's Linear rows. Keychain calls and `linear-teams` run off the main thread; the key
/// goes into the environment of that one command and nowhere else.
@MainActor final class LinearSettings: ObservableObject {
    enum Teams: Equatable { case idle, loading, loaded([LinearTeam]), failed(String) }

    @Published private(set) var hasKey: Bool?   // nil until the Keychain has answered
    @Published private(set) var teams: Teams = .idle
    @Published private(set) var message: String?
    private let queue = DispatchQueue(label: "eavesdroppy.keychain", qos: .userInitiated)

    func refresh() {
        queue.async {
            let has = Keychain.read() != nil
            DispatchQueue.main.async { MainActor.assumeIsolated { self.hasKey = has } }
        }
    }

    func save(_ key: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        queue.async {
            let st = Keychain.write(k)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.hasKey = st == errSecSuccess ? true : self.hasKey
                    self.message = st == errSecSuccess ? "Saved to your Keychain" : "Couldn't save to the Keychain (error \(st))"
                    self.teams = .idle
                }
            }
        }
    }

    func remove() {
        queue.async {
            Keychain.delete()
            DispatchQueue.main.async { MainActor.assumeIsolated { self.hasKey = false; self.teams = .idle; self.message = "Removed" } }
        }
    }

    func loadTeams() {
        guard teams != .loading else { return }
        teams = .loading; message = nil
        let ep = currentEpoch()
        queue.async {
            guard let key = Keychain.read() else {
                DispatchQueue.main.async { MainActor.assumeIsolated { self.teams = .failed("Save your Linear API key first") } }
                return
            }
            let r = Pipeline.run(["linear-teams"], env: ["EAVESDROPPY_LINEAR_KEY": key], epoch: ep)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard ep == currentEpoch() else { return }
                    switch r {
                    case .success(let j):
                        let list = (j["teams"] as? [[String: Any]] ?? []).compactMap { t -> LinearTeam? in
                            guard let id = t["id"] as? String, let name = t["name"] as? String else { return nil }
                            return LinearTeam(id: id, name: name, key: t["key"] as? String ?? "")
                        }
                        self.teams = list.isEmpty ? .failed("This key can't see any teams") : .loaded(list)
                    case .failure(let e): self.teams = .failed(e.description)
                    }
                }
            }
        }
    }
}
