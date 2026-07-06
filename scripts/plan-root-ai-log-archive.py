#!/usr/bin/env python3
"""Plan a non-destructive archive move for legacy root AI log Markdown files."""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import sys
from pathlib import Path


DATE_PREFIX_RE = re.compile(r"^(?P<date>\d{4}-\d{2}-\d{2})_")
SOURCE_KEYS = ("claude", "codex", "chatgpt", "telegram", "openclaw")
TRANSCRIPT_MARKER_RE = re.compile(
    r"(?m)^(?:## Transcript|### (?:User|Assistant) \d+|## [QA]\d+)\s*$"
)
SF_DATALESS = 0x40000000
SKIP_REASONS = (
    "no_date_prefix",
    "icloud_dataless",
    "no_session_id",
    "no_transcript_marker",
    "no_ai_log_marker",
)


def yaml_unquote(value: str) -> str:
    value = value.strip()
    if value.startswith('"') and value.endswith('"'):
        try:
            parsed = json.loads(value)
        except json.JSONDecodeError:
            return value[1:-1]
        return parsed if isinstance(parsed, str) else str(parsed)
    if value.startswith("'") and value.endswith("'"):
        return value[1:-1]
    return value


def read_markdown(path: Path) -> tuple[dict[str, str], str, str]:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return {}, "", ""
    lines = text.splitlines()
    if not lines or lines[0] != "---":
        return {}, "", text
    result: dict[str, str] = {}
    frontmatter_lines: list[str] = []
    body_start = 0
    for index, line in enumerate(lines[1:], start=1):
        if line == "---":
            body_start = index + 1
            break
        frontmatter_lines.append(line)
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        key = key.strip()
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", key):
            result[key] = yaml_unquote(value)
    body = "\n".join(lines[body_start:]) if body_start else text
    return result, "\n".join(frontmatter_lines), body


def read_frontmatter(path: Path) -> dict[str, str]:
    frontmatter, _frontmatter_text, _body = read_markdown(path)
    return frontmatter


def source_key(path: Path, frontmatter: dict[str, str]) -> str:
    haystack = " ".join(
        [
            frontmatter.get("source", ""),
            frontmatter.get("record_kind", ""),
            path.name,
        ]
    ).lower()
    if "claude" in haystack:
        return "claude"
    if "codex" in haystack:
        return "codex"
    if "chatgpt" in haystack or "chat-gpt" in haystack:
        return "chatgpt"
    if "telegram" in haystack:
        return "telegram"
    if "openclaw" in haystack:
        return "openclaw"
    return "unknown"


def has_ai_log_marker(frontmatter: dict[str, str], frontmatter_text: str) -> bool:
    if "ai-log" in frontmatter_text:
        return True
    if frontmatter.get("source"):
        return True
    if frontmatter.get("record_kind"):
        return True
    return False


def planned_target(root: Path, source: str, month: str, filename: str) -> Path:
    return root / "AI-Logs" / "raw-archive" / source / month / filename


def is_icloud_dataless(path: Path) -> bool:
    try:
        flags = getattr(os.stat(path, follow_symlinks=False), "st_flags", 0)
    except OSError:
        return False
    return bool(flags & SF_DATALESS)


def iter_root_markdown(root: Path):
    try:
        paths = sorted(root.iterdir())
    except OSError:
        return
    for path in paths:
        try:
            if path.is_symlink() or not path.is_file() or path.suffix != ".md":
                continue
        except OSError:
            continue
        yield path


def classify_candidate(root: Path, path: Path) -> tuple[dict[str, object] | None, str | None]:
    match = DATE_PREFIX_RE.match(path.name)
    if not match:
        return None, "no_date_prefix"
    if is_icloud_dataless(path):
        return None, "icloud_dataless"

    date = match.group("date")
    frontmatter, frontmatter_text, body = read_markdown(path)
    if not frontmatter.get("session_id"):
        return None, "no_session_id"
    if not TRANSCRIPT_MARKER_RE.search(body):
        return None, "no_transcript_marker"
    if not has_ai_log_marker(frontmatter, frontmatter_text):
        return None, "no_ai_log_marker"

    month = date.rsplit("-", 1)[0]
    source = source_key(path, frontmatter)
    target = planned_target(root, source, month, path.name)
    return {
        "action": "archive_candidate",
        "source": source,
        "date": date,
        "month": month,
        "path": str(path),
        "target": str(target),
        "collision": target.exists(),
        "session_id": frontmatter.get("session_id", ""),
        "title": frontmatter.get("title", path.stem),
    }, None


def print_progress(scanned: int, candidates: int) -> None:
    print(f"progress scanned={scanned} candidates={candidates}", file=sys.stderr, flush=True)


def print_summary(scanned: int, candidates: int, skipped: dict[str, int]) -> None:
    print(f"planned_archive_candidates={candidates}", file=sys.stderr)
    skip_parts = " ".join(f"skipped.{reason}={skipped[reason]}" for reason in SKIP_REASONS)
    print(
        f"archive_scan_summary scanned={scanned} {skip_parts} candidates={candidates}",
        file=sys.stderr,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=os.environ.get("SECOND_BRAIN_DIR", ""))
    parser.add_argument("--format", choices=("jsonl", "tsv"), default="jsonl")
    parser.add_argument(
        "--progress-every",
        type=int,
        default=500,
        help="print progress to stderr every N scanned root markdown files; 0 disables progress",
    )
    args = parser.parse_args()

    if not args.root:
        print("SECOND_BRAIN_DIR is required or pass --root", file=sys.stderr)
        return 2
    root = Path(args.root).expanduser()
    if root.is_symlink() or not root.is_dir():
        print(f"root must be an existing non-symlink directory: {root}", file=sys.stderr)
        return 2

    scanned = 0
    candidates = 0
    skipped = {reason: 0 for reason in SKIP_REASONS}

    if args.format == "tsv":
        writer = csv.writer(sys.stdout, delimiter="\t", lineterminator="\n")
        writer.writerow(["action", "source", "date", "path", "target", "collision", "session_id", "title"])
        sys.stdout.flush()
    else:
        writer = None

    for path in iter_root_markdown(root):
        scanned += 1
        row, skip_reason = classify_candidate(root, path)
        if row is None:
            if skip_reason in skipped:
                skipped[skip_reason] += 1
        elif args.format == "tsv":
            assert writer is not None
            writer.writerow(
                [
                    row["action"],
                    row["source"],
                    row["date"],
                    row["path"],
                    row["target"],
                    row["collision"],
                    row["session_id"],
                    row["title"],
                ]
            )
            candidates += 1
            sys.stdout.flush()
        else:
            print(json.dumps(row, ensure_ascii=False, sort_keys=True), flush=True)
            candidates += 1
        if args.progress_every > 0 and scanned % args.progress_every == 0:
            print_progress(scanned, candidates)

    print_summary(scanned, candidates, skipped)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
