#!/usr/bin/env python3
"""Apply or roll back a frozen Automation view migration manifest."""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
from pathlib import Path


SF_DATALESS = 0x40000000
CLASSIFICATION_RULE = "codex-automation-envelope-v1"


def sha256_bytes(data: bytes) -> str:
    return "sha256:" + hashlib.sha256(data).hexdigest()


def read_stable(path: Path) -> tuple[bytes, os.stat_result]:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags)
    try:
        before = os.fstat(fd)
        if getattr(before, "st_flags", 0) & SF_DATALESS:
            raise RuntimeError(f"dataless file: {path}")
        chunks = []
        while chunk := os.read(fd, 1024 * 1024):
            chunks.append(chunk)
        after = os.fstat(fd)
    finally:
        os.close(fd)
    before_id = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
    after_id = (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
    if before_id != after_id:
        raise RuntimeError(f"file changed while being read: {path}")
    return b"".join(chunks), after


def atomic_write(path: Path, data: bytes, *, mtime_ns: int | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, tmp_name = tempfile.mkstemp(dir=path.parent, prefix=".automation-migration.")
    tmp = Path(tmp_name)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp, 0o600)
        if mtime_ns is not None:
            os.utime(tmp, ns=(mtime_ns, mtime_ns), follow_symlinks=False)
        os.replace(tmp, path)
        dir_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    except Exception:
        try:
            tmp.unlink()
        except OSError:
            pass
        raise


def fsync_directory(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def unlink_fsync(path: Path) -> None:
    path.unlink()
    fsync_directory(path.parent)


def atomic_create(path: Path, data: bytes, *, mtime_ns: int | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, tmp_name = tempfile.mkstemp(dir=path.parent, prefix=".automation-migration-create.")
    tmp = Path(tmp_name)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp, 0o600)
        if mtime_ns is not None:
            os.utime(tmp, ns=(mtime_ns, mtime_ns), follow_symlinks=False)
        os.link(tmp, path, follow_symlinks=False)
        tmp.unlink()
        fsync_directory(path.parent)
    except Exception:
        try:
            tmp.unlink()
        except OSError:
            pass
        raise


def reject_symlink_components(path: Path) -> None:
    absolute = path.expanduser().absolute()
    current = Path(absolute.anchor)
    for part in absolute.parts[1:]:
        current /= part
        try:
            metadata = os.lstat(current)
        except FileNotFoundError:
            continue
        if os.path.islink(current):
            raise RuntimeError(f"symlink path component: {current}")
        if not os.path.isdir(current) and current != absolute:
            raise RuntimeError(f"non-directory path component: {current}")


@contextlib.contextmanager
def migration_lock(_state_root: Path, root: Path):
    lock_path = root / ".ai-second-brain-migration.lock"
    with lock_path.open("a+b") as handle:
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise RuntimeError(f"another migration is active for root: {root}") from exc
        handle.seek(0)
        handle.truncate()
        handle.write(f"pid={os.getpid()}\nroot={root}\n".encode())
        handle.flush()
        os.fsync(handle.fileno())
        try:
            yield
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def split_frontmatter(data: bytes) -> tuple[list[str], list[str]]:
    text = data.decode("utf-8", errors="replace")
    lines = text.splitlines(keepends=True)
    if not lines or lines[0].rstrip("\r\n") != "---":
        raise RuntimeError("missing frontmatter")
    for index, line in enumerate(lines[1:], start=1):
        if line.rstrip("\r\n") == "---":
            return lines[: index + 1], lines[index + 1 :]
    raise RuntimeError("unclosed frontmatter")


def rewrite_frontmatter(data: bytes, updates: dict[str, str | None]) -> bytes:
    frontmatter, body = split_frontmatter(data)
    result = [frontmatter[0]]
    seen = set()
    for line in frontmatter[1:-1]:
        key = line.split(":", 1)[0].strip() if ":" in line else ""
        if key in updates:
            seen.add(key)
            value = updates[key]
            if value is not None:
                result.append(f"{key}: {json.dumps(value, ensure_ascii=False)}\n")
            continue
        result.append(line)
    for key, value in updates.items():
        if key not in seen and value is not None:
            result.append(f"{key}: {json.dumps(value, ensure_ascii=False)}\n")
    result.append(frontmatter[-1])
    result.extend(body)
    return "".join(result).encode("utf-8")


def under(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def load_manifest(path: Path) -> list[dict[str, object]]:
    rows = []
    with path.open("r", encoding="utf-8") as handle:
        for number, line in enumerate(handle, start=1):
            if not line.strip():
                continue
            row = json.loads(line)
            if not isinstance(row, dict):
                raise RuntimeError(f"manifest row {number} is not an object")
            rows.append(row)
    if not rows:
        raise RuntimeError("manifest has no candidates")
    return rows


def expected_paths(root: Path, row: dict[str, object]) -> tuple[Path, Path, Path]:
    raw_input = Path(str(row.get("raw_path", ""))).expanduser().absolute()
    source_input = Path(str(row.get("source_path", ""))).expanduser().absolute()
    target_input = Path(str(row.get("target_path", ""))).expanduser().absolute()
    for path in (raw_input, source_input, target_input):
        reject_symlink_components(path)
    raw = raw_input.resolve()
    source = source_input.resolve()
    target = target_input.resolve()
    raw_root = (root / "AI-Logs" / "raw" / "codex").resolve()
    source_root = (root / "AI-Logs" / "readable" / "codex").resolve()
    target_root = (root / "AI-Logs" / "automation" / "codex").resolve()
    if not under(raw, raw_root) or not under(source, source_root) or not under(target, target_root):
        raise RuntimeError(f"manifest path escapes migration roots: {row.get('session_id', '')}")
    relative = source.relative_to(source_root)
    if raw != raw_root / relative or target != target_root / relative:
        raise RuntimeError(f"manifest paths do not describe one session: {row.get('session_id', '')}")
    return raw, source, target


def snapshot_matches(data: bytes, metadata: os.stat_result, row: dict[str, object], prefix: str) -> bool:
    return (
        sha256_bytes(data) == row.get(f"{prefix}_sha256")
        and metadata.st_size == row.get(f"{prefix}_size")
        and metadata.st_mtime_ns == row.get(f"{prefix}_mtime_ns")
    )


def save_batch(batch_file: Path, batch: dict[str, object]) -> None:
    atomic_write(batch_file, (json.dumps(batch, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode())


def prepare_batch(root: Path, manifest: Path, batch_dir: Path) -> dict[str, object]:
    rows = load_manifest(manifest)
    seen = set()
    prepared = []
    for index, row in enumerate(rows):
        if row.get("action") != "migrate_automation_view":
            raise RuntimeError(f"unsupported manifest action at row {index + 1}")
        session_id = str(row.get("session_id", ""))
        automation_id = str(row.get("automation_id", ""))
        if not re.fullmatch(r"[A-Za-z0-9_.:-]+", session_id) or not re.fullmatch(
            r"[a-z0-9]+(?:-[a-z0-9]+)*", automation_id
        ):
            raise RuntimeError(f"invalid identity at row {index + 1}")
        raw, source, target = expected_paths(root, row)
        identity = (raw, source, target, session_id)
        if identity in seen:
            raise RuntimeError(f"duplicate manifest row: {session_id}")
        seen.add(identity)
        if raw.is_symlink() or source.is_symlink() or target.is_symlink():
            raise RuntimeError(f"symlink in migration paths: {session_id}")
        if target.exists() or bool(row.get("collision")):
            raise RuntimeError(f"target collision: {target}")
        raw_bytes, raw_stat = read_stable(raw)
        source_bytes, source_stat = read_stable(source)
        if not snapshot_matches(raw_bytes, raw_stat, row, "raw"):
            raise RuntimeError(f"raw drift: {raw}")
        if not snapshot_matches(source_bytes, source_stat, row, "source"):
            raise RuntimeError(f"source drift: {source}")

        new_raw = rewrite_frontmatter(
            raw_bytes,
            {
                "record_kind": "automation",
                "automation_id": automation_id,
                "classification_rule": str(row.get("classification_rule") or CLASSIFICATION_RULE),
            },
        )
        new_source = rewrite_frontmatter(
            source_bytes,
            {
                "record_kind": "automation",
                "automation_id": automation_id,
                "classification_rule": str(row.get("classification_rule") or CLASSIFICATION_RULE),
                "raw_hash": sha256_bytes(new_raw),
            },
        )
        backup_dir = batch_dir / "backups" / f"{index:06d}-{session_id}"
        backup_dir.mkdir(parents=True, exist_ok=False, mode=0o700)
        atomic_write(backup_dir / "raw.md", raw_bytes, mtime_ns=raw_stat.st_mtime_ns)
        atomic_write(backup_dir / "source.md", source_bytes, mtime_ns=source_stat.st_mtime_ns)
        prepared.append(
            {
                "session_id": session_id,
                "automation_id": automation_id,
                "classification_rule": str(row.get("classification_rule") or CLASSIFICATION_RULE),
                "raw_path": str(raw),
                "source_path": str(source),
                "target_path": str(target),
                "raw_before_sha256": sha256_bytes(raw_bytes),
                "source_before_sha256": sha256_bytes(source_bytes),
                "raw_before_mtime_ns": raw_stat.st_mtime_ns,
                "source_before_mtime_ns": source_stat.st_mtime_ns,
                "raw_before_dev": raw_stat.st_dev,
                "raw_before_ino": raw_stat.st_ino,
                "source_before_dev": source_stat.st_dev,
                "source_before_ino": source_stat.st_ino,
                "raw_after_sha256": sha256_bytes(new_raw),
                "target_after_sha256": sha256_bytes(new_source),
                "backup_dir": str(backup_dir),
                "state": "prepared",
            }
        )
    shutil.copyfile(manifest, batch_dir / "manifest.jsonl")
    return {
        "version": 1,
        "kind": "automation-view-migration",
        "status": "prepared",
        "root": str(root),
        "created_at": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
        "rows": prepared,
    }


def validate_apply_row(row: dict[str, object], *, check_target: bool = True) -> None:
    raw = Path(str(row["raw_path"]))
    source = Path(str(row["source_path"]))
    target = Path(str(row["target_path"]))
    raw_bytes, raw_stat = read_stable(raw)
    source_bytes, source_stat = read_stable(source)
    if (
        sha256_bytes(raw_bytes) != row["raw_before_sha256"]
        or raw_stat.st_mtime_ns != row["raw_before_mtime_ns"]
        or raw_stat.st_dev != row["raw_before_dev"]
        or raw_stat.st_ino != row["raw_before_ino"]
    ):
        raise RuntimeError(f"raw changed after preflight: {raw}")
    if (
        sha256_bytes(source_bytes) != row["source_before_sha256"]
        or source_stat.st_mtime_ns != row["source_before_mtime_ns"]
        or source_stat.st_dev != row["source_before_dev"]
        or source_stat.st_ino != row["source_before_ino"]
    ):
        raise RuntimeError(f"source changed after preflight: {source}")
    if check_target:
        try:
            os.lstat(target)
        except FileNotFoundError:
            return
        raise RuntimeError(f"target appeared after preflight: {target}")


def live_snapshot(path: Path) -> dict[str, object]:
    try:
        os.lstat(path)
    except FileNotFoundError:
        return {"exists": False}
    data, metadata = read_stable(path)
    return {
        "exists": True,
        "sha256": sha256_bytes(data),
        "mtime_ns": metadata.st_mtime_ns,
        "dev": metadata.st_dev,
        "ino": metadata.st_ino,
    }


def require_same_snapshot(path: Path, expected: dict[str, object]) -> None:
    if live_snapshot(path) != expected:
        raise RuntimeError(f"file changed after rollback preflight: {path}")


def rollback_preflight(batch_file: Path, batch: dict[str, object]) -> list[dict[str, object]]:
    batch_dir = batch_file.parent.resolve()
    root_input = Path(str(batch.get("root", ""))).expanduser().absolute()
    reject_symlink_components(root_input)
    root = root_input.resolve()
    rows = batch.get("rows", [])
    if not isinstance(rows, list):
        raise RuntimeError("invalid batch rows")
    validated = []
    for row in rows:
        if not isinstance(row, dict):
            raise RuntimeError("invalid batch row")
        raw, source, target = expected_paths(root, row)
        backup_input = Path(str(row.get("backup_dir", ""))).expanduser().absolute()
        reject_symlink_components(backup_input)
        backup_dir = backup_input.resolve()
        backup_root = (batch_dir / "backups").resolve()
        if not under(backup_dir, backup_root):
            raise RuntimeError(f"backup path escapes batch: {backup_dir}")
        raw_backup_path = backup_dir / "raw.md"
        source_backup_path = backup_dir / "source.md"
        raw_backup, _ = read_stable(raw_backup_path)
        source_backup, _ = read_stable(source_backup_path)
        if sha256_bytes(raw_backup) != row.get("raw_before_sha256"):
            raise RuntimeError(f"raw backup hash mismatch: {raw_backup_path}")
        if sha256_bytes(source_backup) != row.get("source_before_sha256"):
            raise RuntimeError(f"source backup hash mismatch: {source_backup_path}")

        state = row.get("state")
        if state not in ("prepared", "applying", "applied", "rolled_back"):
            raise RuntimeError(f"invalid row state: {state}")
        raw_snapshot = live_snapshot(raw)
        source_snapshot = live_snapshot(source)
        target_snapshot = live_snapshot(target)
        raw_hash = raw_snapshot.get("sha256")
        source_hash = source_snapshot.get("sha256")
        target_hash = target_snapshot.get("sha256")

        if state in ("prepared", "rolled_back"):
            if raw_hash != row.get("raw_before_sha256") or source_hash != row.get("source_before_sha256") or target_hash is not None:
                raise RuntimeError(f"non-applied row changed: {row.get('session_id', '')}")
        else:
            if raw_hash not in (row.get("raw_before_sha256"), row.get("raw_after_sha256")):
                raise RuntimeError(f"raw changed after apply: {raw}")
            if source_hash not in (None, row.get("source_before_sha256")):
                raise RuntimeError(f"source changed during apply: {source}")
            if target_hash not in (None, row.get("target_after_sha256")):
                raise RuntimeError(f"target changed after apply: {target}")
        validated.append(
            {
                "row": row,
                "raw": raw,
                "source": source,
                "target": target,
                "raw_backup": raw_backup,
                "source_backup": source_backup,
                "raw_snapshot": raw_snapshot,
                "source_snapshot": source_snapshot,
                "target_snapshot": target_snapshot,
            }
        )
    return validated


def restore_batch(batch_file: Path, *, mark_rolled_back: bool = True) -> int:
    batch = json.loads(batch_file.read_text(encoding="utf-8"))
    validated = rollback_preflight(batch_file, batch)
    for item in validated:
        row = item["row"]
        if row.get("state") in ("prepared", "rolled_back"):
            continue
        raw = item["raw"]
        source = item["source"]
        target = item["target"]
        require_same_snapshot(raw, item["raw_snapshot"])
        require_same_snapshot(source, item["source_snapshot"])
        require_same_snapshot(target, item["target_snapshot"])
        if (
            item["raw_snapshot"].get("sha256") != row["raw_before_sha256"]
            or item["raw_snapshot"].get("mtime_ns") != row["raw_before_mtime_ns"]
        ):
            atomic_write(raw, item["raw_backup"], mtime_ns=int(row["raw_before_mtime_ns"]))
        if not item["source_snapshot"].get("exists"):
            atomic_create(source, item["source_backup"], mtime_ns=int(row["source_before_mtime_ns"]))
        elif item["source_snapshot"].get("mtime_ns") != row["source_before_mtime_ns"]:
            atomic_write(source, item["source_backup"], mtime_ns=int(row["source_before_mtime_ns"]))
        if item["target_snapshot"].get("exists"):
            unlink_fsync(target)
        row["state"] = "rolled_back"
        save_batch(batch_file, batch)
    if mark_rolled_back:
        batch["status"] = "rolled_back"
        batch["rolled_back_at"] = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")
        save_batch(batch_file, batch)
    return len(validated)


def apply_manifest(args: argparse.Namespace) -> int:
    root_input = Path(args.root or os.environ.get("SECOND_BRAIN_DIR", "")).expanduser().absolute()
    manifest_input = Path(args.manifest).expanduser().absolute()
    state_root = Path(
        args.state_dir or os.environ.get("AI_SECOND_BRAIN_STATE_DIR", "~/.claude/ai-second-brain-state")
    ).expanduser().absolute()
    for path in (root_input, manifest_input, state_root):
        reject_symlink_components(path)
    root = root_input.resolve()
    manifest = manifest_input.resolve()
    if not root.is_dir():
        raise RuntimeError(f"invalid root: {root}")
    if not manifest.is_file():
        raise RuntimeError(f"invalid manifest: {manifest}")
    batch_id = args.batch_id or dt.datetime.now().strftime("%Y%m%dT%H%M%S")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", batch_id):
        raise RuntimeError("invalid batch id")
    with migration_lock(state_root, root):
        batch_dir = state_root / "migrations" / "automation-view" / batch_id
        batch_dir.mkdir(parents=True, exist_ok=False, mode=0o700)
        batch_file = batch_dir / "batch.json"
        batch = prepare_batch(root, manifest, batch_dir)
        save_batch(batch_file, batch)
        try:
            for row in batch["rows"]:
                validate_apply_row(row)
            for row in batch["rows"]:
                row["state"] = "applying"
                save_batch(batch_file, batch)
                raw = Path(row["raw_path"])
                source = Path(row["source_path"])
                target = Path(row["target_path"])
                backup_dir = Path(row["backup_dir"])
                raw_before = (backup_dir / "raw.md").read_bytes()
                source_before = (backup_dir / "source.md").read_bytes()
                automation_id = str(row.get("automation_id", ""))
                rule = str(row.get("classification_rule") or CLASSIFICATION_RULE)
                if not automation_id:
                    raise RuntimeError(f"missing automation id: {row['session_id']}")
                new_raw = rewrite_frontmatter(
                    raw_before,
                    {"record_kind": "automation", "automation_id": automation_id, "classification_rule": rule},
                )
                new_target = rewrite_frontmatter(
                    source_before,
                    {
                        "record_kind": "automation",
                        "automation_id": automation_id,
                        "classification_rule": rule,
                        "raw_hash": sha256_bytes(new_raw),
                    },
                )
                validate_apply_row(row)
                atomic_create(target, new_target)
                validate_apply_row(row, check_target=False)
                atomic_write(raw, new_raw)
                source_current, source_stat = read_stable(source)
                if (
                    sha256_bytes(source_current) != row["source_before_sha256"]
                    or source_stat.st_mtime_ns != row["source_before_mtime_ns"]
                    or source_stat.st_dev != row["source_before_dev"]
                    or source_stat.st_ino != row["source_before_ino"]
                ):
                    raise RuntimeError(f"source changed before retirement: {source}")
                unlink_fsync(source)
                row["state"] = "applied"
                save_batch(batch_file, batch)

            for row in batch["rows"]:
                raw_bytes, _ = read_stable(Path(row["raw_path"]))
                target_bytes, _ = read_stable(Path(row["target_path"]))
                if sha256_bytes(raw_bytes) != row["raw_after_sha256"]:
                    raise RuntimeError(f"raw postflight mismatch: {row['raw_path']}")
                if sha256_bytes(target_bytes) != row["target_after_sha256"]:
                    raise RuntimeError(f"target postflight mismatch: {row['target_path']}")
                if Path(row["source_path"]).exists():
                    raise RuntimeError(f"source still exists after apply: {row['source_path']}")
            batch["status"] = "applied"
            batch["applied_at"] = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")
            save_batch(batch_file, batch)
        except Exception as apply_error:
            try:
                restore_batch(batch_file, mark_rolled_back=False)
            except Exception as rollback_error:
                try:
                    failed_batch = json.loads(batch_file.read_text(encoding="utf-8"))
                    failed_batch["status"] = "rollback_failed"
                    failed_batch["apply_error"] = str(apply_error)
                    failed_batch["rollback_error"] = str(rollback_error)
                    save_batch(batch_file, failed_batch)
                except Exception:
                    pass
                raise RuntimeError(
                    f"apply failed ({apply_error}); automatic rollback also failed ({rollback_error})"
                ) from rollback_error
            failed_batch = json.loads(batch_file.read_text(encoding="utf-8"))
            failed_batch["status"] = "failed_rolled_back"
            failed_batch["apply_error"] = str(apply_error)
            save_batch(batch_file, failed_batch)
            raise
    print(json.dumps({"status": "applied", "batch_dir": str(batch_dir), "count": len(batch["rows"])}))
    return 0


def rollback(args: argparse.Namespace) -> int:
    batch_input = Path(args.batch_dir).expanduser().absolute()
    reject_symlink_components(batch_input)
    batch_dir = batch_input.resolve()
    batch_file = batch_dir / "batch.json"
    if not batch_file.is_file():
        raise RuntimeError(f"invalid batch: {batch_dir}")
    batch = json.loads(batch_file.read_text(encoding="utf-8"))
    root_input = Path(str(batch.get("root", ""))).expanduser().absolute()
    reject_symlink_components(root_input)
    root = root_input.resolve()
    state_root = batch_dir.parents[2]
    with migration_lock(state_root, root):
        count = restore_batch(batch_file)
    print(json.dumps({"status": "rolled_back", "batch_dir": str(batch_dir), "count": count}))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    apply_parser = subparsers.add_parser("apply")
    apply_parser.add_argument("--manifest", required=True)
    apply_parser.add_argument("--root", default="")
    apply_parser.add_argument("--state-dir", default="")
    apply_parser.add_argument("--batch-id", default="")
    apply_parser.set_defaults(func=apply_manifest)
    rollback_parser = subparsers.add_parser("rollback")
    rollback_parser.add_argument("--batch-dir", required=True)
    rollback_parser.set_defaults(func=rollback)
    args = parser.parse_args()
    try:
        return args.func(args)
    except (OSError, RuntimeError, ValueError, json.JSONDecodeError) as exc:
        print(f"automation migration failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
