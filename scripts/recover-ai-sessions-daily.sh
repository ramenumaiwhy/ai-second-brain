#!/bin/bash
# Bounded daily recovery for recently modified AI sessions.

set -euo pipefail

umask 077

resolve_script_dir() {
    local source="${BASH_SOURCE[0]}"
    local dir
    while [ -L "$source" ]; do
        dir="$(cd -P "$(dirname "$source")" && pwd)"
        source="$(readlink "$source")"
        case "$source" in
            /*) ;;
            *) source="$dir/$source" ;;
        esac
    done
    cd -P "$(dirname "$source")" && pwd
}

SCRIPT_DIR="$(resolve_script_dir)"

STATE_DIR="${AI_SECOND_BRAIN_STATE_DIR:-$HOME/.claude/ai-second-brain-state}"
STATE_FILE="$STATE_DIR/daily-recovery.json"
RECOVERY_LOG="${AI_DAILY_RECOVERY_LOG:-$HOME/.claude/ai-second-brain-daily-recovery.log}"
LOCK_DIR="$STATE_DIR/daily-recovery.lock"
LOOKBACK_DAYS="${AI_RECOVERY_LOOKBACK_DAYS:-3}"
MAX_SESSIONS="${AI_RECOVERY_MAX_SESSIONS:-50}"
CODEX_SESSIONS_DIR="${CODEX_SESSIONS_DIR:-$HOME/.codex/sessions}"
CLAUDE_PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
SECOND_BRAIN_DIR="${SECOND_BRAIN_DIR:-}"
REDACTION_HELPER="${REDACTION_HELPER:-$SCRIPT_DIR/redact-secrets.py}"
if [ ! -f "$REDACTION_HELPER" ] && [ -f "$PWD/scripts/redact-secrets.py" ]; then
    REDACTION_HELPER="$PWD/scripts/redact-secrets.py"
fi
SYNC_RECALL_SCRIPT="${SYNC_RECALL_SCRIPT:-$SCRIPT_DIR/sync-recall-to-obsidian.sh}"
SYNC_CODEX_SCRIPT="${SYNC_CODEX_SCRIPT:-$SCRIPT_DIR/sync-codex-to-obsidian.sh}"

if [[ ! "$LOOKBACK_DAYS" =~ ^[0-9]+$ ]] || [[ ! "$MAX_SESSIONS" =~ ^[0-9]+$ ]] || [ "$MAX_SESSIONS" -eq 0 ]; then
    printf 'AI_RECOVERY_LOOKBACK_DAYS must be a non-negative integer and AI_RECOVERY_MAX_SESSIONS must be a positive integer\n' >&2
    exit 2
fi

mkdir -p "$STATE_DIR" "$(dirname "$RECOVERY_LOG")"

TEMP_FILES=()

log_line() {
    printf '%s: %s\n' "$(date)" "$*" >> "$RECOVERY_LOG"
}

remember_temp() {
    TEMP_FILES+=("$1")
}

write_pid_file() {
    local my_lstart
    my_lstart=$(ps -p "$$" -o lstart= 2>/dev/null || true)
    if [ -z "$my_lstart" ]; then
        my_lstart="unknown"
    fi
    printf '%s:%s\n' "$$" "$my_lstart" > "$LOCK_DIR/pid"
}

lock_info() {
    if [ -f "$LOCK_DIR/pid" ]; then
        head -n 1 "$LOCK_DIR/pid" 2>/dev/null || true
    fi
}

lock_pid() {
    local info
    info=$(lock_info)
    printf '%s' "${info%%:*}"
}

lock_lstart() {
    local info
    info=$(lock_info)
    if [[ "$info" == *:* ]]; then
        printf '%s' "${info#*:}"
    fi
}

pid_matches_lstart() {
    local pid="$1" expected_lstart="$2" current_lstart
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    [ -n "$expected_lstart" ] && [ "$expected_lstart" != "unknown" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    current_lstart=$(ps -p "$pid" -o lstart= 2>/dev/null || true)
    [ -n "$current_lstart" ] && [ "$current_lstart" = "$expected_lstart" ]
}

release_lock() {
    if [ "$(lock_pid)" = "$$" ]; then
        rm -rf "$LOCK_DIR" 2>/dev/null || true
    fi
}

cleanup() {
    local temp_file
    for temp_file in "${TEMP_FILES[@]:-}"; do
        rm -f "$temp_file" 2>/dev/null || true
    done
    release_lock
}
trap cleanup EXIT

acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        write_pid_file
        return 0
    fi

    if [ ! -d "$LOCK_DIR" ]; then
        return 1
    fi

    local lock_age
    lock_age=$(python3 - "$LOCK_DIR" <<'PY'
import os
import sys
import time

try:
    print(int(time.time() - os.path.getmtime(sys.argv[1])))
except OSError:
    print(0)
PY
)
    if [ "$lock_age" -le 300 ]; then
        return 1
    fi

    local pid
    pid=$(lock_pid)
    if pid_matches_lstart "$pid" "$(lock_lstart)"; then
        return 1
    fi

    if rm -rf "$LOCK_DIR" 2>/dev/null && mkdir "$LOCK_DIR" 2>/dev/null; then
        write_pid_file
        return 0
    fi
    return 1
}

discover_candidates() {
    local recall_list_file="$1"
    python3 - "$LOOKBACK_DAYS" "$MAX_SESSIONS" "$CODEX_SESSIONS_DIR" "$CLAUDE_PROJECTS_DIR" "$recall_list_file" "$STATE_FILE" "$SECOND_BRAIN_DIR" "$REDACTION_HELPER" <<'PY'
from __future__ import annotations

import datetime as dt
import fnmatch
import hashlib
import importlib.util
import json
import os
import re
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True

lookback_days = int(sys.argv[1])
max_sessions = int(sys.argv[2])
codex_sessions_dir = Path(sys.argv[3]).expanduser()
claude_projects_dir = Path(sys.argv[4]).expanduser()
recall_list_file = sys.argv[5]
state_file = sys.argv[6]
second_brain_dir = Path(sys.argv[7]).expanduser() if sys.argv[7] else None
redaction_helper = Path(sys.argv[8]).expanduser() if sys.argv[8] else None

now = time.time()
cutoff = now - (lookback_days * 86400)
candidates: dict[str, tuple[float, str, str, str, str]] = {}
ENTRY_HEADING_RE = re.compile(r"^### (User|Assistant) \d+$")
LEGACY_HEADING_RE = re.compile(r"^## ([QA])\d+$")


def load_redactor():
    if redaction_helper is None:
        return lambda text: text
    try:
        if not redaction_helper.is_file():
            return lambda text: text
        spec = importlib.util.spec_from_file_location("daily_recovery_redact_secrets", redaction_helper)
        if spec is None or spec.loader is None:
            return lambda text: text
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    except Exception:
        return lambda text: text
    redact = getattr(module, "redact_text", None)
    return redact if callable(redact) else (lambda text: text)


redact_text = load_redactor()


def load_state() -> dict:
    try:
        with open(state_file, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


previous_state = load_state()


def load_recent_attempts() -> dict[str, float]:
    data = previous_state
    raw_attempts = data.get("recent_attempts", {}) if isinstance(data, dict) else {}
    if not isinstance(raw_attempts, dict):
        return {}
    attempts: dict[str, float] = {}
    for key, value in raw_attempts.items():
        if not isinstance(key, str):
            continue
        if isinstance(value, (int, float)):
            attempts[key] = float(value)
        elif isinstance(value, dict) and isinstance(value.get("last_attempted_at"), (int, float)):
            attempts[key] = float(value["last_attempted_at"])
    return attempts


recent_attempts = load_recent_attempts()


def parse_epoch(value: object) -> float | None:
    if isinstance(value, (int, float)):
        return float(value)
    if not isinstance(value, str):
        return None
    value = value.strip()
    if not value:
        return None
    if value.isdigit():
        return float(value)
    try:
        normalized = value.replace("Z", "+00:00")
        parsed = dt.datetime.fromisoformat(normalized)
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=dt.timezone.utc)
        return parsed.timestamp()
    except ValueError:
        pass
    try:
        parsed_date = dt.date.fromisoformat(value)
        return dt.datetime.combine(parsed_date, dt.time.min, tzinfo=dt.timezone.utc).timestamp()
    except ValueError:
        return None


def safe_field(value: str) -> bool:
    return bool(value) and "\t" not in value and "\n" not in value and "\r" not in value


saved_bare_claude_paths: dict[str, str] = {}
raw_bare_paths = previous_state.get("bare_claude_jsonl_paths", {})
if isinstance(raw_bare_paths, dict):
    for session_id, path in raw_bare_paths.items():
        if isinstance(session_id, str) and isinstance(path, str) and safe_field(session_id) and safe_field(path):
            saved_bare_claude_paths[session_id] = path


def add_candidate(source: str, session_id: str, path: str, modified_at: float) -> None:
    if modified_at < cutoff:
        return
    if source == "claude":
        if not safe_field(session_id) or (path and not safe_field(path)):
            return
        key = f"claude-jsonl:{path}" if path else f"claude:{session_id}"
    elif source == "codex":
        if not safe_field(session_id) or not safe_field(path):
            return
        key = f"codex:{path}"
    else:
        return

    existing = candidates.get(key)
    if existing is None:
        candidates[key] = (modified_at, source, session_id, path, key)
        return

    existing_modified_at, _source, _session_id, existing_path, _key = existing
    next_modified_at = max(existing_modified_at, modified_at)
    next_path = path or existing_path
    if source == "claude" and existing_path:
        next_path = existing_path
    candidates[key] = (next_modified_at, source, session_id, next_path, key)


def iter_json_records(path: Path):
    try:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(record, dict):
                    yield record
    except OSError:
        return


def read_first_json_records(path: Path, limit: int = 200) -> list[dict]:
    records: list[dict] = []
    for record in iter_json_records(path):
        if len(records) >= limit:
            break
        records.append(record)
    return records


def extract_codex_session_id(path: Path) -> str:
    for record in read_first_json_records(path):
        if record.get("type") != "session_meta":
            continue
        payload = record.get("payload")
        if isinstance(payload, dict):
            value = str(payload.get("id") or "")
            if safe_field(value):
                return value
    return ""


def extract_claude_session_id(path: Path) -> str:
    for record in read_first_json_records(path):
        value = str(record.get("sessionId") or record.get("session_id") or "")
        if safe_field(value):
            return value
    stem = path.name[:-6] if path.name.endswith(".jsonl") else path.stem
    if safe_field(stem):
        return stem
    return ""


def has_claude_transcript_message(path: Path) -> bool:
    for record in iter_json_records(path):
        if record.get("type") not in ("user", "assistant"):
            continue
        message = record.get("message")
        if not isinstance(message, dict):
            continue
        content = message.get("content", "")
        text_parts: list[str] = []
        if isinstance(content, list):
            for item in content:
                if isinstance(item, dict) and item.get("type") == "text":
                    text_parts.append(str(item.get("text", "")))
                elif isinstance(item, str):
                    text_parts.append(item)
        elif isinstance(content, str):
            text_parts.append(content)
        if "\n".join(text_parts).strip():
            return True
    return False


def normalize_transcript(value: str) -> str:
    value = value.replace("\r\n", "\n").replace("\r", "\n").rstrip()
    return value + "\n" if value else ""


def frontmatter_value(raw: str) -> str:
    value = raw.strip()
    if value.startswith('"') and value.endswith('"'):
        try:
            parsed = json.loads(value)
        except json.JSONDecodeError:
            parsed = value[1:-1]
        return parsed if isinstance(parsed, str) else str(parsed)
    if value.startswith("'") and value.endswith("'"):
        return value[1:-1]
    return value


def markdown_session_id(path: Path) -> str:
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return ""
    if not lines or lines[0] != "---":
        return ""
    for line in lines[1:]:
        if line == "---":
            return ""
        if line.startswith("session_id:"):
            value = frontmatter_value(line.split(":", 1)[1])
            return value if safe_field(value) else ""
    return ""


def markdown_transcript(path: Path) -> str:
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return ""
    start = None
    for index, line in enumerate(lines):
        if line.strip() == "## Transcript":
            start = index + 1
    if start is None:
        return ""
    return normalize_transcript("\n".join(lines[start:]).lstrip("\n"))


def markdown_shared_contract(path: Path) -> bool:
    required = {"msg_count", "last_message_hash", "transcript_hash"}
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return False
    if not lines or lines[0] != "---":
        return False
    keys: set[str] = set()
    for line in lines[1:]:
        if line == "---":
            return required.issubset(keys)
        if ":" in line:
            keys.add(line.split(":", 1)[0].strip())
    return False


def markdown_legacy_transcript(path: Path) -> str:
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return ""

    body_start = 0
    if lines and lines[0] == "---":
        for index, line in enumerate(lines[1:], start=1):
            if line == "---":
                body_start = index + 1
                break

    entries: list[str] = []
    current_role = ""
    current_lines: list[str] = []
    user_count = 0
    assistant_count = 0

    def flush_entry() -> None:
        nonlocal user_count, assistant_count, current_role, current_lines
        if not current_role:
            current_lines = []
            return
        text = "\n".join(current_lines).strip()
        if not text:
            current_lines = []
            return
        if current_role == "Q":
            user_count += 1
            heading = f"### User {user_count}"
        else:
            assistant_count += 1
            heading = f"### Assistant {assistant_count}"
        entries.append(f"{heading}\n\n{escape_transcript_text(text).rstrip()}\n")
        current_lines = []

    for line in lines[body_start:]:
        match = LEGACY_HEADING_RE.match(line.strip())
        if match:
            flush_entry()
            current_role = match.group(1)
            current_lines = []
            continue
        if current_role:
            current_lines.append(line)
    flush_entry()
    return normalize_transcript("\n".join(entries))


def markdown_existing_transcript(path: Path) -> str:
    if markdown_shared_contract(path):
        return markdown_transcript(path)
    return markdown_legacy_transcript(path)


existing_bare_markdown_cache: dict[str, Path | None] = {}


def existing_bare_markdown_path(session_id: str) -> Path | None:
    if session_id in existing_bare_markdown_cache:
        return existing_bare_markdown_cache[session_id]
    existing_bare_markdown_cache[session_id] = None
    if second_brain_dir is None:
        return None
    try:
        if second_brain_dir.is_symlink() or not second_brain_dir.is_dir():
            return None
    except OSError:
        return None
    search_roots = [
        (second_brain_dir / "AI-Logs" / "raw", True),
        (second_brain_dir / "AI-Logs" / "raw-archive", True),
        (second_brain_dir, False),
    ]
    seen: set[Path] = set()
    paths: list[Path] = []
    for root, recursive in search_roots:
        if not root.exists() or root.is_symlink() or not root.is_dir():
            continue
        root_paths: list[Path] = []
        if not recursive:
            try:
                direct_paths = [path for path in root.iterdir() if path.suffix == ".md"]
            except OSError:
                direct_paths = []
            for path in direct_paths:
                resolved = path.resolve()
                if resolved in seen:
                    continue
                seen.add(resolved)
                root_paths.append(path)
            paths.extend(sorted(root_paths))
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [
                dirname
                for dirname in dirnames
                if not os.path.islink(os.path.join(dirpath, dirname))
                and Path(dirpath, dirname).resolve() != (second_brain_dir / "AI-Logs" / "readable").resolve()
            ]
            for filename in filenames:
                if not filename.endswith(".md"):
                    continue
                path = Path(dirpath) / filename
                resolved = path.resolve()
                if resolved in seen:
                    continue
                seen.add(resolved)
                root_paths.append(path)
        paths.extend(sorted(root_paths))
    for path in paths:
        try:
            if path.is_symlink() or not path.is_file():
                continue
        except OSError:
            continue
        if markdown_session_id(path) == session_id:
            existing_bare_markdown_cache[session_id] = path
            return path
    return None


def escape_transcript_text(value: str) -> str:
    lines = value.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    return "\n".join(f"\\{line}" if ENTRY_HEADING_RE.match(line) else line for line in lines)


def claude_record_text(record: dict) -> str:
    message = record.get("message")
    if not isinstance(message, dict):
        return ""
    content = message.get("content", "")
    text_parts: list[str] = []
    if isinstance(content, list):
        for item in content:
            if isinstance(item, dict) and item.get("type") == "text":
                text_parts.append(str(item.get("text", "")))
            elif isinstance(item, str):
                text_parts.append(item)
    elif isinstance(content, str):
        text_parts.append(content)
    return "\n".join(text_parts)


def claude_jsonl_transcript(path: Path, session_id: str) -> str:
    allow_missing_sid = path.name == f"{session_id}.jsonl"
    user_count = 0
    assistant_count = 0
    entries: list[str] = []
    for record in iter_json_records(path):
        record_session_id = str(record.get("sessionId") or record.get("session_id") or "")
        if record_session_id and record_session_id != session_id:
            continue
        if not record_session_id and not allow_missing_sid:
            continue
        rec_type = record.get("type")
        if rec_type not in ("user", "assistant"):
            continue
        message = record.get("message")
        role = message.get("role", rec_type) if isinstance(message, dict) else rec_type
        if role not in ("user", "assistant"):
            continue
        text = claude_record_text(record)
        if not text.strip():
            continue
        if role == "user":
            user_count += 1
            heading = f"### User {user_count}"
        else:
            assistant_count += 1
            heading = f"### Assistant {assistant_count}"
        text = redact_text(text)
        entries.append(f"{heading}\n\n{escape_transcript_text(text).rstrip()}\n")
        if len(entries) >= 2000:
            break
    return normalize_transcript("\n".join(entries))


def jsonl_path_matching_existing_bare(session_id: str, paths: list[str]) -> str:
    markdown_path = existing_bare_markdown_path(session_id)
    if markdown_path is None:
        return ""
    existing_transcript = markdown_existing_transcript(markdown_path)
    if not existing_transcript:
        return ""
    comparable_transcripts = [existing_transcript]
    redacted_existing_transcript = normalize_transcript(redact_text(existing_transcript))
    if redacted_existing_transcript and redacted_existing_transcript != existing_transcript:
        comparable_transcripts.append(redacted_existing_transcript)

    def matches_transcript(existing: str, candidate_transcript: str) -> bool:
        if candidate_transcript == existing:
            return True
        if not candidate_transcript.startswith(existing):
            return False
        suffix = candidate_transcript[len(existing):].lstrip("\n")
        return suffix.startswith("### User ") or suffix.startswith("### Assistant ")

    def matches_existing(candidate_transcript: str) -> bool:
        return any(matches_transcript(existing, candidate_transcript) for existing in comparable_transcripts)

    matches = [
        path
        for path in sorted(paths)
        if matches_existing(claude_jsonl_transcript(Path(path), session_id))
    ]
    return matches[0] if len(matches) == 1 else ""


def path_persisted_session_id(session_id: str, path: str) -> str:
    digest = hashlib.sha256(os.path.realpath(path).encode("utf-8")).hexdigest()[:16]
    safe_session_id = re.sub(r"[^A-Za-z0-9_.:-]+", "-", session_id).strip("-") or "session"
    return f"{digest}-{safe_session_id}"


def walk_jsonl(root: Path, pattern: str) -> list[Path]:
    if not root.exists() or root.is_symlink() or not root.is_dir():
        return []
    paths: list[Path] = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [
            dirname
            for dirname in dirnames
            if not os.path.islink(os.path.join(dirpath, dirname))
        ]
        for filename in filenames:
            if not fnmatch.fnmatch(filename, pattern):
                continue
            path = Path(dirpath) / filename
            try:
                if path.is_symlink() or not path.is_file():
                    continue
                paths.append(path)
            except OSError:
                continue
    return paths


def add_recall_candidates() -> None:
    if not recall_list_file:
        return
    try:
        with open(recall_list_file, "r", encoding="utf-8", errors="replace") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return
    sessions = data.get("sessions", []) if isinstance(data, dict) else data
    if not isinstance(sessions, list):
        return
    timestamp_keys = (
        "updated_at",
        "last_message_at",
        "last_activity_at",
        "timestamp",
        "created_at",
        "date",
    )
    for item in sessions:
        if not isinstance(item, dict):
            continue
        if str(item.get("source", "")).lower() == "codex":
            continue
        session_id = str(item.get("session_id") or item.get("id") or "")
        modified_at = None
        for key in timestamp_keys:
            modified_at = parse_epoch(item.get(key))
            if modified_at is not None:
                break
        if modified_at is None:
            continue
        add_candidate("claude", session_id, "", modified_at)


add_recall_candidates()

for jsonl_path in walk_jsonl(claude_projects_dir, "*.jsonl"):
    try:
        real_path = os.path.realpath(jsonl_path)
        modified_at = os.path.getmtime(jsonl_path)
    except OSError:
        continue
    if modified_at < cutoff:
        continue
    if not has_claude_transcript_message(jsonl_path):
        continue
    add_candidate("claude", extract_claude_session_id(jsonl_path), real_path, modified_at)

for jsonl_path in walk_jsonl(codex_sessions_dir, "rollout-*.jsonl"):
    try:
        real_path = os.path.realpath(jsonl_path)
        modified_at = os.path.getmtime(jsonl_path)
    except OSError:
        continue
    if modified_at < cutoff:
        continue
    add_candidate("codex", extract_codex_session_id(jsonl_path), real_path, modified_at)

def candidate_sort_key(row: tuple[float, str, str, str, str]) -> tuple[bool, float, float]:
    modified_at, _source, _session_id, _path, key = row
    last_attempted_at = recent_attempts.get(key, 0.0)
    if last_attempted_at < modified_at:
        last_attempted_at = 0.0
    return (last_attempted_at > 0, last_attempted_at, -modified_at)


rows = sorted(candidates.values(), key=candidate_sort_key)[:max_sessions]
claude_paths_by_session: dict[str, list[str]] = {}
claude_has_recall_by_session: dict[str, bool] = {}
for _modified_at, source, session_id, path, _key in candidates.values():
    if source != "claude":
        continue
    if path:
        claude_paths_by_session.setdefault(session_id, []).append(path)
    else:
        claude_has_recall_by_session[session_id] = True

claude_bare_path_by_session: dict[str, str] = {}
for session_id, paths in claude_paths_by_session.items():
    saved_path = saved_bare_claude_paths.get(session_id)
    if saved_path in paths:
        claude_bare_path_by_session[session_id] = saved_path
        continue
    existing_match = jsonl_path_matching_existing_bare(session_id, paths)
    if existing_match:
        claude_bare_path_by_session[session_id] = existing_match
        continue
    if existing_bare_markdown_path(session_id) is not None:
        continue
    basename_matches = sorted(path for path in paths if os.path.basename(path) == f"{session_id}.jsonl")
    if basename_matches:
        claude_bare_path_by_session[session_id] = basename_matches[0]


def claude_identity_mode(session_id: str, path: str) -> str:
    if existing_bare_markdown_path(path_persisted_session_id(session_id, path)) is not None:
        return "path"
    paths = claude_paths_by_session.get(session_id, [])
    existing_bare_collision = (
        existing_bare_markdown_path(session_id) is not None
        and claude_bare_path_by_session.get(session_id) != path
    )
    has_collision = (
        len(paths) > 1
        or claude_has_recall_by_session.get(session_id, False)
        or existing_bare_collision
    )
    if not has_collision:
        return "-"
    if claude_bare_path_by_session.get(session_id) == path:
        return "-"
    return "path"

for modified_at, source, session_id, path, key in rows:
    session_field = session_id or "-"
    path_field = path or "-"
    identity_mode = claude_identity_mode(session_id, path) if source == "claude" and path else "-"
    print(f"{source}\t{session_field}\t{path_field}\t{int(modified_at)}\t{key}\t{identity_mode}")
PY
}

write_recovery_state() {
    local discovered="$1" attempted="$2" succeeded="$3" failed="$4" skipped="$5" attempted_keys_file="$6" bare_paths_file="$7"
    python3 - "$STATE_FILE" "$LOOKBACK_DAYS" "$MAX_SESSIONS" "$discovered" "$attempted" "$succeeded" "$failed" "$skipped" "$attempted_keys_file" "$bare_paths_file" <<'PY'
from __future__ import annotations

import datetime as dt
import json
import os
import sys
import tempfile
import time

state_file, lookback_days, max_sessions, discovered, attempted, succeeded, failed, skipped, attempted_keys_file, bare_paths_file = sys.argv[1:11]
now = time.time()
now_int = int(now)

recent_attempts: dict[str, int] = {}
bare_claude_jsonl_paths: dict[str, str] = {}
try:
    previous = json.load(open(state_file, encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    previous = {}

if isinstance(previous, dict) and isinstance(previous.get("recent_attempts"), dict):
    for key, value in previous["recent_attempts"].items():
        if isinstance(key, str) and isinstance(value, (int, float)):
            recent_attempts[key] = int(value)

if isinstance(previous, dict) and isinstance(previous.get("bare_claude_jsonl_paths"), dict):
    for session_id, path in previous["bare_claude_jsonl_paths"].items():
        if (
            isinstance(session_id, str)
            and isinstance(path, str)
            and "\t" not in session_id
            and "\n" not in session_id
            and "\r" not in session_id
            and "\t" not in path
            and "\n" not in path
            and "\r" not in path
        ):
            bare_claude_jsonl_paths[session_id] = path

try:
    with open(attempted_keys_file, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            key = line.strip()
            if key and "\t" not in key and "\n" not in key and "\r" not in key:
                recent_attempts[key] = now
except OSError:
    pass

try:
    with open(bare_paths_file, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            session_id, sep, path = line.rstrip("\n").partition("\t")
            if (
                sep
                and session_id
                and path
                and "\t" not in session_id
                and "\n" not in session_id
                and "\r" not in session_id
                and "\t" not in path
                and "\n" not in path
                and "\r" not in path
            ):
                bare_claude_jsonl_paths[session_id] = path
except OSError:
    pass

attempt_cutoff = now - (max(int(lookback_days), 1) * 86400)
recent_attempts = {
    key: value
    for key, value in recent_attempts.items()
    if value >= attempt_cutoff
}
recent_attempts = dict(
    sorted(recent_attempts.items(), key=lambda item: item[1], reverse=True)[:1000]
)

data = {
    "version": 1,
    "last_recovery_at": now_int,
    "last_recovery_at_iso": dt.datetime.fromtimestamp(now_int, dt.timezone.utc).isoformat().replace("+00:00", "Z"),
    "lookback_days": int(lookback_days),
    "max_sessions_per_run": int(max_sessions),
    "recent_attempts": recent_attempts,
    "bare_claude_jsonl_paths": dict(sorted(bare_claude_jsonl_paths.items())[:1000]),
    "last_report": {
        "candidate_count": int(discovered),
        "attempted_count": int(attempted),
        "succeeded_count": int(succeeded),
        "failed_count": int(failed),
        "skipped_count": int(skipped),
    },
}

directory = os.path.dirname(state_file)
fd, tmp_path = tempfile.mkstemp(dir=directory, prefix=".daily-recovery.", text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(tmp_path, 0o600)
    os.replace(tmp_path, state_file)
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
PY
}

if ! acquire_lock; then
    log_line "Daily recovery skipped: another run is active"
    exit 0
fi

recall_list_file=""
if command -v recall >/dev/null 2>&1; then
    recall_list_file=$(mktemp "$STATE_DIR/.recall-list.XXXXXX")
    remember_temp "$recall_list_file"
    if ! recall list > "$recall_list_file" 2>/dev/null; then
        recall_list_file=""
    fi
fi

candidates_file=$(mktemp "$STATE_DIR/.daily-candidates.XXXXXX")
remember_temp "$candidates_file"
discover_candidates "$recall_list_file" > "$candidates_file"
attempted_keys_file=$(mktemp "$STATE_DIR/.daily-attempts.XXXXXX")
remember_temp "$attempted_keys_file"
bare_paths_file=$(mktemp "$STATE_DIR/.daily-bare-paths.XXXXXX")
remember_temp "$bare_paths_file"

candidate_count=$(wc -l < "$candidates_file" | tr -d ' ')
attempted=0
succeeded=0
failed=0
skipped=0

while IFS=$'\t' read -r source_name session_id jsonl_path _modified_at candidate_key identity_mode; do
    [ -n "$source_name" ] || continue
    if [ "$session_id" = "-" ]; then
        session_id=""
    fi
    if [ "$jsonl_path" = "-" ]; then
        jsonl_path=""
    fi
    case "$source_name" in
        claude)
            if [ -z "$session_id" ]; then
                skipped=$((skipped + 1))
                continue
            fi
            if [ -n "$jsonl_path" ] && { [ -L "$jsonl_path" ] || [ ! -f "$jsonl_path" ]; }; then
                skipped=$((skipped + 1))
                continue
            fi
            attempted=$((attempted + 1))
            printf '%s\n' "$candidate_key" >> "$attempted_keys_file"
            if [ -n "$jsonl_path" ]; then
                if [ "$identity_mode" = "path" ]; then
                    if CLAUDE_SESSION_JSONL_PATH="$jsonl_path" CLAUDE_SESSION_IDENTITY_MODE=path SYNC_BUSY_EXIT_CODE=75 "$SYNC_RECALL_SCRIPT" "$session_id"; then
                        sync_exit=0
                    else
                        sync_exit=$?
                    fi
                elif CLAUDE_SESSION_JSONL_PATH="$jsonl_path" SYNC_BUSY_EXIT_CODE=75 "$SYNC_RECALL_SCRIPT" "$session_id"; then
                    sync_exit=0
                else
                    sync_exit=$?
                fi
            else
                if SYNC_BUSY_EXIT_CODE=75 "$SYNC_RECALL_SCRIPT" "$session_id"; then
                    sync_exit=0
                else
                    sync_exit=$?
                fi
            fi
            if [ "$sync_exit" -eq 0 ]; then
                succeeded=$((succeeded + 1))
                if [ -n "$jsonl_path" ] && [ "$identity_mode" != "path" ]; then
                    printf '%s\t%s\n' "$session_id" "$jsonl_path" >> "$bare_paths_file"
                fi
            else
                failed=$((failed + 1))
            fi
            ;;
        codex)
            if [ -z "$jsonl_path" ] || [ -L "$jsonl_path" ] || [ ! -f "$jsonl_path" ]; then
                skipped=$((skipped + 1))
                continue
            fi
            attempted=$((attempted + 1))
            printf '%s\n' "$candidate_key" >> "$attempted_keys_file"
            if SYNC_BUSY_EXIT_CODE=75 "$SYNC_CODEX_SCRIPT" "$jsonl_path"; then
                succeeded=$((succeeded + 1))
            else
                failed=$((failed + 1))
            fi
            ;;
        *)
            skipped=$((skipped + 1))
            ;;
    esac
done < "$candidates_file"

write_recovery_state "$candidate_count" "$attempted" "$succeeded" "$failed" "$skipped" "$attempted_keys_file" "$bare_paths_file"
log_line "Daily recovery completed: candidates=$candidate_count attempted=$attempted succeeded=$succeeded failed=$failed skipped=$skipped"

if [ "$failed" -gt 0 ]; then
    exit 1
fi
