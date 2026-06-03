#!/bin/bash
# Install macOS LaunchAgents for deterministic AI Second Brain sync jobs.

set -euo pipefail

umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LOAD_JOBS=1
LABEL_PREFIX="${AI_LAUNCHD_LABEL_PREFIX:-com.ai-second-brain}"
LAUNCH_AGENTS_DIR="${AI_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
STATE_DIR="${AI_SECOND_BRAIN_STATE_DIR:-$HOME/.claude/ai-second-brain-state}"
LAUNCHD_PATH="${AI_LAUNCHD_PATH:-/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin}"
IDLE_INTERVAL_SECONDS="${AI_LAUNCHD_IDLE_INTERVAL_SECONDS:-600}"
DAILY_HOUR="${AI_LAUNCHD_DAILY_HOUR:-5}"
DAILY_MINUTE="${AI_LAUNCHD_DAILY_MINUTE:-0}"

IDLE_LABEL="$LABEL_PREFIX.idle-sync"
DAILY_LABEL="$LABEL_PREFIX.daily-recovery"
IDLE_PLIST="$LAUNCH_AGENTS_DIR/$IDLE_LABEL.plist"
DAILY_PLIST="$LAUNCH_AGENTS_DIR/$DAILY_LABEL.plist"
TEMP_FILES=()

usage() {
    printf 'Usage: %s [--no-load]\n' "$(basename "$0")"
    printf '\n'
    printf 'Writes LaunchAgent plists for idle sync and daily recovery.\n'
    printf 'SECOND_BRAIN_DIR must be an existing absolute non-symlink directory.\n'
}

cleanup() {
    local path
    for path in "${TEMP_FILES[@]:-}"; do
        rm -f "$path" 2>/dev/null || true
    done
}
trap cleanup EXIT

die() {
    printf '%s\n' "$*" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-load)
            LOAD_JOBS=0
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
    shift
done

is_absolute_path() {
    case "$1" in
        /*) return 0 ;;
        *) return 1 ;;
    esac
}

validate_integer() {
    local name="$1" value="$2"
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        die "$name must be an integer"
    fi
}

validate_range() {
    local name="$1" value="$2" min="$3" max="$4"
    validate_integer "$name" "$value"
    if [ "$value" -lt "$min" ] || [ "$value" -gt "$max" ]; then
        die "$name must be between $min and $max"
    fi
}

ensure_directory() {
    local path="$1" label="$2"
    if ! is_absolute_path "$path"; then
        die "$label must be an absolute path: $path"
    fi
    if [ -L "$path" ]; then
        die "$label must not be a symlink: $path"
    fi
    mkdir -p "$path"
    if [ -L "$path" ] || [ ! -d "$path" ]; then
        die "$label must be a directory: $path"
    fi
}

validate_second_brain_dir() {
    if [ -z "${SECOND_BRAIN_DIR:-}" ]; then
        die "SECOND_BRAIN_DIR is required"
    fi
    if ! is_absolute_path "$SECOND_BRAIN_DIR"; then
        die "SECOND_BRAIN_DIR must be an absolute path: $SECOND_BRAIN_DIR"
    fi
    if [ -L "$SECOND_BRAIN_DIR" ] || [ ! -d "$SECOND_BRAIN_DIR" ]; then
        die "SECOND_BRAIN_DIR must be an existing non-symlink directory: $SECOND_BRAIN_DIR"
    fi
}

xml_escape() {
    local value="$1"
    value=${value//&/&amp;}
    value=${value//</&lt;}
    value=${value//>/&gt;}
    value=${value//\"/&quot;}
    value=${value//\'/&apos;}
    printf '%s' "$value"
}

plist_key() {
    local key="$1"
    printf '  <key>%s</key>\n' "$(xml_escape "$key")"
}

plist_string_key() {
    local key="$1" value="$2"
    plist_key "$key"
    printf '  <string>%s</string>\n' "$(xml_escape "$value")"
}

plist_integer_key() {
    local key="$1" value="$2"
    plist_key "$key"
    printf '  <integer>%s</integer>\n' "$value"
}

plist_bool_key() {
    local key="$1" value="$2"
    plist_key "$key"
    printf '  <%s/>\n' "$value"
}

plist_env_pair() {
    local key="$1" value="$2"
    printf '    <key>%s</key>\n' "$(xml_escape "$key")"
    printf '    <string>%s</string>\n' "$(xml_escape "$value")"
}

plist_optional_env_pair() {
    local key="$1" value
    value=$(printenv "$key" 2>/dev/null || true)
    if [ -n "$value" ]; then
        plist_env_pair "$key" "$value"
    fi
}

write_header() {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
    printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"'
    printf '%s\n' '  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    printf '%s\n' '<plist version="1.0">'
    printf '%s\n' '<dict>'
}

write_footer() {
    printf '%s\n' '</dict>'
    printf '%s\n' '</plist>'
}

write_program_arguments() {
    local script_path="$1"
    plist_key "ProgramArguments"
    printf '%s\n' '  <array>'
    printf '    <string>%s</string>\n' '/bin/bash'
    printf '    <string>%s</string>\n' "$(xml_escape "$script_path")"
    printf '%s\n' '  </array>'
}

write_environment() {
    plist_key "EnvironmentVariables"
    printf '%s\n' '  <dict>'
    plist_env_pair "SECOND_BRAIN_DIR" "$SECOND_BRAIN_DIR"
    plist_env_pair "AI_SECOND_BRAIN_STATE_DIR" "$STATE_DIR"
    plist_env_pair "PATH" "$LAUNCHD_PATH"
    plist_optional_env_pair "CODEX_SESSIONS_DIR"
    plist_optional_env_pair "CLAUDE_PROJECTS_DIR"
    plist_optional_env_pair "AI_IDLE_MIN_AGE_SECONDS"
    plist_optional_env_pair "AI_IDLE_MAX_SESSIONS"
    plist_optional_env_pair "AI_IDLE_SYNC_LOG"
    plist_optional_env_pair "AI_RECOVERY_LOOKBACK_DAYS"
    plist_optional_env_pair "AI_RECOVERY_MAX_SESSIONS"
    plist_optional_env_pair "AI_DAILY_RECOVERY_LOG"
    plist_optional_env_pair "REDACTION_HELPER"
    plist_optional_env_pair "SYNC_RECALL_SCRIPT"
    plist_optional_env_pair "SYNC_CODEX_SCRIPT"
    printf '%s\n' '  </dict>'
}

write_idle_plist_content() {
    write_header
    plist_string_key "Label" "$IDLE_LABEL"
    write_program_arguments "$SCRIPT_DIR/sync-idle-ai-sessions.sh"
    write_environment
    plist_integer_key "StartInterval" "$IDLE_INTERVAL_SECONDS"
    plist_bool_key "RunAtLoad" "true"
    plist_string_key "StandardOutPath" "$STATE_DIR/launchd-idle-sync.out.log"
    plist_string_key "StandardErrorPath" "$STATE_DIR/launchd-idle-sync.err.log"
    write_footer
}

write_daily_plist_content() {
    write_header
    plist_string_key "Label" "$DAILY_LABEL"
    write_program_arguments "$SCRIPT_DIR/recover-ai-sessions-daily.sh"
    write_environment
    plist_key "StartCalendarInterval"
    printf '%s\n' '  <dict>'
    printf '%s\n' '    <key>Hour</key>'
    printf '    <integer>%s</integer>\n' "$DAILY_HOUR"
    printf '%s\n' '    <key>Minute</key>'
    printf '    <integer>%s</integer>\n' "$DAILY_MINUTE"
    printf '%s\n' '  </dict>'
    plist_string_key "StandardOutPath" "$STATE_DIR/launchd-daily-recovery.out.log"
    plist_string_key "StandardErrorPath" "$STATE_DIR/launchd-daily-recovery.err.log"
    write_footer
}

write_plist() {
    local target="$1" writer="$2" tmp
    tmp=$(mktemp "$target.tmp.XXXXXX")
    TEMP_FILES+=("$tmp")
    "$writer" > "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$target"
    if command -v plutil >/dev/null 2>&1; then
        plutil -lint "$target" >/dev/null
    fi
}

load_plist() {
    local label="$1" plist="$2" domain
    if [ "$(uname -s)" != "Darwin" ]; then
        die "launchctl loading is only supported on macOS; rerun with --no-load"
    fi
    if ! command -v launchctl >/dev/null 2>&1; then
        die "launchctl not found"
    fi
    domain="gui/$UID"
    launchctl bootout "$domain" "$plist" >/dev/null 2>&1 || true
    launchctl bootstrap "$domain" "$plist"
    launchctl enable "$domain/$label"
}

validate_second_brain_dir
ensure_directory "$LAUNCH_AGENTS_DIR" "AI_LAUNCH_AGENTS_DIR"
ensure_directory "$STATE_DIR" "AI_SECOND_BRAIN_STATE_DIR"

if [[ ! "$LABEL_PREFIX" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; then
    die "AI_LAUNCHD_LABEL_PREFIX contains unsupported characters"
fi
validate_integer "AI_LAUNCHD_IDLE_INTERVAL_SECONDS" "$IDLE_INTERVAL_SECONDS"
if [ "$IDLE_INTERVAL_SECONDS" -le 0 ]; then
    die "AI_LAUNCHD_IDLE_INTERVAL_SECONDS must be greater than 0"
fi
validate_range "AI_LAUNCHD_DAILY_HOUR" "$DAILY_HOUR" 0 23
validate_range "AI_LAUNCHD_DAILY_MINUTE" "$DAILY_MINUTE" 0 59

write_plist "$IDLE_PLIST" write_idle_plist_content
write_plist "$DAILY_PLIST" write_daily_plist_content

printf 'wrote %s\n' "$IDLE_PLIST"
printf 'wrote %s\n' "$DAILY_PLIST"

if [ "$LOAD_JOBS" -eq 1 ]; then
    load_plist "$IDLE_LABEL" "$IDLE_PLIST"
    load_plist "$DAILY_LABEL" "$DAILY_PLIST"
    printf 'loaded %s\n' "$IDLE_LABEL"
    printf 'loaded %s\n' "$DAILY_LABEL"
fi
