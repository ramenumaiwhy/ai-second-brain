#!/usr/bin/env python3
"""Mask obvious secrets before transcript text is persisted."""

from __future__ import annotations

import re
import sys


PRIVATE_KEY_BLOCK_RE = re.compile(
    r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----",
    re.DOTALL,
)

TOKEN_PATTERNS: tuple[tuple[re.Pattern[str], str], ...] = (
    (re.compile(r"\bBearer\s+[A-Za-z0-9._~+/=-]{8,}"), "Bearer [REDACTED]"),
    (re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}\b"), "[REDACTED_API_KEY]"),
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9_]{20,}\b"), "[REDACTED_GITHUB_TOKEN]"),
    (re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"), "[REDACTED_SLACK_TOKEN]"),
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "[REDACTED_AWS_ACCESS_KEY]"),
    (re.compile(r"\b[0-9]{6,10}:[A-Za-z0-9_-]{30,}\b"), "[REDACTED_BOT_TOKEN]"),
)

SENSITIVE_NAME_RE = re.compile(
    r"(api[_-]?key|token|secret|password|passwd|pwd|private[_-]?key|"
    r"access[_-]?key|client[_-]?secret|refresh[_-]?token|webhook[_-]?secret)",
    re.IGNORECASE,
)
ASSIGNMENT_RE = re.compile(r"^(\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*)(.*?)(\s*)$")
COLON_RE = re.compile(r"^(\s*[\"']?([A-Za-z_][A-Za-z0-9_-]*)[\"']?\s*:\s*)(.*?)(\s*)$")


def _redacted_value(value: str) -> str:
    stripped = value.strip()
    if stripped.startswith('"'):
        return '"[REDACTED]"'
    if stripped.startswith("'"):
        return "'[REDACTED]'"
    return "[REDACTED]"


def _redact_sensitive_assignments(text: str) -> str:
    redacted_lines: list[str] = []
    for line in text.splitlines(keepends=True):
        body = line.rstrip("\r\n")
        newline = line[len(body) :]

        assignment = ASSIGNMENT_RE.match(body)
        if assignment and SENSITIVE_NAME_RE.search(assignment.group(2)):
            redacted_lines.append(f"{assignment.group(1)}{_redacted_value(assignment.group(3))}{assignment.group(4)}{newline}")
            continue

        colon = COLON_RE.match(body)
        if colon and SENSITIVE_NAME_RE.search(colon.group(2)):
            redacted_lines.append(f"{colon.group(1)}{_redacted_value(colon.group(3))}{colon.group(4)}{newline}")
            continue

        redacted_lines.append(line)
    return "".join(redacted_lines)


def redact_text(text: str) -> str:
    text = PRIVATE_KEY_BLOCK_RE.sub("[REDACTED_PRIVATE_KEY_BLOCK]", text)
    for pattern, replacement in TOKEN_PATTERNS:
        text = pattern.sub(replacement, text)
    return _redact_sensitive_assignments(text)


def main() -> int:
    sys.stdout.write(redact_text(sys.stdin.read()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
