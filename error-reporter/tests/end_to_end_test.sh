#!/bin/bash
# error-reporter end-to-end smoke test.
#
# Covers the full pipeline (threshold → phase 1 → fork → fallback write) with
# synthetic hook input, a fake gh that always fails (so no real GitHub
# interaction), and a temp CLAUDE_PLUGIN_DATA. Designed to run in CI with
# zero external dependencies beyond jq and bash.
#
# Key invariants verified:
# 1. `--self-test` runs cleanly and reports no side effects.
# 2. Known harness agent_id ("editor") flows through the SubagentStop path
#    and lands in the fallback report body.
# 3. **Issue #15 Approach D**: plugin-provided / unknown agent_id ("grader")
#    flows through identically — no allowlist, no special-casing. Regression
#    fence for the drift class the refactor removed.

set +e
cd "$(dirname "$0")/../.." || exit 1
SCRIPT="$(pwd)/error-reporter/scripts/report.sh"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

# --- Helpers ---

make_fake_gh() {
  # $1 = bin dir. Creates a gh stub that reports "authenticated" for
  # `gh auth status` but FAILS every mutating call (`issue create`,
  # `label create`). This exercises the realistic failure mode: gh is
  # installed and auth'd but a specific command fails — which is the
  # path that triggers error-reporter.log entries. Never touches real
  # GitHub.
  mkdir -p "$1"
  cat > "$1/gh" <<'GH'
#!/bin/bash
case "$1" in
  auth)
    # `gh auth status` — pretend authenticated so the script enters
    # the primary-sink block and then hits our forced issue-create failure.
    exit 0
    ;;
  issue|label|repo)
    # issue create / label create / repo view — force failure with a
    # recognizable stderr line so the log entry is easy to grep.
    echo "smoke-test fake gh $*: forced failure" >&2
    exit 1
    ;;
  *)
    echo "smoke-test fake gh: unhandled subcommand $*" >&2
    exit 1
    ;;
esac
GH
  chmod +x "$1/gh"
}

make_synthetic_debug_log() {
  # $1 = session id, $2 = agent_id (may be empty). Creates a jsonl with one
  # deny entry from verify-before-done.sh (survives EXPECTED_DENY_FILTER
  # because neither the hook nor the phase match any routine-deny rule).
  mkdir -p /tmp/claude-debug
  printf '{"ts":"2026-04-14T00:00:00Z","event":"PreToolUse","hook":"verify-before-done.sh","decision":"deny","reason":"synthetic smoke test","phase":"verifying","session":"%s","agent_id":"%s"}\n' \
    "$1" "$2" > "/tmp/claude-debug/$1.jsonl"
}

wait_for_background() {
  # $1 = session id. Polls for the session marker file to appear — that's
  # the LAST side effect of the backgrounded subshell (touched after the
  # fallback .md write succeeds). Cannot use lockdir disappearance because
  # there's a race: lockdir may not even exist yet when polling starts.
  local marker="/tmp/claude-report-$1.reported"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "$marker" ] && return 0
    sleep 1
  done
  return 1
}

cleanup_session() {
  # $1 = session id, $2 = test data dir
  rm -rf "$2" \
    "/tmp/claude-report-$1.reported" \
    "/tmp/claude-report-$1.lock" \
    "/tmp/claude-debug/$1.jsonl"
}

run_synthetic_subagent_stop() {
  # $1 = agent_id, $2 = out var for SID, $3 = out var for TEST_DATA,
  # $4 = out var for FALLBACK_FILE path.
  local agent="$1"
  local sid
  local td
  sid="smoke-$$-$(date +%s)-${agent}"
  td=$(mktemp -d "/tmp/er-smoke-XXXXXX")

  make_fake_gh "$td/bin"
  make_synthetic_debug_log "$sid" "$agent"

  local input
  input=$(printf '{"hook_event_name":"SubagentStop","session_id":"%s","agent_id":"%s","transcript_path":""}' "$sid" "$agent")

  CLAUDE_PLUGIN_DATA="$td" PATH="$td/bin:$PATH" \
    bash -c "printf '%s' '$input' | bash '$SCRIPT'"

  wait_for_background "$sid"

  local fallback
  fallback=$(ls "$td/reports/${sid}-"*".md" 2>/dev/null | head -1)

  printf -v "$2" '%s' "$sid"
  printf -v "$3" '%s' "$td"
  printf -v "$4" '%s' "$fallback"
}

# --- Test 1: --self-test diagnostic mode ---
printf 'Test 1: --self-test runs cleanly with zero side effects\n'
OUT=$(bash "$SCRIPT" --self-test 2>&1)
RC=$?
[ "$RC" -eq 0 ] && pass "exit 0" || fail "exit $RC"
printf '%s\n' "$OUT" | grep -q "error-reporter self-test" && pass "header present" || fail "header missing"
printf '%s\n' "$OUT" | grep -q "no side effects" && pass "no-side-effects banner" || fail "no-side-effects missing"

# --- Test 2: SubagentStop with known harness agent_id=editor ---
printf '\nTest 2: SubagentStop + agent_id=editor (known harness agent)\n'
SID=""; TEST_DATA=""; FALLBACK_FILE=""
run_synthetic_subagent_stop "editor" SID TEST_DATA FALLBACK_FILE

if [ -n "$FALLBACK_FILE" ] && [ -f "$FALLBACK_FILE" ]; then
  pass "fallback .md written"
  grep -q '\*\*Agent\*\*: `editor`' "$FALLBACK_FILE" && pass "body has Agent=editor" || fail "body missing Agent=editor"
  grep -q 'SubagentStop' "$FALLBACK_FILE" && pass "body has SubagentStop event" || fail "body missing event name"
else
  fail "no fallback .md created"
fi

LOG_FILE="$TEST_DATA/logs/error-reporter.log"
if [ -f "$LOG_FILE" ]; then
  grep -q 'status=fail' "$LOG_FILE" && pass "error-reporter.log has status=fail (gh fake failed)" || fail "no status=fail in log"
  grep -q "sid=$SID" "$LOG_FILE" && pass "log entry matches session" || fail "log entry missing sid"
else
  fail "error-reporter.log not created"
fi

[ -f "/tmp/claude-report-$SID.reported" ] && pass "session marker touched" || fail "no marker"

cleanup_session "$SID" "$TEST_DATA"

# --- Test 3: Approach D regression fence — plugin-provided agent_id=grader ---
printf '\nTest 3: SubagentStop + agent_id=grader (plugin-provided, Approach D)\n'
SID=""; TEST_DATA=""; FALLBACK_FILE=""
run_synthetic_subagent_stop "grader" SID TEST_DATA FALLBACK_FILE

if [ -n "$FALLBACK_FILE" ] && [ -f "$FALLBACK_FILE" ]; then
  grep -q '\*\*Agent\*\*: `grader`' "$FALLBACK_FILE" \
    && pass "plugin-provided agent_id flows through to body (Approach D)" \
    || fail "plugin-provided agent_id=grader NOT in body — Approach D regression"
else
  fail "no fallback .md for grader test"
fi

cleanup_session "$SID" "$TEST_DATA"

# --- Test 4: StopFailure (no debug log required) ---
printf '\nTest 4: StopFailure with synthetic error (no debug log path)\n'
SID="smoke-sf-$$-$(date +%s)"
TEST_DATA=$(mktemp -d "/tmp/er-smoke-XXXXXX")
make_fake_gh "$TEST_DATA/bin"
INPUT=$(printf '{"hook_event_name":"StopFailure","session_id":"%s","error":"synthetic_smoke_error"}' "$SID")

CLAUDE_PLUGIN_DATA="$TEST_DATA" PATH="$TEST_DATA/bin:$PATH" \
  bash -c "printf '%s' '$INPUT' | bash '$SCRIPT'"

wait_for_background "$SID"

FALLBACK_FILE=$(ls "$TEST_DATA/reports/${SID}-"*".md" 2>/dev/null | head -1)
if [ -n "$FALLBACK_FILE" ] && [ -f "$FALLBACK_FILE" ]; then
  pass "StopFailure fallback .md written"
  grep -q 'A1-coordination' "$FALLBACK_FILE" && pass "severity=A1-coordination" || fail "severity missing"
else
  fail "no StopFailure fallback .md"
fi

cleanup_session "$SID" "$TEST_DATA"

# --- Summary ---
printf '\nSummary: %d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
else
  exit 1
fi
