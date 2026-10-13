import Foundation

// mcp_server.py's JSON-RPC layer and its four tools (D25), over the library already ported: LibraryDB for search, StoreDB +
// StoreSearch for action items and Ask, StoreMirror for the notes rendering, NotesGenerator + NotesProviders for the answer.
// Transport-free: MCPHTTP.swift carries it over Streamable HTTP. MCPServerTests compares every response with what the Python
// Server.handle produced for the same message on the same database (tools/golden/mcp_golden.py).
//
// Dual-era like the Python: a request whose params._meta names a 2026-07-28 protocol version is served statelessly; anything
// else is a legacy (2025-11-25 and earlier) request, with `initialize` negotiating the version.

struct MCPRpcError: Error {
    let code: Int, message: String, data: Any?
    init(_ code: Int, _ message: String, data: Any? = nil) { self.code = code; self.message = message; self.data = data }
}

/// A tool failure the model can read (isError result), never a protocol error.
struct MCPToolError: Error { let message: String; init(_ m: String) { message = m } }

final class MCPServer {
    static let modern = ["2026-07-28"]
    static let legacy = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    static let versionKey = "io.modelcontextprotocol/protocolVersion"
    static let serverInfo: [String: Any] = ["name": "eavesdroppy", "version": "1.0.0"]
    static let instructions = "Search and read the user's recorded meetings (notes, transcripts, action items). "
        + "Use search_meetings to find a meeting, get_meeting for its full notes and transcript, "
        + "list_action_items for open to-dos, ask to answer a question across all meetings."
    /// Modern clients reject discover / tools/list results without cache hints.
    static let cache: [String: Any] = ["ttlMs": 300000, "cacheScope": "public"]
    /// MCP clients give up on slow tools, so Ask stops sooner than the in-app one.
    static let askTimeout: TimeInterval = 120

    // Word for word from mcp_server.py: the golden test compares tools/list.
    static let tools: [[String: Any]] = [
        ["name": "search_meetings", "title": "Search meetings",
         "description": "Full-text search over meeting transcripts, titles and notes. Returns matching meetings, best first, "
            + "with a snippet and the transcript timestamp of the hit. With no query, lists the newest meetings.",
         "inputSchema": ["type": "object", "properties": [
            "query": ["type": "string", "description": "Words to search for (all must match; prefixes allowed)."],
            "limit": ["type": "integer", "description": "Max results (default 10, max 50)."]]]],
        ["name": "get_meeting", "title": "Get meeting",
         "description": "The full notes (summary, decisions, action items) and transcript of one meeting, by id from search_meetings.",
         "inputSchema": ["type": "object", "properties": ["id": ["type": "integer", "description": "Meeting id."]], "required": ["id"]]],
        ["name": "list_action_items", "title": "List action items",
         "description": "Action items from all meetings, newest meeting first.",
         "inputSchema": ["type": "object", "properties": [
            "open_only": ["type": "boolean", "description": "Only items not done (default true)."],
            "limit": ["type": "integer", "description": "Max results (default 50, max 200)."]]]],
        ["name": "ask", "title": "Ask your meetings",
         "description": "Answer a question from the user's meetings, with citations [Meeting title, date, MM:SS]. "
            + "Slow (runs Claude over retrieved excerpts).",
         "inputSchema": ["type": "object", "properties": [
            "question": ["type": "string"],
            "meeting_id": ["type": "integer", "description": "Optional: restrict to one meeting."]], "required": ["question"]]],
    ].map { var t = $0; t["annotations"] = ["readOnlyHint": true, "openWorldHint": false]; return t }

    let container: URL
    let userName: @Sendable () async -> String
    let resolve: @Sendable () async -> NotesProviders.Resolution
    var askTimeout = MCPServer.askTimeout

    /// container: the folder holding library.db. resolve: the AI provider at call time (the user may change it in Settings).
    init(container: URL, userName: @escaping @Sendable () async -> String, resolve: @escaping @Sendable () async -> NotesProviders.Resolution) {
        self.container = container; self.userName = userName; self.resolve = resolve
    }

    private var dbURL: URL { Library.dbURL(container) }

    // MARK: JSON helpers (Python's isinstance rules)

    /// A JSON integer: not a bool, not a float (`1.0` is a float in Python, so it is refused there too).
    static func int(_ v: Any?) -> Int? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), !CFNumberIsFloatType(n) else { return nil }
        return n.intValue
    }
    static func bool(_ v: Any?) -> Bool? {
        guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }
    /// `x or {}`: Python's falsiness for the JSON types.
    private static func falsy(_ v: Any?) -> Bool {
        switch v {
        case nil, is NSNull: return true
        case let s as String: return s.isEmpty
        case let a as [Any]: return a.isEmpty
        case let d as [String: Any]: return d.isEmpty
        case let n as NSNumber: return CFGetTypeID(n) == CFBooleanGetTypeID() ? !n.boolValue : n.doubleValue == 0
        default: return false
        }
    }
    private func clamped(_ args: [String: Any], _ key: String, _ def: Int, _ lo: Int, _ hi: Int) throws -> Int {
        guard let v = args.keys.contains(key) ? Self.int(args[key]) : def else { throw MCPToolError("\(key) must be an integer") }
        return max(lo, min(hi, v))
    }
    private static func text(_ s: String) -> [String: Any] { ["content": [["type": "text", "text": s]], "isError": false] }

    // MARK: tools

    /// Python opens read-only and raises on a missing file; here a missing file must never be created.
    private func requireDB() throws {
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            throw MCPToolError("cannot open library at \(dbURL.path): unable to open database file")
        }
    }

    /// StoreDB opened read-only: never creates, migrates or writes. A library from another schema version is a tool error.
    private func openStore() throws -> StoreDB {
        try requireDB()
        do { return try StoreDB(readOnly: dbURL) }
        catch let e as StoreError { throw MCPToolError(e.description) }
    }

    private func searchMeetings(_ a: [String: Any]) throws -> [String: Any] {
        var query: String?
        switch a["query"] {
        case nil, is NSNull: break
        case let s as String: query = s
        default: throw MCPToolError("query must be a string")
        }
        let limit = try clamped(a, "limit", 10, 1, 50)
        let rows: [MeetingSummary]
        do {
            guard let db = try LibraryDB(container: container) else { try requireDB(); return Self.text("No meetings found.") }
            rows = try db.listMeetings(query: query, limit: limit)
        } catch let e as LibraryError { throw MCPToolError("cannot open library at \(dbURL.path): \(e.description)") }
        if rows.isEmpty { return Self.text("No meetings found.") }
        return Self.text(rows.map { r in
            var line = "#\(r.id)  \(PyText.prefix(r.start, 16).replacingOccurrences(of: "T", with: " "))  \(r.title)  (\(StoreMirror.fmtTS(r.duration)))"
            if let s = r.snippet, !s.isEmpty { line += "\n    \(s)" + ((r.hitTS ?? "").isEmpty ? "" : "  [\(r.hitTS!)]") }
            return line
        }.joined(separator: "\n"))
    }

    private func getMeeting(_ a: [String: Any]) throws -> [String: Any] {
        guard let id = Self.int(a["id"]) else { throw MCPToolError("id must be an integer") }
        let m: MeetingDetail?
        do {
            guard let db = try LibraryDB(container: container) else { try requireDB(); throw MCPToolError("no meeting with id \(id)") }
            m = try db.meeting(id: id)
        } catch let e as LibraryError { throw MCPToolError("cannot open library at \(dbURL.path): \(e.description)") }
        guard let d = m else { throw MCPToolError("no meeting with id \(id)") }
        let meeting = StoreMirror.Meeting(
            id: id, title: d.summary.title, start: d.summary.start, duration: d.summary.duration, attendees: d.attendees, notesMD: d.notes,
            folder: d.summary.folder, audioPath: d.summary.audioPath,
            turns: d.turns.map { StoreMirror.Turn(start: $0.start, speaker: $0.speaker, text: $0.text) })
        return Self.text(try StoreMirror.renderNotes(meeting))
    }

    private func listActionItems(_ a: [String: Any]) throws -> [String: Any] {
        var openOnly = true
        if a.keys.contains("open_only") {
            guard let b = Self.bool(a["open_only"]) else { throw MCPToolError("open_only must be a boolean") }
            openOnly = b
        }
        let limit = try clamped(a, "limit", 50, 1, 200)
        let db = try openStore(); defer { db.close() }
        let rows = try db.rows("SELECT a.owner, a.task, a.due, a.done, m.title, m.start, a.meeting_id FROM action_items a"
                               + " JOIN meetings m ON m.id = a.meeting_id" + (openOnly ? " WHERE a.done = 0" : "")
                               + " ORDER BY m.start DESC, a.id LIMIT ?", [limit])
        if rows.isEmpty { return Self.text("No action items.") }
        return Self.text(rows.map { r in
            let owner = r.text(0) ?? "", due = r.text(2) ?? ""
            return "- [\((r.int(3) ?? 0) != 0 ? "x" : " ")] \(owner.isEmpty ? "—" : owner) — \(r.text(1) ?? "") — \(due.isEmpty ? "—" : due)"
                + "  (\(r.text(4) ?? ""), \(PyText.prefix(r.text(5) ?? "", 10)), meeting #\(r.int(6) ?? 0))"
        }.joined(separator: "\n"))
    }

    private func ask(_ a: [String: Any]) async throws -> [String: Any] {
        guard let q = a["question"] as? String, !q.pyStripped.isEmpty else { throw MCPToolError("question must be a non-empty string") }
        var scope: StoreScope?
        if let v = a["meeting_id"], !(v is NSNull) {
            guard let n = Self.int(v) else { throw MCPToolError("meeting_id must be an integer") }
            scope = .meeting(max(0, n))
        }
        let (segments, notes): ([StoreSegment], [StoreNoteExcerpt])
        do {
            let db = try openStore(); defer { db.close() }  // closed before the model runs
            (segments, notes) = try StoreSearch.retrieve(db, question: q, scope: scope)
        }
        let resolution = await resolve(), name = await userName(), timeout = askTimeout
        do {
            let answer = try await withTimeout(name: "ask", seconds: timeout) {
                try await NotesGenerator.ask(
                    question: q, segments: segments.map { .init(title: $0.title, date: $0.date, ts: $0.ts, speaker: $0.speaker, text: $0.text) },
                    notes: notes.map { .init(title: $0.title, date: $0.date, notes: $0.notes) }, userName: name, resolution: resolution)
            }
            return Self.text(answer)
        } catch is CancellationError { throw CancellationError()
        } catch { throw MCPToolError((error as? LocalizedError)?.errorDescription ?? "\(error)") }
    }

    // MARK: protocol

    private func callTool(_ params: [String: Any]) async throws -> [String: Any] {
        let name = params["name"] as? String
        let rawArgs = params["arguments"]
        let args: Any = Self.falsy(rawArgs) ? [String: Any]() : rawArgs!
        guard let name, Self.tools.contains(where: { $0["name"] as? String == name }) else {
            throw MCPRpcError(-32602, "Unknown tool: \(params["name"].map { ($0 as? String) ?? "\($0)" } ?? "None")")
        }
        guard let a = args as? [String: Any] else { throw MCPRpcError(-32602, "arguments must be an object") }
        do {
            switch name {
            case "search_meetings": return try searchMeetings(a)
            case "get_meeting": return try getMeeting(a)
            case "list_action_items": return try listActionItems(a)
            default: return try await ask(a)
            }
        } catch let e as MCPToolError {
            return ["content": [["type": "text", "text": e.message]], "isError": true]
        } catch is CancellationError {
            throw CancellationError()
        } catch {  // a bug or a DB problem must not take the server down
            return ["content": [["type": "text", "text": "\(name) failed: \(error)"]], "isError": true]
        }
    }

    static func ok(_ id: Any, _ result: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": result] }
    static func err(_ id: Any?, _ code: Int, _ message: String, data: Any? = nil) -> [String: Any] {
        var e: [String: Any] = ["code": code, "message": message]
        if let data { e["data"] = data }
        return ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": e]
    }

    /// One parsed JSON-RPC message -> its response, or nil (a notification, or a response to something never sent).
    /// Throws CancellationError only if the caller cancelled the task (the client hung up).
    func handle(_ message: Any) async throws -> [String: Any]? {
        guard let msg = message as? [String: Any], msg["jsonrpc"] as? String == "2.0", let method = msg["method"] as? String else {
            if let m = message as? [String: Any], m["method"] == nil, m["result"] != nil || m["error"] != nil { return nil }
            return Self.err((message as? [String: Any])?["id"], -32600, "Invalid Request")
        }
        guard let id = msg["id"] else { return nil }  // notification: notifications/initialized, notifications/cancelled, ...
        var params: [String: Any] = [:]
        if let p = msg["params"], !(p is NSNull) {
            guard let d = p as? [String: Any] else { return Self.err(id, -32602, "params must be an object") }
            params = d
        }
        do {
            let meta = params["_meta"] as? [String: Any] ?? [:]
            let isModern = meta[Self.versionKey] != nil
            if isModern, !((meta[Self.versionKey] as? String).map(Self.modern.contains) ?? false) {
                throw MCPRpcError(-32022, "Unsupported protocol version", data: ["supported": Self.modern, "requested": meta[Self.versionKey]!])
            }
            if method == "initialize" {
                let want = params["protocolVersion"] as? String
                return Self.ok(id, ["protocolVersion": want.flatMap { Self.legacy.contains($0) ? $0 : nil } ?? Self.legacy[0],
                                    "capabilities": ["tools": [String: Any]()], "serverInfo": Self.serverInfo, "instructions": Self.instructions])
            }
            if method == "server/discover" {
                var r: [String: Any] = ["resultType": "complete", "supportedVersions": Self.modern, "capabilities": ["tools": [String: Any]()],
                                        "_meta": ["io.modelcontextprotocol/serverInfo": Self.serverInfo], "instructions": Self.instructions]
                r.merge(Self.cache) { $1 }
                return Self.ok(id, r)
            }
            var result: [String: Any]
            switch method {
            case "ping": result = [:]
            case "tools/list":
                result = ["tools": Self.tools]
                if isModern { result.merge(Self.cache) { $1 } }
            case "tools/call": result = try await callTool(params)
            default: throw MCPRpcError(-32601, "Method not found: \(method)")
            }
            if isModern { result["resultType"] = "complete" }
            return Self.ok(id, result)
        } catch let e as MCPRpcError {
            return Self.err(id, e.code, e.message, data: e.data)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return Self.err(id, -32603, "Internal error: \(error)")
        }
    }
}
