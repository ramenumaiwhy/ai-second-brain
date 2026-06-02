#!/usr/bin/env python3
"""Build and append shared AI conversation Markdown records."""

from __future__ import annotations

import argparse
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


def load_messages() -> list[dict]:
    raw = sys.stdin.read()
    if not raw.strip():
        return []
    data = json.loads(raw)
    if isinstance(data, dict):
        data = data.get("messages", [])
    messages = []
    for message in data:
        role = message.get("role")
        if role not in ("user", "assistant"):
            continue
        text = redact_text(message_text(message))
        if text.strip():
            messages.append({"role": role, "text": text})
    return messages


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


def create_record(args: argparse.Namespace) -> int:
    messages = load_messages()
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
        *render_tags(tags),
        "---\n",
        "\n",
        f"# {title}\n",
        "\n",
        "## Summary\n",
        "\n",
        "\n",
        "## Decisions\n",
        "\n",
        "\n",
        "## Next Actions\n",
        "\n",
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

    messages = load_messages()
    if len(messages) <= existing_count:
        sys.stdout.write(markdown)
        return 0

    if existing_count > 0:
        source_prefix_transcript, source_prefix_entries = format_entries(messages[:existing_count])
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
                        print("last_message_hash does not match source prefix", file=sys.stderr)
                        return 2
                    if expected_hash and expected_hash != source_prefix_metadata["transcript_hash"]:
                        print("transcript_hash does not match source prefix", file=sys.stderr)
                        return 2

    prefix = redact_text(prefix)
    user_count, assistant_count = transcript_counts(existing_transcript)
    appended_transcript, appended_entries = format_entries(
        messages,
        start_index=existing_count,
        user_count=user_count,
        assistant_count=assistant_count,
    )
    if not appended_entries:
        sys.stdout.write(markdown)
        return 0

    existing_normalized = normalize_transcript(existing_transcript)
    if existing_normalized:
        full_transcript = existing_normalized + "\n" + appended_transcript
    else:
        full_transcript = appended_transcript
    metadata = transcript_metadata(full_transcript)
    updated_prefix = replace_frontmatter(
        prefix,
        {
            "msg_count": metadata["msg_count"],
            "last_message_hash": str(metadata["last_message_hash"]),
            "transcript_hash": str(metadata["transcript_hash"]),
        },
    )
    sys.stdout.write(updated_prefix.rstrip() + "\n\n" + normalize_transcript(full_transcript))
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
    create.add_argument("--tag", action="append", default=[])
    create.set_defaults(func=create_record)

    append = subparsers.add_parser("append")
    append.add_argument("--existing-file", required=True)
    append.set_defaults(func=append_record)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
