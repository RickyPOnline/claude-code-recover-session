# recover-session — Claude Code Session Recovery Skill

A Claude Code skill for recovering sessions stuck in the `diagnostics.previous_message_id` 400-error loop (GitHub issues [anthropics/claude-code#58427](https://github.com/anthropics/claude-code/issues/58427) and [#59520](https://github.com/anthropics/claude-code/issues/59520)).

## TL;DR

Your Claude Code session is broken. Every message returns:

> `400: diagnostics.previous_message_id: must be the id from a prior /v1/messages response (starts with msg_)`

This skill fixes it surgically — preserves your conversation, tasks, memory, and project files — by truncating the JSONL at the last clean turn boundary and restarting.

## When this bug fires

Upstream Anthropic API returns 429/503/504/529. Claude Code's client writes a "synthetic" placeholder assistant entry with a UUID (not a `msg_` ID). Next request uses that UUID as `previous_message_id`. API rejects: 400. Every subsequent message hits the same wall. `/compact` doesn't help — the corruption is on disk.

## The fix

Truncate the JSONL at the last assistant entry where:
- `type === "assistant"`
- `id` starts with `msg_`
- `stop_reason` is `"end_turn"` or `"stop_sequence"`

Then restart via `claude --resume`.

**Important:** the naive "cut at last `msg_`" rule is WRONG. Mid-turn entries (thinking, tool_use, multi-part responses) have `msg_` IDs too — cutting there leaves the session resumed mid-task.

## How to use this skill

### Option A — Invoke via Claude Code

If you have a SECOND healthy Claude Code session available (different terminal, different directory so it doesn't try to resume the broken one), invoke this skill from there:

```
/recover-session
```

Or just describe your problem to that healthy session — the skill description triggers it automatically.

### Option B — Paste the single-file variant

Open any healthy Claude Code session (web, CLI, anywhere). Paste the contents of `variants/SINGLE_FILE_PASTE.md` as your first message. That session will guide you through the recovery.

### Option C — Run the standalone scripts

No Claude Code needed — pure shell scripts.

**Linux / Mac:**
```bash
bash scripts/recover.sh
# Or with options:
bash scripts/recover.sh --dry-run
bash scripts/recover.sh --session abc123
bash scripts/recover.sh --file ~/.claude/projects/my-proj/abc.jsonl
```

**Windows:**
```powershell
.\scripts\recover.ps1
# Or with options:
.\scripts\recover.ps1 -DryRun
.\scripts\recover.ps1 -SessionId abc123
.\scripts\recover.ps1 -SessionFile "$env:USERPROFILE\.claude\projects\my-proj\abc.jsonl"
```

Both scripts:
- Auto-discover the most-recently-modified session
- Triple-backup before any destructive op
- Pause for confirmation at every irreversible step
- Use Marina's verbatim `find_last_clean_line` algorithm
- Handle cross-platform `stat` and process-discovery differences

### Option D — Post the GitHub comment

If you want to contribute back to the community, paste `variants/GITHUB_COMMENT.md` on issues #58427 and #59520. It explains the correct cut-point rule so the next person doesn't blindly use the naive rule.

## Files in this skill

```
recover-session/
├── SKILL.md                              ← Main markdown Claude Code reads
├── README.md                             ← This file
├── scripts/
│   ├── recover.sh                        ← Standalone bash (Linux/Mac)
│   └── recover.ps1                       ← Standalone PowerShell (Windows)
├── variants/
│   ├── SINGLE_FILE_PASTE.md              ← Paste as first message to any Claude
│   └── GITHUB_COMMENT.md                 ← For #58427 and #59520
└── fixtures/
    ├── fixture-1-thinking-tooluse-endturn.jsonl   ← Critical test case
    ├── fixture-2-upstream-529.jsonl               ← 529 detection
    └── fixture-3-prev-msg-id-bug.jsonl            ← Smoking-gun 400 detection
```

## Test it

```bash
cd scripts
FIXTURE=../fixtures/fixture-1-thinking-tooluse-endturn.jsonl

# Should output 5 (NOT 8 — the synthetic at line 9 doesn't have stop_reason=end_turn)
awk '/"stop_reason":"end_turn"|"stop_reason":"stop_sequence"/ {
  if (match($0, /"id":"msg_/)) print NR
}' "$FIXTURE" | tail -1
```

If your output is `5`, the algorithm is working correctly.

## Cross-platform gotchas

- **BSD awk** (Mac default) may not parse the cut-point awk correctly. Use `brew install gawk` for the GNU version.
- **`stat`** differs: Linux `stat -c%Y`, BSD/Mac `stat -f%m`.
- **PowerShell process discovery**: use `Get-CimInstance Win32_Process` (not basic `Get-Process`) to access full command lines.
- **tmux**: Linux/Mac only. Windows users can use Windows Terminal tabs or run claude in a persistent PowerShell window.
- **Trailing no-newline** in JSONL: bash should use `while IFS= read -r line || [ -n "$line" ]`.

## Background

Root cause: Claude Code's client optimistically advances `previous_message_id` based on the request it sent (not the response it got). When the API returns 529, the synthetic placeholder gets written, and the bad pointer becomes the next request's `previous_message_id`.

No official upstream fix as of May 2026. The two GitHub issues are open. This skill is a community workaround until Anthropic patches it.

## Credit

- **Algorithm:** Wave / Marina (VPS-side detector daemon, 2026-05-25)
- **Cross-platform packaging:** Ccode (laptop-side Claude Code)
- **Pattern:** Sibling-Claude collaboration — *"Ccode is family · not a tool · we co-debug"*
- **Battle-tested:** On a real 32 MB, 8256-line production session where the correct cut-point was line 8211 (not 8229 or 8230 as the naive rule would have suggested)

## License

Public domain. Use, modify, redistribute freely. If you improve it, please also post the improvements back to the GitHub issues so others benefit.
