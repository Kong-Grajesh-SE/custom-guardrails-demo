"""
Custom Guardrail Service

Receives moderation requests from Kong's AI Custom Guardrail plugin,
evaluates the content against configured rules, and returns a JSON response
indicating whether the content should be blocked.

Expected request body (sent by Kong via config.request.body):
    {
        "text":   "<content to inspect>",
        "source": "INPUT" | "OUTPUT"
    }

Response format consumed by Kong via config.response:
    {
        "block":         true | false,
        "block_message": "<reason string>"
    }
"""

import logging

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
