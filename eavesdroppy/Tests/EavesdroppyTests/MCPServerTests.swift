import Foundation
import SQLite3
import Testing
@testable import Eavesdroppy

// The JSON-RPC layer and the four tools against what mcp_server.py answered for the same messages on the same database
// (tools/golden/mcp_golden.py -> Fixtures/mcp/golden.json), plus the failure paths the golden file cannot hold.

/// The model call, replaced: Ask's answer is the prompt it was given, so the prompt text is compared too.
struct MCPEchoProvider: NotesProvider {
    var id: String { "echo" }
    var displayName: String { "Echo" }
    var delay: TimeInterval = 0
    var onCancel: (@Sendable () -> Void)?
    func isAvailable() async -> Bool { true }
    func complete(prompt: String) async throws -> String {
        if delay > 0 {
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) } catch { onCancel?(); throw NotesProviderError.cancelled }
        }
        if prompt.contains("FAIL please") { throw NotesProviderError.notConfigured("claude exited 1: boom") }
        return prompt
    }
}

/// A fresh container holding a copy of the store seed database as library.db.
func mcpSeedContainer() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let seed = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/store/seed.db")
    try FileManager.default.copyItem(at: seed, to: dir.appendingPathComponent("library.db"))
    return dir
}

func mcpServer(_ container: URL, provider: MCPEchoProvider = MCPEchoProvider(), userName: String = "Pat") -> MCPServer {
    MCPServer(container: container, userName: { userName }, resolve: { .provider(provider) })
}

/// Normalises through JSON text so Swift and Python numbers, nulls and key order compare the way a client sees them.
private func canonical(_ o: Any?) -> NSObject {
    guard let o else { return NSNull() }
    let data = try! JSONSerialization.data(withJSONObject: [o], options: [])
    return (try! JSONSerialization.jsonObject(with: data) as! [Any])[0] as! NSObject
}

private func text(_ r: [String: Any]?) -> String {
    ((((r?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first)?["text"] as? String) ?? ""
}
private func isError(_ r: [String: Any]?) -> Bool { ((r?["result"] as? [String: Any])?["isError"] as? Bool) ?? false }
private func call(_ name: String, _ args: [String: Any]) -> [String: Any] {
    ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": args]]
}

@Test func responsesMatchPythonMcpServer() async throws {
    let url = try #require(Bundle.module.url(forResource: "golden", withExtension: "json", subdirectory: "Fixtures/mcp"))
    let golden = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let cases = try #require(golden["cases"] as? [[String: Any]])
    #expect(cases.count >= 80)
    let server = mcpServer(try mcpSeedContainer(), userName: golden["userName"] as? String ?? "")
    var failures: [String] = []
    for c in cases {
        let name = c["name"] as? String ?? "?"
        let got = canonical(try await server.handle(c["request"] as Any))
        let want = canonical(c["response"])
        if !got.isEqual(want) {
            failures.append("\(name)\n  python: \(String(data: try JSONSerialization.data(withJSONObject: [c["response"] as Any], options: [.sortedKeys]), encoding: .utf8)!)\n"
                            + "  swift:  \(String(data: try JSONSerialization.data(withJSONObject: [got], options: [.sortedKeys]), encoding: .utf8)!)")
        }
    }
    if !failures.isEmpty { Issue.record(Comment(rawValue: "\(failures.count) of \(cases.count) differ:\n" + failures.joined(separator: "\n"))) }
}

// MARK: failure paths

@Test func missingLibraryIsAToolErrorAndNeverCreatesTheFile() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-empty-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let server = mcpServer(dir)
    for (name, args) in [("search_meetings", [String: Any]()), ("get_meeting", ["id": 1]), ("list_action_items", [:]), ("ask", ["question": "budget"])] as [(String, [String: Any])] {
        let r = try await server.handle(call(name, args))
        #expect(isError(r), "\(name)")
        #expect(text(r).hasPrefix("cannot open library at "), "\(name): \(text(r))")
    }
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("library.db").path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
}

@Test func aLibraryOfAnotherSchemaVersionIsLeftUntouchedAndReported() async throws {
    for name in ["v3", "v1", "newer"] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = dir.appendingPathComponent("library.db")
        try FileManager.default.copyItem(at: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/store/\(name).db"), to: db)
        let before = try Data(contentsOf: db)
        let server = mcpServer(dir)
        for (tool, args) in [("list_action_items", [String: Any]()), ("ask", ["question": "budget"])] as [(String, [String: Any])] {
            let r = try await server.handle(call(tool, args))
            #expect(isError(r), "\(name) \(tool)")
            #expect(text(r).contains("library.db is schema v") && text(r).contains("reads v\(StoreSchema.migrations.count)"), "\(name) \(tool): \(text(r))")
        }
        #expect(try Data(contentsOf: db) == before, "\(name).db was modified")
        let user = try StoreDBVersion.of(db)
        #expect(user != StoreSchema.migrations.count, "\(name).db was migrated to \(user)")
    }
}

/// PRAGMA user_version straight from the file with raw SQLite, read-only.
enum StoreDBVersion {
    static func of(_ url: URL) throws -> Int {
        var h: OpaquePointer?, st: OpaquePointer?
        guard sqlite3_open_v2(url.path, &h, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw StoreError("cannot open \(url.path)") }
        defer { sqlite3_close(h) }
        guard sqlite3_prepare_v2(h, "PRAGMA user_version", -1, &st, nil) == SQLITE_OK, sqlite3_step(st) == SQLITE_ROW else { throw StoreError("no user_version") }
        defer { sqlite3_finalize(st) }
        return Int(sqlite3_column_int(st, 0))
    }
}

@Test func askWithoutAProviderSaysSo() async throws {
    let server = MCPServer(container: try mcpSeedContainer(), userName: { "Pat" }, resolve: { .none(status: NotesProviders.noProviderStatus) })
    let r = try await server.handle(call("ask", ["question": "budget"]))
    #expect(isError(r))
    #expect(text(r) == NotesProviders.noProviderStatus)
}

@Test func askStopsAfterItsTimeout() async throws {
    let server = mcpServer(try mcpSeedContainer(), provider: MCPEchoProvider(delay: 300))
    server.askTimeout = 1
    let t0 = Date()
    let r = try await server.handle(call("ask", ["question": "budget"]))
    #expect(isError(r))
    #expect(text(r) == "ask timed out after 1 s", "\(text(r))")
    #expect(Date().timeIntervalSince(t0) < 60)  // the model call would have run 300 s; the margin is for a loaded machine
}

@Test func cancellingTheRequestCancelsTheModelCall() async throws {
    let cancelled = MCPFlag()
    let server = mcpServer(try mcpSeedContainer(), provider: MCPEchoProvider(delay: 30, onCancel: { cancelled.set() }))
    let task = Task { try await server.handle(call("ask", ["question": "budget"])) }
    try await Task.sleep(nanoseconds: 300_000_000)
    task.cancel()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(cancelled.isSet)
}

final class MCPFlag: @unchecked Sendable {
    private let lock = NSLock(); private var v = false
    func set() { lock.lock(); v = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return v }
}

@Test func toolsAreReadOnlyAndTheDatabaseIsNotChanged() async throws {
    let dir = try mcpSeedContainer()
    let db = dir.appendingPathComponent("library.db")
    let before = try Data(contentsOf: db)
    let server = mcpServer(dir)
    for (n, a) in [("search_meetings", ["query": "budget"]), ("get_meeting", ["id": 1]), ("list_action_items", [:]), ("ask", ["question": "budget"])] as [(String, [String: Any])] {
        _ = try await server.handle(call(n, a))
    }
    // WAL side files may appear; the main file must be byte-identical (no migration, no write).
    #expect(try Data(contentsOf: db) == before)
    let tools = MCPServer.tools
    #expect(tools.map { $0["name"] as? String } == ["search_meetings", "get_meeting", "list_action_items", "ask"])
    #expect(tools.allSatisfy { ($0["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true })
}

@Test func jsonIntegerRulesMatchPython() throws {
    func first(_ json: String) throws -> Any { (try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [Any])[0] }
    #expect(MCPServer.int(try first("[1]")) == 1)
    #expect(MCPServer.int(try first("[1.0]")) == nil)
    #expect(MCPServer.int(try first("[true]")) == nil)
    #expect(MCPServer.int(try first("[1e2]")) == nil)
    #expect(MCPServer.bool(try first("[true]")) == true)
    #expect(MCPServer.bool(try first("[1]")) == nil)
}
