#!/bin/bash
# error-reporter: Capture error stack and create structured GitHub issues.
# Pattern: synchronous snapshot (file reads) → fork (network I/O) → immediate exit 0.
# Output format follows the observation-log taxonomy (pmmm114/claude-harness-engineering#37).
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

# --- Pre-flight: check if debug log exists ---
HAS_LOG=false
[ -f "$LOG_FILE" ] && HAS_LOG=true

# --- Threshold checks per event ---
case "$EVENT" in
  StopFailure)
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
PHASE=$(echo "$STATE_SNAPSHOT" | jq -r '.phase // "unknown"')
TRIGGER_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
DEBUG_LOG_TAIL=$(tail -50 "$LOG_FILE" 2>/dev/null)
TRANSCRIPT_TAIL=""
[ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] && TRANSCRIPT_TAIL=$(tail -20 "$TRANSCRIPT" 2>/dev/null)

# --- Severity classification ---
# StopFailure → A1 (coordination failure — session ended abnormally)
# Stop with block/deny → A2 (guard recovered — hooks caught the problem)
# SubagentStop with block/deny → A2 (guard recovered)
# Timeout errors → A3 (resource exceeded)
SEVERITY="A2-guard-recovered"
case "$EVENT" in
  StopFailure)
    if echo "$SF_ERROR" | grep -qi 'timeout'; then
      SEVERITY="A3-resource"
    else
      SEVERITY="A1-coordination"
    fi
    ;;
esac

# --- Domain inference from debug log hook names ---
# Maps hook script names to their domain
infer_domain() {
  local hooks=""
  if [ "$HAS_LOG" = true ]; then
    hooks=$(jq -r '.hook // empty' "$LOG_FILE" 2>/dev/null | sort -u)
  fi
  # Also check agent_id for agent-domain mapping
  case "$AGENT_ID" in
    planner|tdd-implementer)       echo "domain:agent"; return ;;
    config-planner|config-editor)  echo "domain:agent"; return ;;
    config-guardian)               echo "domain:agent"; return ;;
  esac
  # Map hook names to domains
  for h in $hooks; do
    case "$h" in
      *config-worktree*|*config-agent*|*config-guardian*) echo "domain:hook"; return ;;
      *pre-edit*|*verify-before*|*pr-template*|*pr-review*) echo "domain:hook"; return ;;
      *delegation*|*subagent-validate*|*tdd-dispatch*) echo "domain:hook"; return ;;
      *session-recovery*|*state-recovery*|*compact*|*preflight*) echo "domain:infra"; return ;;
    esac
  done
  echo "domain:hook"
}
DOMAIN=$(infer_domain)

# --- Agent field ---
AGENT_FIELD=""
case "$AGENT_ID" in
  planner|tdd-implementer|config-planner|config-editor|config-guardian)
    AGENT_FIELD="$AGENT_ID"
    ;;
esac

# === Phase 2: Fork to background — all network I/O happens here ===
(
  LOCK_DIR="/tmp/claude-report-${SESSION}.lock"
  # Stale-lock reclamation: SIGKILL / OOM / host crash can leave the lockdir
  # behind — because it's keyed on $SESSION, every subsequent invocation in
  # the same session would `exit 0` at this point and re-introduce the very
  # silent-loss class this script is meant to fix. Reclaim if >5 min old.
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    if [ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +5 2>/dev/null)" ]; then
      rmdir "$LOCK_DIR" 2>/dev/null
      mkdir "$LOCK_DIR" 2>/dev/null || exit 0
    else
      exit 0
    fi
  fi
  trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

  # Opportunistic sweep of leftovers from crashed sessions on long-lived hosts
  # (macOS does not auto-purge /tmp). 7-day TTL matches harness handoff-history.
  find /tmp -maxdepth 1 \( -name 'claude-report-*.lock' -o -name 'claude-report-*.reported' \) -mtime +7 -exec rm -rf {} + 2>/dev/null || true

  TITLE="[incident] $EVENT${AGENT_ID:+($AGENT_ID)} (${SESSION:0:8})"

  REPORT_BODY="## Observation

**Event**: \`$EVENT\`${AGENT_ID:+ | **Agent**: \`$AGENT_ID\`}
**Session ID**: \`${SESSION:0:8}\`
**Phase**: \`$PHASE\`
**Trigger Commit**: \`$TRIGGER_COMMIT\`
**Severity**: \`$SEVERITY\`
**Reproducibility**: observed once

${EVENT} event fired during phase \`$PHASE\`.${AGENT_FIELD:+ Agent \`$AGENT_FIELD\` was active.}

## Counterfactual

<!-- What SHOULD have happened — fill in manually to make this observation actionable -->

## Evidence

### Debug Log (last 50 lines)
\`\`\`
${DEBUG_LOG_TAIL:-(unavailable)}
\`\`\`

### Transcript (last 20 lines)
\`\`\`
${TRANSCRIPT_TAIL:-(unavailable)}
\`\`\`

### State Snapshot
\`\`\`json
${STATE_SNAPSHOT:-(unavailable)}
\`\`\`

### Hook Input
\`\`\`json
$INPUT
\`\`\`

## Hypothesis

<!-- Suspected root cause — fill in manually -->"

  REPORT_REPO="pmmm114/claude-harness-engineering"

  # --- Diagnostic log (error-reporter.log) configuration ---
  ERROR_LOG_MAX=1000
  ERROR_LOG_KEEP=500
  ERROR_LOG_DIR="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/reports}/logs"
  ERROR_LOG_FILE="$ERROR_LOG_DIR/error-reporter.log"

  # log_line <line> — append to error-reporter.log with a first-line-preserving
  # ring-buffer trim, 0600 perm hardening (gh stderr can contain auth token
  # fragments on some failure modes), and a $$-scoped temp file to avoid
  # cross-session races on the trim step.
  log_line() {
    mkdir -p "$ERROR_LOG_DIR" 2>/dev/null || return
    printf '%s\n' "$1" >> "$ERROR_LOG_FILE" 2>/dev/null || return
    chmod 600 "$ERROR_LOG_FILE" 2>/dev/null || true
    local n
    # BSD wc (macOS) prints leading whitespace — tr -d ' ' is load-bearing
    # here, not cosmetic. Without it `[ "   104" -gt 1000 ]` throws and the
    # ring buffer silently disables on macOS.
    n=$(wc -l < "$ERROR_LOG_FILE" 2>/dev/null | tr -d ' ')
    if [ "${n:-0}" -gt "$ERROR_LOG_MAX" ]; then
      { head -1 "$ERROR_LOG_FILE"; tail -$((ERROR_LOG_KEEP - 1)) "$ERROR_LOG_FILE"; } \
        > "${ERROR_LOG_FILE}.$$.tmp" 2>/dev/null \
        && mv "${ERROR_LOG_FILE}.$$.tmp" "$ERROR_LOG_FILE" 2>/dev/null
    fi
  }

  # Ensure required labels exist, then create issue
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    # Pre-create required labels; gh exits non-zero if they already exist — suppressed via || true
    gh label create "type:incident" --description "Immediate response needed" --color "D73A4A" --repo "$REPORT_REPO" 2>/dev/null || true
    gh label create "auto:hook-failure" --description "Auto-generated by error-reporter" --color "EDEDED" --repo "$REPORT_REPO" 2>/dev/null || true
    gh label create "severity:$SEVERITY" --description "" --color "FFA500" --repo "$REPORT_REPO" 2>/dev/null || true
    gh label create "$DOMAIN" --description "Auto-inferred domain" --color "0E8A16" --repo "$REPORT_REPO" 2>/dev/null || true
    [ -n "$AGENT_FIELD" ] && gh label create "agent:${AGENT_FIELD}" --description "Agent scope" --color "1D76DB" --repo "$REPORT_REPO" 2>/dev/null || true

    LABELS="type:incident,auto:hook-failure,severity:${SEVERITY},${DOMAIN}"
    [ -n "$AGENT_FIELD" ] && LABELS="${LABELS},agent:${AGENT_FIELD}"

    # Capture stderr + exit status. On success log an audit breadcrumb
    # (empty log == reporter never ran, not "healthy" — disambiguating per
    # E3 review dissent); on failure log a structured diagnostic and fall
    # through to the local-file fallback so the observation is never
    # silently lost (pmmm114/kb-cc-plugin#10).
    GH_STDERR=$(gh issue create \
      --repo "$REPORT_REPO" \
      --title "$TITLE" \
      --label "$LABELS" \
      --body "$REPORT_BODY" \
      2>&1 >/dev/null)
    GH_EXIT=$?
    TS=$(date -u +%s)
    if [ "$GH_EXIT" -eq 0 ]; then
      log_line "$(printf '[%s] status=ok event=%s sid=%s phase=%s agent=%s domain=%s commit=%s' \
        "$TS" "$EVENT" "$SESSION" "$PHASE" "${AGENT_FIELD:-none}" "$DOMAIN" "$TRIGGER_COMMIT")"
      touch "$MARKER"
      exit 0
    fi
    # Cap gh stderr to 512 bytes and normalize newlines so one failure
    # occupies one grep-able line that stays under PIPE_BUF (4096 B) for
    # atomic append under concurrent sessions.
    GH_STDERR_ONELINE=$(printf '%s' "$GH_STDERR" | tr '\n\r' '  ' | cut -c1-512)
    log_line "$(printf '[%s] status=fail event=%s sid=%s phase=%s agent=%s domain=%s commit=%s exit=%d stderr=%q' \
      "$TS" "$EVENT" "$SESSION" "$PHASE" "${AGENT_FIELD:-none}" "$DOMAIN" "$TRIGGER_COMMIT" "$GH_EXIT" "$GH_STDERR_ONELINE")"
  fi

  # Fallback: save to local file (reached when gh is unavailable OR gh failed).
  # Marker is only touched on a successful write — if BOTH gh and local write
  # fail, leave the marker absent so the next event in the same session can
  # retry instead of going silent for the rest of the session.
  REPORT_DIR="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/reports}/reports"
  mkdir -p "$REPORT_DIR" 2>/dev/null || true
  # Subshell PID in the filename prevents two failures in the same session +
  # same epoch second from clobbering each other. With marker-gated retries
  # on double-failure, this path is hit more often than pre-PR, so the 1-sec
  # resolution collision E1/E2 review flagged is now a real data-loss vector.
  FALLBACK_FILE="$REPORT_DIR/${SESSION}-$(date +%s)-$$.md"
  if printf '%s\n' "$REPORT_BODY" > "$FALLBACK_FILE" 2>/dev/null; then
    chmod 600 "$FALLBACK_FILE" 2>/dev/null || true
    touch "$MARKER"
  fi
) &
disown

# === Immediate return — no blocking ===
exit 0
