import CryptoKit
import Foundation
import Security

/// The per-install bearer token (D25). Minted on first use, kept in the Keychain beside the AI-provider keys (reusing
/// `ProviderKeychain`; the account name says what it is), never in preferences.
enum MCPToken {
    static let account = "mcp-bearer-token"

    /// 32 random bytes from the system CSPRNG, hex: 256 bits.
    static func generate() -> String {
        var b = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, b.count, &b) == errSecSuccess else { fatalError("SecRandomCopyBytes failed") }
        return b.map { String(format: "%02x", $0) }.joined()
    }

    /// Can prompt or stall (Keychain): call off the main thread. nil if the Keychain refuses to store it.
    static func loadOrCreate(account: String = account) -> String? {
        if let t = ProviderKeychain.read(account), t.count >= 32 { return t }
        let t = generate()
        return ProviderKeychain.write(t, vendor: account) == errSecSuccess ? t : nil
    }

    /// Replaces the token (everything registered with the old one stops working). Off the main thread.
    static func regenerate(account: String = account) -> String? {
        let t = generate()
        return ProviderKeychain.write(t, vendor: account) == errSecSuccess ? t : nil
    }

    /// Constant-time: both sides are hashed to 32 bytes first, so neither the content nor the length of the real token
    /// shows in the timing, then the digests are compared without an early exit.
    static func equal(_ a: String, _ b: String) -> Bool {
        let x = Array(SHA256.hash(data: Data(a.utf8))), y = Array(SHA256.hash(data: Data(b.utf8)))
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    /// `Authorization: Bearer <token>` (scheme case-insensitive) -> the token.
    static func bearer(_ header: String?) -> String? {
        guard let h = header, h.count > 7, h.prefix(7).lowercased() == "bearer " else { return nil }
        return String(h.dropFirst(7)).trimmingCharacters(in: .whitespaces)
    }
}

/// The live token, readable from the listener's queue and replaceable from Settings without restarting the server.
final class MCPTokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    init(_ t: String? = nil) { token = t }
    var value: String? { get { lock.lock(); defer { lock.unlock() }; return token } set { lock.lock(); token = newValue; lock.unlock() } }
}
