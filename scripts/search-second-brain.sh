#!/bin/bash
# Search the human-facing Second Brain surface. Raw archives are excluded.

set -euo pipefail

OBSIDIAN_DIR="${SECOND_BRAIN_DIR:?'Error: SECOND_BRAIN_DIR is not set. Set it to your notes directory.'}"

if [ "$#" -eq 0 ]; then
    printf 'usage: %s <rg args>\n' "$(basename "$0")" >&2
    exit 2
fi

exec rg \
    --glob '!**/AI-Logs/raw/**' \
    --glob '!**/AI-Logs/raw-archive/**' \
    "$@" \
    "$OBSIDIAN_DIR"
