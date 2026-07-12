#!/usr/bin/env python3
"""Plan a non-destructive move of misclassified Automation derived views."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import re
import sys
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
WRITER_PATH = Path(os.environ.get("AI_LOG_WRITER", SCRIPT_DIR / "ai-log-writer.py"))
SF_DATALESS = 0x40000000
ENTRY_RE = re.compile(r"(?m)^### (?:User|Assistant) \d+\s*$")
SKIP_REASONS = (
    "dataless",
    "missing_raw",
    "invalid_frontmatter",
    "not_automation",
    "identity_mismatch",
    "hash_mismatch",
    "unstable_file",
)


def load_writer():
    spec = importlib.util.spec_from_file_location("automation_migration_writer", WRITER_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load AI log writer: {WRITER_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


writer = load_writer()


def is_dataless(path: Path) -> bool:
    try:
        flags = getattr(os.stat(path, follow_symlinks=False), "st_flags", 0)
    except OSError:
        return True
    return bool(flags & SF_DATALESS)


def read_stable_bytes(path: Path) -> tuple[bytes, os.stat_result]:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags)
    try:
        before = os.fstat(fd)
        if getattr(before, "st_flags", 0) & SF_DATALESS:
            raise OSError("dataless file")
        chunks = []
        while chunk := os.read(fd, 1024 * 1024):
            chunks.append(chunk)
        after = os.fstat(fd)
    finally:
        os.close(fd)
    identity_before = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
    identity_after = (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
    if identity_before != identity_after:
        raise OSError("file changed while being read")
    return b"".join(chunks), after


def sha256_bytes(data: bytes) -> str:
    return "sha256:" + hashlib.sha256(data).hexdigest()


def read_markdown_bytes(data: bytes) -> tuple[dict[str, str], str]:
    text = data.decode("utf-8", errors="replace")
    lines = text.splitlines()
    if not lines or lines[0] != "---":
        return {}, text
    frontmatter: dict[str, str] = {}
    body_start = 0
    closed = False
    for index, line in enumerate(lines[1:], start=1):
        if line == "---":
            body_start = index + 1
            closed = True
            break
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        key = key.strip()
        value = value.strip()
        if value.startswith('"') and value.endswith('"'):
            try:
                value = str(json.loads(value))
            except json.JSONDecodeError:
                value = value[1:-1]
        frontmatter[key] = value
    if not closed:
        return {}, text
    return frontmatter, "\n".join(lines[body_start:])


def first_user_text(body: str) -> str:
    marker = re.search(r"(?m)^### User 1\s*$", body)
    if not marker:
        return ""
    start = marker.end()
    remainder = body[start:].lstrip("\n")
    next_entry = ENTRY_RE.search(remainder)
    return (remainder[: next_entry.start()] if next_entry else remainder).strip()


def expected_raw_ref(root: Path, raw_path: Path) -> str:
    relative = raw_path.relative_to(root).as_posix()
    return f"[[{relative[:-3]}]]" if relative.endswith(".md") else f"[[{relative}]]"


def classify_candidate(root: Path, readable: Path) -> tuple[dict[str, object] | None, str | None]:
    relative = readable.relative_to(root / "AI-Logs" / "readable" / "codex")
    raw = root / "AI-Logs" / "raw" / "codex" / relative
    target = root / "AI-Logs" / "automation" / "codex" / relative

    if is_dataless(readable) or is_dataless(raw):
        return None, "dataless"
    if raw.is_symlink() or not raw.is_file():
        return None, "missing_raw"

    try:
        readable_bytes, readable_stat = read_stable_bytes(readable)
        raw_bytes, raw_stat = read_stable_bytes(raw)
    except OSError:
        return None, "unstable_file"

    readable_fm, _readable_body = read_markdown_bytes(readable_bytes)
    raw_fm, raw_body = read_markdown_bytes(raw_bytes)
    if not readable_fm or not raw_fm:
        return None, "invalid_frontmatter"

    classification = writer.classify_message_list(
        [{"role": "user", "text": first_user_text(raw_body)}]
    )
    if classification.get("record_kind") != "automation":
        return None, "not_automation"

    session_id = raw_fm.get("session_id", "")
    if (
        not session_id
        or readable_fm.get("raw_session_id") != session_id
        or readable_fm.get("raw_ref") != expected_raw_ref(root, raw)
    ):
        return None, "identity_mismatch"

    raw_hash = sha256_bytes(raw_bytes)
    if readable_fm.get("raw_hash") != raw_hash:
        return None, "hash_mismatch"

    return {
        "action": "migrate_automation_view",
        "session_id": session_id,
        "automation_id": classification.get("automation_id", ""),
        "classification_rule": classification.get("classification_rule", ""),
        "raw_path": str(raw),
        "raw_sha256": raw_hash,
        "raw_mtime_ns": raw_stat.st_mtime_ns,
        "raw_size": raw_stat.st_size,
        "source_path": str(readable),
        "source_sha256": sha256_bytes(readable_bytes),
        "source_mtime_ns": readable_stat.st_mtime_ns,
        "source_size": readable_stat.st_size,
        "target_path": str(target),
        "collision": target.exists(),
    }, None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=os.environ.get("SECOND_BRAIN_DIR", ""))
    args = parser.parse_args()
    if not args.root:
        print("SECOND_BRAIN_DIR is required or pass --root", file=sys.stderr)
        return 2

    root = Path(args.root).expanduser()
    readable_root = root / "AI-Logs" / "readable" / "codex"
    if root.is_symlink() or not root.is_dir():
        print(f"root must be an existing non-symlink directory: {root}", file=sys.stderr)
        return 2

    scanned = 0
    candidates = 0
    skipped = {reason: 0 for reason in SKIP_REASONS}
    if readable_root.is_dir() and not readable_root.is_symlink():
        for readable in sorted(readable_root.rglob("*.md")):
            if readable.is_symlink() or not readable.is_file():
                continue
            scanned += 1
            row, reason = classify_candidate(root, readable)
            if row is None:
                if reason in skipped:
                    skipped[reason] += 1
                continue
            print(json.dumps(row, ensure_ascii=False, sort_keys=True), flush=True)
            candidates += 1

    skip_text = " ".join(f"skipped.{key}={value}" for key, value in skipped.items())
    print(
        f"automation_migration_summary scanned={scanned} {skip_text} candidates={candidates}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
