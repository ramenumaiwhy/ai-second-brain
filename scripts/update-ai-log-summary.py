#!/usr/bin/env python3
"""Safely update Summary/Decisions/Next Actions in a saved AI log."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path


sys.dont_write_bytecode = True
os.umask(0o077)

SCRIPT_DIR = Path(__file__).resolve().parent
REDACTION_HELPER = Path(os.environ.get("REDACTION_HELPER", SCRIPT_DIR / "redact-secrets.py"))
SYNC_LOCK_ROOT = Path(os.environ.get("AI_SUMMARY_SYNC_LOCK_ROOT", Path.home() / ".claude"))
SYNC_LOCK_NAMES = ("codex-obsidian-sync.lock", "recall-obsidian-sync.lock")
SYNC_LOCK_STALE_SECONDS = 300
SECTION_ORDER = ("Summary", "Decisions", "Next Actions")
SECTION_KEYS = {
    "summary": "Summary",
    "decisions": "Decisions",
    "next_actions": "Next Actions",
    "nextActions": "Next Actions",
}
TOP_LEVEL_HEADING_RE = re.compile(r"(?m)^## .+[ \t]*\r?$")
MANAGED_HEADING_LINE_RE = re.compile(r"(?m)^(## (?:Summary|Decisions|Next Actions|Transcript))[ \t]*\r?$")
TRANSCRIPT_HEADING_RE = re.compile(r"(?m)^## Transcript[ \t]*\r?$")
TRANSCRIPT_ENTRY_RE = re.compile(r"^(### (User|Assistant) [0-9]+|### OpenClaw Event)$")


class SummaryRefreshError(Exception):
    """User-facing summary refresh failure."""


class SyncLock:
    """Directory lock compatible with the existing sync scripts."""

    def __init__(self, path: Path):
        self.path = path
        self.held = False

    def acquire(self) -> None:
        for attempt in range(2):
            try:
                self.path.mkdir()
                break
            except FileExistsError as exc:
                if attempt == 0 and self.reap_stale():
                    continue
                raise SummaryRefreshError(f"sync lock is busy: {self.path}") from exc
            except OSError as exc:
                raise SummaryRefreshError(f"cannot acquire sync lock: {self.path}") from exc
        else:
            raise SummaryRefreshError(f"sync lock is busy: {self.path}")
        self.held = True
        try:
            pid = str(os.getpid())
            lstart = process_lstart(pid) or "unknown"
            (self.path / "pid").write_text(f"{pid}:{lstart}\n", encoding="utf-8")
        except OSError as exc:
            self.release()
            raise SummaryRefreshError(f"cannot write sync lock pid: {self.path}") from exc

    def release(self) -> None:
        if not self.held:
            return
        pid_file = self.path / "pid"
        try:
            if pid_file.exists() and not pid_file.read_text(encoding="utf-8", errors="replace").startswith(
                f"{os.getpid()}:"
            ):
                return
            try:
                pid_file.unlink()
            except FileNotFoundError:
                pass
            self.path.rmdir()
        except OSError:
            pass
        finally:
            self.held = False

    def reap_stale(self) -> bool:
        if self.path.is_symlink() or not self.path.is_dir():
            return False
        try:
            age = int(time.time() - self.path.stat().st_mtime)
        except OSError:
            return False
        if age <= SYNC_LOCK_STALE_SECONDS or self.owner_is_live():
            return False
        try:
            shutil.rmtree(self.path)
            return True
        except OSError:
            return False

    def owner_is_live(self) -> bool:
        pid_file = self.path / "pid"
        try:
            info = pid_file.read_text(encoding="utf-8", errors="replace").strip()
        except OSError:
            return False
        pid_text, _, expected_lstart = info.partition(":")
        if not pid_text.isdigit():
            return False
        pid = int(pid_text)
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
        if not expected_lstart or expected_lstart == "unknown":
            return True
        return process_lstart(pid_text) == expected_lstart


def load_redactor():
    spec = importlib.util.spec_from_file_location("summary_refresh_redact_secrets", REDACTION_HELPER)
    if spec is None or spec.loader is None:
        raise SummaryRefreshError(f"cannot load redaction helper: {REDACTION_HELPER}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    redact = getattr(module, "redact_text", None)
    if not callable(redact):
        raise SummaryRefreshError(f"redaction helper has no redact_text: {REDACTION_HELPER}")
    return redact


redact_text = load_redactor()


def yaml_quote(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def sha256_text(value: str) -> str:
    return "sha256:" + hashlib.sha256(value.encode("utf-8")).hexdigest()


def normalize_text(value: str) -> str:
    value = value.replace("\r\n", "\n").replace("\r", "\n").rstrip()
    return value + "\n" if value else ""


def timestamp_now() -> str:
    fixed = os.environ.get("AI_SUMMARY_REFRESHED_AT", "")
    if fixed:
        return fixed
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def process_lstart(pid: str) -> str:
    try:
        result = subprocess.run(
            ["ps", "-p", pid, "-o", "lstart="],
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError:
        return ""
    if result.returncode != 0:
        return ""
    return result.stdout.strip()


def read_text(path: Path) -> str:
    return read_bytes(path).decode("utf-8", errors="replace")


def read_bytes(path: Path) -> bytes:
    try:
        return path.read_bytes()
    except OSError as exc:
        raise SummaryRefreshError(f"cannot read markdown: {path}") from exc


def ensure_unchanged(path: Path, expected: bytes) -> None:
    if read_bytes(path) != expected:
        raise SummaryRefreshError("markdown changed while refreshing summary; retry")


def checked_markdown_path(path_text: str) -> Path:
    path = Path(path_text).expanduser()
    if path.is_symlink() or not path.is_file():
        raise SummaryRefreshError(f"markdown path must be an existing non-symlink file: {path}")
    return path


def split_frontmatter(markdown: str) -> tuple[list[str], str]:
    lines = markdown.splitlines(keepends=True)
    if not lines or lines[0].strip() != "---":
        raise SummaryRefreshError("missing frontmatter")
    for idx in range(1, len(lines)):
        if lines[idx].strip() == "---":
            return lines[1:idx], "".join(lines[idx + 1 :])
    raise SummaryRefreshError("unterminated frontmatter")


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


def replace_frontmatter(markdown: str, updates: dict[str, str]) -> str:
    lines, body = split_frontmatter(markdown)
    updated: list[str] = []
    seen: set[str] = set()
    for line in lines:
        key = line.split(":", 1)[0].strip() if ":" in line else ""
        if key in updates:
            updated.append(f"{key}: {yaml_quote(updates[key])}\n")
            seen.add(key)
        else:
            updated.append(line)
    for key, value in updates.items():
        if key not in seen:
            updated.append(f"{key}: {yaml_quote(value)}\n")
    return "---\n" + "".join(updated) + "---\n" + body


def transcript_after_heading(body: str, match: re.Match[str]) -> str:
    transcript = body[match.end() :]
    if transcript.startswith("\r\n"):
        transcript = transcript[2:]
    elif transcript.startswith("\n"):
        transcript = transcript[1:]
    if transcript.startswith("\r\n"):
        return transcript[2:]
    if transcript.startswith("\n"):
        return transcript[1:]
    return transcript


def starts_with_transcript_entry(transcript: str) -> bool:
    for line in transcript.splitlines():
        if not line.strip():
            continue
        return bool(TRANSCRIPT_ENTRY_RE.match(line.strip()))
    return False


def split_transcript(body: str, *, expected_hash: str = "") -> tuple[str, str]:
    matches = list(TRANSCRIPT_HEADING_RE.finditer(body))
    if not matches:
        raise SummaryRefreshError("missing Transcript section")
    if expected_hash:
        for match in matches:
            transcript = transcript_after_heading(body, match)
            if sha256_text(normalize_text(transcript)) == expected_hash:
                return body[: match.start()], body[match.start() :]
        raise SummaryRefreshError("Transcript section does not match frontmatter metadata")
    for match in matches:
        transcript = transcript_after_heading(body, match)
        if starts_with_transcript_entry(transcript):
            return body[: match.start()], body[match.start() :]
    return body[: matches[0].start()], body[matches[0].start() :]



def top_level_heading_name(match: re.Match[str]) -> str:
    return match.group(0).strip().removeprefix("## ").strip()


def select_canonical_sections(headings: list[re.Match[str]]) -> dict[str, int]:
    selected: dict[str, int] = {}
    cursor = len(headings)
    for section in reversed(SECTION_ORDER):
        for index in range(cursor - 1, -1, -1):
            if top_level_heading_name(headings[index]) == section:
                selected[section] = index
                cursor = index
                break
    return selected


def parse_sections(pre_transcript: str) -> tuple[str, dict[str, str], str]:
    headings = list(TOP_LEVEL_HEADING_RE.finditer(pre_transcript))
    selected = select_canonical_sections(headings)
    if not headings:
        return pre_transcript, {}, ""
    if not selected:
        return pre_transcript[: headings[0].start()], {}, pre_transcript[headings[0].start() :].strip()

    canonical_by_index = {index: section for section, index in selected.items()}
    canonical_indexes = sorted(canonical_by_index)
    first_managed_index = canonical_indexes[0]
    lead = pre_transcript[: headings[first_managed_index].start()]
    sections: dict[str, str] = {}
    extras: list[str] = []
    for position, index in enumerate(canonical_indexes):
        match = headings[index]
        section = canonical_by_index[index]
        section_start = match.end()
        section_end = (
            headings[canonical_indexes[position + 1]].start()
            if position + 1 < len(canonical_indexes)
            else len(pre_transcript)
        )
        content_parts: list[str] = []
        content_cursor = section_start
        inner_indexes = [
            inner_index
            for inner_index in range(index + 1, len(headings))
            if headings[inner_index].start() < section_end
        ]
        for inner_position, inner_index in enumerate(inner_indexes):
            inner = headings[inner_index]
            inner_name = top_level_heading_name(inner)
            inner_end = (
                headings[inner_indexes[inner_position + 1]].start()
                if inner_position + 1 < len(inner_indexes)
                else section_end
            )
            if inner_name in SECTION_ORDER:
                continue
            content_parts.append(pre_transcript[content_cursor : inner.start()])
            extras.append(escape_managed_headings(pre_transcript[inner.start() : inner_end]).strip())
            content_cursor = inner_end
        content_parts.append(pre_transcript[content_cursor:section_end])
        sections[section] = escape_managed_headings("".join(content_parts)).strip()
    return lead, sections, "\n\n".join(extra for extra in extras if extra)


def escape_managed_headings(value: str) -> str:
    return MANAGED_HEADING_LINE_RE.sub(r"\\\1", value)


def format_value(value: object) -> str:
    if value is None:
        return ""
    if isinstance(value, list):
        items: list[str] = []
        for item in value:
            text = escape_managed_headings(redact_text(str(item))).strip()
            if text:
                items.append("- " + text.replace("\n", "\n  "))
        return "\n".join(items)
    if isinstance(value, str):
        return escape_managed_headings(redact_text(value)).strip()
    return escape_managed_headings(redact_text(str(value))).strip()


def load_updates(path_text: str) -> dict[str, str]:
    try:
        if path_text == "-":
            raw = sys.stdin.buffer.read()
        else:
            raw = Path(path_text).expanduser().read_bytes()
        data = json.loads(raw.decode("utf-8", errors="replace"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SummaryRefreshError("cannot read summary JSON") from exc
    if not isinstance(data, dict):
        raise SummaryRefreshError("summary JSON must be an object")

    updates: dict[str, str] = {}
    for key, section in SECTION_KEYS.items():
        if key in data:
            updates[section] = format_value(data[key])
    if not updates:
        raise SummaryRefreshError("summary JSON must include summary, decisions, or next_actions")
    return updates


def refresh_body(body: str, updates: dict[str, str], *, expected_hash: str = "") -> str:
    pre_transcript, transcript = split_transcript(body, expected_hash=expected_hash)
    lead, existing, extras = parse_sections(pre_transcript)
    refreshed = dict(existing)
    refreshed.update(updates)

    blocks = []
    for section in SECTION_ORDER:
        content = refreshed.get(section, "").strip()
        blocks.append(f"## {section}\n\n{content}\n")
    parts = [lead.rstrip(), "\n".join(blocks).rstrip()]
    if extras:
        parts.append(extras)
    return "\n\n".join(part for part in parts if part) + "\n\n" + transcript


def refresh_markdown(markdown: str, updates: dict[str, str]) -> str:
    frontmatter_lines, body = split_frontmatter(markdown)
    frontmatter_values = frontmatter_map(frontmatter_lines)
    frontmatter = "---\n" + "".join(frontmatter_lines) + "---\n"
    refreshed_body = refresh_body(body, updates, expected_hash=frontmatter_values.get("transcript_hash", ""))
    refreshed = frontmatter + refreshed_body
    return replace_frontmatter(refreshed, {"summary_refreshed_at": timestamp_now()})


def atomic_write(path: Path, content: str) -> None:
    directory = path.parent
    mode = path.stat().st_mode & 0o777
    fd, tmp_path = tempfile.mkstemp(dir=directory, prefix=f".{path.name}.", text=False)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(content.encode("utf-8"))
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp_path, mode)
        os.replace(tmp_path, path)
        dir_fd = os.open(directory, os.O_RDONLY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def acquire_sync_locks() -> list[SyncLock]:
    try:
        SYNC_LOCK_ROOT.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise SummaryRefreshError(f"cannot create sync lock root: {SYNC_LOCK_ROOT}") from exc

    locks: list[SyncLock] = []
    try:
        for name in SYNC_LOCK_NAMES:
            lock = SyncLock(SYNC_LOCK_ROOT / name)
            lock.acquire()
            locks.append(lock)
    except Exception:
        release_sync_locks(locks)
        raise
    return locks


def release_sync_locks(locks: list[SyncLock]) -> None:
    for lock in reversed(locks):
        lock.release()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("markdown", help="AI log Markdown file to update")
    parser.add_argument(
        "--input-json",
        default="-",
        help="JSON file with summary, decisions, and/or next_actions. Use '-' for stdin.",
    )
    parser.add_argument("--dry-run", action="store_true", help="write updated Markdown to stdout")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    locks: list[SyncLock] = []
    try:
        path = checked_markdown_path(args.markdown)
        updates = load_updates(args.input_json)
        if not args.dry_run:
            locks = acquire_sync_locks()
            path = checked_markdown_path(str(path))
        original_bytes = read_bytes(path)
        original = original_bytes.decode("utf-8", errors="replace")
        refreshed = refresh_markdown(original, updates)
        if args.dry_run:
            sys.stdout.buffer.write(refreshed.encode("utf-8"))
            return 0
        ensure_unchanged(path, original_bytes)
        atomic_write(path, refreshed)
        sys.stdout.buffer.write(os.fsencode(path) + b"\n")
        return 0
    except SummaryRefreshError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    finally:
        release_sync_locks(locks)


if __name__ == "__main__":
    raise SystemExit(main())
