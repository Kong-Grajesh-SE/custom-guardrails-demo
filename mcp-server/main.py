"""
Sample MCP Server — JSON-RPC 2.0
=================================
Implements the Model Context Protocol so Kong + OPA can intercept and
authorize tool calls before they reach this server.

Safe tools (OPA allows):
  get_weather, calculator, search_docs, get_time

Dangerous tools (OPA blocks before reaching here):
  execute_shell, admin_reset, write_file, drop_database

Endpoint:  POST /
"""

import ast
import logging
from datetime import datetime, timezone
from typing import Any

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger(__name__)

app = FastAPI(title="Demo MCP Server", version="1.0.0")

# ── Fake data ─────────────────────────────────────────────────────────────────

FAKE_WEATHER: dict[str, dict] = {
    "sydney":    {"temp": 22, "condition": "Partly Cloudy", "humidity": "65%"},
    "london":    {"temp": 15, "condition": "Overcast",      "humidity": "80%"},
    "new york":  {"temp": 18, "condition": "Sunny",         "humidity": "55%"},
    "singapore": {"temp": 31, "condition": "Humid & Warm",  "humidity": "90%"},
    "tokyo":     {"temp": 20, "condition": "Clear",         "humidity": "60%"},
    "berlin":    {"temp": 12, "condition": "Rainy",         "humidity": "75%"},
}

FAKE_DOCS: list[dict] = [
    {"id": 1, "title": "Kong AI Gateway Overview",      "snippet": "Kong AI Gateway routes, protects, and observes LLM traffic."},
    {"id": 2, "title": "MCP Protocol Specification",   "snippet": "The Model Context Protocol standardises LLM tool use over JSON-RPC."},
    {"id": 3, "title": "OPA Policy Engine",             "snippet": "Open Policy Agent decouples policy decisions from application code."},
    {"id": 4, "title": "Konnect Serverless Nodes",     "snippet": "Serverless data planes are managed by Kong — no node admin required."},
    {"id": 5, "title": "Kong Pre-function Plugin",     "snippet": "pre-function runs Lua scripts in configurable Kong lifecycle phases."},
]

# ── Tool catalogue (also contains 'dangerous' tools for OPA demo) ─────────────

TOOLS: list[dict] = [
    # ── Safe tools ───────────────────────────────────────────────────────
    {
        "name": "get_weather",
        "description": "Get current weather for a city.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "city": {"type": "string", "description": "City name (e.g. Sydney, London)"},
            },
            "required": ["city"],
        },
    },
    {
        "name": "calculator",
        "description": "Evaluate a safe arithmetic expression (+ - * / ** %).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "expression": {"type": "string", "description": "e.g. '(3 + 5) * 2'"},
            },
            "required": ["expression"],
        },
    },
    {
        "name": "search_docs",
        "description": "Full-text search over the internal document library.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Search term"},
            },
            "required": ["query"],
        },
    },
    {
        "name": "get_time",
        "description": "Return the current UTC date and time.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    # ── Dangerous tools — present to demonstrate OPA blocking ─────────────
    {
        "name": "execute_shell",
        "description": "⛔ DEMO ONLY — Execute an arbitrary shell command.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "cmd": {"type": "string", "description": "Shell command to run"},
            },
            "required": ["cmd"],
        },
    },
    {
        "name": "admin_reset",
        "description": "⛔ DEMO ONLY — Reset admin credentials.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "write_file",
        "description": "⛔ DEMO ONLY — Write content to an arbitrary file path.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "path":    {"type": "string"},
                "content": {"type": "string"},
            },
        },
    },
    {
        "name": "drop_database",
        "description": "⛔ DEMO ONLY — Drop a named database.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string"},
            },
        },
    },
]

# ── Tool implementations ──────────────────────────────────────────────────────

def _tool_get_weather(args: dict) -> str:
    city = args.get("city", "").lower().strip()
    data = FAKE_WEATHER.get(city)
    if not data:
        available = ", ".join(FAKE_WEATHER.keys())
        return f"No data for '{city}'. Available cities: {available}."
    return (
        f"Weather in {city.title()}: {data['temp']}°C, "
        f"{data['condition']}, humidity {data['humidity']}."
    )


def _tool_calculator(args: dict) -> str:
    expr = args.get("expression", "")
    allowed_nodes = (
        ast.Expression, ast.BinOp, ast.UnaryOp, ast.Constant,
        ast.Add, ast.Sub, ast.Mult, ast.Div, ast.Pow, ast.Mod,
        ast.USub, ast.UAdd,
    )
    try:
        tree = ast.parse(expr.strip(), mode="eval")
        for node in ast.walk(tree):
            if not isinstance(node, allowed_nodes):
                return f"Error: operation '{type(node).__name__}' is not allowed."
        result = eval(compile(tree, "<string>", "eval"))  # noqa: S307 — safe: AST-validated
        return f"{expr} = {result}"
    except Exception as exc:
        return f"Error evaluating expression: {exc}"


def _tool_search_docs(args: dict) -> str:
    query = args.get("query", "").lower()
    matches = [
        f"[{d['id']}] {d['title']}: {d['snippet']}"
        for d in FAKE_DOCS
        if query in d["title"].lower() or query in d["snippet"].lower()
    ]
    if not matches:
        return f"No documents matched '{query}'."
    return "\n".join(matches)


def _tool_get_time(_args: dict) -> str:
    return f"Current UTC time: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S')} UTC"


# ── JSON-RPC helpers ──────────────────────────────────────────────────────────

def _ok(rpc_id: Any, result: Any) -> JSONResponse:
    return JSONResponse({"jsonrpc": "2.0", "id": rpc_id, "result": result})


def _error(rpc_id: Any, code: int, message: str) -> JSONResponse:
    return JSONResponse({"jsonrpc": "2.0", "id": rpc_id, "error": {"code": code, "message": message}})


# ── Handlers ──────────────────────────────────────────────────────────────────

def _handle_initialize(rpc_id: Any, _params: dict) -> JSONResponse:
    return _ok(rpc_id, {
        "protocolVersion": "2024-11-05",
        "capabilities": {"tools": {"listChanged": False}},
        "serverInfo": {"name": "demo-mcp-server", "version": "1.0.0"},
    })


def _handle_tools_list(rpc_id: Any, _params: dict) -> JSONResponse:
    return _ok(rpc_id, {"tools": TOOLS})


def _handle_tools_call(rpc_id: Any, params: dict) -> JSONResponse:
    tool = params.get("name", "")
    args = params.get("arguments", {})

    dispatch = {
        "get_weather":  _tool_get_weather,
        "calculator":   _tool_calculator,
        "search_docs":  _tool_search_docs,
        "get_time":     _tool_get_time,
    }

    # Dangerous tools: this code should never be reached if OPA is working
    dangerous = {"execute_shell", "admin_reset", "write_file", "drop_database"}
    if tool in dangerous:
        logger.critical(
            "DANGEROUS TOOL REACHED SERVER — OPA policy may not be enforced! tool=%r", tool
        )
        return _error(rpc_id, -32600, f"Tool '{tool}' is not permitted by server policy.")

    handler = dispatch.get(tool)
    if not handler:
        return _error(rpc_id, -32601, f"Unknown tool: '{tool}'")

    text = handler(args)
    logger.info("tools/call  tool=%r  result=%r", tool, text[:80])
    return _ok(rpc_id, {
        "content": [{"type": "text", "text": text}],
        "isError": False,
    })


# ── Main route ────────────────────────────────────────────────────────────────

@app.post("/")
async def jsonrpc(request: Request) -> JSONResponse:
    try:
        body = await request.json()
    except Exception:
        return _error(None, -32700, "Parse error — body is not valid JSON")

    rpc_id = body.get("id")
    method = body.get("method", "")
    params = body.get("params") or {}

    logger.info("RPC  method=%r  id=%r", method, rpc_id)

    if method == "initialize":
        return _handle_initialize(rpc_id, params)
    if method == "tools/list":
        return _handle_tools_list(rpc_id, params)
    if method == "tools/call":
        return _handle_tools_call(rpc_id, params)
    if method == "ping":
        return _ok(rpc_id, {})

    return _error(rpc_id, -32601, f"Method not found: '{method}'")


@app.get("/health")
def health():
    return {"status": "ok", "service": "demo-mcp-server"}
