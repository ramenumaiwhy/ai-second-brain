#!/usr/bin/env python3
"""Mask obvious secrets before transcript text is persisted."""

from __future__ import annotations

import datetime as _datetime
import os
import re
import sys


sys.dont_write_bytecode = True

PRIVATE_KEY_BLOCK_RE = re.compile(
    r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----",
    re.DOTALL,
)

FLAG_SENSITIVE_NAME_RE = (
    r"api[-_]?key|token|secret|password|passwd|pwd|private[-_]?key|"
    r"access[-_]?(?:key|token)|client[-_]?secret|refresh[-_]?token|webhook[-_]?secret"
)
FLAG_NAME_RE = rf"--(?=[A-Za-z0-9_-]*(?:{FLAG_SENSITIVE_NAME_RE}))[A-Za-z0-9][A-Za-z0-9_-]*"
FLAG_START_RE = re.compile(rf"(?i)({FLAG_NAME_RE})(=|[ \t]+)")
LINE_CONTINUATION = "\\\n"

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

URL_QUERY_SECRET_RE = re.compile(
    rf"([?&](?=[A-Za-z0-9_-]*(?:{FLAG_SENSITIVE_NAME_RE}))[A-Za-z0-9_-]+=)(?!\[REDACTED[^\]]*\])([^&#\s\"'`<>]+)",
    re.IGNORECASE,
)
URL_QUERY_TRAILING_CLOSERS = {
    ")": "(",
    "]": "[",
    "}": "{",
}
URL_QUERY_TRAILING_PUNCTUATION = ".!?,;:"

SENSITIVE_NAME_RE = re.compile(
    r"(api[_-]?key|token|secret|password|passwd|pwd|private[_-]?key|"
    r"access[_-]?key|client[_-]?secret|refresh[_-]?token|webhook[_-]?secret)",
    re.IGNORECASE,
)
ASSIGNMENT_RE = re.compile(r"^(\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*)(.*?)(\s*)$")
COLON_RE = re.compile(r"^(\s*[\"']?([A-Za-z_][A-Za-z0-9_-]*)[\"']?\s*:\s*)(.*?)(\s*)$")
INLINE_PAIR_RE = re.compile(r"([\"']?)([A-Za-z_][A-Za-z0-9_-]*)\1\s*(:|=(?!=|>))\s*")
DELIMITED_NAMED_TAIL_RE = re.compile(r"^\s*[,;]\s*[A-Za-z_][A-Za-z0-9_.$-]*\s*[:=]")
PENDING_JSON_PREFIX = "__PENDING_JSON_CONTAINER__:"
PENDING_SHELL_PAREN_PREFIX = "__PENDING_SHELL_PAREN__:"
PENDING_SHELL_BACKTICK = "__PENDING_SHELL_BACKTICK__"


def _make_json_pending(stack: list[str], quote: str) -> str:
    quote_code = quote if quote else "-"
    return f"{PENDING_JSON_PREFIX}{''.join(stack)}:{quote_code}"


def _is_pending_json(pending: str) -> bool:
    return pending.startswith(PENDING_JSON_PREFIX)


def _parse_json_pending(pending: str) -> tuple[list[str], str]:
    payload = pending[len(PENDING_JSON_PREFIX) :]
    stack_text, quote_code = payload.rsplit(":", 1)
    return list(stack_text), "" if quote_code == "-" else quote_code


def _make_shell_paren_pending(depth: int, quote: str) -> str:
    quote_code = quote if quote else "-"
    return f"{PENDING_SHELL_PAREN_PREFIX}{depth}:{quote_code}"


def _is_pending_shell(pending: str) -> bool:
    return pending == PENDING_SHELL_BACKTICK or pending.startswith(PENDING_SHELL_PAREN_PREFIX)


def _parse_shell_paren_pending(pending: str) -> tuple[int, str]:
    payload = pending[len(PENDING_SHELL_PAREN_PREFIX) :]
    depth_text, quote_code = payload.rsplit(":", 1)
    return int(depth_text), "" if quote_code == "-" else quote_code


def _closing_quote_index(value: str, quote: str, *, allow_json_tail: bool = False) -> int | None:
    escaped = False
    seen_quote = False
    for index, char in enumerate(value[1:], start=1):
        if escaped:
            escaped = False
            continue
        if char == "\\":
            escaped = True
            continue
        if char != quote:
            continue
        tail = value[index + 1 :]
        if (
            _tail_is_strong_closing_context(tail)
            and not (seen_quote and _tail_is_comment_closing_context(tail))
        ) or (
            allow_json_tail and not seen_quote and _tail_starts_json_field(tail)
        ) or (
            not seen_quote and _tail_allows_sensitive_close(tail, quote)
        ) or (not seen_quote and _tail_is_ordinary_closing_context(tail, quote)):
            return index
        seen_quote = True
    return None


def _redacted_leading_value(
    value: str,
    *,
    allow_json_tail: bool = False,
    allow_unquoted_tail: bool = False,
) -> tuple[str, str, str]:
    stripped = value.lstrip()
    leading = value[: len(value) - len(stripped)]
    if not stripped or stripped[0] not in ("'", '"'):
        if allow_json_tail and stripped:
            value_end, pending = _unquoted_json_value_span(stripped)
            return f"{leading}[REDACTED]", pending, "" if pending else stripped[value_end:]
        if allow_unquoted_tail and stripped:
            value_end, pending = _unquoted_inline_value_span(stripped)
            if value_end > 0:
                return f"{leading}[REDACTED]", pending, "" if pending else stripped[value_end:]
        return "[REDACTED]", "", ""
    quote = stripped[0]
    closing_index = _closing_quote_index(stripped, quote, allow_json_tail=allow_json_tail)
    if closing_index is None:
        if _contains_unescaped_quote(stripped[1:], quote):
            return f"{leading}{quote}[REDACTED]{quote}", "", ""
        return f"{leading}{quote}[REDACTED]{quote}", quote, ""
    tail = stripped[closing_index + 1 :]
    if (
        _tail_has_sensitive_hint(tail)
        and not (allow_json_tail and _tail_starts_json_field(tail))
        and not _tail_has_redactable_sensitive_tail(tail)
    ):
        return f"{leading}{quote}[REDACTED]{quote}", "", ""
    return f"{leading}{quote}[REDACTED]{quote}", "", tail


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


def _unquoted_json_value_span(value: str) -> tuple[int, str]:
    if value.startswith(("{", "[")):
        return _json_container_value_span(value)
    for index, char in enumerate(value):
        if char in ",]}":
            return index, ""
    return len(value), ""


def _balanced_shell_substitution_end(value: str, start: int) -> tuple[int, str]:
    depth = 1
    quote = ""
    escaped = False
    index = start
    while index < len(value):
        char = value[index]
        if escaped:
            escaped = False
            index += 1
            continue
        if char == "\\":
            escaped = True
            index += 1
            continue
        if quote:
            if char == quote:
                quote = ""
            index += 1
            continue
        if char in ("'", '"'):
            quote = char
            index += 1
            continue
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return index + 1, ""
        index += 1
    return len(value), _make_shell_paren_pending(depth, quote)


def _backtick_shell_substitution_end(value: str, start: int) -> tuple[int, str]:
    escaped = False
    index = start
    while index < len(value):
        char = value[index]
        if escaped:
            escaped = False
            index += 1
            continue
        if char == "\\":
            escaped = True
            index += 1
            continue
        if char == "`":
            return index + 1, ""
        index += 1
    return len(value), PENDING_SHELL_BACKTICK


def _shell_substitution_end(value: str, start: int) -> tuple[int, str] | None:
    if value.startswith("$(", start) or value.startswith("<(", start):
        return _balanced_shell_substitution_end(value, start + 2)
    if start < len(value) and value[start] == "`":
        return _backtick_shell_substitution_end(value, start + 1)
    return None


def _unquoted_inline_value_span(value: str) -> tuple[int, str]:
    quote = ""
    escaped = False
    index = 0
    while index < len(value):
        char = value[index]
        if escaped:
            escaped = False
            index += 1
            continue
        if char == "\\":
            escaped = True
            index += 1
            continue
        if quote:
            if char == quote:
                quote = ""
            index += 1
            continue
        if char in ("'", '"'):
            quote = char
            index += 1
            continue
        substitution_end = _shell_substitution_end(value, index)
        if substitution_end is not None:
            index, pending = substitution_end
            if pending:
                return index, pending
            continue
        if char.isspace() or char in ";&|<>()":
            return index, ""
        index += 1
    return len(value), ""


def _json_container_value_span(value: str) -> tuple[int, str]:
    stack: list[str] = []
    quote = ""
    escaped = False
    pairs = {"{": "}", "[": "]"}
    closers = set(pairs.values())
    for index, char in enumerate(value):
        if escaped:
            escaped = False
            continue
        if char == "\\":
            escaped = True
            continue
        if quote:
            if char == quote:
                quote = ""
            continue
        if char in ("'", '"'):
            quote = char
            continue
        if char in pairs:
            stack.append(pairs[char])
            continue
        if char in closers:
            if not stack or char != stack[-1]:
                return index, ""
            stack.pop()
            if not stack:
                return index + 1, ""
    if stack:
        return len(value), _make_json_pending(stack, quote)
    return len(value), ""


def _closing_quote_tail(value: str, quote: str, *, allow_json_tail: bool = False) -> str | None:
    if not quote:
        return None
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
        tail = value[index + 1 :]
        if _tail_is_closing_context(tail, allow_json_tail=allow_json_tail):
            return value[index + 1 :]
    return None


def _sensitive_closing_quote_tail(value: str, quote: str) -> str | None:
    if not quote:
        return None
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
        tail = value[index + 1 :]
        if _tail_allows_sensitive_close(tail, quote) or (
            _tail_starts_comment(tail) and _tail_has_sensitive_hint(tail)
        ):
            return tail
    return None


def _ordinary_closing_quote_tail(value: str, quote: str) -> str | None:
    if not quote:
        return None
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
        tail = value[index + 1 :]
        if _tail_is_ordinary_closing_context(tail, quote):
            return tail
    return None


def _find_closing_quote(
    lines: list[str],
    start_index: int,
    quote: str,
    *,
    allow_json_tail: bool = False,
) -> int | None:
    weak_closing_index = None
    ordinary_closing_index = None
    for index in range(start_index, len(lines)):
        body = lines[index].rstrip("\r\n")
        json_field_closing_quote = _has_json_field_closing_quote(body, quote)
        if _has_strong_closing_quote(body, quote) or (
            allow_json_tail and json_field_closing_quote
        ):
            return index
        if weak_closing_index is None and (
            json_field_closing_quote
            or _has_weak_closing_quote(body, quote)
            or _sensitive_closing_quote_tail(body, quote) is not None
            or _closing_quote_tail(body, quote, allow_json_tail=allow_json_tail) is not None
        ):
            weak_closing_index = index
        if ordinary_closing_index is None and _has_single_ordinary_closing_quote(body, quote):
            ordinary_closing_index = index
    return weak_closing_index if weak_closing_index is not None else ordinary_closing_index


def _line_newline(line: str) -> str:
    body = line.rstrip("\r\n")
    return line[len(body) :]


def _tail_is_closing_context(tail: str, *, allow_json_tail: bool = False) -> bool:
    return _tail_is_strong_closing_context(tail) or (
        allow_json_tail and _tail_starts_json_field(tail)
    )


def _tail_is_strong_closing_context(tail: str) -> bool:
    stripped = tail.strip()
    if not stripped or _tail_starts_comment(tail):
        return True
    while stripped and stripped[0] in "]})":
        stripped = stripped[1:].lstrip()
    if not stripped or (stripped.startswith("#") and _tail_starts_comment(tail)):
        return True
    if stripped[0] not in ",;":
        return False
    rest = stripped[1:].lstrip()
    if not rest or (rest.startswith("#") and _tail_starts_comment(tail)) or rest[0] in "]})":
        return True
    return False


def _tail_is_ordinary_closing_context(tail: str, quote: str) -> bool:
    stripped = tail.lstrip()
    starts_with_closer = False
    while stripped and stripped[0] in "]})":
        starts_with_closer = True
        stripped = stripped[1:].lstrip()
    if starts_with_closer:
        if stripped and not (stripped[0].isspace() or stripped[0] in ",;|&{"):
            return False
    else:
        if tail and not (tail[0].isspace() or tail[0] in ",;|&"):
            return False
        if _contains_unescaped_quote(tail, quote) and not _tail_starts_delimited_named_value(tail):
            return False
    if _tail_starts_json_field(tail):
        return False
    return not _tail_has_sensitive_hint(tail)


def _has_single_ordinary_closing_quote(value: str, quote: str) -> bool:
    if not quote:
        return False
    escaped = False
    quote_count = 0
    ordinary_close = False
    for index, char in enumerate(value):
        if escaped:
            escaped = False
            continue
        if char == "\\":
            escaped = True
            continue
        if char != quote:
            continue
        quote_count += 1
        ordinary_close = _tail_is_ordinary_closing_context(value[index + 1 :], quote)
    return quote_count == 1 and ordinary_close


def _tail_has_sensitive_hint(tail: str) -> bool:
    return bool(SENSITIVE_NAME_RE.search(tail))


def _tail_starts_delimited_named_value(tail: str) -> bool:
    return DELIMITED_NAMED_TAIL_RE.match(tail) is not None


def _tail_has_redactable_sensitive_tail(tail: str) -> bool:
    if _tail_starts_comment(tail):
        return False
    return FLAG_START_RE.search(tail) is not None or _find_inline_sensitive_pair(tail) is not None


def _first_redactable_sensitive_tail_start(tail: str) -> int | None:
    starts = []
    flag = FLAG_START_RE.search(tail)
    if flag is not None:
        starts.append(flag.start())
    inline = _find_inline_sensitive_pair(tail)
    if inline is not None:
        starts.append(inline.start())
    return min(starts) if starts else None


def _has_unescaped_quote_before(value: str, quote: str, end: int) -> bool:
    escaped = False
    for char in value[:end]:
        if escaped:
            escaped = False
            continue
        if char == "\\":
            escaped = True
            continue
        if char == quote:
            return True
    return False


def _tail_allows_sensitive_close(tail: str, quote: str) -> bool:
    if not _tail_starts_value_boundary(tail):
        return False
    sensitive_start = _first_redactable_sensitive_tail_start(tail)
    return sensitive_start is not None and not _has_unescaped_quote_before(
        tail,
        quote,
        sensitive_start,
    )


def _tail_starts_value_boundary(tail: str) -> bool:
    return bool(tail) and (tail[0].isspace() or tail[0] in ",;|&)]}#")


def _tail_starts_adjacent_shell_word(tail: str) -> bool:
    return bool(tail) and not (tail[0].isspace() or tail[0] in ";&|<>()")


def _tail_starts_comment(tail: str) -> bool:
    stripped = tail.lstrip()
    has_comment_boundary = len(stripped) < len(tail)
    while stripped and stripped[0] in ",;]})":
        has_comment_boundary = True
        stripped = stripped[1:].lstrip()
    return has_comment_boundary and stripped.startswith("#")


def _tail_is_comment_closing_context(tail: str) -> bool:
    return _tail_starts_comment(tail)


def _tail_is_weak_closing_context(tail: str) -> bool:
    stripped = tail.strip()
    while stripped and stripped[0] in "]})":
        stripped = stripped[1:].lstrip()
    if not stripped or stripped[0] not in ",;":
        return False
    rest = stripped[1:].lstrip()
    pair = INLINE_PAIR_RE.match(rest)
    if pair is None or pair.group(3) != "=":
        return False
    key = pair.group(2)
    return key.upper() == key and any(char.isalpha() for char in key)


def _tail_starts_json_field(tail: str) -> bool:
    stripped = tail.strip()
    while stripped and stripped[0] in "]})":
        stripped = stripped[1:].lstrip()
    if not stripped or stripped[0] != ",":
        return False
    rest = stripped[1:].lstrip()
    pair = INLINE_PAIR_RE.match(rest)
    return pair is not None and pair.group(1) in ("'", '"') and pair.group(3) == ":"


def _has_weak_closing_quote(value: str, quote: str) -> bool:
    if not quote:
        return False
    escaped = False
    for index, char in enumerate(value):
        if escaped:
            escaped = False
            continue
        if char == "\\":
            escaped = True
            continue
        if char == quote and _tail_is_weak_closing_context(value[index + 1 :]):
            return True
    return False


def _has_json_field_closing_quote(value: str, quote: str) -> bool:
    if not quote:
        return False
    escaped = False
    seen_quote = False
    for index, char in enumerate(value):
        if escaped:
            escaped = False
            continue
        if char == "\\":
            escaped = True
            continue
        if char != quote:
            continue
        if not seen_quote and _tail_starts_json_field(value[index + 1 :]):
            return True
        seen_quote = True
    return False


def _has_strong_closing_quote(value: str, quote: str) -> bool:
    if not quote:
        return False
    escaped = False
    quote_count = 0
    strong_close = False
    for index, char in enumerate(value):
        if escaped:
            escaped = False
            continue
        if char == "\\":
            escaped = True
            continue
        if char == quote:
            quote_count += 1
            tail = value[index + 1 :]
            if _tail_is_comment_closing_context(tail):
                return quote_count == 1
            if _tail_is_strong_closing_context(tail):
                strong_close = True
    return quote_count == 1 and strong_close


def _find_inline_sensitive_pair(body: str, start: int = 0) -> re.Match[str] | None:
    for match in INLINE_PAIR_RE.finditer(body, start):
        if (
            _has_inline_pair_boundary(body, match)
            and not _is_inside_quoted_string(body, match.start())
            and _inline_match_has_redactable_value(body, match)
            and SENSITIVE_NAME_RE.search(match.group(2))
        ):
            return match
    return None


def _is_inside_quoted_string(body: str, position: int) -> bool:
    quote = ""
    escaped = False
    for index, char in enumerate(body[:position]):
        if escaped:
            escaped = False
            continue
        if char == "\\":
            escaped = True
            continue
        if char not in ("'", '"'):
            continue
        if not quote and char == "'" and _is_word_apostrophe(body, index):
            continue
        if not quote:
            quote = char
        elif quote == char:
            quote = ""
    return bool(quote)


def _is_word_apostrophe(body: str, index: int) -> bool:
    return (
        index > 0
        and index + 1 < len(body)
        and body[index - 1].isalnum()
        and body[index + 1].isalnum()
    )


def _inline_match_has_redactable_value(body: str, match: re.Match[str]) -> bool:
    value = body[match.end() :].lstrip()
    if not value:
        return False
    if value[0] in ("'", '"'):
        return True
    return _inline_match_allows_json_tail(match) or _inline_match_allows_unquoted_tail(
        match
    )


def _inline_match_allows_json_tail(match: re.Match[str]) -> bool:
    return match.group(1) in ("'", '"') and match.group(3) == ":"


def _inline_match_allows_unquoted_tail(match: re.Match[str]) -> bool:
    key = match.group(2)
    return match.group(3) == "=" and key.upper() == key and any(
        char.isalpha() for char in key
    )


def _has_inline_pair_boundary(body: str, match: re.Match[str]) -> bool:
    if match.start() == 0:
        return True
    previous = body[match.start() - 1]
    return previous.isspace() or previous in "{[(,;"


def _redact_inline_sensitive_pairs(fragment: str) -> tuple[str, int, str, bool]:
    parts: list[str] = []
    count = 0
    position = 0
    while True:
        match = _find_inline_sensitive_pair(fragment, position)
        if match is None:
            parts.append(fragment[position:])
            break
        parts.append(fragment[position : match.end()])
        allow_json_tail = _inline_match_allows_json_tail(match)
        allow_unquoted_tail = _inline_match_allows_unquoted_tail(match)
        redacted_value, pending_quote, tail = _redacted_leading_value(
            fragment[match.end() :],
            allow_json_tail=allow_json_tail,
            allow_unquoted_tail=allow_unquoted_tail,
        )
        parts.append(redacted_value)
        count += 1
        if pending_quote:
            return "".join(parts), count, pending_quote, allow_json_tail
        consumed = len(fragment[match.end() :]) - len(tail)
        if consumed <= 0:
            position = len(fragment)
        else:
            position = match.end() + consumed
    return "".join(parts), count, "", False


def _scan_shell_word(body: str, start: int) -> tuple[int, str]:
    quote = ""
    escaped = False
    index = start
    while index < len(body):
        char = body[index]
        if escaped:
            escaped = False
            index += 1
            continue
        if char == "\\":
            escaped = True
            index += 1
            continue
        if quote:
            if char == quote:
                quote = ""
            index += 1
            continue
        if char in ("'", '"'):
            quote = char
            index += 1
            continue
        substitution_end = _shell_substitution_end(body, index)
        if substitution_end is not None:
            index, pending = substitution_end
            if pending:
                return index, pending
            continue
        if char.isspace() or char in ";&|<>()":
            break
        index += 1
    if escaped and not quote:
        return index, LINE_CONTINUATION
    return index, quote


def _dash_prefixed_word_looks_secret(value: str) -> bool:
    if not value.startswith("--"):
        return False
    stripped = value.lstrip("-")
    return bool(SENSITIVE_NAME_RE.search(value)) or len(stripped) >= 16


def _extend_bearer_flag_value(
    body: str,
    start: int,
    end: int,
    pending_quote: str,
) -> tuple[int, str]:
    if pending_quote or body[start:end].lower() != "bearer":
        return end, pending_quote

    next_start = end
    while next_start < len(body) and body[next_start] in " \t":
        next_start += 1
    if next_start >= len(body) or body[next_start] == ";":
        return end, pending_quote
    if body.startswith("--", next_start):
        if _continued_dash_line_starts_sensitive_flag_with_value(body, next_start):
            return end, pending_quote
        next_end, next_pending_quote = _scan_shell_word(body, next_start)
        if next_end <= next_start:
            return end, pending_quote
        next_word = body[next_start:next_end]
        if not _dash_prefixed_word_looks_secret(next_word):
            return end, pending_quote
        return next_end, next_pending_quote

    next_end, next_pending_quote = _scan_shell_word(body, next_start)
    if next_end <= next_start:
        return end, pending_quote
    return next_end, next_pending_quote


def _extend_spaced_equals_flag_value(
    body: str,
    start: int,
    end: int,
    pending_quote: str,
) -> tuple[int, str]:
    if pending_quote or body[start:end] != "=":
        return end, pending_quote

    next_start = end
    while next_start < len(body) and body[next_start] in " \t":
        next_start += 1
    if next_start >= len(body) or body[next_start] == ";":
        return end, pending_quote
    if body.startswith("--", next_start):
        if (
            _continued_dash_line_starts_sensitive_flag_with_value(body, next_start)
            or not _continued_dash_value_is_sensitive(body, next_start)
        ):
            return end, pending_quote
        next_end, next_pending_quote = _scan_shell_word(body, next_start)
        if next_end <= next_start:
            return end, pending_quote
        return next_end, next_pending_quote

    next_end, next_pending_quote = _scan_shell_word(body, next_start)
    if next_end <= next_start:
        return end, pending_quote
    if body[next_start:next_end].lower() == "bearer":
        return _extend_bearer_flag_value(
            body,
            next_start,
            next_end,
            next_pending_quote,
        )
    return next_end, next_pending_quote


def _redact_flag_line(body: str) -> tuple[str, int, str]:
    parts: list[str] = []
    count = 0
    position = 0
    search_position = 0
    while True:
        match = FLAG_START_RE.search(body, search_position)
        if match is None:
            break
        if match.start() < position:
            search_position = max(search_position + 1, position)
            continue
        if _is_inside_quoted_string(body, match.start()):
            search_position = match.end()
            continue

        value_start = match.end()
        equals_value_attached = False
        if match.group(2) == "=":
            equals_value_attached = value_start < len(body) and body[value_start] not in " \t"
            while value_start < len(body) and body[value_start] in " \t":
                value_start += 1
        if value_start >= len(body):
            search_position = match.end()
            continue
        if not equals_value_attached and body.startswith("--", value_start) and (
            _continued_dash_line_starts_sensitive_flag_with_value(body, value_start)
            or not _continued_dash_value_is_sensitive(body, value_start)
        ):
            search_position = match.end()
            continue
        value_end, pending_quote = _scan_shell_word(body, value_start)
        value_end, pending_quote = _extend_spaced_equals_flag_value(
            body,
            value_start,
            value_end,
            pending_quote,
        )
        value_end, pending_quote = _extend_bearer_flag_value(
            body,
            value_start,
            value_end,
            pending_quote,
        )
        if value_end <= value_start:
            search_position = match.end()
            continue

        parts.append(body[position : match.end()])
        parts.append("[REDACTED]")
        count += 1
        position = value_end
        search_position = value_end
        if pending_quote:
            return "".join(parts), count, pending_quote

    if count == 0:
        return body, 0, ""
    parts.append(body[position:])
    return "".join(parts), count, ""


def _redact_quoted_flag_segments(fragment: str) -> tuple[str, int]:
    parts: list[str] = []
    count = 0
    position = 0
    index = 0
    escaped = False
    while index < len(fragment):
        char = fragment[index]
        if escaped:
            escaped = False
            index += 1
            continue
        if char == "\\":
            escaped = True
            index += 1
            continue
        if char not in ("'", '"') or (char == "'" and _is_word_apostrophe(fragment, index)):
            index += 1
            continue

        close_index = _quote_close_index(fragment[index + 1 :], char)
        if close_index is None:
            break
        close_index += index + 1

        segment = fragment[index + 1 : close_index]
        redacted_segment, segment_count, pending_quote = _redact_flag_line(segment)
        count += segment_count
        if not pending_quote:
            redacted_segment, nested_count = _redact_quoted_flag_segments(redacted_segment)
            count += nested_count

        parts.append(fragment[position : index + 1])
        parts.append(redacted_segment)
        parts.append(char)
        position = close_index + 1
        index = position
        escaped = False

    if count == 0:
        return fragment, 0
    parts.append(fragment[position:])
    return "".join(parts), count


def _quote_close_index(body: str, quote: str) -> int | None:
    escaped = False
    for index, char in enumerate(body):
        if escaped:
            escaped = False
            continue
        if char == "\\":
            escaped = True
            continue
        if char == quote:
            return index
    return None


def _flag_closing_quote_index(body: str, quote: str) -> int | None:
    escaped = False
    for index, char in enumerate(body):
        if escaped:
            escaped = False
            continue
        if char == "\\":
            escaped = True
            continue
        if char != quote:
            continue
        tail = body[index + 1 :]
        if (
            _tail_starts_adjacent_shell_word(tail)
            or _tail_is_strong_closing_context(tail)
            or _tail_allows_sensitive_close(tail, quote)
            or _tail_is_ordinary_closing_context(tail, quote)
        ):
            return index
    return None


def _redact_flag_values(text: str) -> tuple[str, int]:
    lines = text.splitlines(keepends=True)
    redacted_lines: list[str] = []
    count = 0
    index = 0
    while index < len(lines):
        line = lines[index]
        body = line.rstrip("\r\n")
        newline = line[len(body) :]
        redacted_body, line_count, pending_quote = _redact_flag_line(body)
        count += line_count
        redacted_lines.append(redacted_body + newline)
        if pending_quote:
            if pending_quote == LINE_CONTINUATION:
                index, tail_count = _append_line_continuation_flag_tail(
                    redacted_lines,
                    lines,
                    index + 1,
                )
                count += tail_count
                continue
            if _is_pending_json(pending_quote) or _is_pending_shell(pending_quote):
                index, tail_count = _append_container_or_shell_tail(
                    redacted_lines,
                    lines,
                    index + 1,
                    pending_quote,
                )
                count += tail_count
                continue
            closing_line_index = _find_flag_closing_line(lines, index + 1, pending_quote)
            if closing_line_index is not None:
                index, tail_count = _append_flag_closing_tail(
                    redacted_lines,
                    lines,
                    closing_line_index,
                    pending_quote,
                )
                count += tail_count
                continue
        index += 1
    return "".join(redacted_lines), count


def _replace_last_marker_with_tail(redacted_lines: list[str], tail: str) -> int:
    line = redacted_lines[-1].rstrip("\r\n")
    if not line.endswith("[REDACTED]"):
        redacted_lines[-1] = line + tail
        return 0
    redacted_lines[-1] = line[: -len("[REDACTED]")] + tail
    return -1


def _tail_is_line_continuation(tail: str) -> bool:
    return tail.strip(" \t") == "\\"


def _continued_dash_value_is_sensitive(body: str, value_start: int) -> bool:
    value_end, pending_quote = _scan_shell_word(body, value_start)
    if pending_quote or value_end <= value_start:
        return False
    return _dash_prefixed_word_looks_secret(body[value_start:value_end])


def _continued_dash_line_starts_sensitive_flag_with_value(
    body: str,
    value_start: int,
) -> bool:
    match = FLAG_START_RE.match(body, value_start)
    if match is None:
        return False

    flag_value_start = match.end()
    if match.group(2) == "=":
        while flag_value_start < len(body) and body[flag_value_start] in " \t":
            flag_value_start += 1

    if flag_value_start >= len(body):
        return False
    if body.startswith("--", flag_value_start):
        return _continued_dash_value_is_sensitive(body, flag_value_start)
    return True


def _append_line_continuation_flag_tail(
    redacted_lines: list[str],
    lines: list[str],
    value_line_index: int,
) -> tuple[int, int]:
    if value_line_index >= len(lines):
        return value_line_index, 0

    body = lines[value_line_index].rstrip("\r\n")
    newline = lines[value_line_index][len(body) :]
    value_start = 0
    while value_start < len(body) and body[value_start] in " \t":
        value_start += 1

    if body.startswith("--", value_start) and (
        _continued_dash_line_starts_sensitive_flag_with_value(body, value_start)
        or not _continued_dash_value_is_sensitive(body, value_start)
    ):
        redacted_tail, count, next_pending_quote, pending_kind, allow_json_tail = (
            _redact_flag_tail(body[value_start:])
        )
        count += _replace_last_marker_with_tail(redacted_lines, redacted_tail)
        if next_pending_quote == LINE_CONTINUATION:
            next_index, tail_count = _append_line_continuation_flag_tail(
                redacted_lines,
                lines,
                value_line_index + 1,
            )
            return next_index, count + tail_count
        redacted_lines[-1] = redacted_lines[-1].rstrip("\r\n") + newline
        if not next_pending_quote:
            return value_line_index + 1, count
        if _is_pending_json(next_pending_quote) or _is_pending_shell(next_pending_quote):
            next_index, tail_count = _append_container_or_shell_tail(
                redacted_lines,
                lines,
                value_line_index + 1,
                next_pending_quote,
            )
            return next_index, count + tail_count
        if pending_kind == "inline":
            next_index = _find_closing_quote(
                lines,
                value_line_index + 1,
                next_pending_quote,
                allow_json_tail=allow_json_tail,
            )
        else:
            next_index = _find_flag_closing_line(
                lines,
                value_line_index + 1,
                next_pending_quote,
            )
        if next_index is None:
            return value_line_index + 1, count
        if pending_kind == "inline":
            index_after_tail, inline_tail_count = _append_closing_tail(
                redacted_lines,
                lines,
                next_index,
                next_pending_quote,
                allow_json_tail=allow_json_tail,
            )
            return index_after_tail, count + inline_tail_count
        index_after_tail, tail_count = _append_flag_closing_tail(
            redacted_lines,
            lines,
            next_index,
            next_pending_quote,
        )
        return index_after_tail, count + tail_count

    value_end, pending_quote = _scan_shell_word(body, value_start)
    value_end, pending_quote = _extend_spaced_equals_flag_value(
        body,
        value_start,
        value_end,
        pending_quote,
    )
    value_end, pending_quote = _extend_bearer_flag_value(
        body,
        value_start,
        value_end,
        pending_quote,
    )
    tail = body[value_end:] if value_end > value_start else body[value_start:]
    if pending_quote == LINE_CONTINUATION or _tail_is_line_continuation(tail):
        redacted_lines[-1] = redacted_lines[-1].rstrip("\r\n")
        next_index, tail_count = _append_line_continuation_flag_tail(
            redacted_lines,
            lines,
            value_line_index + 1,
        )
        return next_index, tail_count

    redacted_tail, count, next_pending_quote, pending_kind, allow_json_tail = (
        _redact_flag_tail(tail)
    )
    redacted_lines[-1] = redacted_lines[-1].rstrip("\r\n") + redacted_tail

    if next_pending_quote == LINE_CONTINUATION:
        next_index, tail_count = _append_line_continuation_flag_tail(
            redacted_lines,
            lines,
            value_line_index + 1,
        )
        return next_index, count + tail_count

    redacted_lines[-1] = redacted_lines[-1] + newline

    if pending_quote and pending_quote != LINE_CONTINUATION:
        if _is_pending_json(pending_quote) or _is_pending_shell(pending_quote):
            next_index, tail_count = _append_container_or_shell_tail(
                redacted_lines,
                lines,
                value_line_index + 1,
                pending_quote,
            )
            return next_index, count + tail_count
        closing_line_index = _find_flag_closing_line(
            lines,
            value_line_index + 1,
            pending_quote,
        )
        if closing_line_index is not None:
            index_after_tail, tail_count = _append_flag_closing_tail(
                redacted_lines,
                lines,
                closing_line_index,
                pending_quote,
            )
            return index_after_tail, count + tail_count
        return value_line_index + 1, count

    if not next_pending_quote:
        return value_line_index + 1, count
    if _is_pending_json(next_pending_quote) or _is_pending_shell(next_pending_quote):
        next_index, tail_count = _append_container_or_shell_tail(
            redacted_lines,
            lines,
            value_line_index + 1,
            next_pending_quote,
        )
        return next_index, count + tail_count

    if pending_kind == "inline":
        next_index = _find_closing_quote(
            lines,
            value_line_index + 1,
            next_pending_quote,
            allow_json_tail=allow_json_tail,
        )
    else:
        next_index = _find_flag_closing_line(
            lines,
            value_line_index + 1,
            next_pending_quote,
        )
    if next_index is None:
        return value_line_index + 1, count
    if pending_kind == "inline":
        index_after_tail, inline_tail_count = _append_closing_tail(
            redacted_lines,
            lines,
            next_index,
            next_pending_quote,
            allow_json_tail=allow_json_tail,
        )
        return index_after_tail, count + inline_tail_count
    index_after_tail, tail_count = _append_flag_closing_tail(
        redacted_lines,
        lines,
        next_index,
        next_pending_quote,
    )
    return index_after_tail, count + tail_count


def _redact_flag_tail(tail: str) -> tuple[str, int, str, str, bool]:
    redacted_tail, count, inline_pending_quote, inline_allow_json_tail = (
        _redact_inline_sensitive_pairs(tail)
    )
    if inline_pending_quote:
        redacted_tail, flag_count, flag_pending_quote = _redact_flag_line(redacted_tail)
        count += flag_count
        if flag_pending_quote:
            return redacted_tail, count, flag_pending_quote, "flag", False
        redacted_tail, quoted_flag_count = _redact_quoted_flag_segments(redacted_tail)
        count += quoted_flag_count
        return redacted_tail, count, inline_pending_quote, "inline", inline_allow_json_tail

    redacted_tail, flag_count, flag_pending_quote = _redact_flag_line(redacted_tail)
    count += flag_count
    if flag_pending_quote:
        return redacted_tail, count, flag_pending_quote, "flag", False
    redacted_tail, quoted_flag_count = _redact_quoted_flag_segments(redacted_tail)
    count += quoted_flag_count
    return redacted_tail, count, "", "", False


def _append_flag_closing_tail(
    redacted_lines: list[str],
    lines: list[str],
    closing_index: int,
    pending_quote: str,
) -> tuple[int, int]:
    count = 0
    current_index = closing_index
    current_quote = pending_quote
    while True:
        closing_body = lines[current_index].rstrip("\r\n")
        closing_newline = lines[current_index][len(closing_body) :]
        closing_quote_index = _flag_closing_quote_index(closing_body, current_quote)
        tail = ""
        if closing_quote_index is not None:
            tail_start, adjacent_pending_quote = _scan_shell_word(
                closing_body,
                closing_quote_index + 1,
            )
            if adjacent_pending_quote:
                if _is_pending_json(adjacent_pending_quote) or _is_pending_shell(
                    adjacent_pending_quote
                ):
                    next_index, tail_count = _append_container_or_shell_tail(
                        redacted_lines,
                        lines,
                        current_index + 1,
                        adjacent_pending_quote,
                    )
                    return next_index, count + tail_count
                next_index = _find_flag_closing_line(
                    lines,
                    current_index + 1,
                    adjacent_pending_quote,
                )
                if next_index is None:
                    return current_index + 1, count
                current_index = next_index
                current_quote = adjacent_pending_quote
                continue
            tail = closing_body[tail_start:]

        redacted_tail, tail_count, next_pending_quote, pending_kind, allow_json_tail = (
            _redact_flag_tail(tail)
        )
        count += tail_count
        redacted_lines[-1] = (
            redacted_lines[-1].rstrip("\r\n") + redacted_tail
        )
        if next_pending_quote == LINE_CONTINUATION:
            index_after_tail, continuation_tail_count = _append_line_continuation_flag_tail(
                redacted_lines,
                lines,
                current_index + 1,
            )
            return index_after_tail, count + continuation_tail_count
        redacted_lines[-1] = redacted_lines[-1] + closing_newline
        if not next_pending_quote:
            return current_index + 1, count
        if _is_pending_json(next_pending_quote) or _is_pending_shell(next_pending_quote):
            next_index, tail_count = _append_container_or_shell_tail(
                redacted_lines,
                lines,
                current_index + 1,
                next_pending_quote,
            )
            return next_index, count + tail_count

        if pending_kind == "inline":
            next_index = _find_closing_quote(
                lines,
                current_index + 1,
                next_pending_quote,
                allow_json_tail=allow_json_tail,
            )
        else:
            next_index = _find_flag_closing_line(
                lines,
                current_index + 1,
                next_pending_quote,
            )
        if next_index is None:
            return current_index + 1, count
        if pending_kind == "inline":
            index_after_tail, inline_tail_count = _append_closing_tail(
                redacted_lines,
                lines,
                next_index,
                next_pending_quote,
                allow_json_tail=allow_json_tail,
            )
            return index_after_tail, count + inline_tail_count
        current_index = next_index
        current_quote = next_pending_quote


def _find_flag_closing_line(lines: list[str], start_index: int, quote: str) -> int | None:
    for index in range(start_index, len(lines)):
        body = lines[index].rstrip("\r\n")
        if _flag_closing_quote_index(body, quote) is not None:
            return index
    return None


def _preserve_closing_tail(tail: str, *, allow_json_tail: bool = False) -> bool:
    if _tail_has_sensitive_hint(tail) and not (allow_json_tail and _tail_starts_json_field(tail)):
        return False
    stripped = tail.strip()
    if not stripped or stripped.startswith("#"):
        return True
    if stripped.startswith("--"):
        return True
    while stripped and stripped[0] in "]})":
        stripped = stripped[1:].lstrip()
    if not stripped or stripped.startswith("#"):
        return True
    if stripped.startswith("--"):
        return True
    if stripped[0] not in ",;":
        return False
    rest = stripped[1:].lstrip()
    return (
        not rest
        or rest.startswith("#")
        or rest[0] in ("]", "}", ")")
        or _tail_starts_delimited_named_value(tail)
        or _tail_starts_json_field(tail)
    )


def _redacted_closing_tail(
    line: str,
    quote: str,
    *,
    allow_json_tail: bool = False,
) -> tuple[str, int, str, str, bool]:
    body = line.rstrip("\r\n")
    ordinary_tail = _ordinary_closing_quote_tail(body, quote)
    tail = _closing_quote_tail(body, quote, allow_json_tail=allow_json_tail)
    if tail == "" and ordinary_tail:
        tail = ordinary_tail
    sensitive_tail = False
    if tail is None:
        tail = _sensitive_closing_quote_tail(body, quote)
        sensitive_tail = tail is not None
    if tail is None:
        tail = ordinary_tail
    if tail is None:
        return "", 0, "", "", False
    if sensitive_tail and not _tail_has_redactable_sensitive_tail(tail):
        return "", 0, "", "", False
    if not sensitive_tail and not _preserve_closing_tail(tail, allow_json_tail=allow_json_tail):
        return "", 0, "", "", False
    redacted_tail, count, pending_quote, pending_kind, pending_allow_json_tail = (
        _redact_flag_tail(tail)
    )
    return redacted_tail, count, pending_quote, pending_kind, pending_allow_json_tail


def _append_closing_tail(
    redacted_lines: list[str],
    lines: list[str],
    closing_index: int,
    pending_quote: str,
    *,
    allow_json_tail: bool = False,
) -> tuple[int, int]:
    count = 0
    current_index = closing_index
    current_quote = pending_quote
    current_allow_json_tail = allow_json_tail
    while True:
        (
            closing_tail,
            tail_count,
            next_pending_quote,
            pending_kind,
            next_allow_json_tail,
        ) = _redacted_closing_tail(
            lines[current_index],
            current_quote,
            allow_json_tail=current_allow_json_tail,
        )
        count += tail_count
        redacted_lines[-1] = redacted_lines[-1].rstrip("\r\n") + closing_tail
        if next_pending_quote == LINE_CONTINUATION:
            next_index, continuation_tail_count = _append_line_continuation_flag_tail(
                redacted_lines,
                lines,
                current_index + 1,
            )
            return next_index, count + continuation_tail_count
        redacted_lines[-1] = redacted_lines[-1] + _line_newline(lines[current_index])
        if not next_pending_quote:
            return current_index + 1, count
        if _is_pending_json(next_pending_quote) or _is_pending_shell(next_pending_quote):
            next_index, tail_count = _append_container_or_shell_tail(
                redacted_lines,
                lines,
                current_index + 1,
                next_pending_quote,
            )
            return next_index, count + tail_count
        if pending_kind == "flag":
            next_index = _find_flag_closing_line(
                lines,
                current_index + 1,
                next_pending_quote,
            )
        else:
            next_index = _find_closing_quote(
                lines,
                current_index + 1,
                next_pending_quote,
                allow_json_tail=next_allow_json_tail,
            )
        if next_index is None:
            return current_index + 1, count
        if pending_kind == "flag":
            index_after_tail, flag_tail_count = _append_flag_closing_tail(
                redacted_lines,
                lines,
                next_index,
                next_pending_quote,
            )
            return index_after_tail, count + flag_tail_count
        current_index = next_index
        current_quote = next_pending_quote
        current_allow_json_tail = next_allow_json_tail


def _json_container_closing_tail(body: str, pending: str) -> tuple[str | None, str]:
    stack, quote = _parse_json_pending(pending)
    escaped = False
    pairs = {"{": "}", "[": "]"}
    closers = set(pairs.values())
    for index, char in enumerate(body):
        if escaped:
            escaped = False
            continue
        if char == "\\":
            escaped = True
            continue
        if quote:
            if char == quote:
                quote = ""
            continue
        if char in ("'", '"'):
            quote = char
            continue
        if char in pairs:
            stack.append(pairs[char])
            continue
        if char in closers:
            if stack and char == stack[-1]:
                stack.pop()
                if not stack:
                    return body[index + 1 :], ""
                continue
            if stack:
                return body[index + 1 :], ""
    return None, _make_json_pending(stack, quote)


def _shell_substitution_closing_tail(body: str, pending: str) -> tuple[str | None, str]:
    if pending == PENDING_SHELL_BACKTICK:
        escaped = False
        for index, char in enumerate(body):
            if escaped:
                escaped = False
                continue
            if char == "\\":
                escaped = True
                continue
            if char == "`":
                return body[index + 1 :], ""
        return None, PENDING_SHELL_BACKTICK

    depth, quote = _parse_shell_paren_pending(pending)
    escaped = False
    for index, char in enumerate(body):
        if escaped:
            escaped = False
            continue
        if char == "\\":
            escaped = True
            continue
        if quote:
            if char == quote:
                quote = ""
            continue
        if char in ("'", '"'):
            quote = char
            continue
        if char == "(":
            depth += 1
            continue
        if char == ")":
            depth -= 1
            if depth <= 0:
                return body[index + 1 :], ""
    return None, _make_shell_paren_pending(depth, quote)


def _append_container_or_shell_tail(
    redacted_lines: list[str],
    lines: list[str],
    start_index: int,
    pending: str,
) -> tuple[int, int]:
    count = 0
    current_pending = pending
    current_index = start_index
    while current_index < len(lines):
        body = lines[current_index].rstrip("\r\n")
        newline = lines[current_index][len(body) :]
        if _is_pending_json(current_pending):
            tail, next_container_pending = _json_container_closing_tail(
                body,
                current_pending,
            )
        else:
            tail, next_container_pending = _shell_substitution_closing_tail(
                body,
                current_pending,
            )
        if tail is None:
            current_pending = next_container_pending
            current_index += 1
            continue

        redacted_tail, tail_count, next_pending, pending_kind, allow_json_tail = (
            _redact_flag_tail(tail)
        )
        count += tail_count
        redacted_lines[-1] = redacted_lines[-1].rstrip("\r\n") + redacted_tail + newline
        if not next_pending:
            return current_index + 1, count
        next_index, next_count = _append_pending_redaction_tail(
            redacted_lines,
            lines,
            current_index + 1,
            next_pending,
            pending_kind,
            allow_json_tail=allow_json_tail,
        )
        return next_index, count + next_count

    return len(lines), count


def _append_pending_redaction_tail(
    redacted_lines: list[str],
    lines: list[str],
    start_index: int,
    pending_quote: str,
    pending_kind: str,
    *,
    allow_json_tail: bool = False,
) -> tuple[int, int]:
    if _is_pending_json(pending_quote) or _is_pending_shell(pending_quote):
        return _append_container_or_shell_tail(
            redacted_lines,
            lines,
            start_index,
            pending_quote,
        )
    if pending_quote == LINE_CONTINUATION:
        return _append_line_continuation_flag_tail(redacted_lines, lines, start_index)
    if pending_kind == "flag":
        closing_index = _find_flag_closing_line(lines, start_index, pending_quote)
        if closing_index is None:
            return start_index, 0
        return _append_flag_closing_tail(
            redacted_lines,
            lines,
            closing_index,
            pending_quote,
        )
    closing_index = _find_closing_quote(
        lines,
        start_index,
        pending_quote,
        allow_json_tail=allow_json_tail,
    )
    if closing_index is None:
        return start_index, 0
    return _append_closing_tail(
        redacted_lines,
        lines,
        closing_index,
        pending_quote,
        allow_json_tail=allow_json_tail,
    )


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


def _redact_url_query_secrets(text: str) -> tuple[str, int]:
    return URL_QUERY_SECRET_RE.subn(_redact_url_query_match, text)


def _redact_url_query_match(match: re.Match[str]) -> str:
    value = match.group(2)
    suffix = ""
    while value and value[-1] in URL_QUERY_TRAILING_PUNCTUATION:
        suffix = value[-1] + suffix
        value = value[:-1]
    while (
        value
        and value[-1] in URL_QUERY_TRAILING_CLOSERS
        and URL_QUERY_TRAILING_CLOSERS[value[-1]] not in value
    ):
        suffix = value[-1] + suffix
        value = value[:-1]
    if not value:
        return match.group(0)
    return f"{match.group(1)}[REDACTED]{suffix}"


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
            redacted_value, pending_quote, tail = _redacted_leading_value(assignment.group(3))
            pending_allow_json_tail = False
            pending_kind = "inline" if pending_quote else ""
            (
                redacted_tail,
                tail_count,
                tail_pending_quote,
                tail_pending_kind,
                tail_allow_json_tail,
            ) = _redact_flag_tail(tail)
            if tail_pending_quote:
                pending_quote = tail_pending_quote
                pending_kind = tail_pending_kind
                pending_allow_json_tail = tail_allow_json_tail
            redacted_lines.append(f"{assignment.group(1)}{redacted_value}{redacted_tail}{assignment.group(4)}{newline}")
            count += 1 + tail_count
            if pending_quote:
                index, closing_tail_count = _append_pending_redaction_tail(
                    redacted_lines,
                    lines,
                    index + 1,
                    pending_quote,
                    pending_kind,
                    allow_json_tail=pending_allow_json_tail,
                )
                count += closing_tail_count
            else:
                index += 1
            continue

        colon = COLON_RE.match(body)
        if colon and SENSITIVE_NAME_RE.search(colon.group(2)):
            redacted_value, pending_quote, tail = _redacted_leading_value(colon.group(3))
            pending_allow_json_tail = False
            pending_kind = "inline" if pending_quote else ""
            (
                redacted_tail,
                tail_count,
                tail_pending_quote,
                tail_pending_kind,
                tail_allow_json_tail,
            ) = _redact_flag_tail(tail)
            if tail_pending_quote:
                pending_quote = tail_pending_quote
                pending_kind = tail_pending_kind
                pending_allow_json_tail = tail_allow_json_tail
            redacted_lines.append(f"{colon.group(1)}{redacted_value}{redacted_tail}{colon.group(4)}{newline}")
            count += 1 + tail_count
            if pending_quote:
                index, closing_tail_count = _append_pending_redaction_tail(
                    redacted_lines,
                    lines,
                    index + 1,
                    pending_quote,
                    pending_kind,
                    allow_json_tail=pending_allow_json_tail,
                )
                count += closing_tail_count
            else:
                index += 1
            continue

        inline_match = _find_inline_sensitive_pair(body)
        if inline_match is not None:
            value = body[inline_match.end() :]
            pending_allow_json_tail = _inline_match_allows_json_tail(inline_match)
            redacted_value, pending_quote, tail = _redacted_leading_value(
                value,
                allow_json_tail=pending_allow_json_tail,
                allow_unquoted_tail=_inline_match_allows_unquoted_tail(inline_match),
            )
            pending_kind = "inline" if pending_quote else ""
            (
                redacted_tail,
                tail_count,
                tail_pending_quote,
                tail_pending_kind,
                tail_allow_json_tail,
            ) = _redact_flag_tail(tail)
            if tail_pending_quote:
                pending_quote = tail_pending_quote
                pending_kind = tail_pending_kind
                pending_allow_json_tail = tail_allow_json_tail
            redacted_lines.append(f"{body[:inline_match.end()]}{redacted_value}{redacted_tail}{newline}")
            count += 1 + tail_count
            if pending_quote:
                index, closing_tail_count = _append_pending_redaction_tail(
                    redacted_lines,
                    lines,
                    index + 1,
                    pending_quote,
                    pending_kind,
                    allow_json_tail=pending_allow_json_tail,
                )
                count += closing_tail_count
            else:
                index += 1
            continue

        redacted_lines.append(line)
        index += 1
    return "".join(redacted_lines), count


def redact_text(text: str) -> str:
    redaction_count = 0
    text, count = PRIVATE_KEY_BLOCK_RE.subn("[REDACTED_PRIVATE_KEY_BLOCK]", text)
    redaction_count += count
    text, count = _redact_sensitive_assignments(text)
    redaction_count += count
    text, count = _redact_flag_values(text)
    redaction_count += count
    for pattern, replacement in TOKEN_PATTERNS:
        text, count = pattern.subn(replacement, text)
        redaction_count += count
    text, count = _redact_url_query_secrets(text)
    redaction_count += count
    _audit_redaction(redaction_count)
    return text


def main() -> int:
    sys.stdout.write(redact_text(sys.stdin.read()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
