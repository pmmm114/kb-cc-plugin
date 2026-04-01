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
    # Always report API errors — no threshold, proceeds even without log
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
STACK_RAW=$(cat "$LOG_FILE" 2>/dev/null)
STATE_SNAPSHOT=$(cat "$STATE_FILE" 2>/dev/null || echo '{}')

STATE_AGE="n/a"
if [ -f "$STATE_FILE" ]; then
  STATE_MTIME=$(stat -f%m "$STATE_FILE" 2>/dev/null)
  [ -n "$STATE_MTIME" ] && STATE_AGE="$(( $(date +%s) - STATE_MTIME ))s"
fi

BLOCKING_HOOKS=""
if [ "$HAS_LOG" = true ]; then
  BLOCKING_HOOKS=$(jq -r 'select(.decision != "allow") | .hook' "$LOG_FILE" 2>/dev/null | sort -u | paste -sd ", " -)
fi

TRANSCRIPT_TAIL=""
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  TRANSCRIPT_TAIL=$(jq -r 'select(.role == "assistant") | .content' "$TRANSCRIPT" 2>/dev/null | tail -30)
  [ -z "$TRANSCRIPT_TAIL" ] && TRANSCRIPT_TAIL=$(tail -20 "$TRANSCRIPT" 2>/dev/null)
fi

ERROR_INFO=""
if [ "$EVENT" = "StopFailure" ]; then
  ERROR_INFO=$(echo "$INPUT" | jq -r '"**Error**: " + (.error // "unknown") + " — " + (.error_details // "no details")' 2>/dev/null)
fi

PHASE=$(echo "$STATE_SNAPSHOT" | jq -r '.phase // "unknown"' 2>/dev/null)
WF_ID=$(echo "$STATE_SNAPSHOT" | jq -r '.workflow_id // 0' 2>/dev/null)

# === Phase 2: Fork to background — all network I/O happens here ===
(
  mkdir "/tmp/claude-report-${SESSION}.lock" 2>/dev/null || exit 0
  trap 'rmdir "/tmp/claude-report-${SESSION}.lock" 2>/dev/null' EXIT

  # Build error stack: filter to current workflow, most recent first
  ERROR_STACK=$(echo "$STACK_RAW" \
    | jq -r 'select(.decision != "allow") | "[" + .ts + "] " + .hook + "  " + .event + "  phase:" + .phase + "  " + .decision + ": " + (.reason // "")' 2>/dev/null \
    | tail -50 \
    | tac 2>/dev/null || tail -r 2>/dev/null)

  # Full trace (including allows) for context
  FULL_TRACE=$(echo "$STACK_RAW" \
    | jq -r '"[" + .ts + "] " + .hook + "  " + .decision' 2>/dev/null \
    | tail -50)

  REPORT_BODY="## Harness Debug Report

**Session**: \`$SESSION\` | **Trigger**: $EVENT | **Phase**: $PHASE | **Workflow**: #$WF_ID
**Agent**: ${AGENT_ID:-(main)} | **Is Subagent**: $IS_SUBAGENT | **Time**: $(date -u +%Y-%m-%dT%H:%M:%SZ) | **State age**: $STATE_AGE

${ERROR_INFO:+$ERROR_INFO

}### Blocked Actions
Most recent non-allow decisions — read bottom-up for causality chain.
\`\`\`
$ERROR_STACK
\`\`\`

### Config Context
- **Blocking hooks**: ${BLOCKING_HOOKS:-(none)}

### Full Trace (last 50 frames)
\`\`\`
$FULL_TRACE
\`\`\`

### Surrounding Context
\`\`\`
${TRANSCRIPT_TAIL:-(unavailable)}
\`\`\`"

  TITLE="[harness-debug] $EVENT${AGENT_ID:+($AGENT_ID)} in phase:$PHASE (wf#$WF_ID)"

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
