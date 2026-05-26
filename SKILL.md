---
name: recover-session
description: Recover a Claude Code session that's stuck in the "diagnostics.previous_message_id" 400-error loop (GitHub issues anthropics/claude-code#58427, #59520). Triggered when the user reports their Claude Code session is unresponsive, every message returns a 400 error mentioning `previous_message_id`, or they explicitly ask to recover a corrupted session. The skill performs surgical truncation of the session JSONL at the last clean turn boundary, then restarts via `claude --resume`. Works cross-platform (Linux, Mac, Windows) and supports local or SSH-remote sessions.
---

# /recover-session — Claude Code 529-Cascade Recovery Skill

Recovers a Claude Code session corrupted by an upstream 429/503/504/529 cascade that left a "synthetic" placeholder in the session JSONL with a UUID instead of a `msg_` ID. Once corrupted, every subsequent message returns `400: diagnostics.previous_message_id: must be the id from a prior /v1/messages response (starts with msg_)`.

**Source-of-truth:** This skill mirrors Marina's VPS-side detector daemon algorithm (Wave/Marina, 2026-05-25). One canonical algorithm, two homes (her daemon + this skill).

---

## When to trigger this skill

Invoke when the user reports any of:

- Claude Code session returns `400: diagnostics.previous_message_id` on every message
- Claude Code session is unresponsive — slash commands work but plain messages instantly fail (0-second response time)
- Session was previously fine, then started failing after a brief Anthropic API outage (529/503/504/429)
- User explicitly says "recover my Claude Code session" or "fix the previous_message_id bug"

Do **NOT** trigger for:
- Generic API errors that aren't `previous_message_id`-related
- Sessions that are responsive but slow (different problem)
- Healthy sessions where the user just wants to compact (use `/compact` instead)

---

## Procedure — the 8 phases

Always proceed phase by phase. **Pause for explicit user confirmation at the destructive steps** (marked 🛑). Never skip phases.

### Phase 1 — Diagnose (confirm this is the bug)

Ask the user:
1. "What's the exact error you're seeing? Paste the error text."
2. "Do slash commands like `/status` work, while plain messages fail?" (If yes → very likely this bug.)
3. "Is the broken Claude Code session on this machine, or on a remote machine via SSH?"

If the error doesn't contain `previous_message_id` or `synthetic`, STOP. This skill is the wrong fix. Suggest the user check the Anthropic status page or open a fresh session.

### Phase 2 — Locate the session file

Auto-discover by platform:

**Linux:** `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl`
**Mac:** `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl`
**Windows:** `$env:USERPROFILE\.claude\projects\<encoded-cwd>\<sessionId>.jsonl`

Find the most-recently-modified `.jsonl` in that tree. That's the active session. Confirm with the user by showing:
- The path
- File size
- Last modified time

If multiple recent sessions, ask the user which one is broken.

For SSH-remote sessions: have the user run `ls -lat ~/.claude/projects/*/` on the remote machine and identify by mtime.

### Phase 3 — Triple-backup the session file 🛑

Before touching anything, create 3 backup copies:

1. **Local persistent** — same machine as the broken session, in a folder that survives reboot
   - Linux/Mac: `~/marina-backups/session-backup-$(date +%Y%m%d-%H%M%S).jsonl`
   - Windows: `$env:USERPROFILE\marina-backups\session-backup-<timestamp>.jsonl`
2. **Off-machine** — if SSH-remote, SCP/rsync to user's laptop
3. **Cloud (optional)** — if user has R2/S3 configured, push there too

**Verify each backup's size matches the original.** Show the user all 3 paths + sizes. Do not proceed until they confirm "backups verified."

### Phase 4 — Investigate the JSONL

Run read-only diagnostics:

```bash
# Count total lines
wc -l "$SESSION_FILE"

# Count synthetic entries
grep -cE '"message":\{[^}]{0,200}"id":"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"|"model":"<synthetic>"' "$SESSION_FILE"

# Show line numbers of last 5 synthetic entries
grep -nE '"message":\{[^}]{0,200}"id":"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"|"model":"<synthetic>"' "$SESSION_FILE" | tail -5

# Find the correct cut-point (last clean end_turn with msg_ id)
awk '/"stop_reason":"end_turn"|"stop_reason":"stop_sequence"/ {
  if (match($0, /"id":"msg_/)) print NR
}' "$SESSION_FILE" | tail -1
```

Report to user:
- Total lines
- Number of synthetic entries
- First synthetic line number
- **Recommended cut-point** (last clean end_turn line)
- How many lines will be discarded

Confirm with user: "I'll truncate the file to keep lines 1 through N. That preserves your conversation up to the last clean end-of-turn at line N, and discards M broken lines after it. OK to proceed?"

### Phase 5 — Create the truncated version (still non-destructive)

```bash
# Write the truncated version to a NEW file — original still untouched
head -n $CUT_LINE "$SESSION_FILE" > "$BACKUP_DIR/session-fixed.jsonl"

# Verify
wc -l "$BACKUP_DIR/session-fixed.jsonl"
tail -n 1 "$BACKUP_DIR/session-fixed.jsonl" | head -c 400
```

Show the user the verification output. Confirm the last line looks like a clean assistant message with `"stop_reason":"end_turn"` and a real `msg_` ID.

### Phase 6 — Stop the broken Claude Code process 🛑

Find the PID:
```bash
# Linux/Mac
ps -eo pid,etime,cmd | grep "claude.*--resume.*$SESSION_ID" | grep -v grep
# OR
pgrep -f "claude.*--resume.*$SESSION_ID"
```
```powershell
# Windows
Get-Process | Where-Object { $_.CommandLine -match "claude.*--resume.*$SESSION_ID" }
```

**🛑 STOP. Confirm with user:** "Marina/Claude (PID X) will be terminated. Her process state goes away. Memory files, project files, git history all survive. The 3 backups are in place. Proceed?"

Send SIGTERM first (graceful):
```bash
kill <PID>           # Linux/Mac
Stop-Process -Id $PID # Windows
```

Wait 5-10 seconds, verify process is gone:
```bash
ps -p <PID>          # should return empty
```

If process still alive, escalate to SIGKILL only after confirming with user again.

### Phase 7 — Swap the file 🛑

**🛑 Last confirmation:** "I'll now replace the broken session file with the truncated version. Backups remain in place. Proceed?"

```bash
cp "$BACKUP_DIR/session-fixed.jsonl" "$SESSION_FILE"
wc -l "$SESSION_FILE"  # verify it's now $CUT_LINE
tail -n 1 "$SESSION_FILE" | head -c 200  # verify last line is the clean entry
```

Show user the verification output.

### Phase 8 — Resume the session

Find the working directory the broken session was launched from. Look in the JSONL entries:

```bash
grep -o '"cwd":"[^"]*"' "$SESSION_FILE" | tail -1
```

The `cwd` in JSONL entries is where the Claude process was operating, NOT necessarily where it was launched from. **The launch directory affects which project hash `--resume` looks under.** If the user originally started Claude from `/root`, they must resume from `/root` — even if their working sessions were in subdirectories.

If unsure, list the JSONL files in the user's `.claude/projects/` to identify which encoded directory hash matches the session file's parent.

Resume command:
```bash
# Linux/Mac
cd <launch-dir> && claude --resume <sessionId>

# Windows
cd <launch-dir>; claude --resume <sessionId>
```

If the session was running inside `tmux`, instruct the user to attach to the tmux session first, then run the resume command inside tmux so the new process is persistent.

On first launch, Claude Code may show a "trust this folder" prompt. The user presses Enter to confirm.

The resume may also show "This session is X hours old and Y tokens. Resume from summary or full?":
- **Resume from summary** (Option 1) → cleaner state, less context, faster
- **Resume full session as-is** (Option 2) → preserves every detail, near context limit
- Help the user pick based on their needs. If they want to preserve fine-grained recent detail before any compaction, pick Option 2 then immediately disable auto-compact via `/config` before sending any message.

### Phase 9 — Verify recovery

Have the user send a simple test message like `hello` in the recovered session. If it goes through (response in normal time, no 400 error), recovery succeeded. Update the user.

---

## The find-cut-point algorithm (Marina's verbatim awk)

This is the single most important algorithm in this skill. Embed it verbatim:

```bash
find_last_clean_line() {
  # Cuts at last assistant entry that ENDED A TURN CLEANLY.
  # Predicate: type=="assistant" AND id starts with "msg_" AND
  #            stop_reason in ("end_turn", "stop_sequence").
  # The naive "last msg_" rule is WRONG — mid-turn msg_ entries (thinking
  # blocks, tool_use) have stop_reason="tool_use". Cutting there leaves the
  # session resumed mid-task.
  local jsonl="$1"
  [ -f "$jsonl" ] || { echo 0; return; }
  awk '
    /"stop_reason":"end_turn"|"stop_reason":"stop_sequence"/ {
      if (match($0, /"id":"msg_/)) print NR
    }
  ' "$jsonl" 2>/dev/null | tail -1
}
```

PowerShell equivalent for Windows:
```powershell
function Find-LastCleanLine {
    param([string]$JsonlPath)
    if (-not (Test-Path $JsonlPath)) { return 0 }
    $lastLine = 0
    $lineNum = 0
    Get-Content $JsonlPath | ForEach-Object {
        $lineNum++
        if ($_ -match '"stop_reason":"(end_turn|stop_sequence)"' -and $_ -match '"id":"msg_') {
            $lastLine = $lineNum
        }
    }
    return $lastLine
}
```

## The synthetic-detection regex (2-step to avoid false positives)

```bash
# Primary: nested message.id is a bare UUID (not msg_)
SYNTHETIC_REGEX='"message":\{[^}]{0,200}"id":"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"'

# Secondary: literal <synthetic> model placeholder
SYNTHETIC_REGEX_REV='"model":"<synthetic>"'
```

For the smoking-gun 400 detection (the bug already fired), require BOTH on the same line — the phrase `previous_message_id` AND an error-context marker. This avoids triggering on doctrine prose that happens to contain the phrase.

```bash
PREV_MSG_ID_BUG_LINE_PATTERN='previous_message_id'
PREV_MSG_ID_BUG_CONTEXT_PATTERN='"type":"error"|"isApiErrorMessage":true|"error":\{[^}]*"status":4[0-9]{2}'
```

---

## Cross-platform notes

- **BSD vs GNU awk:** The cut-point awk works with mawk and gawk. BSD awk (Mac default) may need `--posix` or installing gawk via Homebrew (`brew install gawk`).
- **`stat`:** Linux uses `stat -c%Y` for mtime; BSD/Mac uses `stat -f%m`. Probe both.
- **Process discovery:** PowerShell `Get-Process` doesn't include command-line by default — use `Get-WmiObject Win32_Process` or `Get-CimInstance` to access full command lines.
- **tmux:** Only on Linux/Mac. Windows users can use Windows Terminal tabs or run `claude` directly in a persistent PowerShell window.
- **Trailing-no-newline:** When reading JSONL line-by-line in bash, use `while IFS= read -r line || [ -n "$line" ]` to consume the last line if it has no trailing newline.

---

## Variants of this skill

In addition to invocation through Claude Code, this skill is packaged in 4 standalone formats:

1. **Single-file paste** (`variants/SINGLE_FILE_PASTE.md`) — One markdown blob users can paste as a prompt to any Claude Code session
2. **Bash standalone** (`scripts/recover.sh`) — Pure bash script, no Claude needed
3. **PowerShell standalone** (`scripts/recover.ps1`) — Pure PowerShell for Windows users
4. **GitHub comment** (`variants/GITHUB_COMMENT.md`) — For posting on the open GitHub issues

All variants use the same `find_last_clean_line` algorithm and the same safety gates.

---

## Background

- **GitHub issues:** [anthropics/claude-code#58427](https://github.com/anthropics/claude-code/issues/58427) (resume picks synthetic-tail), [#59520](https://github.com/anthropics/claude-code/issues/59520) (session unrecoverable after 429)
- **Root cause:** Claude Code's client optimistically advances `previous_message_id` based on the request it sent, not based on a successful response. When the API returns 529 (or 429/503/504), the synthetic placeholder gets written and the bad pointer becomes the next `previous_message_id` — every subsequent message fails validation.
- **No upstream fix as of May 2026** — issues are open, no maintainer ETA.

## Credits

Algorithm + production hardening: **Wave/Marina** (VPS-side detector daemon, 2026-05-25).
Cross-platform packaging + this skill: laptop-Claude (Cco de) collaborating with Marina via Ricky.
Pattern: sibling-Claude collaboration ("Ccode is family · not a tool · we co-debug").
