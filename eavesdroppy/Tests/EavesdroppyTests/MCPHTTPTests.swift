import Foundation
import Security
import Testing
@testable import Eavesdroppy

// The HTTP rules of MCPHandler (2026-07-28 Streamable HTTP, plus the legacy subset) and its security checks, with no socket in
// between: precheck(head) then respond(head, body), exactly the sequence MCPListener runs.

private let token = "t0k3n-" + String(repeating: "a", count: 40)

private func handler(_ box: MCPTokenBox = MCPTokenBox(token)) throws -> MCPHandler {
    MCPHandler(server: mcpServer(try mcpSeedContainer()), token: box)
}

private func good(_ extra: [String: String] = [:], drop: [String] = []) -> [String: String] {
    var h = ["host": "127.0.0.1:47615", "authorization": "Bearer \(token)", "content-type": "application/json"]
    for (k, v) in extra { h[k] = v }
    for k in drop { h[k] = nil }
    return h
}

private func meta(_ version: String = "2026-07-28", caps: Bool = true) -> [String: Any] {
    var m: [String: Any] = ["io.modelcontextprotocol/protocolVersion": version]
    if caps { m["io.modelcontextprotocol/clientCapabilities"] = [String: Any]() }
    return m
}

private func rpc(_ method: String, _ params: [String: Any]? = nil, id: Any = 1) -> [String: Any] {
    var m: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
    if let params { m["params"] = params }
    return m
}

/// Runs the request through the same two steps the listener does.
private func send(_ h: MCPHandler, method: String = "POST", target: String = "/mcp", headers: [String: String]? = nil,
                  body: Data, contentLength: String? = nil) async -> MCPHTTPResponse {
    var hs = headers ?? good()
    if let cl = contentLength { if !cl.isEmpty { hs["content-length"] = cl } } else { hs["content-length"] = String(body.count) }
    let head = MCPHTTPHead(method: method, target: target, headers: hs)
    if let r = h.precheck(head) { return r }
    return await h.respond(head, body: body)
}

private func send(_ h: MCPHandler, _ msg: Any, headers: [String: String]? = nil) async -> MCPHTTPResponse {
    await send(h, headers: headers, body: try! JSONSerialization.data(withJSONObject: msg, options: .fragmentsAllowed))
}

private func errorCode(_ r: MCPHTTPResponse) -> Int? {
    ((try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any]).flatMap { ($0["error"] as? [String: Any])?["code"] as? Int }
}
private func result(_ r: MCPHTTPResponse) -> [String: Any]? {
    ((try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any])?["result"] as? [String: Any]
}
private func header(_ r: MCPHTTPResponse, _ name: String) -> String? { r.headers.first { $0.0.lowercased() == name.lowercased() }?.1 }

// MARK: authentication

@Test func missingOrWrongTokenIs401() async throws {
    let h = try handler()
    let body = try JSONSerialization.data(withJSONObject: rpc("ping"))
    for hs in [good(drop: ["authorization"]),
               good(["authorization": "Bearer nope"]),
               good(["authorization": "Bearer " + token + "x"]),
               good(["authorization": "Bearer " + String(token.dropLast())]),
               good(["authorization": "Bearer "]),
               good(["authorization": "Bearer"]),
               good(["authorization": "Basic " + token]),
               good(["authorization": token]),
               good(["authorization": "Bearer " + token.uppercased()])] {
        let r = await send(h, headers: hs, body: body)
        #expect(r.status == 401, "\(hs["authorization"] ?? "none")")
        #expect(header(r, "WWW-Authenticate")?.hasPrefix("Bearer") == true)
    }
    // the scheme is case-insensitive, the token is not
    #expect(await send(h, headers: good(["authorization": "bearer " + token]), body: body).status == 200)
}

@Test func noTokenConfiguredRejectsEveryone() async throws {
    let h = try handler(MCPTokenBox(nil))
    #expect(await send(h, rpc("ping")).status == 401)
    #expect(await send(h, rpc("ping"), headers: good(["authorization": "Bearer "])).status == 401)
}

@Test func tokenRotationTakesEffectWithoutARestart() async throws {
    let box = MCPTokenBox(token)
    let h = try handler(box)
    #expect(await send(h, rpc("ping")).status == 200)
    box.value = "another-" + String(repeating: "b", count: 40)
    #expect(await send(h, rpc("ping")).status == 401)
}

@Test func tokenComparisonIsExactAndLengthBlind() {
    #expect(MCPToken.equal("abc", "abc"))
    #expect(!MCPToken.equal("abc", "abd"))
    #expect(!MCPToken.equal("abc", "abcd"))
    #expect(!MCPToken.equal("", "x"))
    #expect(MCPToken.equal("", ""))
    #expect(MCPToken.bearer("Bearer  x ") == "x")
    #expect(MCPToken.bearer("Bearer") == nil)
    #expect(MCPToken.bearer(nil) == nil)
}

@Test func generatedTokensAreLongAndDistinct() {
    let a = MCPToken.generate(), b = MCPToken.generate()
    #expect(a.count == 64 && b.count == 64 && a != b)
    #expect(a.allSatisfy { $0.isHexDigit })
}

@Test func tokenLivesInTheKeychainAndSurvivesReads() throws {
    let account = "mcp-test-\(UUID().uuidString)"
    defer { ProviderKeychain.delete(account) }
    let first = try #require(MCPToken.loadOrCreate(account: account), "Keychain refused to store the token")
    #expect(MCPToken.loadOrCreate(account: account) == first)
    #expect(ProviderKeychain.read(account) == first)
    let second = try #require(MCPToken.regenerate(account: account))
    #expect(second != first)
    #expect(MCPToken.loadOrCreate(account: account) == second)
}

// MARK: DNS rebinding: Host and Origin

@Test func nonLoopbackOriginIs403EvenWithTheRightToken() async throws {
    let h = try handler()
    for origin in ["https://evil.example", "http://evil.example:3000", "null", "http://127.0.0.1.evil.com", "http://localhost.evil.com",
                   "file://", "chrome-extension://abcdef", "http://[::2]", "http://0.0.0.0:80", "garbage", ""] {
        let r = await send(h, rpc("ping"), headers: good(["origin": origin]))
        #expect(r.status == 403, "origin \(origin.debugDescription)")
    }
    // checked before authentication: a hostile page learns nothing about the token
    #expect(await send(h, rpc("ping"), headers: good(["origin": "https://evil.example"], drop: ["authorization"])).status == 403)
}

@Test func loopbackOriginsAndNoOriginPass() async throws {
    let h = try handler()
    for origin in ["http://localhost:3000", "http://127.0.0.1", "https://localhost", "http://[::1]:8080", "http://LOCALHOST:1"] {
        #expect(await send(h, rpc("ping"), headers: good(["origin": origin])).status == 200, "origin \(origin)")
    }
    #expect(await send(h, rpc("ping")).status == 200)  // a CLI client sends none
}

@Test func nonLoopbackHostIs403() async throws {
    let h = try handler()
    for host in ["evil.example", "evil.example:47615", "127.0.0.1.evil.com", "192.168.1.5:47615", "0.0.0.0:47615", "[::2]:1", ""] {
        #expect(await send(h, rpc("ping"), headers: good(["host": host])).status == 403, "host \(host.debugDescription)")
    }
    #expect(await send(h, rpc("ping"), headers: good(drop: ["host"])).status == 400)
    for host in ["localhost", "localhost:1", "127.0.0.1:99", "[::1]:99", "LOCALHOST:5"] {
        #expect(await send(h, rpc("ping"), headers: good(["host": host])).status == 200, "\(host)")
    }
}

// MARK: routing and framing

@Test func onlyPostOnTheMcpPathIsServed() async throws {
    let h = try handler()
    let body = try JSONSerialization.data(withJSONObject: rpc("ping"))
    for m in ["GET", "DELETE", "PUT", "OPTIONS", "HEAD", "PATCH"] {
        let r = await send(h, method: m, body: body)
        #expect(r.status == 405, "\(m)")
        #expect(header(r, "Allow") == "POST")
    }
    for t in ["/", "/mcp/", "/mcp?x=1", "/MCP", "/sse", "/mcp/../mcp", "/admin"] {
        #expect(await send(h, target: t, body: body).status == 404, "\(t)")
    }
}

@Test func contentTypeAndLengthAreEnforcedBeforeTheBodyIsRead() async throws {
    let h = try handler()
    let body = try JSONSerialization.data(withJSONObject: rpc("ping"))
    #expect(await send(h, headers: good(["content-type": "text/plain"]), body: body).status == 415)
    #expect(await send(h, headers: good(["content-type": "application/x-www-form-urlencoded"]), body: body).status == 415)
    #expect(await send(h, headers: good(drop: ["content-type"]), body: body).status == 415)
    #expect(await send(h, headers: good(["content-type": "application/json; charset=utf-8"]), body: body).status == 200)
    #expect(await send(h, body: body, contentLength: "").status == 411)
    for cl in ["abc", "-1", "1e3", "+5", "0x10", "١٢"] { #expect(await send(h, body: body, contentLength: cl).status == 400, "\(cl)") }
    #expect(await send(h, body: body, contentLength: String(MCPHTTP.maxBody + 1)).status == 413)
    #expect(await send(h, body: body, contentLength: "99999999999999999999").status == 400)  // does not fit an Int
    #expect(await send(h, body: body, contentLength: String(MCPHTTP.maxBody)).status != 413)
}

// MARK: JSON-RPC over HTTP

@Test func malformedJSONIs400WithAParseError() async throws {
    let h = try handler()
    for raw in ["{", "", "not json", "{\"jsonrpc\":", "\u{0}", "{'a':1}", "[1,2", "nul"] {
        let r = await send(h, body: Data(raw.utf8))
        #expect(r.status == 400, "\(raw.debugDescription)")
        #expect(errorCode(r) == -32700)
        #expect(((try JSONSerialization.jsonObject(with: r.body)) as? [String: Any])?["id"] is NSNull)
    }
    let invalidUTF8 = await send(h, body: Data([0x7b, 0xff, 0xfe, 0x7d]))
    #expect(invalidUTF8.status == 400)
}

@Test func batchesAndScalarsAreInvalidRequests() async throws {
    let h = try handler()
    for raw in ["[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}]", "[]", "42", "\"ping\"", "null", "true"] {
        let r = await send(h, body: Data(raw.utf8))
        #expect(r.status == 400, "\(raw)")
        #expect(errorCode(r) == -32600, "\(raw)")
    }
}

@Test func legacyClientsGetAnswersAndProtocolErrorsStayOn200() async throws {
    let h = try handler()
    let hs = good(["mcp-protocol-version": "2025-11-25", "mcp-session-id": "client-made-up"])
    var r = await send(h, rpc("initialize", ["protocolVersion": "2025-11-25"]), headers: good())
    #expect(r.status == 200)
    #expect(result(r)?["protocolVersion"] as? String == "2025-11-25")
    #expect(header(r, "Mcp-Session-Id") == nil)  // no sessions minted or echoed
    r = await send(h, rpc("tools/list"), headers: hs)
    #expect(r.status == 200 && (result(r)?["tools"] as? [Any])?.count == 4)
    #expect(header(r, "Mcp-Session-Id") == nil)
    r = await send(h, rpc("resources/list"), headers: hs)
    #expect(r.status == 200 && errorCode(r) == -32601)
    r = await send(h, ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "nope"]], headers: hs)
    #expect(r.status == 200 && errorCode(r) == -32602)
    r = await send(h, ["jsonrpc": "2.0", "method": "notifications/initialized"], headers: hs)
    #expect(r.status == 202 && r.body.isEmpty)
    r = await send(h, ["jsonrpc": "2.0", "id": 3, "result": [String: Any]()], headers: hs)  // a client "response" is acknowledged
    #expect(r.status == 202)
}

@Test func headerVersionWithoutMetaIsChecked() async throws {
    let h = try handler()
    var r = await send(h, rpc("tools/list"), headers: good(["mcp-protocol-version": "1900-01-01"]))
    #expect(r.status == 400 && errorCode(r) == -32022)
    let data = ((try JSONSerialization.jsonObject(with: r.body)) as? [String: Any]).flatMap { ($0["error"] as? [String: Any])?["data"] as? [String: Any] }
    #expect((data?["supported"] as? [String])?.contains("2026-07-28") == true && data?["requested"] as? String == "1900-01-01")
    r = await send(h, rpc("tools/list"), headers: good(["mcp-protocol-version": "2026-07-28"]))
    #expect(r.status == 400 && errorCode(r) == -32020)  // claims modern but the body has no _meta
    for v in ["2025-06-18", "2025-03-26", "2024-11-05"] {
        #expect(await send(h, rpc("tools/list"), headers: good(["mcp-protocol-version": v])).status == 200, "\(v)")
    }
}

@Test func modernRequestsAreValidatedAgainstTheirHeaders() async throws {
    let h = try handler()
    let list = rpc("tools/list", ["_meta": meta()])
    let ok = good(["mcp-protocol-version": "2026-07-28", "mcp-method": "tools/list"])
    var r = await send(h, list, headers: ok)
    #expect(r.status == 200)
    #expect(result(r)?["resultType"] as? String == "complete" && result(r)?["ttlMs"] != nil)

    // each of these disagrees with what the body says
    #expect(errorCode(await send(h, list, headers: good(["mcp-protocol-version": "2025-11-25", "mcp-method": "tools/list"]))) == -32020)
    #expect(await send(h, list, headers: good(["mcp-protocol-version": "2025-11-25", "mcp-method": "tools/list"])).status == 400)
    #expect(errorCode(await send(h, list, headers: good(["mcp-protocol-version": "2026-07-28", "mcp-method": "ping"]))) == -32020)
    #expect(errorCode(await send(h, list, headers: good(["mcp-protocol-version": "2026-07-28", "mcp-method": "TOOLS/LIST"]))) == -32020)
    #expect(errorCode(await send(h, list, headers: good(["mcp-method": "ping"]))) == -32020)

    // lenient: the mirrored headers are validated when present, never required
    for hs in [good(), good(["mcp-protocol-version": "2026-07-28"]), good(["mcp-method": "tools/list"])] {
        r = await send(h, list, headers: hs)
        #expect(r.status == 200 && result(r)?["resultType"] as? String == "complete", "\(hs)")
    }

    // unsupported version: header and body agree, the server says what it speaks
    r = await send(h, rpc("tools/list", ["_meta": meta("1900-01-01")]), headers: good(["mcp-protocol-version": "1900-01-01", "mcp-method": "tools/list"]))
    #expect(r.status == 400 && errorCode(r) == -32022)

    // clientCapabilities is not required either
    r = await send(h, rpc("tools/list", ["_meta": meta(caps: false)]), headers: ok)
    #expect(r.status == 200)

    // unknown method: 404 on the modern path
    r = await send(h, rpc("resources/list", ["_meta": meta()]), headers: good(["mcp-protocol-version": "2026-07-28", "mcp-method": "resources/list"]))
    #expect(r.status == 404 && errorCode(r) == -32601)
}

@Test func toolsCallNeedsAMatchingMcpName() async throws {
    let h = try handler()
    let call = rpc("tools/call", ["name": "search_meetings", "arguments": ["query": "budget"], "_meta": meta()])
    let base = ["mcp-protocol-version": "2026-07-28", "mcp-method": "tools/call"]
    var r = await send(h, call, headers: good(base.merging(["mcp-name": "search_meetings"]) { $1 }))
    #expect(r.status == 200 && result(r)?["isError"] as? Bool == false && result(r)?["resultType"] as? String == "complete")
    #expect(await send(h, call, headers: good(base)).status == 200)                                                          // absent: fine
    #expect(errorCode(await send(h, call, headers: good(base.merging(["mcp-name": "get_meeting"]) { $1 }))) == -32020)     // different
    #expect(errorCode(await send(h, call, headers: good(base.merging(["mcp-name": "=?base64?!!!?="]) { $1 }))) == -32020)  // undecodable
    // the base64 sentinel is decoded before comparing (a name that is not plain ASCII)
    let uni = rpc("tools/call", ["name": "grüße", "arguments": [String: Any](), "_meta": meta()])
    let enc = "=?base64?" + Data("grüße".utf8).base64EncodedString() + "?="
    r = await send(h, uni, headers: good(base.merging(["mcp-name": enc]) { $1 }))
    #expect(r.status == 400 && errorCode(r) == -32602)  // header matched; the tool does not exist
    // unknown tool, modern: 400
    r = await send(h, rpc("tools/call", ["name": "nope", "_meta": meta()]), headers: good(base.merging(["mcp-name": "nope"]) { $1 }))
    #expect(r.status == 400 && errorCode(r) == -32602)
}

@Test func aBodyJustUnderTheLimitIsServed() async throws {
    // The listener reads exactly Content-Length bytes; a body near the 1 MiB cap still gets an answer.
    let h = try handler()
    let filler = String(repeating: "x", count: MCPHTTP.maxBody - 1000)
    let r = await send(h, rpc("tools/call", ["name": "search_meetings", "arguments": ["query": filler]]))
    #expect(r.status == 200, "\(r.status) \(String(data: r.body.prefix(300), encoding: .utf8) ?? "")")
    #expect(result(r)?["isError"] as? Bool == false)
}

// MARK: request parsing

@Test func headParsingRefusesAmbiguity() {
    func parse(_ s: String) -> Result<MCPHTTPHead, MCPHTTPResponse> { MCPHTTP.parseHead(Data(s.utf8)) }
    func status(_ s: String) -> Int? { if case .failure(let r) = parse(s) { return r.status }; return nil }
    let line = "POST /mcp HTTP/1.1"
    guard case .success(let ok) = parse(line + "\r\nHost: 127.0.0.1\r\nAuthorization: Bearer x\r\nX-Two: a\r\nX-Two: b") else { Issue.record("good head refused"); return }
    #expect(ok.method == "POST" && ok.target == "/mcp" && ok.headers["authorization"] == "Bearer x" && ok.headers["x-two"] == "a, b")
    #expect(status(line + "\r\nHost: a\r\nContent-Length: 1\r\nContent-Length: 1") == 400)      // repeated
    #expect(status(line + "\r\nHost: a\r\nAuthorization: x\r\nauthorization: y") == 400)
    #expect(status(line + "\r\nHost: a\r\nTransfer-Encoding: chunked") == 400)
    #expect(status(line + "\r\nHost: a\r\nNoColonHere") == 400)
    #expect(status(line + "\r\nHost: a\r\n folded: value") == 400)
    #expect(status(line + "\r\n: empty-name") == 400)
    #expect(status("POST /mcp") == 400)
    #expect(status("POST /mcp HTTP/1.1 extra") == 400)
    #expect(status("POST mcp HTTP/1.1") == 400)
    #expect(status("POST /mcp SPDY/3") == 400)
    #expect(MCPHTTP.parseHead(Data([0x50, 0xff, 0xfe])).isFailure)
}

private extension Result { var isFailure: Bool { if case .failure = self { return true }; return false } }

@Test func originAndHostParsing() {
    #expect(MCPHTTP.hostOnly("127.0.0.1:8080") == "127.0.0.1")
    #expect(MCPHTTP.hostOnly("[::1]:8080") == "::1")
    #expect(MCPHTTP.hostOnly("[::1]") == "::1")
    #expect(MCPHTTP.hostOnly("LocalHost") == "localhost")
    #expect(MCPHTTP.originAllowed("http://localhost:5173"))
    #expect(MCPHTTP.originAllowed("http://[::1]:5173"))
    #expect(!MCPHTTP.originAllowed("http://localhost@evil.com"))
    #expect(!MCPHTTP.originAllowed("ftp://localhost"))
    #expect(!MCPHTTP.originAllowed("http://"))
}

@Test func responsesCarryNoSecretsAndNoHeaderInjection() {
    let wire = String(data: MCPHTTP.serialize(MCPHTTPResponse(status: 401, headers: [("X-A", "ok\r\nSet-Cookie: x=1"), ("X-B", "fine")], body: Data("hi".utf8))), encoding: .utf8)!
    #expect(wire.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
    #expect(!wire.contains("Set-Cookie") && wire.contains("X-B: fine") && wire.contains("Content-Length: 2\r\n") && wire.contains("Connection: close"))
}
