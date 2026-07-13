#!/usr/bin/env python3
"""Append one completed Hermes turn to redacted Second Brain Markdown."""

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


sys.dont_write_bytecode = True
os.umask(0o077)

SCRIPT_DIR = Path(__file__).resolve().parent
WRITER_PATH = SCRIPT_DIR / "ai-log-writer.py"
SAFE_ID_RE = re.compile(r"[^A-Za-z0-9_.:-]+")


class TurnError(ValueError):
    pass


def _load_writer():
    spec = importlib.util.spec_from_file_location("ai_log_writer_runtime", WRITER_PATH)
    if spec is None or spec.loader is None:
        raise TurnError(f"cannot load AI log writer: {WRITER_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


writer = _load_writer()


def load_payload(args: argparse.Namespace) -> dict[str, Any]:
    if args.turn_json:
        raw = Path(args.turn_json).read_text(encoding="utf-8", errors="replace")
    else:
        raw = sys.stdin.buffer.read().decode("utf-8", errors="replace")
    if not raw.strip():
        raise TurnError("turn JSON is empty")
    payload = json.loads(raw)
    if not isinstance(payload, dict):
        raise TurnError("turn JSON must be an object")
    return payload


def required_text(payload: dict[str, Any], field: str) -> str:
    value = payload.get(field)
    if not isinstance(value, str) or not value.strip():
        raise TurnError(f"missing required field: {field}")
    return value.strip()


def safe_session_id(session_id: str) -> str:
    value = SAFE_ID_RE.sub("-", session_id).strip("-") or "session"
    if len(value) <= 120:
        return value
    digest = hashlib.sha256(session_id.encode("utf-8")).hexdigest()[:16]
    return f"{value[:96]}-{digest}"


def ensure_directory(path: Path) -> None:
    if path.exists() and path.is_symlink():
        raise TurnError(f"output path is a symlink: {path}")
    path.mkdir(exist_ok=True)


def output_paths(session_id: str, record_date: str) -> tuple[Path, Path]:
    root_value = os.environ.get("SECOND_BRAIN_DIR", "").strip()
    if not root_value:
        raise TurnError("SECOND_BRAIN_DIR is not set")
    root = Path(root_value).expanduser()
    if root.is_symlink() or not root.is_dir():
        raise TurnError("SECOND_BRAIN_DIR must be an existing non-symlink directory")

    month = record_date[:7]
    raw_dir = root / "AI-Logs" / "raw" / "hermes" / month
    readable_dir = root / "AI-Logs" / "readable" / "hermes" / month
    current = root
    for part in ("AI-Logs", "raw", "hermes", month):
        current = current / part
        ensure_directory(current)
    current = root / "AI-Logs"
    for part in ("readable", "hermes", month):
        current = current / part
        ensure_directory(current)

    name = safe_session_id(session_id) + ".md"
    return raw_dir / name, readable_dir / name


def atomic_write(path: Path, text: str) -> None:
    if path.exists() and path.is_symlink():
        raise TurnError(f"output file is a symlink: {path}")
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    temp_path = Path(temp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_path, path)
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except Exception:
        temp_path.unlink(missing_ok=True)
        raise


def filtered_turn(payload: dict[str, Any]) -> tuple[list[dict[str, str]], int]:
    source = [
        {"role": "user", "text": required_text(payload, "user_message")},
        {"role": "assistant", "text": required_text(payload, "assistant_response")},
    ]
    kept: list[dict[str, str]] = []
    omitted = 0
    for message in source:
        text = writer.redact_text(message["text"])
        if not text.strip() or writer.is_noise_message(text):
            omitted += 1
            continue
        kept.append({"role": message["role"], "text": text})
    return kept, omitted


def create_raw(
    raw_path: Path,
    messages: list[dict[str, str]],
    payload: dict[str, Any],
    record_date: str,
    omitted: int,
) -> str:
    session_id = required_text(payload, "session_id")
    title_source = next((m["text"] for m in messages if m["role"] == "user"), "Hermes session")
    title = title_source.splitlines()[0].strip()[:120] or "Hermes session"
    command = [
        sys.executable,
        str(WRITER_PATH),
        "create",
        f"--date={record_date}",
        f"--title={title}",
        "--source=Hermes Agent",
        f"--session-id={session_id}",
        "--record-kind=conversation",
        "--tag=hermes",
        f"--omitted-msg-count={omitted}",
    ]
    result = subprocess.run(
        command,
        input=json.dumps(messages, ensure_ascii=False),
        text=True,
        capture_output=True,
        timeout=10,
        check=False,
    )
    if result.returncode != 0:
        raise TurnError(result.stderr.strip() or "AI log writer create failed")
    markdown = writer.replace_frontmatter(
        result.stdout,
        {
            "last_hermes_turn_id": turn_id(payload),
            "hermes_platform": str(payload.get("platform") or "hermes"),
        },
    )
    atomic_write(raw_path, markdown)
    return markdown


def turn_id(payload: dict[str, Any]) -> str:
    explicit = str(payload.get("turn_id") or "").strip()
    if explicit:
        return explicit
    basis = required_text(payload, "user_message") + "\0" + required_text(payload, "assistant_response")
    return "sha256:" + hashlib.sha256(basis.encode("utf-8")).hexdigest()


def append_raw(
    raw_path: Path,
    messages: list[dict[str, str]],
    payload: dict[str, Any],
    omitted: int,
) -> tuple[str, bool]:
    markdown = raw_path.read_text(encoding="utf-8", errors="replace")
    frontmatter_lines, _body = writer.split_frontmatter(markdown)
    frontmatter = writer.frontmatter_map(frontmatter_lines)
    current_turn_id = turn_id(payload)
    if frontmatter.get("last_hermes_turn_id") == current_turn_id:
        return markdown, False

    try:
        existing_count = int(frontmatter.get("msg_count", "0"))
        prior_omitted = int(frontmatter.get("omitted_msg_count", "0"))
    except ValueError as exc:
        raise TurnError("invalid Hermes log message count") from exc
    prefix, transcript = writer.split_transcript(
        markdown,
        expected_hash=frontmatter.get("transcript_hash", ""),
        expected_count=existing_count,
    )
    user_count, assistant_count = writer.transcript_counts(transcript)
    addition, entries = writer.format_entries(
        messages,
        user_count=user_count,
        assistant_count=assistant_count,
    )
    if transcript and addition:
        full_transcript = writer.normalize_transcript(transcript) + addition
    else:
        full_transcript = writer.normalize_transcript(transcript) or addition
    metadata = writer.transcript_metadata(full_transcript)
    updates: dict[str, str | int] = {
        "msg_count": metadata["msg_count"],
        "last_message_hash": str(metadata["last_message_hash"]),
        "transcript_hash": str(metadata["transcript_hash"]),
        "last_hermes_turn_id": current_turn_id,
    }
    if prior_omitted + omitted > 0:
        updates["omitted_msg_count"] = prior_omitted + omitted
    updated_prefix = writer.replace_frontmatter(prefix, updates)
    updated = updated_prefix.rstrip() + "\n\n" + writer.normalize_transcript(full_transcript)
    atomic_write(raw_path, updated)
    return updated, bool(entries or omitted)


def messages_from_raw(markdown: str) -> list[dict[str, str]]:
    frontmatter_lines, _body = writer.split_frontmatter(markdown)
    frontmatter = writer.frontmatter_map(frontmatter_lines)
    _prefix, transcript = writer.split_transcript(
        markdown,
        expected_hash=frontmatter.get("transcript_hash", ""),
        expected_count=int(frontmatter.get("msg_count", "0")),
    )
    messages: list[dict[str, str]] = []
    for entry in writer.parse_transcript_entries(transcript):
        lines = entry.rstrip().splitlines()
        if not lines:
            continue
        role = "user" if lines[0].startswith("### User ") else "assistant"
        text_lines = lines[2:] if len(lines) > 1 and not lines[1].strip() else lines[1:]
        text = "\n".join(text_lines)
        text = re.sub(r"(?m)^\\(### (?:User|Assistant) \d+)$", r"\1", text)
        messages.append({"role": role, "text": text})
    return messages


def write_readable(raw_path: Path, readable_path: Path, raw_markdown: str, record_date: str) -> None:
    frontmatter_lines, _body = writer.split_frontmatter(raw_markdown)
    frontmatter = writer.frontmatter_map(frontmatter_lines)
    messages = messages_from_raw(raw_markdown)
    raw_hash = "sha256:" + hashlib.sha256(raw_markdown.encode("utf-8")).hexdigest()
    raw_ref = str(raw_path.relative_to(Path(os.environ["SECOND_BRAIN_DIR"]).expanduser()))
    command = [
        sys.executable,
        str(WRITER_PATH),
        "readable",
        f"--date={record_date}",
        f"--title={frontmatter.get('title', 'Hermes session')}",
        "--source=Hermes Agent",
        f"--raw-session-id={frontmatter.get('session_id', '')}",
        f"--raw-ref={raw_ref}",
        f"--raw-hash={raw_hash}",
        "--record-kind=conversation",
        "--tag=hermes",
    ]
    result = subprocess.run(
        command,
        input=json.dumps(messages, ensure_ascii=False),
        text=True,
        capture_output=True,
        timeout=10,
        check=False,
    )
    if result.returncode != 0:
        raise TurnError(result.stderr.strip() or "AI log writer readable failed")
    atomic_write(readable_path, result.stdout)


def save_turn(args: argparse.Namespace) -> int:
    payload = load_payload(args)
    session_id = required_text(payload, "session_id")
    messages, omitted = filtered_turn(payload)
    if not messages and omitted == 0:
        return 0
    now = dt.datetime.now().astimezone()
    record_date = now.date().isoformat()
    raw_path, readable_path = output_paths(session_id, record_date)

    state_root = Path(os.environ.get("AI_SECOND_BRAIN_STATE_DIR", Path.home() / ".hermes" / "ai-second-brain-state"))
    state_root.mkdir(parents=True, exist_ok=True)
    lock_path = state_root / f"hermes-{safe_session_id(session_id)}.lock"
    with lock_path.open("a+", encoding="utf-8") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        if raw_path.exists():
            if raw_path.is_symlink():
                raise TurnError(f"output file is a symlink: {raw_path}")
            raw_markdown, changed = append_raw(raw_path, messages, payload, omitted)
        else:
            if not messages:
                return 0
            raw_markdown = create_raw(raw_path, messages, payload, record_date, omitted)
            changed = True
        if changed or not readable_path.exists():
            write_readable(raw_path, readable_path, raw_markdown, record_date)

    sys.stdout.buffer.write(os.fsencode(readable_path) + b"\n")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--turn-json")
    args = parser.parse_args()
    try:
        return save_turn(args)
    except (TurnError, json.JSONDecodeError, OSError, subprocess.SubprocessError) as exc:
        print(f"save-hermes-turn: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
