# Claude Code Session Recovery — Paste-to-Claude Variant

> **How to use this file:** If your Claude Code session is broken with the `diagnostics.previous_message_id` error, open a FRESH Claude Code session (a different terminal, possibly a different directory so it doesn't try to resume the broken one) and paste this entire markdown file as your first message. The healthy Claude Code instance will read it as an instruction set and guide you through recovery.
>
> The broken session itself cannot read this file — that's the whole problem. You need a separate healthy Claude Code instance to fix it.

---

## Hi, Claude. Here's what I need you to do.

I have another Claude Code session that's stuck in the `diagnostics.previous_message_id` 400-error loop. Every message I send it returns:

> `API Error: 400 diagnostics.previous_message_id: must be the id from a prior /v1/messages response (starts with msg_)`

This is the bug documented at https://github.com/anthropics/claude-code/issues/58427 and https://github.com/anthropics/claude-code/issues/59520. The root cause: an upstream 429/503/504/529 wrote a "synthetic" placeholder entry in the session JSONL with a UUID instead of a `msg_` ID, and now every subsequent request uses that bad ID as `previous_message_id` and fails.

Please guide me through recovering it. Use the procedure below. **Pause at every destructive step** and wait for my explicit "yes proceed" before doing anything irreversible.

---

## Recovery procedure

Follow these phases in order. Do not skip any. Pause at the 🛑 markers.

### Phase 1 — Diagnose

Ask me:
1. What's the exact error text I'm seeing?
2. Do slash commands like `/status` work, while plain messages fail?
3. Is the broken session on this machine or a remote machine I'll need to SSH into?

If my answers don't match the bug (e.g., the error doesn't contain `previous_message_id`), tell me this skill is the wrong fix and suggest I check status.claude.com or open a fresh session.

### Phase 2 — Locate the session file

Help me find the file. Locations:
- Linux/Mac: `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl`
- Windows: `$env:USERPROFILE\.claude\projects\<encoded-cwd>\<sessionId>.jsonl`

Find the most-recently-modified `.jsonl` in that tree — that's the active session. Show me the path, file size, and last modified time. Confirm with me before proceeding.

If the broken session is on a remote machine, I'll need to SSH in. Walk me through identifying it via `ls -lat ~/.claude/projects/*/` on the remote.

### Phase 3 — Triple-backup 🛑

Before anything destructive, create THREE backup copies:

1. **Local persistent** — on the same machine in a folder that survives reboot (e.g., `~/marina-backups/session-backup-<timestamp>.jsonl`). NOT `/tmp` — that clears on reboot.
2. **Off-machine** — if the broken session is remote, SCP it to my laptop. If it's local, copy to a USB drive or another folder.
3. **Cloud (optional)** — push to S3/R2/B2/OneDrive if I have credentials.

Verify each backup's size matches the original. **🛑 Do not proceed until I confirm all backups exist.**

### Phase 4 — Investigate the JSONL (read-only)

Run these commands and show me the output:

```bash
# Total line count
wc -l "$SESSION_FILE"

# Count synthetic entries (the corruption)
grep -cE '"message":\{[^}]{0,200}"id":"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"|"model":"<synthetic>"' "$SESSION_FILE"

# First synthetic line number
grep -nE '"message":\{[^}]{0,200}"id":"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"|"model":"<synthetic>"' "$SESSION_FILE" | head -1 | cut -d: -f1

# Recommended cut-point: last clean end_turn boundary
# (NOT just "last msg_" — that matches mid-turn entries; cutting there leaves session resumed mid-task)
awk '/"stop_reason":"end_turn"|"stop_reason":"stop_sequence"/ {
  if (match($0, /"id":"msg_/)) print NR
}' "$SESSION_FILE" | tail -1
```

Report to me:
- Total lines
- Number of synthetic entries  
- Where the first synthetic is
- **Recommended cut-point** (the awk output)
- How many lines will be discarded

Tell me clearly: "I'll truncate to keep lines 1 through N. That preserves everything up to your last clean end-of-turn. M lines will be discarded — those are the failed retries after the upstream outage. Proceed?"

### Phase 5 — Create truncated version (still safe — no changes to original)

```bash
head -n $CUT_LINE "$SESSION_FILE" > "$BACKUP_DIR/session-fixed.jsonl"
wc -l "$BACKUP_DIR/session-fixed.jsonl"
tail -n 1 "$BACKUP_DIR/session-fixed.jsonl" | head -c 400
```

Show me the verification. The last line should be a clean assistant entry with `"stop_reason":"end_turn"` and a real `msg_` ID. If it doesn't look right, abort and let me investigate manually.

### Phase 6 — Stop the broken Claude Code process 🛑

Find the PID:
```bash
# Linux/Mac
pgrep -f "claude.*--resume.*$SESSION_ID"
```
```powershell
# Windows
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match "claude.*--resume.*$SESSION_ID" }
```

**🛑 Confirm with me before terminating.** Tell me what's about to happen: "Process X (PID Y) will be terminated. Memory files, project files, git all survive. Backups are in place. Proceed?"

Send SIGTERM first. Wait 5-10 seconds. Verify process is gone. Escalate to SIGKILL only with my explicit OK.

### Phase 7 — Swap the file 🛑

**🛑 Final confirmation:** "I'll now replace the broken file with the truncated version. Backups remain in place. Proceed?"

```bash
cp "$BACKUP_DIR/session-fixed.jsonl" "$SESSION_FILE"
wc -l "$SESSION_FILE"  # verify new line count
tail -n 1 "$SESSION_FILE" | head -c 200  # verify last line is clean
```

Show me the verification.

### Phase 8 — Resume the session

Find the launch directory. The Claude Code "project hash" is encoded from the working directory it was launched from. The path on disk is `~/.claude/projects/<hash>/<sessionId>.jsonl`. Decode the hash by removing the leading dash and replacing remaining dashes with slashes (e.g., `-root-wc-foo` → `/root/wc/foo`).

If the broken session was running inside tmux, instruct me to attach to that tmux session first, then run the resume command inside tmux.

```bash
cd <launch-dir>
claude --resume <sessionId>
```

Claude Code may show:
- A "trust this folder" prompt → press Enter
- A "resume from summary or full session" prompt → guide me through the trade-off:
  - **Summary**: faster, less context, summarized older turns
  - **Full**: preserves every detail, may auto-compact on first message
  - If I want to preserve fine-grained detail, recommend Full + immediately disable auto-compact via `/config`

### Phase 9 — Verify

Have me send a simple test message like "hello" in the recovered session. If it responds normally with no 400 error, recovery succeeded. Otherwise, walk me back through what might have gone wrong.

---

## Important constraints

- **Never skip a 🛑 confirmation gate.** I want explicit "yes" before each destructive step.
- **Backup before any destructive operation.** Always 3 copies. Always verify sizes.
- **Don't auto-compact or auto-clear.** If you think those are needed, explain why and ask.
- **If the cut-point algorithm finds line 0** (no clean turn boundary), STOP. Tell me manual surgery is needed and let me investigate.
- **Don't rewrite my code base or memory files** during recovery. Only the session JSONL gets touched.

---

## Cross-platform notes you should be aware of

- BSD awk (Mac default) may not parse the cut-point awk correctly. Install gawk via Homebrew (`brew install gawk`) or use the grep-pipe fallback:
  ```bash
  grep -nE '"stop_reason":"(end_turn|stop_sequence)"' "$SESSION" | grep '"id":"msg_' | tail -1 | cut -d: -f1
  ```
- `stat` syntax differs: Linux uses `stat -c%Y`, BSD/Mac uses `stat -f%m`.
- Windows: use `Get-CimInstance Win32_Process` to access full command lines; basic `Get-Process` doesn't include them.
- Trailing-no-newline: when reading JSONL in bash, use `while IFS= read -r line || [ -n "$line" ]` to consume the last line.

---

## Credit

This recovery procedure was developed collaboratively by Marina (Wave VPS-side detector daemon) and Ccode (laptop-side Claude Code) on 2026-05-25, after the bug bit a live production session. Marina's `find_last_clean_line()` awk is the canonical algorithm — it's mirrored verbatim in this document.

GitHub: https://github.com/anthropics/claude-code/issues/58427 and #59520. As of May 2026 no upstream fix has shipped.

---

OK Claude — please start with Phase 1. Ask me the diagnose questions and proceed from there.
