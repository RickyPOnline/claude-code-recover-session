#!/usr/bin/env bash
# recover.sh · Standalone Claude Code session recovery tool
# Recovers from the diagnostics.previous_message_id 400-error loop
# (GitHub issues anthropics/claude-code#58427, #59520)
#
# Usage:
#   ./recover.sh                                    Interactive mode, auto-discover session
#   ./recover.sh --session <id>                     Specify session ID directly
#   ./recover.sh --file <path>                      Specify session file directly
#   ./recover.sh --dry-run                          Preview only, no changes
#   ./recover.sh --backup-dir <path>                Custom backup destination
#   ./recover.sh --yes                              Skip all confirmation prompts (dangerous)
#
# Source: mirrors Marina's VPS-side detector-helpers.sh find_last_clean_line algorithm.

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────

DRY_RUN=0
ASSUME_YES=0
SESSION_FILE=""
SESSION_ID=""
BACKUP_DIR="${HOME}/marina-backups"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

# ─── Colors ──────────────────────────────────────────────────────────

if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BOLD=""; C_OFF=""
fi

say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✓%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s⚠%s %s\n' "$C_YEL" "$C_OFF" "$*"; }
err()  { printf '%s✗%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; }
step() { printf '\n%s━━━ %s ━━━%s\n' "$C_BOLD" "$*" "$C_OFF"; }

# ─── Cross-platform stat ─────────────────────────────────────────────

stat_mtime() {
  stat -c%Y "$1" 2>/dev/null || stat -f%m "$1" 2>/dev/null || echo 0
}
stat_size() {
  stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || echo 0
}

# ─── Marina's verbatim find_last_clean_line (with credit) ────────────

find_last_clean_line() {
  # CREDIT: Wave/Marina VPS-side detector-helpers.sh, 2026-05-25
  # Cuts at last assistant entry that ENDED A TURN CLEANLY.
  # Predicate: type=="assistant" AND id starts with "msg_" AND
  #            stop_reason in ("end_turn", "stop_sequence").
  local jsonl="$1"
  [ -f "$jsonl" ] || { echo 0; return; }
  awk '
    /"stop_reason":"end_turn"|"stop_reason":"stop_sequence"/ {
      if (match($0, /"id":"msg_/)) print NR
    }
  ' "$jsonl" 2>/dev/null | tail -1
}

# ─── Marina's verbatim synthetic detection ───────────────────────────

SYNTHETIC_REGEX='"message":\{[^}]{0,200}"id":"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"'
SYNTHETIC_REGEX_REV='"model":"<synthetic>"'

count_synthetic() {
  local jsonl="$1"
  grep -cE "$SYNTHETIC_REGEX|$SYNTHETIC_REGEX_REV" "$jsonl" 2>/dev/null || echo 0
}

first_synthetic_line() {
  local jsonl="$1"
  grep -nE "$SYNTHETIC_REGEX|$SYNTHETIC_REGEX_REV" "$jsonl" 2>/dev/null \
    | head -1 | cut -d: -f1
}

# ─── User interaction ────────────────────────────────────────────────

confirm() {
  local prompt="$1"
  if [ "$ASSUME_YES" = "1" ]; then
    say "${prompt} [auto-yes]"
    return 0
  fi
  local reply
  printf '%s' "$prompt [y/N]: "
  read -r reply
  [ "$reply" = "y" ] || [ "$reply" = "Y" ]
}

# ─── Parse args ──────────────────────────────────────────────────────

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --session) SESSION_ID="$2"; shift 2 ;;
    --file) SESSION_FILE="$2"; shift 2 ;;
    --backup-dir) BACKUP_DIR="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,15p' "$0"; exit 0 ;;
    *) err "Unknown arg: $1"; exit 1 ;;
  esac
done

# ─── Phase 1: locate session file ────────────────────────────────────

step "Phase 1 · Locate session file"

if [ -z "$SESSION_FILE" ] && [ -z "$SESSION_ID" ]; then
  # Auto-discover most recently modified JSONL in ~/.claude/projects/
  PROJECTS_DIR="${HOME}/.claude/projects"
  if [ ! -d "$PROJECTS_DIR" ]; then
    err "Projects dir not found: $PROJECTS_DIR"
    err "If Claude Code uses a different location on your system, pass --file <path>"
    exit 1
  fi
  SESSION_FILE="$(find "$PROJECTS_DIR" -maxdepth 3 -name '*.jsonl' -type f -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | head -1 | cut -d' ' -f2- )"
  if [ -z "$SESSION_FILE" ]; then
    # Fallback for systems without find -printf (BSD)
    SESSION_FILE="$(ls -1t "$PROJECTS_DIR"/*/*.jsonl 2>/dev/null | head -1)"
  fi
  if [ -z "$SESSION_FILE" ]; then
    err "No .jsonl session files found under $PROJECTS_DIR"
    exit 1
  fi
elif [ -n "$SESSION_ID" ]; then
  SESSION_FILE="$(find "${HOME}/.claude/projects" -name "${SESSION_ID}*.jsonl" -type f 2>/dev/null | head -1)"
  if [ -z "$SESSION_FILE" ]; then
    err "Session ID '$SESSION_ID' not found"
    exit 1
  fi
fi

[ -f "$SESSION_FILE" ] || { err "Session file not found: $SESSION_FILE"; exit 1; }

SESSION_ID="$(basename "$SESSION_FILE" .jsonl)"
ok "Session file: $SESSION_FILE"
say "  Size:    $(stat_size "$SESSION_FILE") bytes"
say "  mtime:   $(stat_mtime "$SESSION_FILE")"
say "  Session: $SESSION_ID"

# ─── Phase 2: investigate ────────────────────────────────────────────

step "Phase 2 · Investigate corruption"

TOTAL_LINES="$(wc -l < "$SESSION_FILE" | tr -d ' ')"
SYNTH_COUNT="$(count_synthetic "$SESSION_FILE")"
say "  Total lines:        $TOTAL_LINES"
say "  Synthetic entries:  $SYNTH_COUNT"

if [ "$SYNTH_COUNT" = "0" ]; then
  ok "No synthetic entries detected. Session looks clean."
  warn "If you're seeing errors anyway, this may be a different bug. Aborting."
  exit 0
fi

FIRST_SYNTH="$(first_synthetic_line "$SESSION_FILE")"
say "  First synthetic at line: $FIRST_SYNTH"

CUT_LINE="$(find_last_clean_line "$SESSION_FILE")"
if [ -z "$CUT_LINE" ] || [ "$CUT_LINE" = "0" ]; then
  err "Could not find a clean cut-point (no msg_ entry with stop_reason in end_turn|stop_sequence)"
  err "Manual surgery required. Inspect the JSONL by hand."
  exit 2
fi
ok "Recommended cut-point: line $CUT_LINE (last clean end_turn boundary)"
say "  Discarding $((TOTAL_LINES - CUT_LINE)) lines after line $CUT_LINE"

# ─── Phase 3: triple-backup ──────────────────────────────────────────

step "Phase 3 · Triple-backup"

mkdir -p "$BACKUP_DIR"
BACKUP1="$BACKUP_DIR/session-backup-${TIMESTAMP}.jsonl"

if [ "$DRY_RUN" = "1" ]; then
  warn "DRY-RUN: would copy $SESSION_FILE → $BACKUP1"
else
  cp -p "$SESSION_FILE" "$BACKUP1"
  ok "Backup 1 (local persistent): $BACKUP1 ($(stat_size "$BACKUP1") bytes)"
fi

say ""
say "  Backup 2 (off-machine) — manual step:"
say "    From your OTHER machine, run:"
say "      scp $(hostname):$BACKUP1 ~/Downloads/"
say "    Or use rsync / cloud sync of your choice."
say ""
say "  Backup 3 (cloud) — optional:"
say "    If you have S3/R2/B2 configured, push $BACKUP1 there too."

if ! confirm "Have you verified at least 2 backup copies exist?"; then
  err "Aborting at user request. Session file is untouched."
  exit 0
fi

# ─── Phase 4: prepare truncated version ──────────────────────────────

step "Phase 4 · Prepare truncated version"

FIXED="$BACKUP_DIR/session-fixed-${TIMESTAMP}.jsonl"
if [ "$DRY_RUN" = "1" ]; then
  warn "DRY-RUN: would create $FIXED with $CUT_LINE lines"
else
  head -n "$CUT_LINE" "$SESSION_FILE" > "$FIXED"
  NEW_LINES="$(wc -l < "$FIXED" | tr -d ' ')"
  if [ "$NEW_LINES" != "$CUT_LINE" ]; then
    warn "Expected $CUT_LINE lines, got $NEW_LINES (file may have lacked trailing newline — usually fine)"
  fi
  ok "Truncated copy ready: $FIXED ($NEW_LINES lines, $(stat_size "$FIXED") bytes)"

  TAIL_PREVIEW="$(tail -n 1 "$FIXED" | head -c 200)"
  say ""
  say "  Last line preview:"
  say "    ${TAIL_PREVIEW}..."
fi

# ─── Phase 5: stop the broken process ────────────────────────────────

step "Phase 5 · Stop the broken Claude Code process"

PIDS="$(pgrep -f "claude.*--resume[ =].*${SESSION_ID}" 2>/dev/null || true)"
if [ -z "$PIDS" ]; then
  PIDS="$(pgrep -f "claude.*${SESSION_ID}" 2>/dev/null || true)"
fi

if [ -z "$PIDS" ]; then
  warn "No live Claude Code process found for session $SESSION_ID"
  warn "Either it was already killed, or it's not currently running."
  if ! confirm "Proceed with file swap anyway?"; then
    err "Aborting. Session file is untouched."
    exit 0
  fi
else
  say "  Found PID(s): $PIDS"
  ps -p $PIDS 2>/dev/null || true
  say ""
  if ! confirm "Send SIGTERM to PID(s) above?"; then
    err "Aborting. Session file is untouched. Process(es) still alive."
    exit 0
  fi
  if [ "$DRY_RUN" = "1" ]; then
    warn "DRY-RUN: would send SIGTERM to $PIDS"
  else
    for pid in $PIDS; do kill -TERM "$pid" 2>/dev/null || true; done
    say "  Waiting up to 10s for graceful shutdown..."
    for i in 1 2 3 4 5 6 7 8 9 10; do
      sleep 1
      ALIVE="$(pgrep -f "claude.*${SESSION_ID}" 2>/dev/null || true)"
      [ -z "$ALIVE" ] && break
    done
    if [ -n "$ALIVE" ]; then
      warn "Process(es) still alive after 10s: $ALIVE"
      if confirm "Escalate to SIGKILL?"; then
        for pid in $ALIVE; do kill -KILL "$pid" 2>/dev/null || true; done
        sleep 1
      else
        err "Aborting. Session file is untouched."
        exit 0
      fi
    fi
    ok "Process terminated."
  fi
fi

# ─── Phase 6: swap the file ──────────────────────────────────────────

step "Phase 6 · Swap the file"

if ! confirm "Replace $SESSION_FILE with the truncated version?"; then
  err "Aborting. Session file is UNTOUCHED. Truncated copy remains at $FIXED."
  exit 0
fi

if [ "$DRY_RUN" = "1" ]; then
  warn "DRY-RUN: would cp $FIXED → $SESSION_FILE"
else
  cp -p "$FIXED" "$SESSION_FILE"
  NEW_LINES="$(wc -l < "$SESSION_FILE" | tr -d ' ')"
  ok "Session file replaced: $NEW_LINES lines"
fi

# ─── Phase 7: resume instructions ────────────────────────────────────

step "Phase 7 · Resume the session"

# Try to detect the launch directory from JSONL entries
LAUNCH_DIR="$(grep -o '"cwd":"[^"]*"' "$SESSION_FILE" 2>/dev/null | head -1 | sed 's/.*"cwd":"\([^"]*\)".*/\1/')"

# Project hash heuristic: the parent directory name of the session file
# usually encodes the launch cwd as the project hash
PROJECT_HASH="$(basename "$(dirname "$SESSION_FILE")")"
say "  Project hash: $PROJECT_HASH"
say "  Session ID:   $SESSION_ID"
say ""
say "  To resume, run from the original launch directory:"
say ""

# Decode the project hash: leading dash + dashes-as-slashes
DECODED="$(echo "$PROJECT_HASH" | sed 's|^-||; s|-|/|g')"
say "    cd /$DECODED && claude --resume $SESSION_ID"

say ""
say "  Or if you use tmux to keep the session persistent:"
say "    tmux attach -t <session>  (then run the cd+claude command inside tmux)"

ok "Recovery complete."
say ""
say "Backups:"
say "  Local:    $BACKUP1"
say "  Fixed:    $FIXED"
say "  Original was replaced with the truncated version."

say ""
say "After resume, send a simple test message like 'hello' to verify the bug is fixed."
say ""
say "If you appreciate this fix, post on GitHub issues #58427 and #59520"
say "to help prioritize the upstream patch."
