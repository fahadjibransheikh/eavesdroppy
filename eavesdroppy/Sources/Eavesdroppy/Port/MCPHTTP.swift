import Foundation
import Network

// Streamable HTTP for the MCP server (D25), protocol revision 2026-07-28, with the legacy (2025-11-25 and earlier) JSON-only
// subset for older clients: one POST endpoint, one JSON object per reply (never SSE), 405 for GET and DELETE, Mcp-Session-Id
// ignored. DroppyKit has no host network service: `network-server` is a permission only, so the droplet opens its own
// NWListener, bound to 127.0.0.1, and stops it in deactivate().
//
// Defences, in the order they run (MCPHandler.precheck, before any body byte is read):
//   Host not loopback            -> 403   (DNS rebinding: a rebound name carries its own Host)
//   Origin present, not loopback -> 403   (spec: MUST; browsers always send Origin on cross-site POSTs; "null" is refused)
//   no / wrong bearer token      -> 401   (constant-time compare)
//   other path -> 404, other verb -> 405, body not JSON -> 415, no Content-Length -> 411, body over 1 MiB -> 413
// shortcut: HTTP/1.1 is hand-parsed (request line, headers, Content-Length body), Connection: close, no keep-alive, no TLS
// (loopback only). Upgrade to a real HTTP stack if the endpoint ever leaves the loopback interface.

struct MCPHTTPHead {
    var method: String
    var target: String
    var headers: [String: String]  // names lowercased
}

struct MCPHTTPResponse: Error {
    var status: Int
    var headers: [(String, String)] = []
    var body = Data()
}

enum MCPHTTP {
    static let maxHead = 16 * 1024
    static let maxBody = 1 << 20

    static func reason(_ s: Int) -> String {
        switch s {
        case 100: return "Continue"; case 200: return "OK"; case 202: return "Accepted"
        case 400: return "Bad Request"; case 401: return "Unauthorized"; case 403: return "Forbidden"; case 404: return "Not Found"
        case 405: return "Method Not Allowed"; case 408: return "Request Timeout"; case 411: return "Length Required"
        case 413: return "Content Too Large"; case 415: return "Unsupported Media Type"; case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"; default: return "Status"
        }
    }

    static func plain(_ status: Int, _ text: String, _ extra: [(String, String)] = []) -> MCPHTTPResponse {
        MCPHTTPResponse(status: status, headers: [("Content-Type", "text/plain; charset=utf-8")] + extra, body: Data((text + "\n").utf8))
    }

    static func json(_ status: Int, _ object: [String: Any]) -> MCPHTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return MCPHTTPResponse(status: status, headers: [("Content-Type", "application/json")], body: data)
    }

    static func serialize(_ r: MCPHTTPResponse) -> Data {
        var s = "HTTP/1.1 \(r.status) \(reason(r.status))\r\n"
        // unicodeScalars: "\r\n" is a single Character, so String.contains("\r") would miss it
        for (k, v) in r.headers where !v.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" }) { s += "\(k): \(v)\r\n" }
        s += "Content-Length: \(r.body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n"
        return Data(s.utf8) + r.body
    }

    /// The request line and headers (without the blank line). Anything odd is refused rather than interpreted: obs-fold,
    /// a header without a colon, a repeated security-relevant header, Transfer-Encoding (no request smuggling by chunking).
    static func parseHead(_ raw: Data) -> Result<MCPHTTPHead, MCPHTTPResponse> {
        guard let text = String(data: raw, encoding: .utf8) else { return .failure(plain(400, "headers are not UTF-8")) }
        var lines = text.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1."), !parts[0].isEmpty, parts[1].hasPrefix("/") else {
            return .failure(plain(400, "malformed request line"))
        }
        var headers: [String: String] = [:]
        for l in lines {
            guard let c = l.firstIndex(of: ":"), c != l.startIndex, !l.hasPrefix(" "), !l.hasPrefix("\t") else {
                return .failure(plain(400, "malformed header"))
            }
            let name = l[..<c].lowercased(), value = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
            if headers[name] != nil, ["content-length", "authorization", "origin", "host", "content-type", "mcp-protocol-version"].contains(name) {
                return .failure(plain(400, "repeated \(name) header"))
            }
            headers[name] = headers[name].map { $0 + ", " + value } ?? value
        }
        if headers["transfer-encoding"] != nil { return .failure(plain(400, "Transfer-Encoding is not supported; send Content-Length")) }
        return .success(MCPHTTPHead(method: String(parts[0]), target: String(parts[1]), headers: headers))
    }

    /// "127.0.0.1:8080", "localhost", "[::1]:8080" -> the host part, lowercased.
    static func hostOnly(_ hostPort: String) -> String {
        let h = hostPort.lowercased()
        if h.hasPrefix("["), let end = h.firstIndex(of: "]") { return String(h[h.index(after: h.startIndex)..<end]) }
        return String(h.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }

    static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    /// An Origin is acceptable only if it is http(s) on a loopback host (any port).
    static func originAllowed(_ origin: String) -> Bool {
        guard let u = URLComponents(string: origin), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = u.host?.lowercased() else { return false }
        return loopbackHosts.contains(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
    }

    /// Mcp-Name / Mcp-Param values that are not plain ASCII travel as `=?base64?...?=`.
    static func decodeHeaderValue(_ v: String) -> String? {
        guard v.hasPrefix("=?base64?"), v.hasSuffix("?="), v.count >= 11 else { return v }
        return Data(base64Encoded: String(v.dropFirst(9).dropLast(2))).flatMap { String(data: $0, encoding: .utf8) }
    }
}

/// Everything between "a parsed HTTP request" and "a response": security checks, header/body validation, status mapping.
/// No sockets in here, so every ugly path is testable directly.
final class MCPHandler: @unchecked Sendable {
    let server: MCPServer
    let token: MCPTokenBox
    let endpoint = "/mcp"

    init(server: MCPServer, token: MCPTokenBox) { self.server = server; self.token = token }

    /// What the head alone decides. nil = go on and read the body.
    func precheck(_ head: MCPHTTPHead) -> MCPHTTPResponse? {
        guard let host = head.headers["host"] else { return MCPHTTP.plain(400, "Host header required") }
        guard MCPHTTP.loopbackHosts.contains(MCPHTTP.hostOnly(host)) else { return MCPHTTP.plain(403, "Forbidden host") }
        if let origin = head.headers["origin"], !MCPHTTP.originAllowed(origin) { return MCPHTTP.plain(403, "Forbidden origin") }
        guard let expected = token.value, let given = MCPToken.bearer(head.headers["authorization"]), MCPToken.equal(given, expected) else {
            return MCPHTTP.plain(401, "Unauthorized", [("WWW-Authenticate", "Bearer realm=\"eavesdroppy\"")])
        }
        guard head.target == endpoint else { return MCPHTTP.plain(404, "Not found") }
        // 2026-07-28 removed the GET stream and DELETE sessions; older clients get the same 405 the spec prescribes.
        guard head.method == "POST" else { return MCPHTTP.plain(405, "Method not allowed", [("Allow", "POST")]) }
        guard (head.headers["content-type"] ?? "").lowercased().hasPrefix("application/json") else {
            return MCPHTTP.plain(415, "Content-Type must be application/json")
        }
        guard let cl = head.headers["content-length"] else { return MCPHTTP.plain(411, "Content-Length required") }
        guard let n = Int(cl), n >= 0, cl.allSatisfy(\.isASCII), cl.allSatisfy(\.isNumber) else { return MCPHTTP.plain(400, "bad Content-Length") }
        guard n <= MCPHTTP.maxBody else { return MCPHTTP.plain(413, "Body over \(MCPHTTP.maxBody) bytes") }
        return nil
    }

    private func rpc(_ status: Int, _ id: Any?, _ code: Int, _ message: String, data: Any? = nil) -> MCPHTTPResponse {
        MCPHTTP.json(status, MCPServer.err(id, code, message, data: data))
    }

    /// HTTP status for a JSON-RPC reply. Legacy clients get 200 for every protocol error, as before 2026-07-28.
    static func status(for reply: [String: Any], modern: Bool) -> Int {
        guard let e = reply["error"] as? [String: Any], let code = e["code"] as? Int else { return 200 }
        switch code {
        case -32700, -32600: return 400
        case -32602, -32022, -32020: return modern ? 400 : 200
        case -32601: return modern ? 404 : 200
        case -32603: return 500
        default: return 200
        }
    }

    func respond(_ head: MCPHTTPHead, body: Data) async -> MCPHTTPResponse {
        guard let parsed = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) else { return rpc(400, nil, -32700, "Parse error") }
        guard let msg = parsed as? [String: Any] else { return rpc(400, nil, -32600, "Invalid Request") }  // batches ended with 2025-06-18
        let id = msg["id"]
        let method = msg["method"] as? String
        let params = msg["params"] as? [String: Any]
        let metaVersion = (params?["_meta"] as? [String: Any])?[MCPServer.versionKey]
        let headerVersion = head.headers["mcp-protocol-version"]
        let modern = metaVersion != nil

        func mismatch(_ why: String) -> MCPHTTPResponse { rpc(400, id, -32020, "Header mismatch: \(why)") }
        if modern {
            // Body is the source of truth. The mirrored headers are checked when the client sent them (a mismatch is -32020, per
            // spec) and are not required: a client that omits them is still served. Same for _meta.clientCapabilities.
            if let hv = headerVersion, (metaVersion as? String) != hv { return mismatch("MCP-Protocol-Version \(hv) does not match the request body") }
            if let hm = head.headers["mcp-method"], hm != method { return mismatch("Mcp-Method does not match the request body") }
            if method == "tools/call", let raw = head.headers["mcp-name"] {
                guard let given = MCPHTTP.decodeHeaderValue(raw), given == params?["name"] as? String else {
                    return mismatch("Mcp-Name does not match the request body")
                }
            }
        } else if let hv = headerVersion {
            if MCPServer.modern.contains(hv) { return mismatch("MCP-Protocol-Version \(hv) needs params._meta to carry the same version") }
            if !MCPServer.legacy.contains(hv) {
                return rpc(400, id, -32022, "Unsupported protocol version", data: ["supported": MCPServer.modern + MCPServer.legacy, "requested": hv])
            }
        }
        do {
            guard let reply = try await server.handle(msg) else { return MCPHTTPResponse(status: 202) }  // notification
            return MCPHTTP.json(Self.status(for: reply, modern: modern), reply)
        } catch {
            return MCPHTTPResponse(status: 499)  // the client hung up and cancelled us; nobody reads this
        }
    }
}

// MARK: - Listener

/// 127.0.0.1 only. Owns every connection it accepted: stop() leaves nothing listening and nothing running.
final class MCPListener: @unchecked Sendable {
    private final class Conn: @unchecked Sendable {
        let c: NWConnection
        var buf = Data()
        var head: MCPHTTPHead?
        var need = 0
        var done = false       // the request is complete (or refused): no more reading
        var responded = false
        var timeout: DispatchWorkItem?
        var task: Task<Void, Never>?
        init(_ c: NWConnection) { self.c = c }
    }

    private let handler: MCPHandler
    private let queue = DispatchQueue(label: "eavesdroppy.mcp.listener")  // all state below is confined to it
    private var listener: NWListener?
    private var conns: [ObjectIdentifier: Conn] = [:]
    private var stopped = false
    let maxConnections = 16
    var requestTimeout: TimeInterval = 15
    /// Called on the listener's queue if the listener dies after it was ready.
    var onFailure: (@Sendable (Error) -> Void)?

    init(handler: MCPHandler) { self.handler = handler }

    /// Binds 127.0.0.1:port (0 = any free port) and returns the bound port once the socket is ready.
    func start(port: UInt16) async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        // No allowLocalEndpointReuse: it would let another socket bind this port and receive token-bearing requests.
        let l = try NWListener(using: params)
        return try await withCheckedThrowingContinuation { (k: CheckedContinuation<UInt16, Error>) in
            final class Once: @unchecked Sendable { var done = false }  // state changes arrive on `queue`
            let once = Once()
            l.newConnectionHandler = { [weak self] nw in self?.accept(nw) }
            l.stateUpdateHandler = { [weak self] st in
                switch st {
                case .ready:
                    if !once.done { once.done = true; k.resume(returning: l.port?.rawValue ?? port) }
                case .failed(let e):
                    if !once.done { once.done = true; k.resume(throwing: e) } else { self?.onFailure?(e) }
                case .cancelled:
                    if !once.done { once.done = true; k.resume(throwing: CancellationError()) }
                default: break
                }
            }
            queue.sync { listener = l; stopped = false }
            l.start(queue: queue)
        }
    }

    /// Closes the listening socket and every open connection, and cancels the work they started. Idempotent.
    func stop() {
        let closed = DispatchSemaphore(value: 0)
        let l: NWListener? = queue.sync {
            stopped = true
            let l = listener
            listener = nil
            for c in conns.values { teardown(c) }
            conns.removeAll()
            return l
        }
        guard let l else { return }
        l.stateUpdateHandler = { if case .cancelled = $0 { closed.signal() } }
        l.cancel()
        _ = closed.wait(timeout: .now() + 1)  // the socket is closed when stop() returns, so the port can be rebound at once
    }

    // MARK: connections (on `queue`)

    private func accept(_ nw: NWConnection) {
        guard !stopped, conns.count < maxConnections else { nw.cancel(); return }
        let conn = Conn(nw)
        conns[ObjectIdentifier(conn)] = conn
        nw.stateUpdateHandler = { [weak self, weak conn] st in
            if case .failed = st, let conn { self?.drop(conn) }
        }
        nw.start(queue: queue)
        let t = DispatchWorkItem { [weak self, weak conn] in
            guard let self, let conn, !conn.done else { return }
            self.finish(conn, MCPHTTP.plain(408, "Request timeout"))
        }
        conn.timeout = t
        queue.asyncAfter(deadline: .now() + requestTimeout, execute: t)
        read(conn)
    }

    private func teardown(_ conn: Conn) {
        conn.timeout?.cancel(); conn.task?.cancel(); conn.c.cancel()
    }

    private func drop(_ conn: Conn) {
        conns.removeValue(forKey: ObjectIdentifier(conn))
        teardown(conn)
    }

    private func finish(_ conn: Conn, _ r: MCPHTTPResponse) {
        guard !conn.responded else { return }
        conn.responded = true; conn.done = true
        conn.timeout?.cancel()
        conn.c.send(content: MCPHTTP.serialize(r), contentContext: .finalMessage, isComplete: true,
                    completion: .contentProcessed { [weak self, weak conn] _ in self?.queue.async { if let conn { self?.drop(conn) } } })
    }

    private func read(_ conn: Conn) {
        conn.c.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self, weak conn] data, _, complete, error in
            guard let self, let conn, !conn.done else { return }
            if let data { conn.buf.append(data) }
            if error != nil || (complete && conn.head == nil) { self.drop(conn); return }
            self.process(conn)
        }
    }

    private func process(_ conn: Conn) {
        if conn.head == nil {
            guard let end = conn.buf.range(of: Data([13, 10, 13, 10])) else {
                if conn.buf.count > MCPHTTP.maxHead { finish(conn, MCPHTTP.plain(431, "Headers too large")) } else { read(conn) }
                return
            }
            let raw = conn.buf[conn.buf.startIndex..<end.lowerBound]
            conn.buf = Data(conn.buf[end.upperBound...])
            switch MCPHTTP.parseHead(Data(raw)) {
            case .failure(let r): finish(conn, r); return
            case .success(let h):
                if let rejection = handler.precheck(h) { finish(conn, rejection); return }
                conn.head = h
                conn.need = Int(h.headers["content-length"] ?? "0") ?? 0  // precheck validated it
                if conn.buf.count < conn.need, h.headers["expect"]?.lowercased() == "100-continue" {
                    conn.c.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                }
            }
        }
        guard let head = conn.head else { return }
        guard conn.buf.count >= conn.need else { read(conn); return }
        let body = Data(conn.buf.prefix(conn.need))
        conn.timeout?.cancel()
        conn.done = true
        // The client closing its end while the tool runs (Ask can take minutes) cancels the work, as the spec asks.
        conn.c.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self, weak conn] _, _, complete, error in
            if (complete || error != nil), let conn { self?.queue.async { self?.drop(conn) } }
        }
        conn.task = Task { [handler, weak self, weak conn] in
            let r = await handler.respond(head, body: body)
            guard !Task.isCancelled else { return }
            self?.queue.async { if let conn { self?.finish(conn, r) } }
        }
    }
}
