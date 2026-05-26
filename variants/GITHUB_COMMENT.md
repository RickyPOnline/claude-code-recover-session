# GitHub Comment Draft — for posting on #58427 and #59520

> Post-ready. Co-authored with Marina (Wave VPS-side). Lightly edited from her draft.
> Cross-link both issues when posting.

---

+1 hit this in production · session became unrecoverable after a 529 cascade fired during an autonomous loop wakeup. After surgical recovery, sharing one finding worth knowing for whoever ships the upstream fix.

## The naive truncation rule is wrong

Several existing community recovery scripts suggest *"cut at the last `msg_` entry."* That matches mid-turn entries (thinking blocks, tool_use calls, multi-part responses) whose `stop_reason` is `"tool_use"`, not a turn-ending value. Cutting there leaves the session resumed mid-task — which itself causes weird state on `--resume`.

## The correct rule

Cut at the last assistant entry where **all three** hold:

- `type === "assistant"`
- `id` starts with `msg_`
- `stop_reason` is one of `"end_turn"` or `"stop_sequence"`

## Empirical evidence

In one corrupted 8256-line session, the naive rule suggested line 8229 (an `api_error` log entry) or line 8230 (the first synthetic placeholder). Both cuts would have restarted the session mid-turn. The **correct** rule identified line 8211 — the last clean `end_turn` boundary — which produced a perfectly clean restart.

## One-liner (grep-style)

```bash
grep -nE '"stop_reason":"(end_turn|stop_sequence)"' "$SESSION" \
  | grep '"id":"msg_' \
  | tail -1 \
  | cut -d: -f1
```

## Stricter awk (requires both predicates on the same line, JSON-key-order-agnostic)

```bash
awk '/"stop_reason":"end_turn"|"stop_reason":"stop_sequence"/ {
  if (match($0, /"id":"msg_/)) print NR
}' "$SESSION" | tail -1
```

## Sibling note: detector should gate on more than 529

The same cascade pattern surfaces from **429, 503, 504, and 529** — not just 529. A detector worth its salt should also flag any `400` response whose body carries `diagnostics.previous_message_id`, since that's the smoking gun that the bug has already fired and the session needs cut-point recovery.

Detection regexes that work in production:

```bash
# Synthetic-entry signature in JSONL (the corruption)
SYNTHETIC_REGEX='"message":\{[^}]{0,200}"id":"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"'
SYNTHETIC_REGEX_REV='"model":"<synthetic>"'

# Upstream errors that trigger the bug
UPSTREAM_ERROR_REGEX='"status":(429|503|504|529)|"http_status":(429|503|504|529)|"statusCode":(429|503|504|529)'

# Smoking-gun 400 (bug has fired). 2-step match to avoid false-positives on
# documentation that contains the phrase "previous_message_id" in body text:
# require the phrase AND an error-context marker on the same line.
PREV_MSG_ID_BUG_LINE_PATTERN='previous_message_id'
PREV_MSG_ID_BUG_CONTEXT_PATTERN='"type":"error"|"isApiErrorMessage":true|"error":\{[^}]*"status":4[0-9]{2}'
```

## Portable recovery skill

We've packaged the full procedure as a Claude Code skill that works cross-platform (bash for Linux/Mac, PowerShell for Windows) and supports both local and SSH-remote broken sessions. It's available here: **https://github.com/RickyPOnline/claude-code-recover-session**

The skill includes:
- Auto-discovery of the broken session file
- Triple-backup before any destructive op
- Marina's verbatim `find_last_clean_line()` algorithm
- 2-step regex with error-context anchoring (zero false positives on documentation)
- Process-kill with `$$`-self-exclusion safety
- Tmux re-attach handling
- Three standalone variants (skill, single-file paste, bash script, PowerShell script)

## Closing

Filing in case it helps the upstream patch land correctly. Happy to provide more detail or test patches — we've reproduced the bug deterministically and have smoke-test fixtures available.

— Co-authored by Marina (Wave VPS-side, autonomous detector daemon) and Ccode (laptop-side Claude Code recovery skill), via Ricky.
