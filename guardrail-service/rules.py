"""
Moderation rules for the custom guardrail service.

Rules are split into INPUT (user request) and OUTPUT (LLM response) phases
so different policies can apply in each direction.
"""

import re
from dataclasses import dataclass
from typing import Dict, List, Optional


@dataclass
class ModerationResult:
    block: bool
    block_message: str
    category: Optional[str] = None


# ── INPUT rules (applied to the incoming user message) ───────────────────────

INPUT_BLOCKED_KEYWORDS: Dict[str, List[str]] = {
    "jailbreak": [
        "ignore your instructions",
        "ignore previous instructions",
        "forget your instructions",
        "bypass your safeguards",
        "jailbreak",
        "dan mode",
        "do anything now",
        "disregard all rules",
    ],
    "violence": [
        "how to kill someone",
        "how to harm someone",
        "how to murder",
        "commit violence",
    ],
    "illegal_activity": [
        "how to make a bomb",
        "how to build a bomb",
        "how to make meth",
        "how to make fentanyl",
        "how to make cocaine",
        "how to synthesize drugs",
        "how to make explosives",
    ],
    "malware": [
        "write me malware",
        "create a virus",
        "write a keylogger",
        "ransomware code",
        "write me a trojan",
    ],
}

INPUT_BLOCKED_PATTERNS: Dict[str, List[str]] = {
    "jailbreak": [
        r"(ignore|forget|bypass|disregard|override)\s+(your\s+)?(previous\s+)?(instructions?|rules?|guidelines?|training|system\s+prompt)",
        r"(pretend|act|behave)\s+(as\s+if\s+)?(you\s+)?(are|were|have|with)\s*(no\s+)?(restrictions?|rules?|limits?|filter)",
        r"\bDAN\b.{0,20}(mode|prompt)",
    ],
    "violence": [
        r"how\s+to\s+(kill|murder|harm|hurt|attack)\s+(a\s+)?(person|someone|people|human)",
        r"(kill|murder|hurt)\s+(my|the)\s+(boss|teacher|parent|classmate|neighbor)",
    ],
    "illegal_activity": [
        r"how\s+to\s+(make|build|create|synthesize|produce)\s+(a\s+)?(bomb|explosive|methamphetamine|fentanyl|cocaine|drug)",
        r"(buy|obtain|acquire)\s+(illegal\s+)?(gun|weapon|drug|narcotic)s?\s+(online|darkweb|dark\s+web)",
    ],
    "malware": [
        r"(write|create|build|code|develop)\s+(me\s+)?(a\s+)?(malware|virus|keylogger|ransomware|trojan|rootkit|spyware)",
    ],
}


# ── OUTPUT rules (applied to the LLM response) ───────────────────────────────

OUTPUT_BLOCKED_KEYWORDS: Dict[str, List[str]] = {
    "harmful_step_by_step": [
        "step 1: obtain the explosive",
        "step 1: acquire the weapon",
    ],
}

OUTPUT_BLOCKED_PATTERNS: Dict[str, List[str]] = {
    "pii_leak": [
        # email addresses
        r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b",
        # US Social Security Number
        r"\b\d{3}-\d{2}-\d{4}\b",
        # Credit card numbers (16-digit groups)
        r"\b(?:\d{4}[ -]?){3}\d{4}\b",
    ],
    "harmful_instruction": [
        r"(step\s+\d+|first,?|second,?|third,?).{0,80}(obtain|acquire|purchase)\s+(explosive|weapon|drug|firearm)",
    ],
}


# ── Core moderation logic ─────────────────────────────────────────────────────

def _check_keywords(
    text_lower: str,
    rules: Dict[str, List[str]],
    source: str,
) -> Optional[ModerationResult]:
    for category, keywords in rules.items():
        for kw in keywords:
            if kw and kw in text_lower:
                return ModerationResult(
                    block=True,
                    block_message=(
                        f"[{source}] Blocked — category: {category}. "
                        f"Content matches a prohibited keyword."
                    ),
                    category=category,
                )
    return None


def _check_patterns(
    text: str,
    rules: Dict[str, List[str]],
    source: str,
) -> Optional[ModerationResult]:
    for category, patterns in rules.items():
        for pattern in patterns:
            if re.search(pattern, text, re.IGNORECASE):
                return ModerationResult(
                    block=True,
                    block_message=(
                        f"[{source}] Blocked — category: {category}. "
                        f"Content matches a prohibited pattern."
                    ),
                    category=category,
                )
    return None


def moderate(text: str, source: str = "INPUT") -> ModerationResult:
    """
    Inspect *text* and return a ModerationResult.

    Args:
        text:   The content to inspect (user message or LLM response).
        source: "INPUT" when checking the request, "OUTPUT" when checking
                the response.  Kong sets this automatically via $(source).
    """
    text_lower = text.lower()

    if source == "INPUT":
        result = _check_keywords(text_lower, INPUT_BLOCKED_KEYWORDS, source)
        if result:
            return result
        result = _check_patterns(text, INPUT_BLOCKED_PATTERNS, source)
        if result:
            return result
    else:  # OUTPUT
        result = _check_keywords(text_lower, OUTPUT_BLOCKED_KEYWORDS, source)
        if result:
            return result
        result = _check_patterns(text, OUTPUT_BLOCKED_PATTERNS, source)
        if result:
            return result

    return ModerationResult(block=False, block_message="Content approved")
