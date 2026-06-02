#!/usr/bin/env python3
"""Mask obvious secrets before transcript text is persisted."""

from __future__ import annotations

import datetime as _datetime
import os
import re
import sys


PRIVATE_KEY_BLOCK_RE = re.compile(
    r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----",
    re.DOTALL,
)

TOKEN_PATTERNS: tuple[tuple[re.Pattern[str], str], ...] = (
    (re.compile(r"\bBearer\s+[A-Za-z0-9._~+/=-]{8,}"), "Bearer [REDACTED]"),
    (re.compile(r"\bsk-ant-[A-Za-z0-9_-]{20,}\b"), "[REDACTED_ANTHROPIC_KEY]"),
    (re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}\b"), "[REDACTED_API_KEY]"),
    (re.compile(r"\bAIza[0-9A-Za-z_-]{30,}\b"), "[REDACTED_GOOGLE_API_KEY]"),
    (re.compile(r"\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}\b"), "[REDACTED_STRIPE_KEY]"),
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9_]{20,}\b"), "[REDACTED_GITHUB_TOKEN]"),
    (re.compile(r"\bhf_[A-Za-z0-9]{20,}\b"), "[REDACTED_HUGGINGFACE_TOKEN]"),
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


def _contains_unescaped_quote(value: str, quote: str) -> bool:
    escaped = False
    for char in value:
        if escaped:
            escaped = False
            continue
        if char == "\\":
            escaped = True
            continue
        if char == quote:
            return True
    return False


def _starts_unclosed_quote(value: str) -> str:
    stripped = value.lstrip()
    if not stripped or stripped[0] not in ("'", '"'):
        return ""
    quote = stripped[0]
    if _contains_unescaped_quote(stripped[1:], quote):
        return ""
    return quote


def _has_closing_quote(value: str, quote: str) -> bool:
    escaped = False
    for index, char in enumerate(value):
        if escaped:
            escaped = False
            continue
        if char == "\\":
            escaped = True
            continue
        if char != quote:
            continue
        tail = value[index + 1 :].strip()
        while tail and tail[0] in ",;]})":
            tail = tail[1:].lstrip()
        return not tail or tail.startswith("#")
    return False


def _find_closing_quote(lines: list[str], start_index: int, quote: str) -> int | None:
    for index in range(start_index, len(lines)):
        body = lines[index].rstrip("\r\n")
        if _has_closing_quote(body, quote):
            return index
    return None


def _audit_redaction(count: int) -> None:
    if count <= 0:
        return
    audit_log = os.environ.get("REDACTION_AUDIT_LOG", "")
    if not audit_log:
        return
    timestamp = _datetime.datetime.now().isoformat(timespec="seconds")
    try:
        with open(audit_log, "a", encoding="utf-8") as handle:
            handle.write(f"{timestamp}: redacted {count} secret marker(s)\n")
    except OSError:
        pass


def _redact_sensitive_assignments(text: str) -> tuple[str, int]:
    lines = text.splitlines(keepends=True)
    redacted_lines: list[str] = []
    count = 0
    index = 0
    while index < len(lines):
        line = lines[index]
        body = line.rstrip("\r\n")
        newline = line[len(body) :]

        assignment = ASSIGNMENT_RE.match(body)
        if assignment and SENSITIVE_NAME_RE.search(assignment.group(2)):
            redacted_lines.append(f"{assignment.group(1)}{_redacted_value(assignment.group(3))}{assignment.group(4)}{newline}")
            count += 1
            pending_quote = _starts_unclosed_quote(assignment.group(3))
            closing_index = _find_closing_quote(lines, index + 1, pending_quote) if pending_quote else None
            index = closing_index + 1 if closing_index is not None else index + 1
            continue

        colon = COLON_RE.match(body)
        if colon and SENSITIVE_NAME_RE.search(colon.group(2)):
            redacted_lines.append(f"{colon.group(1)}{_redacted_value(colon.group(3))}{colon.group(4)}{newline}")
            count += 1
            pending_quote = _starts_unclosed_quote(colon.group(3))
            closing_index = _find_closing_quote(lines, index + 1, pending_quote) if pending_quote else None
            index = closing_index + 1 if closing_index is not None else index + 1
            continue

        redacted_lines.append(line)
        index += 1
    return "".join(redacted_lines), count


def redact_text(text: str) -> str:
    redaction_count = 0
    text, count = PRIVATE_KEY_BLOCK_RE.subn("[REDACTED_PRIVATE_KEY_BLOCK]", text)
    redaction_count += count
    for pattern, replacement in TOKEN_PATTERNS:
        text, count = pattern.subn(replacement, text)
        redaction_count += count
    text, count = _redact_sensitive_assignments(text)
    redaction_count += count
    _audit_redaction(redaction_count)
    return text


def main() -> int:
    sys.stdout.write(redact_text(sys.stdin.read()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
