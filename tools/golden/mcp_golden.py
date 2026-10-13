"""Golden fixtures for the Swift MCP server (eavesdroppy/Sources/Eavesdroppy/Port/MCP*.swift).

Runs the Python oracle (mcp_server.Server.handle) on a scratch copy of the store seed database and records, per JSON-RPC
message, the exact response. MCPServerTests replays the same messages on the Swift server (same database, a fake AI provider
that echoes the prompt) and compares the JSON.

  .venv/bin/python tools/golden/mcp_golden.py      # rewrite Tests/EavesdroppyTests/Fixtures/mcp/golden.json

The seed database comes from store_golden.py's fixtures (Fixtures/store/seed.db); regenerate that first if the seed changes.
`ask` uses a runner that returns the prompt it was given, so the prompt text is compared too. The user name is pinned to "Pat".
"""
import json, shutil, sys, tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))
import mcp_server  # noqa: E402
import notes  # noqa: E402

FIX = REPO / "eavesdroppy" / "Tests" / "EavesdroppyTests" / "Fixtures"
USER = "Pat"
MODERN_META = {"io.modelcontextprotocol/protocolVersion": "2026-07-28"}


def call(name, args=None, mid=1, meta=None, **extra):
    p = {"name": name}
    if args is not None:
        p["arguments"] = args
    if meta is not None:
        p["_meta"] = meta
    p.update(extra)
    return {"jsonrpc": "2.0", "id": mid, "method": "tools/call", "params": p}


def rpc(method, params=None, mid=1):
    m = {"jsonrpc": "2.0", "id": mid, "method": method}
    if params is not None:
        m["params"] = params
    return m


CASES = [
    # protocol
    ("initialize 2025-11-25", rpc("initialize", {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "t", "version": "1"}})),
    ("initialize 2024-11-05", rpc("initialize", {"protocolVersion": "2024-11-05"})),
    ("initialize unknown version", rpc("initialize", {"protocolVersion": "1999-01-01"})),
    ("initialize no params", rpc("initialize")),
    ("initialize modern meta", rpc("initialize", {"_meta": MODERN_META})),
    ("server/discover", rpc("server/discover", {"_meta": MODERN_META})),
    ("server/discover bare", rpc("server/discover")),
    ("ping", rpc("ping")),
    ("ping modern", rpc("ping", {"_meta": MODERN_META})),
    ("tools/list legacy", rpc("tools/list")),
    ("tools/list modern", rpc("tools/list", {"_meta": MODERN_META})),
    ("unknown method", rpc("resources/list")),
    ("unknown method modern", rpc("resources/list", {"_meta": MODERN_META})),
    ("modern unsupported version", rpc("tools/list", {"_meta": {"io.modelcontextprotocol/protocolVersion": "1900-01-01"}})),
    ("modern legacy version in meta", rpc("tools/list", {"_meta": {"io.modelcontextprotocol/protocolVersion": "2025-11-25"}})),
    ("string id", rpc("ping", mid="abc-1")),
    ("params not an object", rpc("tools/list", [1, 2])),
    ("params null", {"jsonrpc": "2.0", "id": 5, "method": "ping", "params": None}),
    ("notification", {"jsonrpc": "2.0", "method": "notifications/initialized"}),
    ("response from client", {"jsonrpc": "2.0", "id": 9, "result": {}}),
    ("not jsonrpc 2.0", {"jsonrpc": "1.0", "id": 1, "method": "ping"}),
    ("method not a string", {"jsonrpc": "2.0", "id": 1, "method": 7}),
    ("not an object", [1, 2, 3]),
    ("a bare string", "ping"),
    # search_meetings
    ("search: word", call("search_meetings", {"query": "budget"})),
    ("search: two words", call("search_meetings", {"query": "roadmap blocked"})),
    ("search: prefix", call("search_meetings", {"query": "budg"})),
    ("search: no hits", call("search_meetings", {"query": "zzzqqq"})),
    ("search: no query", call("search_meetings", {})),
    ("search: no arguments", call("search_meetings")),
    ("search: null query", call("search_meetings", {"query": None})),
    ("search: empty query", call("search_meetings", {"query": "  "})),
    ("search: fts syntax is quoted", call("search_meetings", {"query": 'budget" OR NEAR(a b) *'})),
    ("search: limit 1", call("search_meetings", {"limit": 1})),
    ("search: limit 0 clamps to 1", call("search_meetings", {"limit": 0})),
    ("search: limit 999 clamps to 50", call("search_meetings", {"limit": 999})),
    ("search: negative limit", call("search_meetings", {"query": "sync", "limit": -4})),
    ("search: limit is a float", call("search_meetings", {"limit": 1.0})),
    ("search: limit is a bool", call("search_meetings", {"limit": True})),
    ("search: limit is a string", call("search_meetings", {"limit": "3"})),
    ("search: query is a number", call("search_meetings", {"query": 5})),
    ("search: modern", call("search_meetings", {"query": "budget"}, meta=MODERN_META)),
    ("search: arguments is []", call("search_meetings", [])),
    ("search: arguments is 0", call("search_meetings", 0)),
    ("search: arguments is a non-empty list", call("search_meetings", [1])),
    ("search: arguments is a string", call("search_meetings", "x")),
    # get_meeting
    ("get 1", call("get_meeting", {"id": 1})),
    ("get 2 (offset +05:30)", call("get_meeting", {"id": 2})),
    ("get 3 (no turns, no notes)", call("get_meeting", {"id": 3})),
    ("get 4", call("get_meeting", {"id": 4})),
    ("get 5", call("get_meeting", {"id": 5})),
    ("get missing", call("get_meeting", {"id": 999})),
    ("get id 0", call("get_meeting", {"id": 0})),
    ("get id negative", call("get_meeting", {"id": -1})),
    ("get no id", call("get_meeting", {})),
    ("get id null", call("get_meeting", {"id": None})),
    ("get id string", call("get_meeting", {"id": "1"})),
    ("get id bool", call("get_meeting", {"id": True})),
    ("get id float", call("get_meeting", {"id": 1.5})),
    ("get id whole float", call("get_meeting", {"id": 1.0})),
    ("get modern", call("get_meeting", {"id": 1}, meta=MODERN_META)),
    # list_action_items
    ("actions: default (open)", call("list_action_items", {})),
    ("actions: all", call("list_action_items", {"open_only": False})),
    ("actions: open_only true", call("list_action_items", {"open_only": True})),
    ("actions: limit 1", call("list_action_items", {"open_only": False, "limit": 1})),
    ("actions: limit 0", call("list_action_items", {"limit": 0})),
    ("actions: limit 5000", call("list_action_items", {"limit": 5000, "open_only": False})),
    ("actions: open_only not a bool", call("list_action_items", {"open_only": "yes"})),
    ("actions: open_only 1", call("list_action_items", {"open_only": 1})),
    ("actions: open_only null", call("list_action_items", {"open_only": None})),
    ("actions: limit string", call("list_action_items", {"limit": "5"})),
    ("actions: modern", call("list_action_items", {}, meta=MODERN_META)),
    # ask (the runner returns the prompt)
    ("ask: word", call("ask", {"question": "What was agreed about the budget?"})),
    ("ask: stop words only", call("ask", {"question": "what is the"})),
    ("ask: scoped to meeting 2", call("ask", {"question": "roadmap blocked", "meeting_id": 2})),
    ("ask: scoped, no hit", call("ask", {"question": "zzzqqq", "meeting_id": 1})),
    ("ask: scoped to a missing meeting", call("ask", {"question": "budget", "meeting_id": 777})),
    ("ask: meeting_id null", call("ask", {"question": "budget", "meeting_id": None})),
    ("ask: meeting_id negative clamps to 0", call("ask", {"question": "budget", "meeting_id": -3})),
    ("ask: meeting_id string", call("ask", {"question": "budget", "meeting_id": "1"})),
    ("ask: empty question", call("ask", {"question": "   "})),
    ("ask: no question", call("ask", {})),
    ("ask: question not a string", call("ask", {"question": 4})),
    ("ask: modern", call("ask", {"question": "budget"}, meta=MODERN_META)),
    ("ask: runner error", call("ask", {"question": "FAIL please"})),
    # tools/call framing
    ("unknown tool", call("nope", {})),
    ("tools/call no name", rpc("tools/call", {"arguments": {}})),
    ("tools/call no params", rpc("tools/call")),
    ("unknown tool modern", call("nope", {}, meta=MODERN_META)),
]


def runner(prompt, timeout):
    assert timeout == mcp_server.ASK_TIMEOUT
    if "FAIL please" in prompt:
        return "", "claude exited 1: boom"
    return prompt, None


def main():
    notes.USER_NAME = USER
    notes.build_ask_prompt.__defaults__ = (tuple(), USER)  # user_name default is bound at def time
    scratch = Path(tempfile.mkdtemp(prefix="mcp-golden-"))
    try:
        db = scratch / "library.db"
        shutil.copy(FIX / "store" / "seed.db", db)
        server = mcp_server.Server(str(db), runner=runner)
        cases = []
        for name, msg in CASES:
            cases.append({"name": name, "request": msg, "response": server.handle(msg)})
        out = FIX / "mcp"
        out.mkdir(exist_ok=True)
        (out / "golden.json").write_text(json.dumps({"userName": USER, "cases": cases}, indent=1, ensure_ascii=False) + "\n")
        print(f"{len(cases)} cases -> {out / 'golden.json'}")
    finally:
        shutil.rmtree(scratch)


if __name__ == "__main__":
    main()
