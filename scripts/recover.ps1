# recover.ps1 · Standalone Claude Code session recovery tool (Windows)
# Recovers from the diagnostics.previous_message_id 400-error loop
# (GitHub issues anthropics/claude-code#58427, #59520)
#
# Usage:
#   .\recover.ps1                                   Interactive mode, auto-discover session
#   .\recover.ps1 -SessionId <id>                   Specify session ID directly
#   .\recover.ps1 -SessionFile <path>               Specify session file directly
#   .\recover.ps1 -DryRun                           Preview only, no changes
#   .\recover.ps1 -BackupDir <path>                 Custom backup destination
#   .\recover.ps1 -Yes                              Skip all confirmation prompts (dangerous)
#
# Source: mirrors Marina's VPS-side detector-helpers.sh find_last_clean_line algorithm.

[CmdletBinding()]
param(
    [string]$SessionId = "",
    [string]$SessionFile = "",
    [string]$BackupDir = "$env:USERPROFILE\marina-backups",
    [switch]$DryRun,
    [switch]$Yes
)

$ErrorActionPreference = "Stop"
$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

# ─── Output helpers ──────────────────────────────────────────────────

function Say  { param([string]$msg) Write-Host $msg }
function Ok   { param([string]$msg) Write-Host "[OK] $msg" -ForegroundColor Green }
function Warn { param([string]$msg) Write-Host "[!]  $msg" -ForegroundColor Yellow }
function Err  { param([string]$msg) Write-Host "[X]  $msg" -ForegroundColor Red }
function Step {
    param([string]$msg)
    Write-Host ""
    Write-Host "=== $msg ===" -ForegroundColor Cyan
}

function Confirm-Action {
    param([string]$Prompt)
    if ($Yes) {
        Say "$Prompt [auto-yes]"
        return $true
    }
    $reply = Read-Host "$Prompt [y/N]"
    return ($reply -eq "y" -or $reply -eq "Y")
}

# ─── Marina's algorithm — find last clean turn boundary ──────────────

function Find-LastCleanLine {
    # CREDIT: Wave/Marina VPS-side detector-helpers.sh, 2026-05-25
    # Cuts at last assistant entry that ENDED A TURN CLEANLY.
    # Predicate: type=="assistant" AND id starts with "msg_" AND
    #            stop_reason in ("end_turn", "stop_sequence").
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

# ─── Synthetic detection (same regexes as bash version) ──────────────

$SyntheticRegex = '"message":\{[^}]{0,200}"id":"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"'
$SyntheticRegexRev = '"model":"<synthetic>"'

function Count-Synthetic {
    param([string]$JsonlPath)
    $count = 0
    Get-Content $JsonlPath | ForEach-Object {
        if ($_ -match $SyntheticRegex -or $_ -match $SyntheticRegexRev) { $count++ }
    }
    return $count
}

function First-SyntheticLine {
    param([string]$JsonlPath)
    $lineNum = 0
    foreach ($line in Get-Content $JsonlPath) {
        $lineNum++
        if ($line -match $SyntheticRegex -or $line -match $SyntheticRegexRev) {
            return $lineNum
        }
    }
    return 0
}

# ─── Phase 1: Locate session file ────────────────────────────────────

Step "Phase 1 - Locate session file"

if (-not $SessionFile -and -not $SessionId) {
    # Auto-discover most-recently-modified JSONL
    $ProjectsDir = "$env:USERPROFILE\.claude\projects"
    if (-not (Test-Path $ProjectsDir)) {
        Err "Projects dir not found: $ProjectsDir"
        Err "If Claude Code uses a different location, pass -SessionFile <path>"
        exit 1
    }
    $candidate = Get-ChildItem -Path $ProjectsDir -Recurse -Filter "*.jsonl" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $candidate) {
        Err "No .jsonl session files found under $ProjectsDir"
        exit 1
    }
    $SessionFile = $candidate.FullName
} elseif ($SessionId) {
    $found = Get-ChildItem -Path "$env:USERPROFILE\.claude\projects" -Recurse -Filter "$SessionId*.jsonl" -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $found) {
        Err "Session ID '$SessionId' not found"
        exit 1
    }
    $SessionFile = $found.FullName
}

if (-not (Test-Path $SessionFile)) {
    Err "Session file not found: $SessionFile"
    exit 1
}

$SessionId = [System.IO.Path]::GetFileNameWithoutExtension($SessionFile)
$fileInfo = Get-Item $SessionFile
Ok "Session file: $SessionFile"
Say "  Size:    $($fileInfo.Length) bytes"
Say "  mtime:   $($fileInfo.LastWriteTime)"
Say "  Session: $SessionId"

# ─── Phase 2: Investigate ────────────────────────────────────────────

Step "Phase 2 - Investigate corruption"

$totalLines = (Get-Content $SessionFile | Measure-Object -Line).Lines
$synthCount = Count-Synthetic -JsonlPath $SessionFile
Say "  Total lines:        $totalLines"
Say "  Synthetic entries:  $synthCount"

if ($synthCount -eq 0) {
    Ok "No synthetic entries detected. Session looks clean."
    Warn "If you're seeing errors anyway, this may be a different bug. Aborting."
    exit 0
}

$firstSynth = First-SyntheticLine -JsonlPath $SessionFile
Say "  First synthetic at line: $firstSynth"

$cutLine = Find-LastCleanLine -JsonlPath $SessionFile
if ($cutLine -le 0) {
    Err "Could not find a clean cut-point (no msg_ entry with stop_reason in end_turn/stop_sequence)"
    Err "Manual surgery required. Inspect the JSONL by hand."
    exit 2
}
Ok "Recommended cut-point: line $cutLine (last clean end_turn boundary)"
Say "  Discarding $($totalLines - $cutLine) lines after line $cutLine"

# ─── Phase 3: Backup ─────────────────────────────────────────────────

Step "Phase 3 - Triple-backup"

if (-not (Test-Path $BackupDir)) {
    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
}
$backup1 = Join-Path $BackupDir "session-backup-$Timestamp.jsonl"

if ($DryRun) {
    Warn "DRY-RUN: would copy $SessionFile -> $backup1"
} else {
    Copy-Item $SessionFile $backup1
    $backupSize = (Get-Item $backup1).Length
    Ok "Backup 1 (local persistent): $backup1 ($backupSize bytes)"
}

Say ""
Say "  Backup 2 (off-machine) - manual step:"
Say "    Copy $backup1 to another device of your choice (USB drive, second computer, cloud sync)"
Say ""
Say "  Backup 3 (cloud) - optional:"
Say "    Upload $backup1 to S3/R2/B2/OneDrive/Dropbox if you have credentials configured"

if (-not (Confirm-Action "Have you verified at least 2 backup copies exist?")) {
    Err "Aborting at user request. Session file is untouched."
    exit 0
}

# ─── Phase 4: Prepare truncated version ──────────────────────────────

Step "Phase 4 - Prepare truncated version"

$fixed = Join-Path $BackupDir "session-fixed-$Timestamp.jsonl"
if ($DryRun) {
    Warn "DRY-RUN: would create $fixed with $cutLine lines"
} else {
    Get-Content $SessionFile -TotalCount $cutLine | Set-Content $fixed -Encoding UTF8
    $newLines = (Get-Content $fixed | Measure-Object -Line).Lines
    $fixedSize = (Get-Item $fixed).Length
    if ($newLines -ne $cutLine) {
        Warn "Expected $cutLine lines, got $newLines (file may have lacked trailing newline)"
    }
    Ok "Truncated copy ready: $fixed ($newLines lines, $fixedSize bytes)"

    $lastLine = Get-Content $fixed -Tail 1
    $preview = $lastLine.Substring(0, [Math]::Min(200, $lastLine.Length))
    Say ""
    Say "  Last line preview:"
    Say "    $preview..."
}

# ─── Phase 5: Stop the broken process ────────────────────────────────

Step "Phase 5 - Stop the broken Claude Code process"

# Find Claude process by command line (requires WMI/CIM for full cmdline access)
$claudeProcs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match "claude.*--resume.*$SessionId" -or `
                   ($_.Name -eq "claude.exe" -and $_.CommandLine -match $SessionId) }

if (-not $claudeProcs) {
    Warn "No live Claude Code process found for session $SessionId"
    Warn "Either it was already killed, or it's not currently running."
    if (-not (Confirm-Action "Proceed with file swap anyway?")) {
        Err "Aborting. Session file is untouched."
        exit 0
    }
} else {
    Say "  Found process(es):"
    $claudeProcs | ForEach-Object { Say "    PID $($_.ProcessId): $($_.CommandLine)" }
    Say ""
    if (-not (Confirm-Action "Terminate the above process(es)?")) {
        Err "Aborting. Session file is untouched. Process(es) still alive."
        exit 0
    }
    if ($DryRun) {
        Warn "DRY-RUN: would Stop-Process for $($claudeProcs.ProcessId -join ', ')"
    } else {
        $claudeProcs | ForEach-Object {
            try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
        }
        Say "  Waiting up to 10s for shutdown..."
        for ($i = 1; $i -le 10; $i++) {
            Start-Sleep -Seconds 1
            $stillAlive = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -match "claude.*$SessionId" }
            if (-not $stillAlive) { break }
        }
        Ok "Process terminated."
    }
}

# ─── Phase 6: Swap the file ──────────────────────────────────────────

Step "Phase 6 - Swap the file"

if (-not (Confirm-Action "Replace $SessionFile with the truncated version?")) {
    Err "Aborting. Session file is UNTOUCHED. Truncated copy remains at $fixed."
    exit 0
}

if ($DryRun) {
    Warn "DRY-RUN: would copy $fixed -> $SessionFile"
} else {
    Copy-Item $fixed $SessionFile -Force
    $newLines = (Get-Content $SessionFile | Measure-Object -Line).Lines
    Ok "Session file replaced: $newLines lines"
}

# ─── Phase 7: Resume instructions ────────────────────────────────────

Step "Phase 7 - Resume the session"

$projectHash = Split-Path -Parent $SessionFile | Split-Path -Leaf
# Decode project hash heuristically
$decoded = ($projectHash -replace '^-', '') -replace '-', '\'
$decoded = "$decoded"

Say "  Project hash: $projectHash"
Say "  Session ID:   $SessionId"
Say ""
Say "  To resume, run from your original launch directory:"
Say ""
Say "    cd '$decoded'"
Say "    claude --resume $SessionId"
Say ""

Ok "Recovery complete."
Say ""
Say "Backups:"
Say "  Local:    $backup1"
Say "  Fixed:    $fixed"
Say "  Original was replaced with the truncated version."
Say ""
Say "After resume, send a test message like 'hello' to verify the bug is fixed."
Say ""
Say "If this helped, please add a +1 on GitHub issues #58427 and #59520"
Say "to help prioritize the upstream Anthropic patch."
