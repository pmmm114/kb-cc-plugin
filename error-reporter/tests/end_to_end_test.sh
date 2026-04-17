#!/bin/bash
# error-reporter end-to-end smoke test — v3.1 decoupled edition.
#
# All tests MUST use per-test isolated $CLAUDE_PLUGIN_DATA via mktemp -d (E7).
# All tests except 10 and 12e export CLAUDE_PLUGIN_ROOT="$REPO_ROOT/error-reporter"
# so the claude-harness preset can be loaded when needed (C3).
#
# Test 5 pre-touches $MARKER_DIR/.v3.1-opt-in-notice.ack to isolate the
# generic-no-op assertion from the T13 opt-in-notice side effect.
# Test 11 is the ONLY test that exercises the fresh opt-in-notice path.
# Test 10 must run last — it manipulates CLAUDE_PLUGIN_ROOT in a subshell.

set +e
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/error-reporter/scripts/report.sh"
PLUGIN_ROOT="$REPO_ROOT/error-reporter"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

# --- Helpers ---

make_fake_gh() {
  # $1 = bin dir. Creates a gh stub that reports "authenticated" but FAILS
  # every mutating call. Simulates "installed + auth'd but command-specific
  # failure" — the realistic failure mode that triggers error-reporter.log.
  mkdir -p "$1"
  cat > "$1/gh" <<'GH'
#!/bin/bash
case "$1" in
  auth) exit 0 ;;
  issue|label|repo)
    echo "smoke-test fake gh $*: forced failure" >&2
    exit 1
    ;;
  *) echo "smoke-test fake gh: unhandled subcommand $*" >&2; exit 1 ;;
esac
GH
  chmod +x "$1/gh"
}

make_fake_gh_fatal() {
  # $1 = bin dir. For tests where gh MUST NOT be called (gh-skip path).
  # Any invocation touches a sentinel file so the test can assert non-call.
  mkdir -p "$1"
  cat > "$1/gh" <<GH
#!/bin/bash
touch "$1/../gh-was-called"
echo "FATAL: real gh should not be called" >&2
exit 1
GH
  chmod +x "$1/gh"
}

make_synthetic_debug_log() {
  # $1 = session id, $2 = agent_id (may be empty).
  mkdir -p /tmp/claude-debug
  printf '{"ts":"2026-04-16T00:00:00Z","event":"PreToolUse","hook":"verify-before-done.sh","decision":"deny","reason":"synthetic smoke test","phase":"verifying","session":"%s","agent_id":"%s"}\n' \
    "$1" "$2" > "/tmp/claude-debug/$1.jsonl"
}

wait_for_background() {
  # $1 = session id, $2 = marker dir. Polls for marker file appearance.
  local marker="$2/$1.reported"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "$marker" ] && return 0
    sleep 1
  done
  return 1
}

cleanup_session() {
  # $1 = session id, $2 = test data dir
  rm -rf "$2" "/tmp/claude-debug/$1.jsonl"
}

# --- Test 1 (migrated): --self-test diagnostic mode with preset ---
printf 'Test 1: --self-test runs cleanly with preset loaded and configured repo\n'
TD=$(mktemp -d "/tmp/er-smoke-XXXXXX")
OUT=$(CLAUDE_PLUGIN_DATA="$TD" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  ERROR_REPORTER_PRESET=claude-harness ERROR_REPORTER_REPO=dummy/repo \
  bash "$SCRIPT" --self-test 2>&1)
RC=$?
[ "$RC" -eq 0 ] && pass "T1 exit 0" || fail "T1 exit $RC"
printf '%s\n' "$OUT" | grep -q "error-reporter self-test" && pass "T1 header present" || fail "T1 header missing"
printf '%s\n' "$OUT" | grep -q "no side effects" && pass "T1 no-side-effects banner" || fail "T1 no-side-effects missing"
printf '%s\n' "$OUT" | grep -qF '[ok]   preset: claude-harness (loaded)' && pass "T1 preset loaded line" || fail "T1 preset loaded line"
# gh stub not in PATH for this test — real gh may or may not reach dummy/repo
# So we only check the prefix, not reachable vs unreachable
printf '%s\n' "$OUT" | grep -qE 'target repo: dummy/repo \(source=env, (reachable|\?)\)|target repo unreachable: dummy/repo \(source=env\)' && pass "T1 target repo line" || fail "T1 target repo line"
rm -rf "$TD"

# --- Test 2 (migrated): SubagentStop + agent_id=editor (preset mode) ---
printf '\nTest 2: SubagentStop + agent_id=editor (preset mode)\n'
SID="smoke-$$-$(date +%s)-editor"
TD=$(mktemp -d "/tmp/er-smoke-XXXXXX")
mkdir -p "$TD/markers"
touch "$TD/markers/.v3.1-opt-in-notice.ack"
make_fake_gh "$TD/bin"
make_synthetic_debug_log "$SID" "editor"

INPUT=$(printf '{"hook_event_name":"SubagentStop","session_id":"%s","agent_id":"editor","transcript_path":""}' "$SID")
CLAUDE_PLUGIN_DATA="$TD" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  ERROR_REPORTER_PRESET=claude-harness ERROR_REPORTER_REPO=dummy/repo \
  PATH="$TD/bin:$PATH" \
  bash -c "printf '%s' '$INPUT' | bash '$SCRIPT'"

wait_for_background "$SID" "$TD/markers"

FALLBACK_FILE=$(ls "$TD/reports/${SID}-"*".md" 2>/dev/null | head -1)
if [ -n "$FALLBACK_FILE" ] && [ -f "$FALLBACK_FILE" ]; then
  pass "T2 fallback .md written"
  grep -q '\*\*Agent\*\*: `editor`' "$FALLBACK_FILE" && pass "T2 body has Agent=editor" || fail "T2 body missing Agent=editor"
  grep -q 'SubagentStop' "$FALLBACK_FILE" && pass "T2 body has SubagentStop event" || fail "T2 body missing event"
  grep -q 'A2-guard-recovered' "$FALLBACK_FILE" && pass "T2 severity=A2-guard-recovered (preset)" || fail "T2 severity"
else
  fail "T2 no fallback .md"
fi

LOG_FILE="$TD/logs/error-reporter.log"
[ -f "$LOG_FILE" ] && grep -q 'status=fail' "$LOG_FILE" && pass "T2 error-reporter.log status=fail (fake gh)" || fail "T2 no status=fail in log"
[ -f "$TD/markers/$SID.reported" ] && pass "T2 session marker touched" || fail "T2 no marker"
cleanup_session "$SID" "$TD"

# --- Test 3 (migrated): Approach D regression — agent_id=grader ---
printf '\nTest 3: SubagentStop + agent_id=grader (Approach D, preset mode)\n'
SID="smoke-$$-$(date +%s)-grader"
TD=$(mktemp -d "/tmp/er-smoke-XXXXXX")
mkdir -p "$TD/markers"
touch "$TD/markers/.v3.1-opt-in-notice.ack"
make_fake_gh "$TD/bin"
make_synthetic_debug_log "$SID" "grader"

INPUT=$(printf '{"hook_event_name":"SubagentStop","session_id":"%s","agent_id":"grader","transcript_path":""}' "$SID")
CLAUDE_PLUGIN_DATA="$TD" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  ERROR_REPORTER_PRESET=claude-harness ERROR_REPORTER_REPO=dummy/repo \
  PATH="$TD/bin:$PATH" \
  bash -c "printf '%s' '$INPUT' | bash '$SCRIPT'"

wait_for_background "$SID" "$TD/markers"
FALLBACK_FILE=$(ls "$TD/reports/${SID}-"*".md" 2>/dev/null | head -1)
if [ -n "$FALLBACK_FILE" ] && [ -f "$FALLBACK_FILE" ]; then
  grep -q '\*\*Agent\*\*: `grader`' "$FALLBACK_FILE" \
    && pass "T3 plugin-provided agent_id flows through (Approach D)" \
    || fail "T3 Approach D regression"
else
  fail "T3 no fallback .md"
fi
cleanup_session "$SID" "$TD"

# --- Test 4 (migrated): StopFailure in preset mode ---
printf '\nTest 4: StopFailure with synthetic error (preset mode)\n'
SID="smoke-sf-$$-$(date +%s)"
TD=$(mktemp -d "/tmp/er-smoke-XXXXXX")
mkdir -p "$TD/markers"
touch "$TD/markers/.v3.1-opt-in-notice.ack"
make_fake_gh "$TD/bin"
INPUT=$(printf '{"hook_event_name":"StopFailure","session_id":"%s","error":"synthetic_smoke_error"}' "$SID")

CLAUDE_PLUGIN_DATA="$TD" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  ERROR_REPORTER_PRESET=claude-harness ERROR_REPORTER_REPO=dummy/repo \
  PATH="$TD/bin:$PATH" \
  bash -c "printf '%s' '$INPUT' | bash '$SCRIPT'"

wait_for_background "$SID" "$TD/markers"
FALLBACK_FILE=$(ls "$TD/reports/${SID}-"*".md" 2>/dev/null | head -1)
if [ -n "$FALLBACK_FILE" ] && [ -f "$FALLBACK_FILE" ]; then
  pass "T4 StopFailure fallback .md written"
  grep -q 'A1-coordination' "$FALLBACK_FILE" && pass "T4 severity=A1-coordination (preset)" || fail "T4 severity"
else
  fail "T4 no StopFailure fallback .md"
fi
cleanup_session "$SID" "$TD"

# --- Test 5: Generic no-op (no preset, third-party payload) ---
printf '\nTest 5: generic no-op Stop — no preset, ack pre-touched, third-party agent\n'
SID=$(uuidgen 2>/dev/null || printf 'gen-%s-%s' "$$" "$(date +%s)")
TD=$(mktemp -d "/tmp/er-smoke-XXXXXX")
mkdir -p "$TD/markers" "$TD/reports"
touch "$TD/markers/.v3.1-opt-in-notice.ack"   # E1: suppress T13 upgrade-notice
INPUT=$(printf '{"hook_event_name":"Stop","session_id":"%s","agent_id":"third-party-bot","transcript_path":""}' "$SID")

CLAUDE_PLUGIN_DATA="$TD" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  bash -c "unset ERROR_REPORTER_PRESET ERROR_REPORTER_REPO; printf '%s' '$INPUT' | bash '$SCRIPT'"

sleep 1  # allow any stray background work
MD_COUNT=$(find "$TD/reports" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
[ "$MD_COUNT" -eq 0 ] && pass "T5 no fallback .md generated" || fail "T5 unexpected .md files ($MD_COUNT)"
[ ! -f "$TD/markers/$SID.reported" ] && pass "T5 session marker NOT touched" || fail "T5 marker unexpectedly touched"
rm -rf "$TD"

# --- Test 6: Generic StopFailure with repo configured ---
printf '\nTest 6: generic StopFailure — no preset, repo configured, severity=unknown\n'
SID="smoke-t6-$$-$(date +%s)"
TD=$(mktemp -d "/tmp/er-smoke-XXXXXX")
mkdir -p "$TD/markers"
touch "$TD/markers/.v3.1-opt-in-notice.ack"
make_fake_gh "$TD/bin"
INPUT=$(printf '{"hook_event_name":"StopFailure","session_id":"%s","error":"generic_failure"}' "$SID")

CLAUDE_PLUGIN_DATA="$TD" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  ERROR_REPORTER_REPO=dummy/repo PATH="$TD/bin:$PATH" \
  bash -c "unset ERROR_REPORTER_PRESET; printf '%s' '$INPUT' | bash '$SCRIPT'"

wait_for_background "$SID" "$TD/markers"
FALLBACK_FILE=$(ls "$TD/reports/${SID}-"*".md" 2>/dev/null | head -1)
if [ -n "$FALLBACK_FILE" ] && [ -f "$FALLBACK_FILE" ]; then
  pass "T6 generic StopFailure fallback .md written"
  grep -qi 'severity.*unknown' "$FALLBACK_FILE" && pass "T6 severity=unknown (generic mode)" || fail "T6 severity not unknown"
  grep -q '(unavailable)' "$FALLBACK_FILE" && pass "T6 body has (unavailable) debug log" || fail "T6 body missing (unavailable)"
else
  fail "T6 no fallback .md"
fi
cleanup_session "$SID" "$TD"

# --- Test 6b: Generic StopFailure + repo unset (gh-skip path, E5) ---
printf '\nTest 6b: generic StopFailure + repo unset (E5 skip branch)\n'
SID="smoke-t6b-$$-$(date +%s)"
TD=$(mktemp -d "/tmp/er-smoke-XXXXXX")
mkdir -p "$TD/markers"
touch "$TD/markers/.v3.1-opt-in-notice.ack"
make_fake_gh_fatal "$TD/bin"  # gh invocation → test failure via sentinel
INPUT=$(printf '{"hook_event_name":"StopFailure","session_id":"%s","error":"generic_failure"}' "$SID")

CLAUDE_PLUGIN_DATA="$TD" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  PATH="$TD/bin:$PATH" \
  bash -c "unset ERROR_REPORTER_PRESET ERROR_REPORTER_REPO; printf '%s' '$INPUT' | bash '$SCRIPT'"

wait_for_background "$SID" "$TD/markers"
FALLBACK_FILE=$(ls "$TD/reports/${SID}-"*".md" 2>/dev/null | head -1)
if [ -n "$FALLBACK_FILE" ] && [ -f "$FALLBACK_FILE" ]; then
  pass "T6b fallback .md written even without repo"
  grep -qi 'severity.*unknown' "$FALLBACK_FILE" && pass "T6b severity=unknown" || fail "T6b severity"
else
  fail "T6b no fallback .md"
fi
LOG_FILE="$TD/logs/error-reporter.log"
[ -f "$LOG_FILE" ] && grep -q 'status=fail.*reason=repo_resolution_failed' "$LOG_FILE" \
  && pass "T6b log has status=fail reason=repo_resolution_failed" \
  || fail "T6b missing fail breadcrumb"
[ ! -f "$TD/gh-was-called" ] && pass "T6b gh NOT invoked (fail path)" || fail "T6b gh was called — fail path broken"
cleanup_session "$SID" "$TD"

# --- Test 7: Preset filter equivalence — routine + incident ---
printf '\nTest 7: preset filter — routine deny filtered, incident counts\n'
SID="smoke-t7-$$-$(date +%s)"
TD=$(mktemp -d "/tmp/er-smoke-XXXXXX")
mkdir -p "$TD/markers" /tmp/claude-debug
touch "$TD/markers/.v3.1-opt-in-notice.ack"
make_fake_gh "$TD/bin"
cat > "/tmp/claude-debug/$SID.jsonl" <<JSONL
{"ts":"2026-04-16T00:00:01Z","event":"PreToolUse","hook":"pre-edit-guard.sh","decision":"deny","reason":"routine","phase":"planning","session":"$SID"}
{"ts":"2026-04-16T00:00:02Z","event":"PreToolUse","hook":"verify-before-done.sh","decision":"deny","reason":"real incident","phase":"verifying","session":"$SID"}
JSONL
INPUT=$(printf '{"hook_event_name":"Stop","session_id":"%s","transcript_path":""}' "$SID")

CLAUDE_PLUGIN_DATA="$TD" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  ERROR_REPORTER_PRESET=claude-harness ERROR_REPORTER_REPO=dummy/repo \
  PATH="$TD/bin:$PATH" \
  bash -c "printf '%s' '$INPUT' | bash '$SCRIPT'"

wait_for_background "$SID" "$TD/markers"
FALLBACK_FILE=$(ls "$TD/reports/${SID}-"*".md" 2>/dev/null | head -1)
if [ -n "$FALLBACK_FILE" ] && [ -f "$FALLBACK_FILE" ]; then
  pass "T7 incident triggered (1 of 2 lines is non-routine)"
  grep -q 'verify-before-done' "$FALLBACK_FILE" && pass "T7 body includes incident hook" || fail "T7 body missing verify-before-done"
else
  fail "T7 no fallback .md — filter under-matched"
fi
cleanup_session "$SID" "$TD"

# --- Test 8: Preset routine-only (no incident) ---
printf '\nTest 8: preset routine-only — agent-dispatch-guard alone → no incident\n'
SID="smoke-t8-$$-$(date +%s)"
TD=$(mktemp -d "/tmp/er-smoke-XXXXXX")
mkdir -p "$TD/markers" /tmp/claude-debug
touch "$TD/markers/.v3.1-opt-in-notice.ack"
make_fake_gh "$TD/bin"
printf '{"ts":"2026-04-16T00:00:01Z","event":"PreToolUse","hook":"agent-dispatch-guard.sh","decision":"deny","reason":"routine","phase":"idle","session":"%s"}\n' "$SID" \
  > "/tmp/claude-debug/$SID.jsonl"
INPUT=$(printf '{"hook_event_name":"Stop","session_id":"%s","transcript_path":""}' "$SID")

CLAUDE_PLUGIN_DATA="$TD" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  ERROR_REPORTER_PRESET=claude-harness ERROR_REPORTER_REPO=dummy/repo \
  PATH="$TD/bin:$PATH" \
  bash -c "printf '%s' '$INPUT' | bash '$SCRIPT'"

sleep 2
MD_COUNT=$(find "$TD/reports" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
[ "$MD_COUNT" -eq 0 ] && pass "T8 no fallback .md (all routine filtered)" || fail "T8 unexpected .md files ($MD_COUNT)"
cleanup_session "$SID" "$TD"

# --- Test 9: Preset active + repo unset → gh-skip ---
printf '\nTest 9: preset active + repo unset → local archive only\n'
SID="smoke-t9-$$-$(date +%s)"
TD=$(mktemp -d "/tmp/er-smoke-XXXXXX")
mkdir -p "$TD/markers" /tmp/claude-debug
touch "$TD/markers/.v3.1-opt-in-notice.ack"
make_fake_gh_fatal "$TD/bin"
make_synthetic_debug_log "$SID" ""
INPUT=$(printf '{"hook_event_name":"Stop","session_id":"%s","transcript_path":""}' "$SID")

CLAUDE_PLUGIN_DATA="$TD" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  ERROR_REPORTER_PRESET=claude-harness PATH="$TD/bin:$PATH" \
  bash -c "unset ERROR_REPORTER_REPO; printf '%s' '$INPUT' | bash '$SCRIPT'"

wait_for_background "$SID" "$TD/markers"
FALLBACK_FILE=$(ls "$TD/reports/${SID}-"*".md" 2>/dev/null | head -1)
[ -n "$FALLBACK_FILE" ] && pass "T9 fallback .md written" || fail "T9 no fallback .md"
LOG_FILE="$TD/logs/error-reporter.log"
[ -f "$LOG_FILE" ] && grep -q 'status=fail.*reason=repo_resolution_failed' "$LOG_FILE" \
  && pass "T9 status=fail reason=repo_resolution_failed (exactly 1)" \
  || fail "T9 missing fail breadcrumb"
[ ! -f "$TD/gh-was-called" ] && pass "T9 gh NOT invoked" || fail "T9 gh was called"
cleanup_session "$SID" "$TD"

# --- Test 11: Opt-in notice once-only (runs BEFORE Test 10) ---
printf '\nTest 11: opt-in notice fires once, then dedups via .v3.1-opt-in-notice.ack\n'
SID="smoke-t11-$$-$(date +%s)"
TD=$(mktemp -d "/tmp/er-smoke-XXXXXX")
# NO pre-touch of .ack — this test EXERCISES the fresh-install path
INPUT=$(printf '{"hook_event_name":"Stop","session_id":"%s","transcript_path":""}' "$SID")

CLAUDE_PLUGIN_DATA="$TD" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  bash -c "unset ERROR_REPORTER_PRESET ERROR_REPORTER_REPO; printf '%s' '$INPUT' | bash '$SCRIPT'"

sleep 1
NOTICE_FILES=$(find "$TD/reports" -type f -name 'error-reporter-notice-*.md' 2>/dev/null | wc -l | tr -d ' ')
[ "$NOTICE_FILES" = "1" ] && pass "T11 first invocation: 1 notice .md written" || fail "T11 expected 1 notice, got $NOTICE_FILES"
[ -f "$TD/markers/.v3.1-opt-in-notice.ack" ] && pass "T11 ack marker created" || fail "T11 ack marker missing"
LOG_FILE="$TD/logs/error-reporter.log"
[ -f "$LOG_FILE" ] && grep -q 'status=opt_in_notice' "$LOG_FILE" && pass "T11 log has status=opt_in_notice" || fail "T11 no opt_in_notice log"

# Second invocation
INPUT2=$(printf '{"hook_event_name":"Stop","session_id":"%s-b","transcript_path":""}' "$SID")
CLAUDE_PLUGIN_DATA="$TD" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  bash -c "unset ERROR_REPORTER_PRESET ERROR_REPORTER_REPO; printf '%s' '$INPUT2' | bash '$SCRIPT'"
sleep 1
NOTICE_FILES_2=$(find "$TD/reports" -type f -name 'error-reporter-notice-*.md' 2>/dev/null | wc -l | tr -d ' ')
[ "$NOTICE_FILES_2" = "1" ] && pass "T11 second invocation: still 1 notice (dedup)" || fail "T11 notice rewrote ($NOTICE_FILES_2)"
LOG_NOTICE_COUNT=$(grep -c 'status=opt_in_notice' "$LOG_FILE" 2>/dev/null || echo 0)
[ "$LOG_NOTICE_COUNT" = "1" ] && pass "T11 log has exactly 1 opt_in_notice line" || fail "T11 opt_in_notice count = $LOG_NOTICE_COUNT"
rm -rf "$TD"

# --- Test 12: --self-test 4 scenarios + R2 CLAUDE_PLUGIN_ROOT unset ---
printf '\nTest 12: --self-test 4 scenarios + R2 edge case\n'

# 12a: preset loaded + repo reachable
TD=$(mktemp -d "/tmp/er-smoke-XXXXXX")
mkdir -p "$TD/bin"
# A gh stub where `gh repo view` succeeds
cat > "$TD/bin/gh" <<'GH'
#!/bin/bash
case "$1" in
  --version) echo "gh version fake" ;;
  auth) exit 0 ;;
  repo) exit 0 ;;
  *) exit 0 ;;
esac
GH
chmod +x "$TD/bin/gh"
SETUP_DIR_COUNT=$(find "$TD" -type d | wc -l | tr -d ' ')
OUT=$(CLAUDE_PLUGIN_DATA="$TD" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  ERROR_REPORTER_PRESET=claude-harness ERROR_REPORTER_REPO=dummy/repo \
  PATH="$TD/bin:$PATH" bash "$SCRIPT" --self-test 2>&1)
RC=$?
[ "$RC" -eq 0 ] && pass "T12a exit 0" || fail "T12a exit $RC"
printf '%s\n' "$OUT" | grep -qF '[ok]   preset: claude-harness (loaded)' && pass "T12a preset loaded" || fail "T12a preset loaded line"
printf '%s\n' "$OUT" | grep -qF '[ok]   target repo: dummy/repo (source=env, reachable)' && pass "T12a target repo reachable" || fail "T12a target repo line"
AFTER_DIR_COUNT=$(find "$TD" -type d | wc -l | tr -d ' ')
[ "$SETUP_DIR_COUNT" = "$AFTER_DIR_COUNT" ] && pass "T12a F1 verified (no dirs created)" || fail "T12a F1 violation (dirs: $SETUP_DIR_COUNT → $AFTER_DIR_COUNT)"
rm -rf "$TD"

# 12b: preset loaded + repo unreachable
TD=$(mktemp -d "/tmp/er-smoke-XXXXXX")
mkdir -p "$TD/bin"
cat > "$TD/bin/gh" <<'GH'
#!/bin/bash
case "$1" in
  --version) echo "gh version fake" ;;
  auth) exit 0 ;;
  repo) exit 1 ;;
  *) exit 1 ;;
esac
GH
chmod +x "$TD/bin/gh"
OUT=$(CLAUDE_PLUGIN_DATA="$TD" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  ERROR_REPORTER_PRESET=claude-harness ERROR_REPORTER_REPO=dummy/repo \
  PATH="$TD/bin:$PATH" bash "$SCRIPT" --self-test 2>&1)
printf '%s\n' "$OUT" | grep -qF '[WARN] target repo unreachable: dummy/repo (source=env)' && pass "T12b target repo unreachable" || fail "T12b target repo line"
rm -rf "$TD"

# 12c: preset none + repo configured
TD=$(mktemp -d "/tmp/er-smoke-XXXXXX")
mkdir -p "$TD/bin"
cat > "$TD/bin/gh" <<'GH'
#!/bin/bash
case "$1" in
  --version) echo "gh version fake" ;;
  auth) exit 0 ;;
  repo) exit 0 ;;
  *) exit 0 ;;
esac
GH
chmod +x "$TD/bin/gh"
OUT=$(CLAUDE_PLUGIN_DATA="$TD" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  ERROR_REPORTER_REPO=dummy/repo PATH="$TD/bin:$PATH" \
  bash -c "unset ERROR_REPORTER_PRESET; bash '$SCRIPT' --self-test" 2>&1)
RC=$?
# P0-2: preset unset now FAILs (was "none generic mode" in v3.1). Exit non-zero.
[ "$RC" -eq 1 ] && pass "T12c exit 1 (preset unset → FAIL)" || fail "T12c exit $RC (expected 1 after P0-2)"
printf '%s\n' "$OUT" | grep -qF '[FAIL] preset: not configured' && pass "T12c preset FAIL line" || fail "T12c preset FAIL line"
printf '%s\n' "$OUT" | grep -qF '[ok]   target repo: dummy/repo (source=env, reachable)' && pass "T12c target repo reachable" || fail "T12c target repo line"
rm -rf "$TD"

# 12d: preset none + repo unset (both FAIL under P0-2)
TD=$(mktemp -d "/tmp/er-smoke-XXXXXX")
# P0-5: unset HOME-like vars so CWD detection also fails — must run in a /tmp dir that isn't a git repo.
OUT=$(cd "$TD" && CLAUDE_PLUGIN_DATA="$TD" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  bash -c "unset ERROR_REPORTER_PRESET ERROR_REPORTER_REPO; bash '$SCRIPT' --self-test" 2>&1)
RC=$?
[ "$RC" -eq 1 ] && pass "T12d exit 1 (preset+repo unset → FAIL)" || fail "T12d exit $RC (expected 1 after P0-2)"
printf '%s\n' "$OUT" | grep -qF '[FAIL] preset: not configured' && pass "T12d preset FAIL line" || fail "T12d preset FAIL line"
printf '%s\n' "$OUT" | grep -qF '[FAIL] target repo: not resolvable' && pass "T12d target repo FAIL line" || fail "T12d target repo FAIL line"
rm -rf "$TD"

# 12e: CLAUDE_PLUGIN_ROOT unset (P0-2 escalates to FAIL + exit 1)
TD=$(mktemp -d "/tmp/er-smoke-XXXXXX")
OUT=$(cd "$TD" && CLAUDE_PLUGIN_DATA="$TD" \
  bash -c "unset CLAUDE_PLUGIN_ROOT ERROR_REPORTER_PRESET ERROR_REPORTER_REPO; bash '$SCRIPT' --self-test" 2>&1)
RC=$?
[ "$RC" -eq 1 ] && pass "T12e exit 1 (CLAUDE_PLUGIN_ROOT unset → FAIL)" || fail "T12e exit $RC (expected 1 after P0-2)"
printf '%s\n' "$OUT" | grep -qF '[FAIL] preset: cannot check (CLAUDE_PLUGIN_ROOT unset)' && pass "T12e FAIL line" || fail "T12e FAIL line"
rm -rf "$TD"

# --- Test 10: Malformed preset (MUST run last — manipulates CLAUDE_PLUGIN_ROOT) ---
printf '\nTest 10: malformed preset — fail-closed (MUST run last)\n'
(
  SID="smoke-t10-$$-$(date +%s)"
  TMP_ROOT=$(mktemp -d "/tmp/er-t10-root-XXXXXX")
  TD=$(mktemp -d "/tmp/er-smoke-XXXXXX")
  mkdir -p "$TMP_ROOT/presets" "$TD/markers"
  touch "$TD/markers/.v3.1-opt-in-notice.ack"
  printf '{"schema_version":2}' > "$TMP_ROOT/presets/broken.json"
  INPUT=$(printf '{"hook_event_name":"Stop","session_id":"%s","transcript_path":""}' "$SID")

  CLAUDE_PLUGIN_DATA="$TD" CLAUDE_PLUGIN_ROOT="$TMP_ROOT" \
    ERROR_REPORTER_PRESET=broken ERROR_REPORTER_REPO=dummy/repo \
    bash -c "printf '%s' '$INPUT' | bash '$SCRIPT'"
  RC=$?
  [ "$RC" -eq 0 ] && pass "T10 exit 0 despite malformed preset" || fail "T10 exit $RC"
  sleep 1
  LOG_FILE="$TD/logs/error-reporter.log"
  [ -f "$LOG_FILE" ] && grep -q 'status=preset_bad_schema preset=broken' "$LOG_FILE" \
    && pass "T10 log has status=preset_bad_schema preset=broken" \
    || fail "T10 missing preset_bad_schema log"
  rm -rf "$TD" "$TMP_ROOT"
)

# --- Summary ---
printf '\nSummary: %d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
else
  exit 1
fi
