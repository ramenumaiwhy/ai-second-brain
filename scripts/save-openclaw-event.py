#!/usr/bin/env python3
"""Save one OpenClaw/Himeno event as a redacted Second Brain source page."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import re
import sys
import tempfile
from pathlib import Path
from typing import Any


sys.dont_write_bytecode = True
os.umask(0o077)

SCRIPT_DIR = Path(__file__).resolve().parent
REDACTION_HELPER = Path(os.environ.get("REDACTION_HELPER", SCRIPT_DIR / "redact-secrets.py"))
DEFAULT_SOURCE = "OpenClaw/Himeno"
ALLOWED_RECORD_KINDS = {
    "task_result",
    "user_decision",
    "failure_recovery",
    "ops_lesson",
    "daily_summary",
}
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


class EventError(ValueError):
    pass


def _load_redactor():
    spec = importlib.util.spec_from_file_location("redact_secrets_runtime", REDACTION_HELPER)
    if spec is None or spec.loader is None:
        raise EventError(f"cannot load redaction helper: {REDACTION_HELPER}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.redact_text


redact_text = _load_redactor()


def yaml_quote(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def print_path(path: Path) -> None:
    sys.stdout.buffer.write(os.fsencode(path) + b"\n")


def sha256_text(value: str) -> str:
    return "sha256:" + hashlib.sha256(value.encode("utf-8")).hexdigest()


def normalize_text(value: str) -> str:
    value = value.replace("\r\n", "\n").replace("\r", "\n").rstrip()
    return value + "\n" if value else ""


def redacted_value(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        text = value
    else:
        text = json.dumps(value, ensure_ascii=False, sort_keys=True)
    return redact_text(text).strip()


def list_block(value: Any) -> str:
    if value is None or value == "":
        return ""
    if isinstance(value, list):
        lines = []
        for item in value:
            text = redacted_value(item)
            if text:
                lines.append(f"- {text}")
        return "\n".join(lines)
    return redacted_value(value)


def required_text(event: dict[str, Any], field: str) -> str:
    value = redacted_value(event.get(field))
    if not value:
        raise EventError(f"missing required field: {field}")
    return value


def event_date(event: dict[str, Any], *fields: str) -> str:
    for field in ("date", *fields, "timestamp"):
        value = redacted_value(event.get(field))
        if not value:
            continue
        candidate = value[:10]
        if DATE_RE.match(candidate):
            return candidate
    raise EventError("missing required date or timestamp")


def content_basis(event: dict[str, Any]) -> str:
    parts = [
        redacted_value(event.get("summary")),
        list_block(event.get("decisions")),
        list_block(event.get("next_actions")),
        redacted_value(event.get("content")),
    ]
    return normalize_text("\n".join(part for part in parts if part))


def content_hash(event: dict[str, Any]) -> str:
    basis = content_basis(event)
    if not basis:
        raise EventError("missing event content for content hash")
    return sha256_text(basis)


def dedupe_key(event: dict[str, Any], kind: str, source_name: str) -> str:
    if kind == "task_result":
        task_id = required_text(event, "task_id")
        completed_at = redacted_value(event.get("completed_at")) or required_text(event, "timestamp")
        return f"task_result:{task_id}:{completed_at}"
    if kind == "user_decision":
        decision_id = redacted_value(event.get("decision_id"))
        if decision_id:
            return f"user_decision:decision:{decision_id}"
        source_message_id = required_text(event, "source_message_id")
        return f"user_decision:hash:{source_message_id}:{content_hash(event)}"
    if kind == "failure_recovery":
        recovered_at = redacted_value(event.get("recovered_at")) or required_text(event, "timestamp")
        incident_id = redacted_value(event.get("incident_id"))
        if incident_id:
            return f"failure_recovery:incident:{incident_id}:{recovered_at}"
        return f"failure_recovery:hash:{recovered_at}:{content_hash(event)}"
    if kind == "ops_lesson":
        source_artifact_path = required_text(event, "source_artifact_path")
        return f"ops_lesson:{source_artifact_path}:{content_hash(event)}"
    if kind == "daily_summary":
        summary_date = event_date(event)
        return f"daily_summary:{summary_date}:{source_name}"
    raise EventError(f"unsupported record_kind: {kind}")


def title_for_event(event: dict[str, Any], kind: str) -> str:
    title = redacted_value(event.get("title"))
    if title:
        return title.replace("\n", " ")[:120]
    summary = redacted_value(event.get("summary")) or redacted_value(event.get("content"))
    first_line = summary.splitlines()[0].strip() if summary else ""
    if first_line:
        return first_line[:120]
    return kind.replace("_", " ").title()


def source_metadata(event: dict[str, Any], kind: str, dedupe_hash: str) -> str:
    fields_by_kind = {
        "task_result": ("task_id", "completed_at", "timestamp"),
        "user_decision": ("decision_id", "source_message_id", "timestamp"),
        "failure_recovery": ("incident_id", "recovered_at", "timestamp"),
        "ops_lesson": ("source_artifact_path", "timestamp"),
        "daily_summary": ("date", "timestamp"),
    }
    lines = [
        f"- record_kind: {kind}",
        f"- dedupe_key_hash: {dedupe_hash}",
    ]
    for field in fields_by_kind[kind]:
        value = redacted_value(event.get(field))
        if value:
            lines.append(f"- {field}: {value}")
    return "\n".join(lines)


def source_content(event: dict[str, Any]) -> str:
    content = redacted_value(event.get("content"))
    if content:
        return content
    parts = [
        redacted_value(event.get("summary")),
        list_block(event.get("decisions")),
        list_block(event.get("next_actions")),
    ]
    return "\n\n".join(part for part in parts if part).strip()


def render_markdown(event: dict[str, Any], kind: str, record_date: str, source_name: str) -> tuple[str, str]:
    dedupe = dedupe_key(event, kind, source_name)
    dedupe_hash = sha256_text(dedupe)
    digest = dedupe_hash.removeprefix("sha256:")[:16]
    title = title_for_event(event, kind)
    summary = redacted_value(event.get("summary")) or source_content(event)
    decisions = list_block(event.get("decisions"))
    if kind == "user_decision" and not decisions:
        decisions = summary
    next_actions = list_block(event.get("next_actions"))
    source = source_content(event)

    transcript = normalize_text(
        "\n".join(
            [
                "### OpenClaw Event",
                "",
                "#### Metadata",
                "",
                source_metadata(event, kind, dedupe_hash),
                "",
                "#### Source",
                "",
                source,
            ]
        )
    )
    metadata_hash = sha256_text(transcript)
    session_id = f"openclaw:{kind}:{digest}"
    tag_kind = kind.replace("_", "-")

    markdown = "".join(
        [
            "---\n",
            f"date: {record_date}\n",
            f"title: {yaml_quote(title)}\n",
            f"source: {yaml_quote(source_name)}\n",
            f"session_id: {yaml_quote(session_id)}\n",
            f"record_kind: {yaml_quote(kind)}\n",
            "msg_count: 1\n",
            f"last_message_hash: {yaml_quote(metadata_hash)}\n",
            f"transcript_hash: {yaml_quote(metadata_hash)}\n",
            f"dedupe_key_hash: {yaml_quote(dedupe_hash)}\n",
            "tags:\n",
            '  - "ai-log"\n',
            '  - "openclaw"\n',
            '  - "himeno"\n',
            f"  - {yaml_quote(tag_kind)}\n",
            "---\n",
            "\n",
            f"# {title}\n",
            "\n",
            "## Summary\n",
            "\n",
            normalize_text(summary),
            "\n",
            "## Decisions\n",
            "\n",
            normalize_text(decisions),
            "\n",
            "## Next Actions\n",
            "\n",
            normalize_text(next_actions),
            "\n",
            "## Transcript\n",
            "\n",
            transcript,
        ]
    )
    return markdown, dedupe_hash


def ensure_output_dir(second_brain_dir: str) -> Path:
    if not second_brain_dir:
        raise EventError("SECOND_BRAIN_DIR is not set")
    root = Path(second_brain_dir).expanduser()
    if root.is_symlink() or not root.is_dir():
        raise EventError("SECOND_BRAIN_DIR must be an existing non-symlink directory")
    openclaw_dir = root / "OpenClaw"
    output_dir = openclaw_dir / "sources"
    for path in (openclaw_dir, output_dir):
        if path.exists() and path.is_symlink():
            raise EventError(f"output path is a symlink: {path}")
        path.mkdir(exist_ok=True)
    return output_dir


def path_has_dedupe_hash(path: Path, dedupe_hash: str) -> bool:
    needle = f"dedupe_key_hash: {yaml_quote(dedupe_hash)}"
    return needle in path.read_text(encoding="utf-8", errors="replace")


def checked_event_path(path: Path) -> None:
    if path.is_symlink():
        raise EventError(f"event path is a symlink: {path}")


def find_existing(output_dir: Path, dedupe_hash: str) -> Path | None:
    digest = dedupe_hash.removeprefix("sha256:")[:16]
    for path in sorted(output_dir.glob(f"*_{digest}.md")):
        checked_event_path(path)
        try:
            if path_has_dedupe_hash(path, dedupe_hash):
                return path
        except OSError:
            continue
    for path in sorted(output_dir.glob("*.md")):
        checked_event_path(path)
        try:
            if path_has_dedupe_hash(path, dedupe_hash):
                return path
        except OSError:
            continue
    return None


def ensure_new_target(target: Path, dedupe_hash: str) -> None:
    if not target.exists():
        return
    checked_event_path(target)
    try:
        if path_has_dedupe_hash(target, dedupe_hash):
            return
    except OSError:
        pass
    raise EventError(f"target event path already exists with another dedupe hash: {target}")


def atomic_write(path: Path, text: str) -> None:
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    tmp_path = Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp_path, path)
        dir_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    except Exception:
        try:
            tmp_path.unlink()
        except FileNotFoundError:
            pass
        raise


def load_event(args: argparse.Namespace) -> dict[str, Any]:
    if args.event_json:
        raw = Path(args.event_json).read_text(encoding="utf-8", errors="replace")
    else:
        raw = sys.stdin.buffer.read().decode("utf-8", errors="replace")
    if not raw.strip():
        raise EventError("event JSON is empty")
    data = json.loads(raw)
    if not isinstance(data, dict):
        raise EventError("event JSON must be an object")
    return data


def save_event(args: argparse.Namespace) -> int:
    event = load_event(args)
    kind = redacted_value(event.get("record_kind") or event.get("kind"))
    if kind not in ALLOWED_RECORD_KINDS:
        allowed = ", ".join(sorted(ALLOWED_RECORD_KINDS))
        raise EventError(f"unsupported record_kind: {kind or '(empty)'}; allowed: {allowed}")
    if not content_basis(event):
        raise EventError("missing event content")

    source_name = redacted_value(event.get("source")) or DEFAULT_SOURCE
    date_fields = {
        "task_result": ("completed_at",),
        "failure_recovery": ("recovered_at",),
    }.get(kind, ())
    record_date = event_date(event, *date_fields)
    markdown, dedupe_hash = render_markdown(event, kind, record_date, source_name)
    output_dir = ensure_output_dir(os.environ.get("SECOND_BRAIN_DIR", ""))
    existing = find_existing(output_dir, dedupe_hash)
    if existing is not None:
        print_path(existing)
        return 0

    digest = dedupe_hash.removeprefix("sha256:")[:16]
    target = output_dir / f"{record_date}_{kind}_{digest}.md"
    ensure_new_target(target, dedupe_hash)
    if target.exists():
        print_path(target)
        return 0
    atomic_write(target, markdown)
    print_path(target)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--event-json", help="Read event JSON from this file instead of stdin")
    args = parser.parse_args()
    try:
        return save_event(args)
    except (EventError, json.JSONDecodeError, OSError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
