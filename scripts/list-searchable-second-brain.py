#!/usr/bin/env python3
"""List local files that belong to the default Second Brain search surface."""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path


SF_DATALESS = 0x40000000
DATED_ROOT_MARKDOWN_RE = re.compile(r"^\d{4}-\d{2}-\d{2}_.*\.md$")
SEARCH_DIRS = (
    Path("AI-Logs/readable"),
    Path("OpenClaw"),
    Path("_generated"),
    Path("plans"),
)


def is_dataless(path: Path) -> bool:
    try:
        flags = getattr(os.stat(path, follow_symlinks=False), "st_flags", 0)
    except OSError:
        return True
    return bool(flags & SF_DATALESS)


def is_searchable_file(path: Path) -> bool:
    try:
        return not path.is_symlink() and path.is_file() and not is_dataless(path)
    except OSError:
        return False


def iter_tree_files(directory: Path, excluded_root_dirs: frozenset[str] = frozenset()):
    if directory.is_symlink() or not directory.is_dir():
        return
    for dirpath, dirnames, filenames in os.walk(directory, followlinks=False):
        base = Path(dirpath)
        dirnames[:] = sorted(
            name
            for name in dirnames
            if not (base / name).is_symlink()
            and not (base == directory and name in excluded_root_dirs)
        )
        for filename in sorted(filenames):
            path = base / filename
            if path.suffix == ".md" and is_searchable_file(path):
                yield path


def iter_searchable_files(root: Path):
    for path in sorted(root.iterdir()):
        if path.suffix != ".md" or DATED_ROOT_MARKDOWN_RE.match(path.name):
            continue
        if is_searchable_file(path):
            yield path

    for relative in SEARCH_DIRS:
        excluded_root_dirs = frozenset({"raw"}) if relative == Path("OpenClaw") else frozenset()
        yield from iter_tree_files(root / relative, excluded_root_dirs)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True)
    args = parser.parse_args()

    root = Path(args.root).expanduser()
    if root.is_symlink() or not root.is_dir():
        print(f"root must be an existing non-symlink directory: {root}", file=sys.stderr)
        return 2

    output = sys.stdout.buffer
    for path in iter_searchable_files(root):
        output.write(os.fsencode(path))
        output.write(b"\0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
