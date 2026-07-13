#!/bin/bash
# Search the local human-facing Second Brain surface without hydrating iCloud placeholders.

set -euo pipefail

OBSIDIAN_DIR="${SECOND_BRAIN_DIR:?'Error: SECOND_BRAIN_DIR is not set. Set it to your notes directory.'}"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILE_LISTER="${SEARCH_FILE_LISTER:-$SCRIPT_DIR/list-searchable-second-brain.py}"
PYTHON_BIN="${SECOND_BRAIN_PYTHON:-python3}"

if [ "$#" -eq 0 ]; then
    printf 'usage: %s <rg args>\n' "$(basename "$0")" >&2
    exit 2
fi

if [ ! -f "$FILE_LISTER" ]; then
    printf 'search file lister not found: %s\n' "$FILE_LISTER" >&2
    exit 2
fi

if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    printf 'Second Brain Python runtime not found: %s\n' "$PYTHON_BIN" >&2
    exit 2
fi

file_list=$(mktemp "${TMPDIR:-/tmp}/ai-second-brain-search.XXXXXX")
trap 'rm -f "$file_list"' EXIT

"$PYTHON_BIN" "$FILE_LISTER" --root "$OBSIDIAN_DIR" > "$file_list"
if [ ! -s "$file_list" ]; then
    printf 'No local files are available in the default Second Brain search scope.\n' >&2
    exit 0
fi

"$PYTHON_BIN" - "$file_list" "$@" <<'PY'
import os
import stat
import subprocess
import sys

file_list = sys.argv[1]
rg_args = sys.argv[2:]
with open(file_list, "rb") as handle:
    files = [os.fsdecode(item) for item in handle.read().split(b"\0") if item]

SF_DATALESS = 0x40000000
local_files = []
for path in files:
    try:
        metadata = os.stat(path, follow_symlinks=False)
    except OSError:
        continue
    if stat.S_ISREG(metadata.st_mode) and not (getattr(metadata, "st_flags", 0) & SF_DATALESS):
        local_files.append(path)
if not local_files:
    print("No local files are available in the default Second Brain search scope.", file=sys.stderr)
    raise SystemExit(0)

matched = False
batch = []
batch_bytes = 0
for path in local_files + [None]:
    path_bytes = len(os.fsencode(path)) + 1 if path is not None else 0
    if batch and (path is None or batch_bytes + path_bytes > 256 * 1024):
        result = subprocess.run(["rg", *rg_args, "--", *batch], check=False)
        if result.returncode not in (0, 1):
            raise SystemExit(result.returncode)
        matched = matched or result.returncode == 0
        batch = []
        batch_bytes = 0
    if path is not None:
        batch.append(path)
        batch_bytes += path_bytes
raise SystemExit(0 if matched else 1)
PY
