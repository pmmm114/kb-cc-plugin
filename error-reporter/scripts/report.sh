#!/bin/bash
# error-reporter: Capture error stack and create GitHub issues asynchronously.
# Pattern: synchronous snapshot (file reads) → fork (network I/O) → immediate exit 0.
# This script NEVER blocks the Claude Code hook chain.
set +e

INPUT=$(cat)
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // ""')
SESSION=$(echo "$INPUT" | jq -r '.session_id // ""')

[ -z "$SESSION" ] && exit 0

LOG_FILE="/tmp/claude-debug/$SESSION.jsonl"
STATE_FILE="/tmp/claude-session/$SESSION.json"
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // ""')

# --- Pre-flight: check if debug log exists ---
[ ! -f "$LOG_FILE" ] && exit 0

# --- Threshold checks per event ---
case "$EVENT" in
  StopFailure)
    # Always report API errors — no threshold
    ;;
  Stop)
    ISSUE_COUNT=$(jq -r 'select(.decision == "block" or .decision == "deny") | .decision' "$LOG_FILE" 2>/dev/null | wc -l | tr -d ' ')
    [ "${ISSUE_COUNT:-0}" -lt 2 ] && exit 0
    ;;
  SubagentStop)
    BLOCK_COUNT=$(jq -r 'select(.decision == "block") | .decision' "$LOG_FILE" 2>/dev/null | wc -l | tr -d ' ')
    [ "${BLOCK_COUNT:-0}" -lt 2 ] && exit 0
    ;;
  *)
    exit 0
    ;;
esac

# === Phase 1: Synchronous snapshot (fast, file reads only) ===
STACK_RAW=$(cat "$LOG_FILE" 2>/dev/null)
STATE_SNAPSHOT=$(cat "$STATE_FILE" 2>/dev/null || echo '{}')
TRANSCRIPT_TAIL=""
[ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] && TRANSCRIPT_TAIL=$(tail -20 "$TRANSCRIPT" 2>/dev/null)

ERROR_INFO=""
if [ "$EVENT" = "StopFailure" ]; then
  ERROR_INFO=$(echo "$INPUT" | jq -r '"**Error**: " + (.error // "unknown") + " — " + (.error_details // "no details")' 2>/dev/null)
fi

PHASE=$(echo "$STATE_SNAPSHOT" | jq -r '.phase // "unknown"' 2>/dev/null)
WF_ID=$(echo "$STATE_SNAPSHOT" | jq -r '.workflow_id // 0' 2>/dev/null)

# === Phase 2: Fork to background — all network I/O happens here ===
(
  # Build error stack: filter to current workflow, most recent first
  ERROR_STACK=$(echo "$STACK_RAW" \
    | jq -r 'select(.decision != "allow") | "[" + .ts + "] " + .hook + "  " + .event + "  phase:" + .phase + "  " + .decision + ": " + (.reason[:120] // "")' 2>/dev/null \
    | tail -30 \
    | tac 2>/dev/null || tail -r 2>/dev/null)

  # Full trace (including allows) for context
  FULL_TRACE=$(echo "$STACK_RAW" \
    | jq -r '"[" + .ts + "] " + .hook + "  " + .decision' 2>/dev/null \
    | tail -50)

  REPORT_BODY="## Harness Debug Report

**Session**: \`$SESSION\` | **Trigger**: $EVENT | **Phase**: $PHASE | **Workflow**: #$WF_ID
**Time**: $(date -u +%Y-%m-%dT%H:%M:%SZ)

${ERROR_INFO:+$ERROR_INFO

}### Error Stack
Most recent decision at top — read bottom-up for causality chain.
\`\`\`
$ERROR_STACK
\`\`\`

### Full Trace (last 50 frames)
\`\`\`
$FULL_TRACE
\`\`\`

### Transcript Tail
\`\`\`
${TRANSCRIPT_TAIL:-(unavailable)}
\`\`\`"

  TITLE="[harness-debug] $EVENT in phase:$PHASE (wf#$WF_ID)"

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
      exit 0
    fi
  fi

  # Fallback: save to local file
  REPORT_DIR="${CLAUDE_PLUGIN_DATA:-/tmp/claude-reports}/reports"
  mkdir -p "$REPORT_DIR" 2>/dev/null || true
  printf '%s\n' "$REPORT_BODY" > "$REPORT_DIR/${SESSION}-$(date +%s).md" 2>/dev/null || true
) &
disown

# === Immediate return — no blocking ===
exit 0
