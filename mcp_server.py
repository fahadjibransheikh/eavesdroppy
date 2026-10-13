#!/usr/bin/env python3
"""Eavesdroppy MCP server (D17): JSON-RPC 2.0 over newline-delimited stdio, stdlib only, read-only on library.db.

Dual-era per the MCP spec (current revision 2026-07-28, checked at modelcontextprotocol.io 2026-10-12):
  - modern clients: stateless, every request carries _meta["io.modelcontextprotocol/protocolVersion"];
    `server/discover` is answered; results carry resultType "complete"; an unknown version gets -32022.
  - legacy clients (2025-11-25 and earlier): `initialize` handshake with version negotiation.
Tools: search_meetings, get_meeting, list_action_items, ask. Tool failures are isError results, never crashes.

  python mcp_server.py [--db PATH]      (default: $EAVESDROPPY_DB or the droplet container's library.db)
"""
import argparse, json, os, sys
from pathlib import Path

import library, notes

MODERN = ["2026-07-28"]
LEGACY = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
VERSION_KEY = "io.modelcontextprotocol/protocolVersion"
SERVER_INFO = {"name": "eavesdroppy", "version": "1.0.0"}
INSTRUCTIONS = ("Search and read the user's recorded meetings (notes, transcripts, action items). "
                "Use search_meetings to find a meeting, get_meeting for its full notes and transcript, "
                "list_action_items for open to-dos, ask to answer a question across all meetings.")
DEFAULT_DB = "~/Library/Application Support/Droppy/Droplets/eavesdroppy/Container/library.db"
CACHE = {"ttlMs": 300000, "cacheScope": "public"}  # required by 2026-07-28 clients on discover/tools/list (Claude Code 2.1.296 enforces it)
ASK_TIMEOUT = 120  # MCP clients give up on slow tools; the in-app Ask uses the longer default

TOOLS = [
    {"name": "search_meetings", "title": "Search meetings",
     "description": "Full-text search over meeting transcripts, titles and notes. Returns matching meetings, best first, "
                    "with a snippet and the transcript timestamp of the hit. With no query, lists the newest meetings.",
     "inputSchema": {"type": "object", "properties": {
         "query": {"type": "string", "description": "Words to search for (all must match; prefixes allowed)."},
         "limit": {"type": "integer", "description": "Max results (default 10, max 50)."}}}},
    {"name": "get_meeting", "title": "Get meeting",
     "description": "The full notes (summary, decisions, action items) and transcript of one meeting, by id from search_meetings.",
     "inputSchema": {"type": "object", "properties": {"id": {"type": "integer", "description": "Meeting id."}}, "required": ["id"]}},
    {"name": "list_action_items", "title": "List action items",
     "description": "Action items from all meetings, newest meeting first.",
     "inputSchema": {"type": "object", "properties": {
         "open_only": {"type": "boolean", "description": "Only items not done (default true)."},
         "limit": {"type": "integer", "description": "Max results (default 50, max 200)."}}}},
    {"name": "ask", "title": "Ask your meetings",
     "description": "Answer a question from the user's meetings, with citations [Meeting title, date, MM:SS]. "
                    "Slow (runs Claude over retrieved excerpts).",
     "inputSchema": {"type": "object", "properties": {
         "question": {"type": "string"},
         "meeting_id": {"type": "integer", "description": "Optional: restrict to one meeting."}}, "required": ["question"]}},
]
for _t in TOOLS:
    _t["annotations"] = {"readOnlyHint": True, "openWorldHint": False}


class ToolError(Exception):
    pass


def _int(args, key, default, lo, hi):
    v = args.get(key, default)
    if isinstance(v, bool) or not isinstance(v, int):
        raise ToolError(f"{key} must be an integer")
    return max(lo, min(hi, v))


def _text(s):
    return {"content": [{"type": "text", "text": s}], "isError": False}


class Server:
    def __init__(self, db_path, runner=notes.run_claude):
        self.db_path, self.runner = db_path, runner

    def _db(self):
        try:
            return library.connect_readonly(self.db_path)
        except Exception as e:
            raise ToolError(f"cannot open library at {self.db_path}: {e}")

    # ----- tools -----
    def search_meetings(self, a):
        query = a.get("query")
        if query is not None and not isinstance(query, str):
            raise ToolError("query must be a string")
        limit = _int(a, "limit", 10, 1, 50)
        db = self._db()
        try:
            rows = library.list_meetings(db, query, limit=limit)
        finally:
            db.close()
        if not rows:
            return _text("No meetings found.")
        out = []
        for r in rows:
            line = f"#{r['id']}  {r['start'][:16].replace('T', ' ')}  {r['title']}  ({library.fmt_ts(r['duration'])})"
            if r.get("snippet"):
                line += f"\n    {r['snippet']}" + (f"  [{r['hit_ts']}]" if r.get("hit_ts") else "")
            out.append(line)
        return _text("\n".join(out))

    def get_meeting(self, a):
        mid = a.get("id")
        if isinstance(mid, bool) or not isinstance(mid, int):
            raise ToolError("id must be an integer")
        db = self._db()
        try:
            m = library.get_meeting(db, mid)
        finally:
            db.close()
        if not m:
            raise ToolError(f"no meeting with id {mid}")
        return _text(library.render_notes_md(m))

    def list_action_items(self, a):
        open_only = a.get("open_only", True)
        if not isinstance(open_only, bool):
            raise ToolError("open_only must be a boolean")
        limit = _int(a, "limit", 50, 1, 200)
        db = self._db()
        try:
            rows = library.list_action_items(db, open_only, limit)
        finally:
            db.close()
        if not rows:
            return _text("No action items.")
        return _text("\n".join(
            f"- [{'x' if r['done'] else ' '}] {r['owner'] or '—'} — {r['task']} — {r['due'] or '—'}"
            f"  ({r['meeting_title']}, {r['meeting_start'][:10]}, meeting #{r['meeting_id']})" for r in rows))

    def ask(self, a):
        q = a.get("question")
        if not isinstance(q, str) or not q.strip():
            raise ToolError("question must be a non-empty string")
        scope = None
        if a.get("meeting_id") is not None:
            scope = {"meeting_id": _int(a, "meeting_id", 0, 0, 2**62)}
        db = self._db()
        try:
            segments, nts = notes.retrieve(db, q, scope)
        finally:
            db.close()
        text, err = self.runner(notes.build_ask_prompt(q, segments, nts), ASK_TIMEOUT)
        if err:
            raise ToolError(err)
        return _text(text)

    # ----- protocol -----
    def call_tool(self, params):
        name, args = params.get("name"), params.get("arguments") or {}
        fn = {t["name"]: getattr(self, t["name"]) for t in TOOLS}.get(name)
        if fn is None:
            raise RpcError(-32602, f"Unknown tool: {name}")
        if not isinstance(args, dict):
            raise RpcError(-32602, "arguments must be an object")
        try:
            return fn(args)
        except ToolError as e:
            return {"content": [{"type": "text", "text": str(e)}], "isError": True}
        except Exception as e:  # a bug or a DB problem must not take the server down
            print(f"tool {name} failed: {e!r}", file=sys.stderr)
            return {"content": [{"type": "text", "text": f"{name} failed: {type(e).__name__}: {e}"}], "isError": True}

    def handle(self, msg):
        """One parsed JSON-RPC message -> response dict, or None (notification)."""
        if not isinstance(msg, dict) or msg.get("jsonrpc") != "2.0" or not isinstance(msg.get("method"), str):
            if isinstance(msg, dict) and "method" not in msg and ("result" in msg or "error" in msg):
                return None  # a response to something we never sent
            return _err(msg.get("id") if isinstance(msg, dict) else None, -32600, "Invalid Request")
        mid, method = msg.get("id"), msg["method"]
        if "id" not in msg:
            return None  # notification: notifications/initialized, notifications/cancelled, ...
        params = msg.get("params")
        if params is None:
            params = {}
        if not isinstance(params, dict):
            return _err(mid, -32602, "params must be an object")
        try:
            meta = params.get("_meta") if isinstance(params.get("_meta"), dict) else {}
            modern = VERSION_KEY in meta
            if modern and meta[VERSION_KEY] not in MODERN:
                raise RpcError(-32022, "Unsupported protocol version", {"supported": MODERN, "requested": meta[VERSION_KEY]})
            if method == "initialize":
                want = params.get("protocolVersion")
                return _ok(mid, {"protocolVersion": want if want in LEGACY else LEGACY[0], "capabilities": {"tools": {}},
                                 "serverInfo": SERVER_INFO, "instructions": INSTRUCTIONS})
            if method == "server/discover":
                return _ok(mid, {"resultType": "complete", "supportedVersions": MODERN, "capabilities": {"tools": {}},
                                 "_meta": {"io.modelcontextprotocol/serverInfo": SERVER_INFO}, "instructions": INSTRUCTIONS, **CACHE})
            if method == "ping":
                result = {}
            elif method == "tools/list":
                result = {"tools": TOOLS, **(CACHE if modern else {})}  # modern clients reject list results without cache hints
            elif method == "tools/call":
                result = self.call_tool(params)
            else:
                raise RpcError(-32601, f"Method not found: {method}")
            if modern:
                result = {"resultType": "complete", **result}
            return _ok(mid, result)
        except RpcError as e:
            return _err(mid, e.code, e.message, e.data)
        except Exception as e:
            print(f"internal error: {e!r}", file=sys.stderr)
            return _err(mid, -32603, f"Internal error: {e}")

    def handle_line(self, line):
        try:
            msg = json.loads(line)
        except ValueError:
            return _err(None, -32700, "Parse error")
        return self.handle(msg)


class RpcError(Exception):
    def __init__(self, code, message, data=None):
        super().__init__(message)
        self.code, self.message, self.data = code, message, data


def _ok(mid, result):
    return {"jsonrpc": "2.0", "id": mid, "result": result}


def _err(mid, code, message, data=None):
    e = {"code": code, "message": message}
    if data is not None:
        e["data"] = data
    return {"jsonrpc": "2.0", "id": mid, "error": e}


def serve(server, stdin=sys.stdin, stdout=sys.stdout):
    for line in stdin:  # EOF on stdin = the client closed us: exit
        if not line.strip():
            continue
        resp = server.handle_line(line)
        if resp is not None:
            stdout.write(json.dumps(resp) + "\n")
            stdout.flush()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--db", default=os.environ.get("EAVESDROPPY_DB") or DEFAULT_DB)
    a = ap.parse_args()
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stdin.reconfigure(encoding="utf-8", errors="replace")
    serve(Server(str(Path(a.db).expanduser())))


if __name__ == "__main__":
    main()
