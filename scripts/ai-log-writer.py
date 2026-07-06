#!/usr/bin/env python3
"""Build and append shared AI conversation Markdown records."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import importlib.util
import json
import os
import re
import sys
from pathlib import Path


sys.dont_write_bytecode = True
SCRIPT_DIR = Path(__file__).resolve().parent
REDACTION_HELPER = Path(os.environ.get("REDACTION_HELPER", SCRIPT_DIR / "redact-secrets.py"))
ENTRY_HEADING_RE = re.compile(r"^### (User|Assistant) \d+$")
READABLE_GENERATOR_VERSION = "ai-log-readable-v1"
DEFAULT_NOISE_PATTERN_TEXTS = (
    r"^\s*(?:#\s*)?(?:heartbeat|cron|checkpoint)\s+automation\s*:?\s*"
    r"(?:completed|started|finished|no changes|no-op|noop|checked|triggered|"
    r"scheduled|idle sync|daily recovery|nothing to do)\b",
    r"^\s*(?:#\s*)?automation\s+(?:heartbeat|cron|status|run|checkpoint)\s*:?\s*"
    r"(?:completed|started|finished|no changes|no-op|noop|checked|triggered|"
    r"scheduled|idle sync|daily recovery|nothing to do)\b",
    r"^\s*\[(?:heartbeat|cron|checkpoint|automation)[^\]]*\]\s*:?\s*"
    r"(?:completed|started|finished|no changes|no-op|noop|checked|triggered|"
    r"scheduled|idle sync|daily recovery|nothing to do)\b",
    r"^\s*(?:heartbeat|cron|checkpoint|automation)\s*:\s*"
    r"(?:completed|started|finished|no changes|no-op|noop|checked|triggered|"
    r"scheduled|idle sync|daily recovery|nothing to do)\b",
)
SYSTEM_CONTEXT_PREFIXES = (
    "# AGENTS.md",
    "<INSTRUCTIONS>",
    "<environment_context>",
    "<uploaded_file",
    "This session is being continued from a previous conversation",
)
READABLE_CHATTER_TEXTS = {
    "確認します。",
    "確認する。",
    "調べます。",
    "調べる。",
    "探します。",
    "探す。",
    "見ていきます。",
    "見ていく。",
    "進めます。",
    "進める。",
    "実装に入る。",
    "テストを実行する。",
    "テストを走らせる。",
    "レビューを挟む。",
    "差分を確認する。",
}
NOISE_STATUS_TEXT = (
    r"(?:completed|started|finished|no changes|no-op|noop|checked|triggered|"
    r"scheduled|idle sync|daily recovery|nothing to do)"
)
NOISE_STATUS_VALUE_RE = re.compile(rf"^{NOISE_STATUS_TEXT}$", re.IGNORECASE)
NOISE_TAIL_RE = re.compile(
    rf"^\s*(?:[:.,;/-]\s*)?(?:{NOISE_STATUS_TEXT}"
    rf"(?:\s*[:.,;/-]\s*{NOISE_STATUS_TEXT})*)?\s*[:.,;/-]?\s*$",
    re.IGNORECASE,
)
NOISE_XML_TAG_TEXT = r"(?:(?:ai[_-]?)?(?:heartbeat|cron|checkpoint)|automation)"
NOISE_XML_BLOCK_RE = re.compile(
    rf"^\s*<(?P<tag>{NOISE_XML_TAG_TEXT})\b(?P<attrs>[^>]*)>"
    rf"(?P<body>.*?)"
    rf"\s*(?:</(?P=tag)>)?\s*$",
    re.IGNORECASE | re.DOTALL,
)
XML_ATTR_RE = re.compile(
    r"""(?P<name>[A-Za-z_:][\w:.-]*)\s*=\s*(?:"(?P<double>[^"]*)"|'(?P<single>[^']*)'|(?P<bare>[^\s/>]+))"""
)
NOISE_XML_ATTR_NAMES = {"status", "state", "result"}
LEGACY_REDACTED_ASSIGNMENT_TAIL_RE = re.compile(
    r"^(\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*)([\"'])\[REDACTED\]\3(.+)$"
)
LEGACY_REDACTED_COLON_TAIL_RE = re.compile(
    r"^(\s*[\"']?([A-Za-z_][A-Za-z0-9_-]*)[\"']?\s*:\s*)([\"'])\[REDACTED\]\3(.+)$"
)
LEGACY_SENSITIVE_NAME_RE = re.compile(
    r"(api[_-]?key|token|secret|password|passwd|pwd|private[_-]?key|"
    r"access[_-]?key|client[_-]?secret|refresh[_-]?token|webhook[_-]?secret)",
    re.IGNORECASE,
)


def _load_redactor():
    spec = importlib.util.spec_from_file_location("redact_secrets_runtime", REDACTION_HELPER)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load redaction helper: {REDACTION_HELPER}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.redact_text


redact_text = _load_redactor()
_noise_patterns: list[re.Pattern[str]] | None = None


def yaml_quote(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def sha256_text(value: str) -> str:
    return "sha256:" + hashlib.sha256(value.encode("utf-8")).hexdigest()


def normalize_transcript(value: str) -> str:
    value = value.replace("\r\n", "\n").replace("\r", "\n").rstrip()
    return value + "\n" if value else ""


def escape_transcript_text(value: str) -> str:
    lines = value.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    return "\n".join(f"\\{line}" if ENTRY_HEADING_RE.match(line) else line for line in lines)


def message_text(message: dict) -> str:
    content = message.get("text", message.get("content", ""))
    if isinstance(content, list):
        parts: list[str] = []
        for item in content:
            if isinstance(item, dict) and "text" in item:
                parts.append(str(item["text"]))
            elif isinstance(item, str):
                parts.append(item)
        return "\n".join(parts)
    if isinstance(content, str):
        return content
    return str(content)


def noise_filter_enabled() -> bool:
    value = os.environ.get("AI_LOG_NOISE_FILTER", "1").strip().lower()
    return value not in {"0", "false", "no", "off"}


def load_noise_patterns() -> list[re.Pattern[str]]:
    global _noise_patterns
    if _noise_patterns is not None:
        return _noise_patterns

    pattern_texts = list(DEFAULT_NOISE_PATTERN_TEXTS)
    pattern_file = os.environ.get("AI_LOG_NOISE_PATTERNS_FILE", "")
    if pattern_file:
        path = Path(pattern_file).expanduser()
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                stripped = line.strip()
                if not stripped or stripped.startswith("#"):
                    continue
                pattern_texts.append(stripped)

    _noise_patterns = [re.compile(pattern, re.IGNORECASE) for pattern in pattern_texts]
    return _noise_patterns


def meaningful_lines(value: str) -> list[str]:
    return [
        line.strip()
        for line in value.replace("\r\n", "\n").replace("\r", "\n").split("\n")
        if line.strip()
    ]


def is_noise_tail(value: str) -> bool:
    return bool(NOISE_TAIL_RE.fullmatch(value))


def is_noise_status_value(value: str) -> bool:
    return bool(NOISE_STATUS_VALUE_RE.fullmatch(value.strip()))


def xml_attr_value(match: re.Match[str]) -> str:
    for group_name in ("double", "single", "bare"):
        value = match.group(group_name)
        if value is not None:
            return value
    return ""


def xml_attrs_are_noise(attrs: str) -> bool:
    for match in XML_ATTR_RE.finditer(attrs):
        name = match.group("name").lower()
        if name not in NOISE_XML_ATTR_NAMES:
            return False
        if not is_noise_status_value(xml_attr_value(match)):
            return False
    remaining = XML_ATTR_RE.sub("", attrs).replace("/", "").strip()
    return not remaining


def is_noise_line(line: str) -> bool:
    for pattern in load_noise_patterns():
        match = pattern.search(line)
        if not match:
            continue
        tail = line[match.end():]
        if not tail.strip() or is_noise_tail(tail):
            return True
    return False


def is_noise_xml_block(value: str) -> bool:
    match = NOISE_XML_BLOCK_RE.fullmatch(value)
    if not match:
        return False
    if not xml_attrs_are_noise(match.group("attrs") or ""):
        return False
    body = match.group("body") or ""
    return not body.strip() or is_noise_tail(body)


def is_noise_message(value: str) -> bool:
    if not noise_filter_enabled():
        return False
    normalized = value.replace("\r\n", "\n").replace("\r", "\n").strip()
    if not normalized:
        return True
    if any(normalized.startswith(prefix) for prefix in SYSTEM_CONTEXT_PREFIXES):
        return True
    if is_noise_xml_block(normalized):
        return True
    lines = meaningful_lines(normalized)
    if not lines:
        return True
    if len(lines) == 1:
        return is_noise_line(lines[0])
    return all(is_noise_line(line) for line in lines)


class AppendMismatch(ValueError):
    """Saved transcript and source messages cannot be aligned."""


def load_message_sets() -> tuple[list[dict], list[dict], int]:
    raw = sys.stdin.read()
    if not raw.strip():
        return [], [], 0
    data = json.loads(raw)
    if isinstance(data, dict):
        data = data.get("messages", [])
    all_messages = []
    kept_messages = []
    omitted_count = 0
    for message in data:
        role = message.get("role")
        if role not in ("user", "assistant"):
            continue
        text = redact_text(message_text(message))
        if not text.strip():
            all_messages.append({"role": role, "text": "", "omitted": True, "empty": True})
            omitted_count += 1
            continue
        omitted = is_noise_message(text)
        source_message = {"role": role, "text": text, "omitted": omitted}
        all_messages.append(source_message)
        if omitted:
            omitted_count += 1
            continue
        kept_messages.append({"role": role, "text": text})
    return all_messages, kept_messages, omitted_count


def load_messages() -> tuple[list[dict], int]:
    _all_messages, kept_messages, omitted_count = load_message_sets()
    return kept_messages, omitted_count


def format_entries(
    messages: list[dict],
    *,
    start_index: int = 0,
    user_count: int = 0,
    assistant_count: int = 0,
) -> tuple[str, list[str]]:
    entries: list[str] = []
    for message in messages[start_index:]:
        if message["role"] == "user":
            user_count += 1
            heading = f"### User {user_count}"
        else:
            assistant_count += 1
            heading = f"### Assistant {assistant_count}"
        entry = f"{heading}\n\n{escape_transcript_text(message['text']).rstrip()}\n"
        entries.append(entry)
    return normalize_transcript("\n".join(entries)), entries


def transcript_metadata(transcript: str, entries: list[str] | None = None) -> dict[str, str | int]:
    normalized = normalize_transcript(transcript)
    if entries is None:
        entries = parse_transcript_entries(normalized)
    last_entry = normalize_transcript(entries[-1]) if entries else ""
    return {
        "msg_count": len(entries),
        "last_message_hash": sha256_text(last_entry),
        "transcript_hash": sha256_text(normalized),
    }


def parse_transcript_entries(transcript: str) -> list[str]:
    lines = normalize_transcript(transcript).splitlines()
    starts = [
        idx
        for idx, line in enumerate(lines)
        if ENTRY_HEADING_RE.match(line)
    ]
    if not starts:
        return []
    entries: list[str] = []
    for offset, start in enumerate(starts):
        end = starts[offset + 1] if offset + 1 < len(starts) else len(lines)
        entries.append(normalize_transcript("\n".join(lines[start:end])))
    return entries


def transcript_counts(transcript: str) -> tuple[int, int]:
    user_count = 0
    assistant_count = 0
    for line in transcript.splitlines():
        user_match = re.match(r"^### User (\d+)$", line)
        assistant_match = re.match(r"^### Assistant (\d+)$", line)
        if user_match:
            user_count = max(user_count, int(user_match.group(1)))
        elif assistant_match:
            assistant_count = max(assistant_count, int(assistant_match.group(1)))
    return user_count, assistant_count


def transcript_entry_matches(source_entry: str, existing_entry: str) -> bool:
    source_normalized = normalize_transcript(source_entry)
    existing_normalized = normalize_transcript(existing_entry)
    if source_normalized == existing_normalized:
        return True
    if normalize_transcript(redact_text(existing_normalized)) == source_normalized:
        return True
    return legacy_overredacted_source_for_existing(source_normalized, existing_normalized) is not None


def align_existing_source_index(
    existing_entries: list[str],
    source_messages: list[dict],
    *,
    unmarked_skip_limit: int = 0,
) -> int | None:
    user_count = 0
    assistant_count = 0
    entry_index = 0

    for source_index, message in enumerate(source_messages):
        if entry_index >= len(existing_entries):
            return source_index

        _transcript, source_entries = format_entries(
            [message],
            user_count=user_count,
            assistant_count=assistant_count,
        )
        source_entry = source_entries[0]
        if transcript_entry_matches(source_entry, existing_entries[entry_index]):
            if message["role"] == "user":
                user_count += 1
            else:
                assistant_count += 1
            entry_index += 1
            continue

        if message.get("omitted"):
            continue
        if unmarked_skip_limit > 0:
            unmarked_skip_limit -= 1
            continue
        return None

    if entry_index == len(existing_entries):
        return len(source_messages)
    return None


def legacy_overredacted_line(body: str) -> str:
    for pattern in (LEGACY_REDACTED_ASSIGNMENT_TAIL_RE, LEGACY_REDACTED_COLON_TAIL_RE):
        match = pattern.match(body)
        if match and LEGACY_SENSITIVE_NAME_RE.search(match.group(2)):
            return f"{match.group(1)}{match.group(3)}[REDACTED]{match.group(3)}"
    return body


def legacy_overredacted_source_for_existing(
    source_transcript: str,
    existing_transcript: str,
) -> str | None:
    source_lines = normalize_transcript(source_transcript).splitlines(keepends=True)
    existing_lines = normalize_transcript(existing_transcript).splitlines(keepends=True)
    if len(source_lines) != len(existing_lines):
        return None

    aligned_lines: list[str] = []
    for source_line, existing_line in zip(source_lines, existing_lines):
        if source_line == existing_line:
            aligned_lines.append(source_line)
            continue

        source_body = source_line.rstrip("\r\n")
        existing_body = existing_line.rstrip("\r\n")
        existing_newline = existing_line[len(existing_body) :]
        if legacy_overredacted_line(source_body) == existing_body:
            aligned_lines.append(existing_body + existing_newline)
            continue
        return None

    return normalize_transcript("".join(aligned_lines))


def split_frontmatter(markdown: str) -> tuple[list[str], str]:
    lines = markdown.splitlines(keepends=True)
    if not lines or lines[0].strip() != "---":
        return [], markdown
    for idx in range(1, len(lines)):
        if lines[idx].strip() == "---":
            return lines[1:idx], "".join(lines[idx + 1 :])
    return [], markdown


def frontmatter_map(lines: list[str]) -> dict[str, str]:
    result: dict[str, str] = {}
    for line in lines:
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        key = key.strip()
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", key):
            result[key] = value.strip().strip('"')
    return result


def replace_frontmatter(markdown: str, updates: dict[str, str | int]) -> str:
    lines, body = split_frontmatter(markdown)
    if not lines:
        raise ValueError("missing frontmatter")
    updated: list[str] = []
    seen: set[str] = set()
    for line in lines:
        key = line.split(":", 1)[0].strip() if ":" in line else ""
        if key in updates:
            value = updates[key]
            if isinstance(value, int):
                updated.append(f"{key}: {value}\n")
            else:
                updated.append(f"{key}: {yaml_quote(value)}\n")
            seen.add(key)
        else:
            updated.append(line)
    for key, value in updates.items():
        if key in seen:
            continue
        if isinstance(value, int):
            updated.append(f"{key}: {value}\n")
        else:
            updated.append(f"{key}: {yaml_quote(value)}\n")
    return "---\n" + "".join(updated) + "---\n" + body


def split_transcript(
    markdown: str,
    *,
    expected_hash: str = "",
    expected_count: int | None = None,
) -> tuple[str, str]:
    matches = list(re.finditer(r"(?m)^## Transcript\s*$", markdown))
    if not matches:
        raise ValueError("missing Transcript section")

    for match in matches:
        heading_end = match.end()
        prefix = markdown[:heading_end]
        transcript = markdown[heading_end:]
        if transcript.startswith("\n"):
            transcript = transcript[1:]
        if expected_count is None and not expected_hash:
            return prefix, transcript

        entries = parse_transcript_entries(transcript)
        metadata = transcript_metadata(transcript, entries)
        if expected_count is not None and len(entries) != expected_count:
            continue
        if expected_hash and metadata["transcript_hash"] != expected_hash:
            continue
        return prefix, transcript

    raise ValueError("Transcript section does not match frontmatter metadata")


def render_tags(tags: list[str]) -> list[str]:
    unique_tags: list[str] = []
    for tag in tags:
        if tag and tag not in unique_tags:
            unique_tags.append(tag)
    return ["tags:\n", *[f"  - {yaml_quote(tag)}\n" for tag in unique_tags]]


def filter_messages(args: argparse.Namespace) -> int:
    all_messages, kept_messages, omitted_count = load_message_sets()
    messages = all_messages if args.include_omitted else kept_messages
    payload = {
        "count": len(kept_messages),
        "omitted_count": omitted_count,
        "source_count": len(all_messages),
        "messages": [
            {
                "role": message["role"],
                "text": message["text"],
                "content": message["text"],
                **({"omitted": bool(message.get("omitted"))} if args.include_omitted else {}),
            }
            for message in messages
        ],
    }
    json.dump(payload, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


def generated_at_now() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def is_readable_chatter_message(message: dict) -> bool:
    if message.get("role") != "assistant":
        return False
    text = str(message.get("text", "")).replace("\r\n", "\n").replace("\r", "\n").strip()
    if "\n" in text or len(text) > 80:
        return False
    return text in READABLE_CHATTER_TEXTS


def flush_omission_marker(entries: list[str], omitted_run: int) -> int:
    if omitted_run > 0:
        entries.append(f"(省略 {omitted_run} 件)\n")
    return 0


def format_readable_entries(messages: list[dict]) -> tuple[str, int, int]:
    entries: list[str] = []
    user_count = 0
    assistant_count = 0
    omitted_count = 0
    omitted_run = 0

    for message in messages:
        omitted = bool(message.get("omitted")) or is_readable_chatter_message(message)
        if omitted:
            omitted_count += 1
            omitted_run += 1
            continue

        omitted_run = flush_omission_marker(entries, omitted_run)
        if message["role"] == "user":
            user_count += 1
            heading = f"### User {user_count}"
        else:
            assistant_count += 1
            heading = f"### Assistant {assistant_count}"
        entries.append(f"{heading}\n\n{escape_transcript_text(message['text']).rstrip()}\n")

    flush_omission_marker(entries, omitted_run)
    kept_count = user_count + assistant_count
    return normalize_transcript("\n".join(entries)), kept_count, omitted_count


def render_readable_record(args: argparse.Namespace) -> int:
    all_messages, _kept_messages, writer_omitted_count = load_message_sets()
    conversation, kept_count, readable_omitted_count = format_readable_entries(all_messages)
    total_omitted_count = max(readable_omitted_count, writer_omitted_count) + args.omitted_msg_count
    title = redact_text(args.title).replace("\n", " ").replace("\r", "").strip() or "untitled"
    tags = args.tag or []
    for tag in ("ai-log", "ai-log-readable"):
        if tag not in tags:
            tags.append(tag)
    generated_at = args.generated_at or generated_at_now()

    lines = [
        "---\n",
        f"date: {args.date}\n",
        f"title: {yaml_quote(title)}\n",
        f"source: {yaml_quote(args.source)}\n",
        f"raw_ref: {yaml_quote(args.raw_ref)}\n",
        f"raw_session_id: {yaml_quote(args.raw_session_id)}\n",
        f"record_kind: {yaml_quote(args.record_kind)}\n",
        f"msg_count: {kept_count}\n",
        *([f"omitted_msg_count: {total_omitted_count}\n"] if total_omitted_count > 0 else []),
        f"raw_hash: {yaml_quote(args.raw_hash)}\n",
        f"generated_at: {yaml_quote(generated_at)}\n",
        f"generator_version: {yaml_quote(args.generator_version)}\n",
        *render_tags(tags),
        "---\n",
        "\n",
        f"# {title}\n",
        "\n",
        "## Conversation\n",
        "\n",
        conversation,
        "\n",
        "## Raw\n",
        "\n",
        f"- {args.raw_ref}\n",
    ]
    sys.stdout.write("".join(lines))
    return 0


def render_existing_update(
    prefix: str,
    frontmatter: dict[str, str],
    existing_transcript: str,
    *,
    effective_omitted_count: int,
    update_omitted_count: bool = True,
) -> str | None:
    entries = parse_transcript_entries(existing_transcript)
    metadata = transcript_metadata(existing_transcript, entries)
    updates: dict[str, str | int] = {}
    if frontmatter.get("msg_count") != str(metadata["msg_count"]):
        updates["msg_count"] = metadata["msg_count"]
    if frontmatter.get("last_message_hash", "") != str(metadata["last_message_hash"]):
        updates["last_message_hash"] = str(metadata["last_message_hash"])
    if frontmatter.get("transcript_hash", "") != str(metadata["transcript_hash"]):
        updates["transcript_hash"] = str(metadata["transcript_hash"])
    if update_omitted_count and (effective_omitted_count > 0 or "omitted_msg_count" in frontmatter):
        if frontmatter.get("omitted_msg_count") != str(effective_omitted_count):
            updates["omitted_msg_count"] = effective_omitted_count
    if not updates:
        return None
    updated_prefix = replace_frontmatter(redact_text(prefix), updates)
    return updated_prefix.rstrip() + "\n\n" + normalize_transcript(existing_transcript)


def render_append_from_messages(
    markdown: str,
    prefix: str,
    frontmatter: dict[str, str],
    existing_transcript: str,
    existing_count: int,
    source_messages: list[dict],
    *,
    omitted_count: int,
    append_omitted: bool,
) -> str:
    existing_entries = parse_transcript_entries(existing_transcript)
    if existing_count != len(existing_entries):
        raise AppendMismatch("msg_count does not match Transcript entries")

    expected_hash = frontmatter.get("transcript_hash", "")
    actual_hash = transcript_metadata(existing_transcript, existing_entries)["transcript_hash"]
    if expected_hash and expected_hash != actual_hash:
        raise AppendMismatch("transcript_hash does not match existing Transcript")

    try:
        prior_omitted_count = int(frontmatter.get("omitted_msg_count", "0"))
    except ValueError:
        prior_omitted_count = 0
    effective_omitted_count = max(omitted_count, prior_omitted_count)
    has_omitted_markers = any(message.get("omitted") for message in source_messages)
    append_start = existing_count
    raw_alignment = not append_omitted and (has_omitted_markers or prior_omitted_count > 0)
    if raw_alignment:
        aligned_index = align_existing_source_index(
            existing_entries,
            source_messages,
            unmarked_skip_limit=0 if has_omitted_markers else prior_omitted_count,
        )
        if aligned_index is None:
            raise AppendMismatch("source messages do not match existing Transcript")
        append_start = aligned_index
        redacted_existing_transcript = normalize_transcript(redact_text(existing_transcript))
        if redacted_existing_transcript != normalize_transcript(existing_transcript):
            existing_transcript = redacted_existing_transcript
            existing_entries = parse_transcript_entries(existing_transcript)
    elif len(source_messages) <= existing_count:
        updated = render_existing_update(
            prefix,
            frontmatter,
            existing_transcript,
            effective_omitted_count=effective_omitted_count,
            update_omitted_count=False,
        )
        if updated is not None:
            return updated
        return markdown

    if existing_count > 0 and not raw_alignment:
        source_prefix_transcript, source_prefix_entries = format_entries(source_messages[:existing_count])
        source_prefix_metadata = transcript_metadata(source_prefix_transcript, source_prefix_entries)
        expected_last_hash = frontmatter.get("last_message_hash", "")
        prefix_matches = (
            (not expected_last_hash or expected_last_hash == source_prefix_metadata["last_message_hash"])
            and (not expected_hash or expected_hash == source_prefix_metadata["transcript_hash"])
        )
        if not prefix_matches:
            redacted_existing_transcript = normalize_transcript(redact_text(existing_transcript))
            redacted_existing_entries = parse_transcript_entries(redacted_existing_transcript)
            redacted_metadata = transcript_metadata(redacted_existing_transcript, redacted_existing_entries)
            redacted_prefix_matches = (
                len(redacted_existing_entries) == existing_count
                and redacted_metadata["last_message_hash"] == source_prefix_metadata["last_message_hash"]
                and redacted_metadata["transcript_hash"] == source_prefix_metadata["transcript_hash"]
            )
            if redacted_prefix_matches:
                existing_transcript = redacted_existing_transcript
                existing_entries = redacted_existing_entries
            else:
                legacy_source_transcript = legacy_overredacted_source_for_existing(
                    source_prefix_transcript,
                    existing_transcript,
                )
                legacy_prefix_matches = False
                if legacy_source_transcript is not None:
                    legacy_source_entries = parse_transcript_entries(legacy_source_transcript)
                    legacy_source_metadata = transcript_metadata(
                        legacy_source_transcript,
                        legacy_source_entries,
                    )
                    legacy_prefix_matches = (
                        len(legacy_source_entries) == existing_count
                        and (
                            not expected_last_hash
                            or expected_last_hash == legacy_source_metadata["last_message_hash"]
                        )
                        and (
                            not expected_hash
                            or expected_hash == legacy_source_metadata["transcript_hash"]
                        )
                    )
                if not legacy_prefix_matches:
                    if expected_last_hash and expected_last_hash != source_prefix_metadata["last_message_hash"]:
                        raise AppendMismatch("last_message_hash does not match source prefix")
                    if expected_hash and expected_hash != source_prefix_metadata["transcript_hash"]:
                        raise AppendMismatch("transcript_hash does not match source prefix")

    if len(source_messages) <= append_start:
        updated = render_existing_update(
            prefix,
            frontmatter,
            existing_transcript,
            effective_omitted_count=effective_omitted_count,
            update_omitted_count=False,
        )
        if updated is not None:
            return updated
        return markdown

    append_candidates = source_messages[append_start:]
    should_update_omitted_count = any(
        message.get("omitted") and not message.get("empty")
        for message in append_candidates
    )
    if not append_omitted:
        append_candidates = [message for message in append_candidates if not message.get("omitted")]

    prefix = redact_text(prefix)
    user_count, assistant_count = transcript_counts(existing_transcript)
    appended_transcript, appended_entries = format_entries(
        append_candidates,
        user_count=user_count,
        assistant_count=assistant_count,
    )
    if not appended_entries:
        updated = render_existing_update(
            prefix,
            frontmatter,
            existing_transcript,
            effective_omitted_count=effective_omitted_count,
            update_omitted_count=should_update_omitted_count,
        )
        if updated is not None:
            return updated
        return markdown

    existing_normalized = normalize_transcript(existing_transcript)
    if existing_normalized:
        full_transcript = existing_normalized + "\n" + appended_transcript
    else:
        full_transcript = appended_transcript
    metadata = transcript_metadata(full_transcript)
    updates: dict[str, str | int] = {
        "msg_count": metadata["msg_count"],
        "last_message_hash": str(metadata["last_message_hash"]),
        "transcript_hash": str(metadata["transcript_hash"]),
    }
    if effective_omitted_count > 0 or "omitted_msg_count" in frontmatter:
        updates["omitted_msg_count"] = effective_omitted_count
    updated_prefix = replace_frontmatter(prefix, updates)
    return updated_prefix.rstrip() + "\n\n" + normalize_transcript(full_transcript)


def create_record(args: argparse.Namespace) -> int:
    messages, omitted_count = load_messages()
    omitted_count += args.omitted_msg_count
    transcript, entries = format_entries(messages)
    metadata = transcript_metadata(transcript, entries)
    title = redact_text(args.title).replace("\n", " ").replace("\r", "").strip() or "untitled"
    tags = args.tag or []
    if "ai-log" not in tags:
        tags.append("ai-log")

    lines = [
        "---\n",
        f"date: {args.date}\n",
        f"title: {yaml_quote(title)}\n",
        f"source: {yaml_quote(args.source)}\n",
        f"session_id: {yaml_quote(args.session_id)}\n",
        f"record_kind: {yaml_quote(args.record_kind)}\n",
        f"msg_count: {metadata['msg_count']}\n",
        f"last_message_hash: {yaml_quote(str(metadata['last_message_hash']))}\n",
        f"transcript_hash: {yaml_quote(str(metadata['transcript_hash']))}\n",
        *([f"omitted_msg_count: {omitted_count}\n"] if omitted_count > 0 else []),
        *render_tags(tags),
        "---\n",
        "\n",
        f"# {title}\n",
        "\n",
        "## Transcript\n",
        "\n",
        transcript,
    ]
    sys.stdout.write("".join(lines))
    return 0


def append_record(args: argparse.Namespace) -> int:
    path = Path(args.existing_file)
    markdown = path.read_text(encoding="utf-8", errors="replace")
    frontmatter_lines, _body = split_frontmatter(markdown)
    frontmatter = frontmatter_map(frontmatter_lines)
    if not frontmatter_lines:
        print("missing frontmatter", file=sys.stderr)
        return 3

    try:
        existing_count = int(frontmatter.get("msg_count", "0"))
    except ValueError:
        print("invalid msg_count", file=sys.stderr)
        return 2

    expected_hash = frontmatter.get("transcript_hash", "")
    try:
        prefix, existing_transcript = split_transcript(
            markdown,
            expected_hash=expected_hash,
            expected_count=existing_count,
        )
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 3

    existing_entries = parse_transcript_entries(existing_transcript)
    if existing_count != len(existing_entries):
        print("msg_count does not match Transcript entries", file=sys.stderr)
        return 2

    actual_hash = transcript_metadata(existing_transcript, existing_entries)["transcript_hash"]
    if expected_hash and expected_hash != actual_hash:
        print("transcript_hash does not match existing Transcript", file=sys.stderr)
        return 2

    all_messages, kept_messages, omitted_count = load_message_sets()
    omitted_count += args.omitted_msg_count
    has_omitted_messages = any(message.get("omitted") for message in all_messages)
    try:
        prior_omitted_count = int(frontmatter.get("omitted_msg_count", "0"))
    except ValueError:
        prior_omitted_count = 0
    raw_fallback = omitted_count > 0 or has_omitted_messages or prior_omitted_count > 0

    if raw_fallback and len(all_messages) > existing_count:
        try:
            output = render_append_from_messages(
                markdown,
                prefix,
                frontmatter,
                existing_transcript,
                existing_count,
                all_messages,
                omitted_count=omitted_count,
                append_omitted=False,
            )
        except AppendMismatch:
            pass
        else:
            sys.stdout.write(output)
            return 0

    try:
        output = render_append_from_messages(
            markdown,
            prefix,
            frontmatter,
            existing_transcript,
            existing_count,
            kept_messages,
            omitted_count=omitted_count,
            append_omitted=True,
        )
    except AppendMismatch as filtered_exc:
        print(str(filtered_exc), file=sys.stderr)
        return 2
    else:
        if output != markdown or not raw_fallback or len(all_messages) <= existing_count:
            sys.stdout.write(output)
            return 0

    sys.stdout.write(output)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    create = subparsers.add_parser("create")
    create.add_argument("--date", required=True)
    create.add_argument("--title", required=True)
    create.add_argument("--source", required=True)
    create.add_argument("--session-id", required=True)
    create.add_argument("--record-kind", required=True)
    create.add_argument("--omitted-msg-count", type=int, default=0)
    create.add_argument("--tag", action="append", default=[])
    create.set_defaults(func=create_record)

    append = subparsers.add_parser("append")
    append.add_argument("--existing-file", required=True)
    append.add_argument("--omitted-msg-count", type=int, default=0)
    append.set_defaults(func=append_record)

    filter_parser = subparsers.add_parser("filter")
    filter_parser.add_argument("--include-omitted", action="store_true")
    filter_parser.set_defaults(func=filter_messages)

    readable = subparsers.add_parser("readable")
    readable.add_argument("--date", required=True)
    readable.add_argument("--title", required=True)
    readable.add_argument("--source", required=True)
    readable.add_argument("--raw-session-id", required=True)
    readable.add_argument("--raw-ref", required=True)
    readable.add_argument("--raw-hash", required=True)
    readable.add_argument("--record-kind", required=True)
    readable.add_argument("--omitted-msg-count", type=int, default=0)
    readable.add_argument("--generated-at", default="")
    readable.add_argument("--generator-version", default=READABLE_GENERATOR_VERSION)
    readable.add_argument("--tag", action="append", default=[])
    readable.set_defaults(func=render_readable_record)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
