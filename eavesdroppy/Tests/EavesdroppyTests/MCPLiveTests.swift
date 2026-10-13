import Darwin
import Foundation
import Testing
@testable import Eavesdroppy

// The real listener on real sockets: bound to loopback only, spoken to with /usr/bin/curl and raw sockets, stopped cleanly.
// Set MCP_TRANSCRIPT=/path to have the curl session of `curlSessionEndToEnd` written out.

private let liveToken = "live-" + String(repeating: "c", count: 59)

private struct Live {
    let listener: MCPListener
    let port: UInt16
    let container: URL
}

private func startLive(provider: MCPEchoProvider = MCPEchoProvider(), port: UInt16 = 0, container: URL? = nil) async throws -> Live {
    let dir = try container ?? mcpSeedContainer()
    let handler = MCPHandler(server: mcpServer(dir, provider: provider), token: MCPTokenBox(liveToken))
    let l = MCPListener(handler: handler)
    return Live(listener: l, port: try await l.start(port: port), container: dir)
}

@discardableResult
private func shell(_ exe: String, _ args: [String]) -> (code: Int32, out: String) {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

private func curl(_ port: UInt16, _ extra: [String], path: String = "/mcp", auth: Bool = true, json: String? = nil, extraHeaders: [String] = []) -> (code: Int32, out: String) {
    var a = ["-sS", "-i", "--max-time", "10"]
    if auth { a += ["-H", "Authorization: Bearer \(liveToken)"] }
    for h in extraHeaders { a += ["-H", h] }
    if let json { a += ["-H", "Content-Type: application/json", "-d", json] }
    return shell("/usr/bin/curl", a + extra + ["http://127.0.0.1:\(port)\(path)"])
}

/// A blocking TCP client: connect, optionally send bytes, read until close or the timeout.
private final class RawClient {
    let fd: Int32
    init?(port: UInt16, host: String = "127.0.0.1") {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET); a.sin_port = port.bigEndian; a.sin_addr.s_addr = inet_addr(host)
        let rc = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if rc != 0 { return nil }  // deinit closes the descriptor (a failable init that already initialised every property still runs it)
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }
    func send(_ s: String) { let d = Array(s.utf8); _ = d.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, d.count, 0) } }
    func send(bytes: [UInt8]) { _ = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, bytes.count, 0) } }
    /// Everything until the peer closes (or the 5 s timeout); `closed` says which.
    func readAll() -> (text: String, closed: Bool) {
        var out = Data(), buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n > 0 { out.append(contentsOf: buf[0..<n]) } else { return (String(decoding: out, as: UTF8.self), n == 0) }
        }
    }
    /// One chunk (for the 100 Continue exchange).
    func readSome() -> String {
        var buf = [UInt8](repeating: 0, count: 8192)
        let n = recv(fd, &buf, buf.count, 0)
        return n > 0 ? String(decoding: buf[0..<n], as: UTF8.self) : ""
    }
    private var open = true
    /// Idempotent: a second close(2) of the same number would close whatever a parallel test has been handed since, and a
    /// Foundation-guarded descriptor (FileHandle, Pipe) kills the whole process with EXC_GUARD.
    func close() { if open { open = false; Darwin.close(fd) } }
    deinit { close() }
}

private func status(_ response: String) -> Int? { response.split(separator: " ", maxSplits: 2).dropFirst().first.flatMap { Int($0) } }

private func post(_ body: String, extra: String = "") -> String {
    "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(liveToken)\r\nContent-Type: application/json\r\n\(extra)Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
}

private func nonLoopbackAddress() -> String? {
    var ifa: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifa) == 0, let first = ifa else { return nil }
    defer { freeifaddrs(ifa) }
    for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
        guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        let s = String(cString: host)
        if !s.hasPrefix("127.") && !s.hasPrefix("169.254.") { return s }
    }
    return nil
}

// MARK: binding

/// One at a time: these tests make blocking socket reads, and in parallel they starve the thread pool the server runs on.
@Suite(.serialized) struct MCPLive {
@Test func listensOnLoopbackOnly() async throws {
    let live = try await startLive()
    defer { live.listener.stop() }
    let lsof = shell("/usr/sbin/lsof", ["-nP", "-a", "-p", "\(getpid())", "-iTCP:\(live.port)", "-sTCP:LISTEN"]).out
    #expect(lsof.contains("127.0.0.1:\(live.port)"), "lsof: \(lsof)")
    #expect(!lsof.contains("*:\(live.port)") && !lsof.contains("[::"), "lsof: \(lsof)")
    if let lan = nonLoopbackAddress() {  // the same port on the machine's own LAN address must refuse
        #expect(RawClient(port: live.port, host: lan) == nil, "connected via \(lan)")
    }
    #expect(RawClient(port: live.port) != nil)
}

// MARK: lifecycle

@Test func stopLeavesNothingListeningAndTheSameAddressCanBeReused() async throws {
    let live = try await startLive()
    let idle = try #require(RawClient(port: live.port))  // a connection that never sends anything
    #expect(curl(live.port, [], json: #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#).out.contains("200 OK"))
    live.listener.stop()
    live.listener.stop()  // idempotent
    // the open connection is closed by the server, new ones are refused
    let closed = idle.readAll()
    #expect(closed.closed, "idle connection survived stop()")
    #expect(RawClient(port: live.port) == nil, "something still accepts on :\(live.port)")
    let refused = curl(live.port, [], json: "{}")
    #expect(refused.code == 7, "curl exit \(refused.code): \(refused.out)")  // 7 = couldn't connect
    let lsof = shell("/usr/sbin/lsof", ["-nP", "-a", "-p", "\(getpid())", "-iTCP:\(live.port)"]).out
    #expect(!lsof.contains("LISTEN"), "lsof: \(lsof)")
    // start again on the very same port
    let again = try await startLive(port: live.port, container: live.container)
    defer { again.listener.stop() }
    #expect(again.port == live.port)
    #expect(curl(again.port, [], json: #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#).out.contains("200 OK"))
}

@Test func aSecondServerOnABusyPortFailsInsteadOfSharingIt() async throws {
    let live = try await startLive()
    defer { live.listener.stop() }
    await #expect(throws: (any Error).self) { _ = try await startLive(port: live.port) }
}

@Test func stopCancelsAToolInFlight() async throws {
    let cancelled = MCPFlag()
    let live = try await startLive(provider: MCPEchoProvider(delay: 60, onCancel: { cancelled.set() }))
    let c = try #require(RawClient(port: live.port))
    c.send(post(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ask","arguments":{"question":"budget"}}}"#))
    try await Task.sleep(nanoseconds: 500_000_000)
    #expect(!cancelled.isSet)
    live.listener.stop()
    try await Task.sleep(nanoseconds: 500_000_000)
    #expect(cancelled.isSet, "the model call outlived stop()")
    #expect(c.readAll().closed)
}

@Test func theClientHangingUpCancelsTheTool() async throws {
    let cancelled = MCPFlag()
    let live = try await startLive(provider: MCPEchoProvider(delay: 60, onCancel: { cancelled.set() }))
    defer { live.listener.stop() }
    let c = try #require(RawClient(port: live.port))
    c.send(post(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ask","arguments":{"question":"budget"}}}"#))
    try await Task.sleep(nanoseconds: 500_000_000)
    #expect(!cancelled.isSet)
    c.close()
    for _ in 0..<30 where !cancelled.isSet { try await Task.sleep(nanoseconds: 100_000_000) }
    #expect(cancelled.isSet, "the model call kept running after the client left")
}

// MARK: ugly requests on the wire

@Test func oversizedBodyIsRefusedBeforeItIsSent() async throws {
    let live = try await startLive()
    defer { live.listener.stop() }
    let c = try #require(RawClient(port: live.port))
    c.send("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(liveToken)\r\nContent-Type: application/json\r\nContent-Length: 5000000\r\n\r\n")
    let r = c.readAll()  // no body was sent; the answer must not wait for one
    #expect(status(r.text) == 413, "\(r.text)")
    #expect(r.closed)
}

@Test func aBodyUnderTheLimitButShortOfItsLengthTimesOut() async throws {
    let live = try await startLive()
    defer { live.listener.stop() }
    live.listener.requestTimeout = 1
    let c = try #require(RawClient(port: live.port))
    c.send("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(liveToken)\r\nContent-Type: application/json\r\nContent-Length: 100\r\n\r\n{\"jsonrpc\"")
    let t0 = Date()
    let r = c.readAll()
    #expect(status(r.text) == 408, "\(r.text)")
    #expect(Date().timeIntervalSince(t0) < 4)
}

@Test func garbageHeaderFloodAndPartialHeadsAreHandled() async throws {
    let live = try await startLive()
    defer { live.listener.stop() }
    live.listener.requestTimeout = 1
    var c = try #require(RawClient(port: live.port))
    c.send(bytes: [0x00, 0x01, 0x02, 0xff, 13, 10, 13, 10])
    #expect(status(c.readAll().text) == 400)
    c = try #require(RawClient(port: live.port))
    c.send("POST /mcp HTTP/1.1\r\n" + String(repeating: "X-Pad: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\r\n", count: 600))  // no end of head
    #expect(status(c.readAll().text) == 431)
    c = try #require(RawClient(port: live.port))
    c.send("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n")  // slowloris: head never finished
    #expect(status(c.readAll().text) == 408)
    c = try #require(RawClient(port: live.port))
    c.send("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n")
    #expect(status(c.readAll().text) == 400)
}

@Test func expectContinueIsHonoured() async throws {
    let live = try await startLive()
    defer { live.listener.stop() }
    let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
    let c = try #require(RawClient(port: live.port))
    c.send(post(body, extra: "Expect: 100-continue\r\n").components(separatedBy: "\r\n\r\n")[0] + "\r\n\r\n")
    #expect(c.readSome().hasPrefix("HTTP/1.1 100 Continue"))
    c.send(body)
    #expect(status(c.readAll().text) == 200)
}

@Test func tooManyConnectionsAreTurnedAway() async throws {
    let live = try await startLive()
    defer { live.listener.stop() }
    let idle = (0..<live.listener.maxConnections).compactMap { _ in RawClient(port: live.port) }
    try await Task.sleep(nanoseconds: 300_000_000)
    let extra = try #require(RawClient(port: live.port))
    #expect(extra.readAll().closed)  // accepted by the kernel, closed by us at once
    #expect(idle.count == live.listener.maxConnections)
    idle.forEach { $0.close() }
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(curl(live.port, [], json: #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#).out.contains("200 OK"))
}

@Test func requestsOnOneConnectionAreNotPipelined() async throws {
    let live = try await startLive()
    defer { live.listener.stop() }
    let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
    let c = try #require(RawClient(port: live.port))
    c.send(post(body) + post(body))
    let r = c.readAll()
    #expect(r.closed)
    #expect(r.text.components(separatedBy: "HTTP/1.1 ").count - 1 == 1, "one answer, then the connection closes")
}

// MARK: the curl session

@Test func curlSessionEndToEnd() async throws {
    let live = try await startLive()
    defer { live.listener.stop() }
    var transcript = "# server: 127.0.0.1:\(live.port), token \(liveToken), seed library (5 meetings)\n"
    func run(_ title: String, _ shown: String, _ r: (code: Int32, out: String)) {
        transcript += "\n## \(title)\n$ \(shown)\n\(r.out.trimmingCharacters(in: .whitespacesAndNewlines))\n[curl exit \(r.code)]\n"
    }
    let url = "http://127.0.0.1:\(live.port)/mcp"
    let auth = "-H 'Authorization: Bearer <token>'", ct = "-H 'Content-Type: application/json'"
    let modernH = ["MCP-Protocol-Version: 2026-07-28", "Mcp-Method: tools/call", "Mcp-Name: search_meetings"]
    let meta = #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}"#

    var r = curl(live.port, [], json: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"curl","version":"1"}}}"#)
    run("legacy initialize", "curl -si \(auth) \(ct) -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",...}' \(url)", r)
    #expect(r.out.contains("200 OK") && r.out.contains(#""protocolVersion":"2025-11-25""#))

    r = curl(live.port, [], json: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, extraHeaders: ["MCP-Protocol-Version: 2025-11-25"])
    run("initialized notification -> 202, no body", "curl -si \(auth) \(ct) -H 'MCP-Protocol-Version: 2025-11-25' -d '{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}' \(url)", r)
    #expect(r.out.contains("202 Accepted"))

    r = curl(live.port, [], json: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#, extraHeaders: ["MCP-Protocol-Version: 2025-11-25"])
    run("tools/list (legacy)", "curl -si \(auth) \(ct) -H 'MCP-Protocol-Version: 2025-11-25' -d '{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}' \(url)", r)
    #expect(r.out.contains("search_meetings") && r.out.contains("list_action_items"))

    r = curl(live.port, [], json: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_meetings","arguments":{"query":"budget"},\#(meta)}}"#, extraHeaders: modernH)
    run("tools/call search_meetings (2026-07-28, with the mirrored headers)", "curl -si \(auth) \(ct) \(modernH.map { "-H '\($0)'" }.joined(separator: " ")) -d '{...\"name\":\"search_meetings\",\"arguments\":{\"query\":\"budget\"},\"_meta\":{...}}' \(url)", r)
    #expect(r.out.contains("200 OK") && r.out.contains("Weekly sync") && r.out.contains(#""resultType":"complete""#))

    r = curl(live.port, [], json: #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_meeting","arguments":{"id":2}}}"#)
    run("tools/call get_meeting 2 (legacy)", "curl -si \(auth) \(ct) -d '{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"get_meeting\",\"arguments\":{\"id\":2}}}' \(url)", r)
    #expect(r.out.contains("1:1 with Sam"))

    r = curl(live.port, [], json: #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"list_action_items","arguments":{}}}"#)
    run("tools/call list_action_items", "curl -si \(auth) \(ct) -d '{...\"name\":\"list_action_items\",\"arguments\":{}}' \(url)", r)
    #expect(r.out.contains("Chase legal"))

    r = curl(live.port, [], json: #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"ask","arguments":{"question":"What was agreed about the budget?"}}}"#)
    run("tools/call ask (test provider echoes the prompt it would send)", "curl -si \(auth) \(ct) -d '{...\"name\":\"ask\",\"arguments\":{\"question\":\"What was agreed about the budget?\"}}' \(url)", r)
    #expect(r.out.contains("200 OK") && r.out.contains("<excerpts>") && r.out.contains("Question: What was agreed about the budget?"))

    // refusals
    r = curl(live.port, [], auth: false, json: #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
    run("no token -> 401", "curl -si \(ct) -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}' \(url)", r)
    #expect(r.out.contains("401 Unauthorized") && r.out.contains("WWW-Authenticate: Bearer"))

    r = shell("/usr/bin/curl", ["-sS", "-i", "--max-time", "10", "-H", "Authorization: Bearer wrong-token", "-H", "Content-Type: application/json", "-d", "{}", url])
    run("wrong token -> 401", "curl -si -H 'Authorization: Bearer wrong-token' \(ct) -d '{}' \(url)", r)
    #expect(r.out.contains("401 Unauthorized"))

    r = curl(live.port, [], json: #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, extraHeaders: ["Origin: https://evil.example"])
    run("hostile Origin (right token) -> 403", "curl -si \(auth) \(ct) -H 'Origin: https://evil.example' -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}' \(url)", r)
    #expect(r.out.contains("403 Forbidden"))

    r = curl(live.port, [], json: #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, extraHeaders: ["Host: rebound.example"])
    run("rebound Host header -> 403", "curl -si \(auth) \(ct) -H 'Host: rebound.example' -d '{...}' \(url)", r)
    #expect(r.out.contains("403 Forbidden"))

    r = curl(live.port, [], json: "{not json")
    run("malformed JSON -> 400 -32700", "curl -si \(auth) \(ct) -d '{not json' \(url)", r)
    #expect(r.out.contains("400 Bad Request") && r.out.contains("-32700"))

    r = curl(live.port, [], json: #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"drop_tables","arguments":{}}}"#)
    run("unknown tool -> -32602", "curl -si \(auth) \(ct) -d '{...\"name\":\"drop_tables\"...}' \(url)", r)
    #expect(r.out.contains("-32602") && r.out.contains("Unknown tool: drop_tables"))

    r = curl(live.port, [], json: #"{"jsonrpc":"2.0","id":8,"method":"resources/list"}"#)
    run("unknown method (legacy) -> 200, -32601", "curl -si \(auth) \(ct) -d '{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"resources/list\"}' \(url)", r)
    #expect(r.out.contains("200 OK") && r.out.contains("-32601"))

    r = curl(live.port, [], json: #"{"jsonrpc":"2.0","id":9,"method":"resources/list","params":{\#(meta)}}"#, extraHeaders: ["MCP-Protocol-Version: 2026-07-28", "Mcp-Method: resources/list"])
    run("unknown method (2026-07-28) -> 404, -32601", "curl -si \(auth) \(ct) -H 'MCP-Protocol-Version: 2026-07-28' -H 'Mcp-Method: resources/list' -d '{...}' \(url)", r)
    #expect(r.out.contains("404 Not Found") && r.out.contains("-32601"))

    r = curl(live.port, [], json: #"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"search_meetings","arguments":{},\#(meta)}}"#, extraHeaders: ["MCP-Protocol-Version: 2026-07-28", "Mcp-Method: tools/call", "Mcp-Name: get_meeting"])
    run("header/body mismatch (Mcp-Name) -> 400 -32020", "curl -si \(auth) \(ct) -H 'MCP-Protocol-Version: 2026-07-28' -H 'Mcp-Method: tools/call' -H 'Mcp-Name: get_meeting' -d '{...\"name\":\"search_meetings\"...}' \(url)", r)
    #expect(r.out.contains("400 Bad Request") && r.out.contains("-32020"))

    r = curl(live.port, ["-X", "GET"], json: nil)
    run("GET -> 405", "curl -si \(auth) -X GET \(url)", r)
    #expect(r.out.contains("405 Method Not Allowed") && r.out.contains("Allow: POST"))

    let big = String(repeating: "a", count: 2_000_000)
    let bigFile = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-big-\(UUID().uuidString).json")
    try Data(#"{"jsonrpc":"2.0","id":1,"method":"ping","pad":"\#(big)"}"#.utf8).write(to: bigFile)
    defer { try? FileManager.default.removeItem(at: bigFile) }
    r = shell("/usr/bin/curl", ["-sS", "-i", "--max-time", "10", "-H", "Authorization: Bearer \(liveToken)", "-H", "Content-Type: application/json", "--data-binary", "@\(bigFile.path)", url])
    run("2 MB body -> 413", "curl -si \(auth) \(ct) --data-binary @2MB.json \(url)", r)
    #expect(r.out.contains("413") || r.code != 0, "\(r.out)")  // curl may see the reset first; either way nothing was processed

    live.listener.stop()
    r = curl(live.port, [], json: #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
    run("after stop() -> connection refused", "curl -si \(auth) \(ct) -d '{...}' \(url)", r)
    #expect(r.code == 7)

    if let path = ProcessInfo.processInfo.environment["MCP_TRANSCRIPT"] { try transcript.write(toFile: path, atomically: true, encoding: .utf8) }
}

// MARK: a real MCP client

/// Off unless MCP_HOLD_PORT_FILE is set: serves the seed library until `<file>.stop` appears (60 s at most), so an external
/// MCP client can be pointed at it. The port is written to the file.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MCP_HOLD_PORT_FILE"] != nil))
func holdServerForAnExternalClient() async throws {
    let file = ProcessInfo.processInfo.environment["MCP_HOLD_PORT_FILE"]!
    let live = try await startLive()
    defer { live.listener.stop() }
    try "\(live.port) \(liveToken)".write(toFile: file, atomically: true, encoding: .utf8)
    for _ in 0..<600 where !FileManager.default.fileExists(atPath: file + ".stop") { try await Task.sleep(nanoseconds: 100_000_000) }
}

// MARK: the Settings model drives the real server

@MainActor private final class MemPrefs {
    var enabled = false, port = 0
    var prefs: MCPPrefs { MCPPrefs(enabled: { self.enabled }, setEnabled: { self.enabled = $0 }, port: { self.port }, setPort: { self.port = $0 }) }
}

@MainActor private func eventually(_ what: String, _ cond: @MainActor () -> Bool) async {
    for _ in 0..<100 where !cond() { try? await Task.sleep(nanoseconds: 50_000_000) }
    #expect(cond(), "\(what)")
}

@Test @MainActor func settingsModelStartsOnlyWhenEnabledAndStopsCleanly() async throws {
    let account = "mcp-test-\(UUID().uuidString)"
    defer { ProviderKeychain.delete(account) }
    let mem = MemPrefs()
    mem.port = Int.random(in: 20000...40000)  // below macOS's ephemeral range, so no client socket holds it
    let model = MCPServerModel()
    model.tokenAccount = account
    model.attach(mem.prefs, container: try mcpSeedContainer(), userName: { "Pat" }, providerConfig: { NotesProviderConfig() }, copy: { _ in true })
    // default OFF: nothing listens
    try await Task.sleep(nanoseconds: 200_000_000)
    #expect(!model.running && RawClient(port: UInt16(mem.port)) == nil)

    model.setEnabled(true)
    await eventually("running") { model.running }
    let token = try #require(model.token)
    #expect(model.url == "http://127.0.0.1:\(mem.port)/mcp")
    #expect(model.addCommand(token: token) == "claude mcp add --transport http eavesdroppy http://127.0.0.1:\(mem.port)/mcp --header \"Authorization: Bearer \(token)\"")
    var r = shell("/usr/bin/curl", ["-sS", "-i", "--max-time", "10", "-H", "Authorization: Bearer \(token)", "-H", "Content-Type: application/json",
                                    "-d", #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, model.url])
    #expect(r.out.contains("200 OK"))

    let old = token
    model.regenerateToken()
    await eventually("new token") { model.token != nil && model.token != old }
    r = shell("/usr/bin/curl", ["-sS", "-i", "--max-time", "10", "-H", "Authorization: Bearer \(old)", "-H", "Content-Type: application/json", "-d", "{}", model.url])
    #expect(r.out.contains("401"), "the old token still works: \(r.out)")

    model.setEnabled(false)
    #expect(!model.running && model.token == nil)
    #expect(mem.enabled == false)
    #expect(RawClient(port: UInt16(mem.port)) == nil, "still listening after switching off")

    // deactivate while a start is still in flight: nothing may be left listening
    model.setEnabled(true)
    model.stop()
    try await Task.sleep(nanoseconds: 800_000_000)
    #expect(!model.running && RawClient(port: UInt16(mem.port)) == nil, "a start that raced stop() left a listener")

    // a busy port is reported, not crashed on
    let blocker = try await startLive(port: UInt16(mem.port))
    defer { blocker.listener.stop() }
    model.setEnabled(true)
    await eventually("a message about the busy port") { model.message != nil }
    #expect(!model.running)
    model.stop()
}
}
