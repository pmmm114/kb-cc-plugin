#!/bin/bash
# error-reporter: Capture error stack and create structured GitHub issues.
# Pattern: synchronous snapshot (file reads) → fork (network I/O) → immediate exit 0.
# Output format follows the observation-log taxonomy (pmmm114/claude-harness-engineering#37).
# This script NEVER blocks the Claude Code hook chain.
#
# Self-test mode: `bash report.sh --self-test` runs a dependency/reachability
# probe with zero side effects — useful for on-call triage.
set +e

# --- Self-test: pure diagnostics, no side effects ---
if [ "${1:-}" = "--self-test" ]; then
  printf 'error-reporter self-test\n========================\n\n'
  printf 'dependencies:\n'
  if command -v jq >/dev/null 2>&1; then
    printf '  [ok]   jq: %s\n' "$(jq --version 2>/dev/null)"
  else
    printf '  [FAIL] jq: not found — error-reporter will exit 0 silently on all events\n'
  fi
  if command -v gh >/dev/null 2>&1; then
    printf '  [ok]   gh: %s\n' "$(gh --version 2>/dev/null | head -1)"
  else
    printf '  [WARN] gh: not found — fallback-only mode\n'
  fi
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    printf '  [ok]   gh auth: authenticated\n'
  else
    printf '  [WARN] gh auth: not authenticated — fallback-only mode\n'
  fi
  _SELF_TEST_REPO="pmmm114/claude-harness-engineering"
  if command -v gh >/dev/null 2>&1 && gh repo view "$_SELF_TEST_REPO" >/dev/null 2>&1; then
    printf '  [ok]   target repo reachable: %s\n' "$_SELF_TEST_REPO"
  else
    printf '  [WARN] target repo unreachable: %s\n' "$_SELF_TEST_REPO"
  fi
  _SELF_TEST_DATA="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/reports}"
  printf '\ndata dir:\n'
  if [ -d "$_SELF_TEST_DATA" ] && [ -w "$_SELF_TEST_DATA" ]; then
    printf '  [ok]   %s (writable)\n' "$_SELF_TEST_DATA"
  elif [ -d "$_SELF_TEST_DATA" ]; then
    printf '  [FAIL] %s (exists but not writable)\n' "$_SELF_TEST_DATA"
  else
    printf '  [warn] %s (will be created on first write)\n' "$_SELF_TEST_DATA"
  fi
  _SELF_TEST_LOG="$_SELF_TEST_DATA/logs/error-reporter.log"
  _SELF_TEST_REPORTS="$_SELF_TEST_DATA/reports"
  printf '\nrecent activity:\n'
  if [ -f "$_SELF_TEST_LOG" ]; then
    _SELF_TEST_LINES=$(wc -l < "$_SELF_TEST_LOG" 2>/dev/null | tr -d ' ')
    printf '  error-reporter.log: %s lines\n' "${_SELF_TEST_LINES:-0}"
    printf '  last 5 entries:\n'
    tail -5 "$_SELF_TEST_LOG" 2>/dev/null | sed 's/^/    /' || true
    printf '\n'
    _SELF_TEST_FAILS=$(grep -c 'status=fail' "$_SELF_TEST_LOG" 2>/dev/null || echo 0)
    _SELF_TEST_OKS=$(grep -c 'status=ok' "$_SELF_TEST_LOG" 2>/dev/null || echo 0)
    printf '  status tally: ok=%s fail=%s\n' "${_SELF_TEST_OKS:-0}" "${_SELF_TEST_FAILS:-0}"
  else
    printf '  error-reporter.log: missing (%s)\n' "$_SELF_TEST_LOG"
    printf '  note: empty log means the reporter has never run — not "healthy"\n'
  fi
  if [ -d "$_SELF_TEST_REPORTS" ]; then
    _SELF_TEST_REPORT_COUNT=$(find "$_SELF_TEST_REPORTS" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
    printf '  fallback .md reports: %s in %s\n' "${_SELF_TEST_REPORT_COUNT:-0}" "$_SELF_TEST_REPORTS"
  else
    printf '  fallback .md reports: dir absent\n'
  fi
  _SELF_TEST_MARKERS=$(find /tmp -maxdepth 1 -name 'claude-report-*.reported' -type f 2>/dev/null | wc -l | tr -d ' ')
  _SELF_TEST_LOCKS=$(find /tmp -maxdepth 1 -name 'claude-report-*.lock' -type d 2>/dev/null | wc -l | tr -d ' ')
  printf '  /tmp markers: %s reported, %s lockdirs\n' "${_SELF_TEST_MARKERS:-0}" "${_SELF_TEST_LOCKS:-0}"
  printf '\n(no side effects: no issues created, no files written)\n'
  exit 0
fi

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
# TRIGGER_HOOK: populated for Stop/SubagentStop from the last entry that
# survived EXPECTED_DENY_FILTER — i.e. the actual hook that tripped the
# incident threshold. Used by infer_domain(). Empty for StopFailure
# (the event isn't a hook deny, it's an upstream API error).
TRIGGER_HOOK=""
case "$EVENT" in
  StopFailure)
    SF_ERROR=$(echo "$INPUT" | jq -r '.error // ""')
    case "$SF_ERROR" in rate_limit|server_error) exit 0 ;; esac
    ;;
  Stop|SubagentStop)
    [ "$HAS_LOG" != true ] && exit 0
    # Exclude known-routine guard denies that fire as designed:
    #   - pre-edit-guard during planning/reviewing/plan_review (plan-before-act is working)
    #   - agent-dispatch-guard when routing user to /kb-harness entry (expected)
    #   - pr-template-guard when routing direct gh pr create to /pr skill (expected)
    #   - worktree-guard during config_* phases (first-edit redirect is expected)
    #   - guardian-worktree-guard (always a routing guard)
    # These are NOT hook failures; they are the harness guiding the user correctly.
    # Without this filter, every session that used /kb-harness or plan-before-act
    # would false-positive as an "incident" on the target repo (E4-F2 finding).
    EXPECTED_DENY_FILTER='
      select(.decision == "block" or .decision == "deny")
      | select(
          (
            (.hook // "") as $h |
            (.phase // "") as $p |
            (
              ($h == "pre-edit-guard.sh" and ($p == "planning" or $p == "reviewing" or $p == "plan_review" or $p == "config_planning" or $p == "config_plan_review" or $p == "config_editing"))
              or ($h == "agent-dispatch-guard.sh")
              or ($h == "pr-template-guard.sh")
              or ($h == "worktree-guard.sh" and ($p == "idle" or ($p | startswith("config_"))))
              or ($h == "guardian-worktree-guard.sh")
            )
          ) | not
        )
    '
    if [ "$EVENT" = "SubagentStop" ] && [ -n "$AGENT_ID" ]; then
      BLOCK_COUNT=$(jq -r --arg aid "$AGENT_ID" "$EXPECTED_DENY_FILTER | select(.agent_id == \$aid or .agent_id == null) | .decision" "$LOG_FILE" 2>/dev/null | wc -l | tr -d ' ')
      TRIGGER_HOOK=$(jq -r --arg aid "$AGENT_ID" "$EXPECTED_DENY_FILTER | select(.agent_id == \$aid or .agent_id == null) | .hook // empty" "$LOG_FILE" 2>/dev/null | tail -1)
    else
      BLOCK_COUNT=$(jq -r "$EXPECTED_DENY_FILTER | .decision" "$LOG_FILE" 2>/dev/null | wc -l | tr -d ' ')
      TRIGGER_HOOK=$(jq -r "$EXPECTED_DENY_FILTER | .hook // empty" "$LOG_FILE" 2>/dev/null | tail -1)
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

# --- Domain inference (issue #15 refactor) ---
#
# Classify the incident into a reporter:domain:* bucket. Two signals:
#
# 1. $AGENT_ID truthy → reporter:domain:agent. **No allowlist.** The harness
#    already gates which agent_id values reach a SubagentStop event via
#    subagent-validate.sh + settings.json hook matchers, so any value that
#    gets here is by definition a real agent invocation. Plugin-provided
#    agents (skill-creator's grader/comparator/analyzer, code-simplifier,
#    etc.) are handled automatically — no per-plugin update needed. This
#    replaces the earlier hardcoded `planner|tdd-implementer|config-*`
#    allowlist that had drifted from the real roster. See issue #15 and the
#    5-engineer review panel findings (Approach D).
#
# 2. $TRIGGER_HOOK = the single hook that tripped the threshold, extracted
#    from EXPECTED_DENY_FILTER | tail -1 (set in the case arm above). This
#    replaces the earlier "sort -u over all hooks + first match wins" logic,
#    which was alphabetically arbitrary and often misclassified incidents.
infer_domain() {
  [ -n "$AGENT_ID" ] && { echo "reporter:domain:agent"; return; }
  case "$TRIGGER_HOOK" in
    *config-worktree*|*config-agent*|*config-guardian*) echo "reporter:domain:hook"; return ;;
    *pre-edit*|*verify-before*|*pr-template*|*pr-review*) echo "reporter:domain:hook"; return ;;
    *delegation*|*subagent-validate*|*tdd-dispatch*) echo "reporter:domain:hook"; return ;;
    *session-recovery*|*state-recovery*|*compact*|*preflight*) echo "reporter:domain:infra"; return ;;
  esac
  echo "reporter:domain:hook"
}
DOMAIN=$(infer_domain)

# --- Agent field (issue #15 refactor) ---
# Trust $AGENT_ID verbatim — see infer_domain() comment. The existing
# ${AGENT_FIELD:+...} guards in the subshell handle the empty case naturally.
AGENT_FIELD="$AGENT_ID"

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

  # --- Always-local archive (E3-R6): write the fallback .md BEFORE attempting
  # gh so the observation body is retained even on gh success. If the target
  # repo is ever deleted/privated/rotated, the local archive remains. Storage
  # is cheap; post-hoc forensics are not. Also dramatically shortens the
  # failure path — if the local write is the only successful sink, the marker
  # is still touched and the session is dedup'd as usual.
  REPORT_DIR="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/reports}/reports"
  mkdir -p "$REPORT_DIR" 2>/dev/null || true
  # Subshell PID + epoch second: two failures in the same session within the
  # same second cannot collide (a real hazard under marker-gated retry).
  FALLBACK_FILE="$REPORT_DIR/${SESSION}-$(date +%s)-$$.md"
  LOCAL_OK=false
  if printf '%s\n' "$REPORT_BODY" > "$FALLBACK_FILE" 2>/dev/null; then
    chmod 600 "$FALLBACK_FILE" 2>/dev/null || true
    LOCAL_OK=true
  fi

  # --- Primary sink: gh issue create on the central observation-log repo ---
  GH_OK=false
  TS=$(date -u +%s)
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    # Pre-create required labels; gh exits non-zero if they already exist — suppressed via || true
    gh label create "type:incident" --description "Immediate response needed" --color "D73A4A" --repo "$REPORT_REPO" 2>/dev/null || true
    gh label create "auto:hook-failure" --description "Auto-generated by error-reporter" --color "EDEDED" --repo "$REPORT_REPO" 2>/dev/null || true
    gh label create "severity:$SEVERITY" --description "" --color "FFA500" --repo "$REPORT_REPO" 2>/dev/null || true
    gh label create "$DOMAIN" --description "Auto-inferred domain (error-reporter plugin)" --color "0E8A16" --repo "$REPORT_REPO" 2>/dev/null || true
    [ -n "$AGENT_FIELD" ] && gh label create "reporter:agent:${AGENT_FIELD}" --description "Agent scope (error-reporter plugin)" --color "1D76DB" --repo "$REPORT_REPO" 2>/dev/null || true

    LABELS="type:incident,auto:hook-failure,severity:${SEVERITY},${DOMAIN}"
    [ -n "$AGENT_FIELD" ] && LABELS="${LABELS},reporter:agent:${AGENT_FIELD}"

    # Capture stderr + exit status. On success log an audit breadcrumb
    # (empty log == reporter never ran, not "healthy" — disambiguating per
    # E3 review dissent); on failure log a structured diagnostic. The local
    # .md file above already archived the full body, so a gh failure here
    # never means observation loss (pmmm114/kb-cc-plugin#10).
    GH_STDERR=$(gh issue create \
      --repo "$REPORT_REPO" \
      --title "$TITLE" \
      --label "$LABELS" \
      --body "$REPORT_BODY" \
      2>&1 >/dev/null)
    GH_EXIT=$?
    if [ "$GH_EXIT" -eq 0 ]; then
      log_line "$(printf '[%s] status=ok event=%s sid=%s phase=%s agent=%s domain=%s commit=%s local=%s' \
        "$TS" "$EVENT" "$SESSION" "$PHASE" "${AGENT_FIELD:-none}" "$DOMAIN" "$TRIGGER_COMMIT" "$LOCAL_OK")"
      GH_OK=true
    else
      # Cap gh stderr to 512 bytes and normalize newlines so one failure
      # occupies one grep-able line that stays under PIPE_BUF (4096 B) for
      # atomic append under concurrent sessions.
      GH_STDERR_ONELINE=$(printf '%s' "$GH_STDERR" | tr '\n\r' '  ' | cut -c1-512)
      log_line "$(printf '[%s] status=fail event=%s sid=%s phase=%s agent=%s domain=%s commit=%s local=%s exit=%d stderr=%q' \
        "$TS" "$EVENT" "$SESSION" "$PHASE" "${AGENT_FIELD:-none}" "$DOMAIN" "$TRIGGER_COMMIT" "$LOCAL_OK" "$GH_EXIT" "$GH_STDERR_ONELINE")"
    fi
  fi

  # --- Session-dedup marker: touch if ANY sink succeeded. If BOTH gh and
  # local write failed, marker stays absent so the next event in the same
  # session retries instead of going silent for the rest of the session.
  if [ "$GH_OK" = true ] || [ "$LOCAL_OK" = true ]; then
    touch "$MARKER"
  fi
) &
disown

# === Immediate return — no blocking ===
exit 0
