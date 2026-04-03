#!/bin/bash
# error-reporter: Capture error stack and create GitHub issues asynchronously.
# Pattern: synchronous snapshot (file reads) → fork (network I/O) → immediate exit 0.
# This script NEVER blocks the Claude Code hook chain.
set +e

command -v jq >/dev/null 2>&1 || { echo "error-reporter: jq not found" >&2; exit 0; }

INPUT=$(cat)
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // ""')
SESSION=$(echo "$INPUT" | jq -r '.session_id // ""')

[ -z "$SESSION" ] && exit 0

MARKER="/tmp/claude-report-${SESSION}.reported"
[ -f "$MARKER" ] && exit 0

LOG_FILE="/tmp/claude-debug/$SESSION.jsonl"
STATE_FILE="/tmp/claude-session/$SESSION.json"
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // ""')
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // ""')
IS_SUBAGENT=$(echo "$INPUT" | jq -r '.is_subagent // false')

# --- Pre-flight: check if debug log exists ---
HAS_LOG=false
[ -f "$LOG_FILE" ] && HAS_LOG=true

# --- Threshold checks per event ---
case "$EVENT" in
  StopFailure)
    # Filter transient errors — not harness bugs, just provider-side noise
    SF_ERROR=$(echo "$INPUT" | jq -r '.error // ""')
    case "$SF_ERROR" in rate_limit|server_error) exit 0 ;; esac
    ;;
  Stop)
    [ "$HAS_LOG" != true ] && exit 0
    ISSUE_COUNT=$(jq -r 'select(.decision == "block" or .decision == "deny") | .decision' "$LOG_FILE" 2>/dev/null | wc -l | tr -d ' ')
    [ "${ISSUE_COUNT:-0}" -lt 1 ] && exit 0
    ;;
  SubagentStop)
    [ "$HAS_LOG" != true ] && exit 0
    if [ -n "$AGENT_ID" ]; then
      BLOCK_COUNT=$(jq -r --arg aid "$AGENT_ID" 'select(.decision == "block" or .decision == "deny") | select(.agent_id == $aid or .agent_id == null) | .decision' "$LOG_FILE" 2>/dev/null | wc -l | tr -d ' ')
    else
      BLOCK_COUNT=$(jq -r 'select(.decision == "block" or .decision == "deny") | .decision' "$LOG_FILE" 2>/dev/null | wc -l | tr -d ' ')
    fi
    [ "${BLOCK_COUNT:-0}" -lt 1 ] && exit 0
    ;;
  *)
    exit 0
    ;;
esac

# === Phase 1: Synchronous snapshot (fast, file reads only) ===
STATE_SNAPSHOT=$(cat "$STATE_FILE" 2>/dev/null || echo '{}')
DEBUG_LOG_TAIL=$(tail -50 "$LOG_FILE" 2>/dev/null)
TRANSCRIPT_TAIL=""
[ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] && TRANSCRIPT_TAIL=$(tail -20 "$TRANSCRIPT" 2>/dev/null)

# === Phase 2: Fork to background — all network I/O happens here ===
(
  mkdir "/tmp/claude-report-${SESSION}.lock" 2>/dev/null || exit 0
  trap 'rmdir "/tmp/claude-report-${SESSION}.lock" 2>/dev/null' EXIT

  TITLE="[harness-debug] $EVENT (${SESSION:0:8})"

  REPORT_BODY="## Raw State
\`\`\`json
${STATE_SNAPSHOT:-(unavailable)}
\`\`\`

## Debug Log (last 50)
\`\`\`
${DEBUG_LOG_TAIL:-(unavailable)}
\`\`\`

## Transcript (last 20 lines)
\`\`\`
${TRANSCRIPT_TAIL:-(unavailable)}
\`\`\`

## Hook Input
\`\`\`json
$INPUT
\`\`\`"

  # Attempt GitHub issue creation
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null)
    if [ -n "$REPO" ]; then
      gh issue create \
        --repo "$REPO" \
        --title "$TITLE" \
        --label "harness-debug" \
        --body "$REPORT_BODY" \
        >/dev/null 2>&1 || true
      touch "$MARKER"
      exit 0
    fi
  fi

  # Fallback: save to local file
  REPORT_DIR="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/reports}/reports"
  mkdir -p "$REPORT_DIR" 2>/dev/null || true
  printf '%s\n' "$REPORT_BODY" > "$REPORT_DIR/${SESSION}-$(date +%s).md" 2>/dev/null || true
  touch "$MARKER"
) &
disown

# === Immediate return — no blocking ===
exit 0
