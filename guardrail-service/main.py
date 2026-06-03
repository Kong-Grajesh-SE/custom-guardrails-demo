"""
Guardrail Service

Two responsibilities:
  1. /moderate  — LLM content moderation for the ai-custom-guardrail plugin
                  (main branch / local Kong stack)
  2. /v1/data/mcp/authz/allow — MCP tool-call authorization for the Kong OPA plugin
                  (serverless-gw branch / Konnect Serverless)
                  Accepts OPA plugin input format, returns {"result": true/false}.
"""

import logging
import re
from typing import Generator

from fastapi import FastAPI
from pydantic import BaseModel

from rules import moderate

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger(__name__)

app = FastAPI(title="Custom Guardrail Service", version="1.0.0")


class ModerateRequest(BaseModel):
    text: str
    source: str = "INPUT"


class ModerateResponse(BaseModel):
    block: bool
    block_message: str
    category: str | None = None
    source: str


@app.post("/moderate", response_model=ModerateResponse)
def moderate_content(req: ModerateRequest) -> ModerateResponse:
    result = moderate(req.text, req.source)

    log_fn = logger.warning if result.block else logger.info
    log_fn(
        "phase=%-6s  block=%-5s  category=%-20s  preview=%r",
        req.source,
        result.block,
        result.category or "-",
        req.text[:120],
    )

    return ModerateResponse(
        block=result.block,
        block_message=result.block_message,
        category=result.category,
        source=req.source,
    )


@app.get("/health")
def health():
    return {"status": "ok", "service": "custom-guardrail"}


# =============================================================================
# MCP tool-call authorization (Kong OPA plugin compatible)
# =============================================================================
#
# The Kong OPA plugin POSTs to this endpoint on every /mcp request:
#   POST /v1/data/mcp/authz/allow
#   {"input": {"request": {"http": {"parsed_body": {"method": "...", "params": {"name": "...", "arguments": {...}}}}}}}
#
# Returns {"result": true} to allow, {"result": false} to deny (Kong → HTTP 403).
#
# Three checks (all must pass):
#   1. method must be in ALLOWED_MCP_METHODS
#   2. params.name must NOT be in BLOCKED_TOOLS
#   3. no value in params.arguments matches DANGEROUS_ARG_PATTERNS

_ALLOWED_MCP_METHODS = {
    # Lifecycle
    "initialize",
    "ping",
    # Notifications (client → server, no response expected)
    "notifications/initialized",
    "notifications/cancelled",
    "notifications/progress",
    "notifications/roots/list_changed",
    # Tools
    "tools/call",
    "tools/list",
    # Resources
    "resources/list",
    "resources/read",
    "resources/templates/list",
    "resources/subscribe",
    "resources/unsubscribe",
    # Prompts
    "prompts/list",
    "prompts/get",
    # Completion
    "completion/complete",
    # Logging
    "logging/setLevel",
}

_BLOCKED_TOOLS = {
    "execute_shell",
    "run_command",
    "eval_code",
    "write_file",
    "delete_file",
    "drop_database",
    "admin_reset",
}

_DANGEROUS_ARG_PATTERNS = [
    r"rm\s+-rf",
    r"DROP\s+(TABLE|DATABASE)",
    r"/etc/passwd",
    r"__import__",
    r"eval\(",
    r"exec\(",
]


def _iter_values(obj) -> Generator[str, None, None]:
    """Recursively yield all scalar values from a nested dict/list as strings."""
    if isinstance(obj, dict):
        for v in obj.values():
            yield from _iter_values(v)
    elif isinstance(obj, list):
        for item in obj:
            yield from _iter_values(item)
    else:
        yield str(obj)


@app.post("/v1/data/mcp/authz/allow")
def mcp_authz(body: dict) -> dict:
    inp = body.get("input", {})
    http = inp.get("request", {}).get("http", {})
    http_method = http.get("method", "POST").upper()

    # GET requests (SSE channel setup) have no body — allow through
    if http_method == "GET":
        logger.info("mcp_authz ALLOW  GET request (SSE channel)")
        return {"result": True}

    # Kong OPA plugin nests parsed_body under input.request.http
    parsed = http.get("parsed_body", {})
    # fallback for direct/test calls that send input.parsed_body
    if not parsed:
        parsed = inp.get("parsed_body", {})
    method = parsed.get("method", "")
    params = parsed.get("params", {}) or {}
    tool_name = params.get("name", "")
    arguments = params.get("arguments", {}) or {}

    # Check 1 — method allowlist
    if method not in _ALLOWED_MCP_METHODS:
        logger.warning("mcp_authz DENY  method=%r not in allowlist", method)
        return {"result": False}

    # Check 2 — tool blocklist
    if tool_name in _BLOCKED_TOOLS:
        logger.warning("mcp_authz DENY  tool=%r is blocked", tool_name)
        return {"result": False}

    # Check 3 — dangerous argument patterns
    for val in _iter_values(arguments):
        for pattern in _DANGEROUS_ARG_PATTERNS:
            if re.search(pattern, val, re.IGNORECASE):
                logger.warning("mcp_authz DENY  dangerous pattern %r in args", pattern)
                return {"result": False}

    logger.info("mcp_authz ALLOW method=%r tool=%r", method, tool_name)
    return {"result": True}
