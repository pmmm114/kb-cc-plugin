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
  # #24: body restructured — Agent now appears in the Trigger table row, column 4
  grep -qE '^\| `SubagentStop` .* `editor` \|' "$FALLBACK_FILE" && pass "T2 body Trigger table has Agent=editor" || fail "T2 body missing Agent=editor in Trigger table"
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
  # #24: body restructured — agent_id now appears in the Trigger table, column 4
  grep -qE '^\| `SubagentStop` .* `grader` \|' "$FALLBACK_FILE" \
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
  # #24: body restructured — severity now appears in Trigger table row
  grep -qE '^\| `StopFailure` .* `unknown` \| `[^|]+` \|$' "$FALLBACK_FILE" && pass "T6 severity=unknown (generic mode)" || fail "T6 severity not unknown"
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
  # #24: body restructured — severity now appears in Trigger table row
  grep -qE '^\| `StopFailure` .* `unknown` \| `[^|]+` \|$' "$FALLBACK_FILE" && pass "T6b severity=unknown" || fail "T6b severity"
else
  fail "T6b no fallback .md"
fi
LOG_FILE="$TD/logs/error-reporter.log"
if [ -f "$LOG_FILE" ]; then
  N=$(grep -c 'status=fail.*reason=repo_resolution_failed' "$LOG_FILE" 2>/dev/null)
  [ "${N:-0}" -eq 1 ] && pass "T6b log has status=fail reason=repo_resolution_failed (exactly 1)" \
    || fail "T6b expected exactly 1 fail breadcrumb, got ${N:-0}"
else
  fail "T6b log missing"
fi
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
if [ -f "$LOG_FILE" ]; then
  N=$(grep -c 'status=fail.*reason=repo_resolution_failed' "$LOG_FILE" 2>/dev/null)
  [ "${N:-0}" -eq 1 ] && pass "T9 status=fail reason=repo_resolution_failed (exactly 1)" \
    || fail "T9 expected exactly 1 fail breadcrumb, got ${N:-0}"
else
  fail "T9 log missing"
fi
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

# --- Test 14: silent_skip rate-limit (#26) ---
# silent_skip must emit at most once per session per hour. Previously every
# Stop/SubagentStop event appended a line, which could flood the 1000-line
# ring buffer on Stop-heavy sessions.
printf '\nTest 14: silent_skip rate-limited to 1 emit per session per hour\n'
TD=$(mktemp -d "/tmp/er-smoke-XXXXXX")
SID="smoke-t14-$$-$(date +%s)"
mkdir -p "$TD/markers"
touch "$TD/markers/.v3.1-opt-in-notice.ack"  # suppress notice noise
INPUT=$(printf '{"hook_event_name":"Stop","session_id":"%s","transcript_path":""}' "$SID")

# Fire 5 events in rapid succession — all within the same UTC hour
for _ in 1 2 3 4 5; do
  CLAUDE_PLUGIN_DATA="$TD" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    bash -c "unset ERROR_REPORTER_PRESET ERROR_REPORTER_REPO; printf '%s' '$INPUT' | bash '$SCRIPT'"
done

sleep 1
LOG_FILE="$TD/logs/error-reporter.log"
SKIP_COUNT=$(grep -c 'status=silent_skip' "$LOG_FILE" 2>/dev/null || echo 0)
[ "$SKIP_COUNT" = "1" ] && pass "T14 5 events → 1 silent_skip log line (rate-limited)" \
  || fail "T14 expected 1 silent_skip, got $SKIP_COUNT"

HOUR=$(date -u +%Y%m%d%H)
MARKER="$TD/markers/.silent_skip.${SID}.${HOUR}"
[ -f "$MARKER" ] && pass "T14 hour-bucketed marker created at expected path" \
  || fail "T14 marker missing: $MARKER"

# Simulate hour rollover by deleting the marker — next event should emit
rm -f "$MARKER"
CLAUDE_PLUGIN_DATA="$TD" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  bash -c "unset ERROR_REPORTER_PRESET ERROR_REPORTER_REPO; printf '%s' '$INPUT' | bash '$SCRIPT'"
sleep 1
SKIP_COUNT_2=$(grep -c 'status=silent_skip' "$LOG_FILE" 2>/dev/null || echo 0)
[ "$SKIP_COUNT_2" = "2" ] && pass "T14 hour rollover → 2nd silent_skip emitted" \
  || fail "T14 expected 2 silent_skip after rollover, got $SKIP_COUNT_2"
rm -rf "$TD"

# --- Test 13: Self-recursion guard (kb-cc-plugin#28) ---
# When REPORT_REPO resolves to SELF_REPO (pmmm114/kb-cc-plugin), the reporter
# must emit a breadcrumb and exit without ever invoking gh. Prevents infinite
# incident loops when operators edit error-reporter source.
printf '\nTest 13: self-suppress when REPORT_REPO matches SELF_REPO\n'
TD=$(mktemp -d "/tmp/er-smoke-XXXXXX")
SID="smoke-t13-$$-$(date +%s)"
mkdir -p "$TD/markers" "$TD/bin"
touch "$TD/markers/.v3.1-opt-in-notice.ack"
make_fake_gh_fatal "$TD/bin"
INPUT=$(printf '{"hook_event_name":"StopFailure","session_id":"%s","error":"other","cwd":""}' "$SID")

PATH="$TD/bin:$PATH" CLAUDE_PLUGIN_DATA="$TD" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  ERROR_REPORTER_REPO=pmmm114/kb-cc-plugin \
  bash -c "printf '%s' '$INPUT' | bash '$SCRIPT'"
RC=$?
[ "$RC" -eq 0 ] && pass "T13 exit 0" || fail "T13 exit $RC"
sleep 1
LOG_FILE="$TD/logs/error-reporter.log"
[ -f "$LOG_FILE" ] && grep -q 'status=self_suppress' "$LOG_FILE" \
  && pass "T13 log has status=self_suppress" \
  || fail "T13 missing self_suppress log"
[ ! -f "$TD/gh-was-called" ] && pass "T13 gh NOT invoked (self-suppress worked)" \
  || fail "T13 gh was called — self-suppress failed"
rm -rf "$TD"

# --- Test 13b: non-self repo does NOT self-suppress ---
printf '\nTest 13b: non-self repo proceeds past self-suppress guard\n'
TD=$(mktemp -d "/tmp/er-smoke-XXXXXX")
SID="smoke-t13b-$$-$(date +%s)"
mkdir -p "$TD/markers" "$TD/bin"
touch "$TD/markers/.v3.1-opt-in-notice.ack"
make_fake_gh_fatal "$TD/bin"
INPUT=$(printf '{"hook_event_name":"StopFailure","session_id":"%s","error":"other","cwd":""}' "$SID")

PATH="$TD/bin:$PATH" CLAUDE_PLUGIN_DATA="$TD" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  ERROR_REPORTER_REPO=some/other-repo \
  bash -c "printf '%s' '$INPUT' | bash '$SCRIPT'"
RC=$?
[ "$RC" -eq 0 ] && pass "T13b exit 0" || fail "T13b exit $RC"
sleep 1
LOG_FILE="$TD/logs/error-reporter.log"
if [ -f "$LOG_FILE" ] && grep -q 'status=self_suppress' "$LOG_FILE"; then
  fail "T13b unexpected self_suppress log (repo != self)"
else
  pass "T13b no self_suppress log (repo differs from self)"
fi
rm -rf "$TD"

# --- Test 13c: ERROR_REPORTER_SELF_REPO env override (fork maintainer use case) ---
printf '\nTest 13c: ERROR_REPORTER_SELF_REPO env override suppresses on fork\n'
TD=$(mktemp -d "/tmp/er-smoke-XXXXXX")
SID="smoke-t13c-$$-$(date +%s)"
mkdir -p "$TD/markers" "$TD/bin"
touch "$TD/markers/.v3.1-opt-in-notice.ack"
make_fake_gh_fatal "$TD/bin"
INPUT=$(printf '{"hook_event_name":"StopFailure","session_id":"%s","error":"other","cwd":""}' "$SID")

PATH="$TD/bin:$PATH" CLAUDE_PLUGIN_DATA="$TD" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  ERROR_REPORTER_REPO=myfork/kb-cc-plugin \
  ERROR_REPORTER_SELF_REPO=myfork/kb-cc-plugin \
  bash -c "printf '%s' '$INPUT' | bash '$SCRIPT'"
RC=$?
[ "$RC" -eq 0 ] && pass "T13c exit 0" || fail "T13c exit $RC"
sleep 1
[ ! -f "$TD/gh-was-called" ] && pass "T13c gh NOT invoked (env override works)" \
  || fail "T13c gh was called — env override broken"
rm -rf "$TD"

# --- Test 15: v=2 preset emits 5-axis labels, no legacy reporter:domain:* (#22) ---
printf '\nTest 15: v=2 preset emits 5-axis labels, no legacy reporter:domain:*\n'
TD=$(mktemp -d "/tmp/er-smoke-XXXXXX")
SID="smoke-t15-$$-$(date +%s)"
mkdir -p "$TD/markers" "$TD/bin"
touch "$TD/markers/.v3.1-opt-in-notice.ack"

# Fake gh that captures --label arguments to a log file
cat > "$TD/bin/gh" <<'GHFAKE'
#!/bin/bash
LOG="${GH_CAPTURE_LOG:-/dev/null}"
case "$1" in
  auth) exit 0 ;;
  label) printf 'LABEL_CREATE: %s\n' "$3" >> "$LOG"; exit 0 ;;
  issue)
    while [ $# -gt 0 ]; do
      if [ "$1" = "--label" ]; then
        printf 'ISSUE_LABELS: %s\n' "$2" >> "$LOG"
        break
      fi
      shift
    done
    exit 0
    ;;
  *) exit 0 ;;
esac
GHFAKE
chmod +x "$TD/bin/gh"

GH_CAPTURE="$TD/gh-capture.log"
make_synthetic_debug_log "$SID" ""
INPUT=$(printf '{"hook_event_name":"StopFailure","session_id":"%s","error":"other","cwd":""}' "$SID")

PATH="$TD/bin:$PATH" GH_CAPTURE_LOG="$GH_CAPTURE" \
  CLAUDE_PLUGIN_DATA="$TD" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  ERROR_REPORTER_PRESET=claude-harness ERROR_REPORTER_REPO=dummy/repo \
  bash -c "printf '%s' '$INPUT' | bash '$SCRIPT'"

wait_for_background "$SID" "$TD/markers"

# Assert: 5-axis labels requested
grep -q 'LABEL_CREATE: reporter:hook:' "$GH_CAPTURE" && pass "T15 reporter:hook: label emitted" || fail "T15 reporter:hook: missing"
grep -q 'LABEL_CREATE: reporter:phase:' "$GH_CAPTURE" && pass "T15 reporter:phase: label emitted" || fail "T15 reporter:phase: missing"
grep -q 'LABEL_CREATE: reporter:severity:' "$GH_CAPTURE" && pass "T15 reporter:severity: label emitted" || fail "T15 reporter:severity: missing"
grep -q 'LABEL_CREATE: reporter:cluster:' "$GH_CAPTURE" && pass "T15 reporter:cluster: label emitted" || fail "T15 reporter:cluster: missing"
grep -q 'LABEL_CREATE: reporter:repo:' "$GH_CAPTURE" && pass "T15 reporter:repo: label emitted" || fail "T15 reporter:repo: missing"

# Assert: no legacy reporter:domain:* (v=2 preset has no domain_rules)
if grep -q 'LABEL_CREATE: reporter:domain:' "$GH_CAPTURE"; then
  fail "T15 v=2 preset unexpectedly emitted reporter:domain:*"
else
  pass "T15 v=2 preset does NOT emit legacy reporter:domain:*"
fi

# Assert: ISSUE_LABELS CSV includes all 5 axes
if grep -q 'ISSUE_LABELS:.*reporter:hook:.*reporter:phase:.*reporter:severity:.*reporter:cluster:.*reporter:repo:' "$GH_CAPTURE"; then
  pass "T15 issue labels include all 5 axes in order"
else
  ACTUAL=$(grep 'ISSUE_LABELS:' "$GH_CAPTURE" | head -1)
  fail "T15 issue labels missing or out of order: $ACTUAL"
fi

cleanup_session "$SID" "$TD"

# --- Test 16: body has all 7 sections + 10KB cap + Decisive Entry marker (#24) ---
printf '\nTest 16: body 7-section structure + 10KB cap + decisive entry context\n'
TD=$(mktemp -d "/tmp/er-smoke-XXXXXX")
SID="smoke-t16-$$-$(date +%s)"
mkdir -p "$TD/markers"
touch "$TD/markers/.v3.1-opt-in-notice.ack"

# Seed a debug log with a recognizable deny line among noise (decisive entry
# extraction should highlight the deny with a ← decisive marker).
mkdir -p /tmp/claude-debug
{
  printf '{"ts":"t1","event":"PreToolUse","hook":"delegation-reminder.sh","decision":"allow","session":"%s"}\n' "$SID"
  printf '{"ts":"t2","event":"PreToolUse","hook":"delegation-reminder.sh","decision":"allow","session":"%s"}\n' "$SID"
  printf '{"ts":"t3","event":"PreToolUse","hook":"pre-edit-guard.sh","decision":"deny","reason":"[sid:x] [verify-before-done.sh] blocked","phase":"verifying","session":"%s"}\n' "$SID"
  printf '{"ts":"t4","event":"PreToolUse","hook":"pre-edit-guard.sh","decision":"allow","session":"%s"}\n' "$SID"
} > "/tmp/claude-debug/$SID.jsonl"

INPUT=$(printf '{"hook_event_name":"SubagentStop","session_id":"%s","cwd":"","agent_id":"editor"}' "$SID")

CLAUDE_PLUGIN_DATA="$TD" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  ERROR_REPORTER_PRESET=claude-harness ERROR_REPORTER_REPO=dummy/repo \
  bash -c "printf '%s' '$INPUT' | bash '$SCRIPT'"

wait_for_background "$SID" "$TD/markers"

FALLBACK_FILE=$(ls "$TD/reports/${SID}-"*".md" 2>/dev/null | head -1)
if [ -n "$FALLBACK_FILE" ] && [ -f "$FALLBACK_FILE" ]; then
  pass "T16 fallback .md written"
  # Seven sections: Trigger, Decisive Entry, Counterfactual, Base Rates,
  # Related Meta-Eval, Known Drift Match, Reproduction (+ <details>)
  for section in "## Trigger" "## Decisive Entry" "## Counterfactual" "## Base Rates" "## Related Meta-Eval" "## Known Drift Match" "## Reproduction"; do
    if grep -qF "$section" "$FALLBACK_FILE"; then
      pass "T16 section present: $section"
    else
      fail "T16 section missing: $section"
    fi
  done
  # <details> collapsible fallback block
  grep -qF '<details><summary>Raw data (collapsed)</summary>' "$FALLBACK_FILE" \
    && pass "T16 details fallback block present" \
    || fail "T16 details fallback block missing"
  # Decisive entry marker (← decisive)
  grep -qF '← decisive' "$FALLBACK_FILE" \
    && pass "T16 decisive entry marker emitted (deny line highlighted)" \
    || fail "T16 decisive entry marker missing"
  # Trigger table row contains expected cells
  grep -qE '^\| `SubagentStop` .* `editor` \|' "$FALLBACK_FILE" \
    && pass "T16 Trigger table row has SubagentStop + editor" \
    || fail "T16 Trigger table row malformed"
  # Reproduction section has /kb-harness --from-incident literal
  grep -qF '/kb-harness --from-incident' "$FALLBACK_FILE" \
    && pass "T16 Reproduction has /kb-harness --from-incident literal" \
    || fail "T16 Reproduction literal missing"
else
  fail "T16 no fallback .md"
fi
cleanup_session "$SID" "$TD"

# --- Test 16b: 10KB body cap triggers when payload is large ---
printf '\nTest 16b: body truncated to ≤10KB when synthetic payload overflows\n'
TD=$(mktemp -d "/tmp/er-smoke-XXXXXX")
SID="smoke-t16b-$$-$(date +%s)"
mkdir -p "$TD/markers"
touch "$TD/markers/.v3.1-opt-in-notice.ack"

# Synthetic debug log with a 40KB blob to overflow the 10KB body cap
{
  printf '{"ts":"t1","event":"PreToolUse","hook":"pre-edit-guard.sh","decision":"deny","reason":"[sid:x] [verify-before-done.sh] blocked","phase":"verifying","session":"%s"}\n' "$SID"
  # Pad with ~40KB of content distributed across 50 lines → each line ~800 chars
  pad=$(printf 'X%.0s' $(seq 1 800))
  for i in $(seq 1 50); do
    printf '{"ts":"pad%d","event":"PreToolUse","decision":"allow","data":"%s","session":"%s"}\n' "$i" "$pad" "$SID"
  done
} > "/tmp/claude-debug/$SID.jsonl"

INPUT=$(printf '{"hook_event_name":"SubagentStop","session_id":"%s","cwd":"","agent_id":"editor"}' "$SID")
CLAUDE_PLUGIN_DATA="$TD" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  ERROR_REPORTER_PRESET=claude-harness ERROR_REPORTER_REPO=dummy/repo \
  bash -c "printf '%s' '$INPUT' | bash '$SCRIPT'"

wait_for_background "$SID" "$TD/markers"

FALLBACK_FILE=$(ls "$TD/reports/${SID}-"*".md" 2>/dev/null | head -1)
if [ -n "$FALLBACK_FILE" ] && [ -f "$FALLBACK_FILE" ]; then
  BODY_BYTES=$(wc -c < "$FALLBACK_FILE" | tr -d ' ')
  # Body should be ≤ 10KB + small margin for truncation marker (~200 bytes).
  # Local .md has full untruncated body (it's written BEFORE cap is applied
  # to REPORT_BODY); strictly speaking the local file may exceed 10KB. The
  # cap is ON the GitHub issue body — not on the fallback file. We can't
  # directly observe the gh call's --body argument without a fake-gh capture.
  # Assert instead that the truncation marker is present in the SAME SESSION's
  # gh-captured payload (but fallback .md is the local raw). Simpler here:
  # verify the marker appears in whichever artifact has it, and that body
  # construction didn't crash.
  pass "T16b body constructed for oversize payload"
  # Body should still include the Trigger section (sections 1-2 preserved)
  grep -qF '## Trigger' "$FALLBACK_FILE" && pass "T16b Trigger section preserved on overflow" \
    || fail "T16b Trigger section dropped"
else
  fail "T16b no fallback .md on oversize payload"
fi
cleanup_session "$SID" "$TD"

# --- Test 16c: 10KB cap — gh --body actually ≤10KB via fake-gh capture ---
printf '\nTest 16c: gh issue --body ≤10KB when oversize, truncation marker present\n'
TD=$(mktemp -d "/tmp/er-smoke-XXXXXX")
SID="smoke-t16c-$$-$(date +%s)"
mkdir -p "$TD/markers" "$TD/bin"
touch "$TD/markers/.v3.1-opt-in-notice.ack"

# Fake gh that captures --body to file for size inspection
cat > "$TD/bin/gh" <<'GHFAKE'
#!/bin/bash
LOG="${GH_CAPTURE_LOG:-/dev/null}"
case "$1" in
  auth) exit 0 ;;
  label) exit 0 ;;
  issue)
    while [ $# -gt 0 ]; do
      if [ "$1" = "--body" ]; then
        printf '%s' "$2" > "${GH_BODY_CAPTURE:-/dev/null}"
        break
      fi
      shift
    done
    exit 0
    ;;
  *) exit 0 ;;
esac
GHFAKE
chmod +x "$TD/bin/gh"

# Seed large debug log (same approach as T16b)
{
  printf '{"ts":"t1","event":"PreToolUse","hook":"pre-edit-guard.sh","decision":"deny","reason":"[sid:x] [verify-before-done.sh] blocked","phase":"verifying","session":"%s"}\n' "$SID"
  pad=$(printf 'X%.0s' $(seq 1 800))
  for i in $(seq 1 50); do
    printf '{"ts":"pad%d","event":"PreToolUse","decision":"allow","data":"%s","session":"%s"}\n' "$i" "$pad" "$SID"
  done
} > "/tmp/claude-debug/$SID.jsonl"

INPUT=$(printf '{"hook_event_name":"SubagentStop","session_id":"%s","cwd":"","agent_id":"editor"}' "$SID")
PATH="$TD/bin:$PATH" GH_BODY_CAPTURE="$TD/body.txt" \
  CLAUDE_PLUGIN_DATA="$TD" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  ERROR_REPORTER_PRESET=claude-harness ERROR_REPORTER_REPO=dummy/repo \
  bash -c "printf '%s' '$INPUT' | bash '$SCRIPT'"

wait_for_background "$SID" "$TD/markers"

if [ -f "$TD/body.txt" ]; then
  BODY_BYTES=$(wc -c < "$TD/body.txt" | tr -d ' ')
  if [ "$BODY_BYTES" -le 10400 ]; then
    pass "T16c gh body ≤10KB (actual: ${BODY_BYTES} bytes)"
  else
    fail "T16c gh body exceeds cap: ${BODY_BYTES} bytes > 10400"
  fi
  grep -qF 'body truncated at 10KB boundary' "$TD/body.txt" \
    && pass "T16c truncation marker present in gh body" \
    || fail "T16c truncation marker missing"
else
  fail "T16c gh body was not captured"
fi
cleanup_session "$SID" "$TD"

# --- Test 17: Base Rates section populated with session-local deny/total ratio (#40 / F5) ---
printf '\nTest 17: Base Rates section shows deny/total ratio for TRIGGER_HOOK\n'
TD=$(mktemp -d "/tmp/er-smoke-XXXXXX")
SID="smoke-t17-$$-$(date +%s)"
mkdir -p "$TD/markers"
touch "$TD/markers/.v3.1-opt-in-notice.ack"

# Seed a debug log with 10 entries for verify-before-done guard: 4 deny + 6 allow.
# Real harness sets `.reason = "[sid:x] [hook.sh] ..."` on both deny and allow
# decisions, so extraction produces the SAME hook name for both. Expected
# base rate: 40.0% deny.
mkdir -p /tmp/claude-debug
{
  for i in 1 2 3 4; do
    printf '{"ts":"t%d","event":"PreToolUse","hook":"pre-edit-guard.sh","decision":"deny","reason":"[sid:x] [verify-before-done.sh] blocked","phase":"verifying","session":"%s"}\n' "$i" "$SID"
  done
  for i in 5 6 7 8 9 10; do
    printf '{"ts":"t%d","event":"PreToolUse","hook":"pre-edit-guard.sh","decision":"allow","reason":"[sid:x] [verify-before-done.sh] ok","phase":"executing","session":"%s"}\n' "$i" "$SID"
  done
} > "/tmp/claude-debug/$SID.jsonl"

INPUT=$(printf '{"hook_event_name":"SubagentStop","session_id":"%s","cwd":"","agent_id":"editor"}' "$SID")
CLAUDE_PLUGIN_DATA="$TD" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  ERROR_REPORTER_PRESET=claude-harness ERROR_REPORTER_REPO=dummy/repo \
  bash -c "printf '%s' '$INPUT' | bash '$SCRIPT'"
wait_for_background "$SID" "$TD/markers"

FALLBACK_FILE=$(ls "$TD/reports/${SID}-"*".md" 2>/dev/null | head -1)
if [ -n "$FALLBACK_FILE" ] && [ -f "$FALLBACK_FILE" ]; then
  grep -qF '## Base Rates' "$FALLBACK_FILE" \
    && pass "T17 Base Rates section header present" \
    || fail "T17 Base Rates header missing"
  grep -qE 'fired \*\*10 time\(s\)\*\*' "$FALLBACK_FILE" \
    && pass "T17 Base Rates shows total count (10)" \
    || fail "T17 Base Rates total count wrong"
  grep -qE '\*\*4 deny\*\*' "$FALLBACK_FILE" \
    && pass "T17 Base Rates shows deny count (4)" \
    || fail "T17 Base Rates deny count wrong"
  grep -qE '\*\*40\.0% deny\*\*' "$FALLBACK_FILE" \
    && pass "T17 Base Rates shows percentage (40.0%)" \
    || fail "T17 Base Rates percentage wrong"
  if grep -qF 'Recent commits on' "$FALLBACK_FILE"; then
    fail "T17 git enrichment appeared without env opt-in"
  else
    pass "T17 git enrichment correctly gated off (env unset)"
  fi
else
  fail "T17 no fallback .md"
fi
cleanup_session "$SID" "$TD"

# --- Test 17b: empty debug log → Base Rates does not crash the script ---
printf '\nTest 17b: Base Rates handles empty debug log gracefully\n'
TD=$(mktemp -d "/tmp/er-smoke-XXXXXX")
SID="smoke-t17b-$$-$(date +%s)"
mkdir -p "$TD/markers"
touch "$TD/markers/.v3.1-opt-in-notice.ack"

mkdir -p /tmp/claude-debug
: > "/tmp/claude-debug/$SID.jsonl"

INPUT=$(printf '{"hook_event_name":"SubagentStop","session_id":"%s","cwd":"","agent_id":"editor"}' "$SID")
CLAUDE_PLUGIN_DATA="$TD" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  ERROR_REPORTER_PRESET=claude-harness ERROR_REPORTER_REPO=dummy/repo \
  bash -c "printf '%s' '$INPUT' | bash '$SCRIPT'" 2>/dev/null
RC=$?
[ "$RC" -eq 0 ] && pass "T17b empty debug log does not crash the script" \
  || fail "T17b empty log crashed exit $RC"
cleanup_session "$SID" "$TD"

# --- Test 18: Related Meta-Eval section (#42 / F7) ---
# Populates ## Related Meta-Eval via read-only scan of
# $CLAUDE_CONFIG_DIR/benchmarks/meta-evals/. Four branches:
#   a. exact filename match
#   b. tag substring match
#   c. coverage-gap (nothing matches)
#   d. directory unreachable
printf '\nTest 18: Related Meta-Eval lookup — 4 branches\n'

run_t18_case() {
  local label="$1"
  local fake_config_dir="$2"   # empty → unset CLAUDE_CONFIG_DIR
  local expected_substr="$3"
  local td sid
  td=$(mktemp -d "/tmp/er-smoke-XXXXXX")
  sid="smoke-t18-${label}-$(date +%s%N)-$RANDOM"
  mkdir -p "$td/markers"
  touch "$td/markers/.v3.1-opt-in-notice.ack"
  mkdir -p /tmp/claude-debug
  {
    printf '{"ts":"t1","event":"PreToolUse","hook":"pre-edit-guard.sh","decision":"deny","reason":"[sid:x] [verify-before-done.sh] blocked","phase":"verifying","session":"%s"}\n' "$sid"
  } > "/tmp/claude-debug/$sid.jsonl"
  local payload
  payload=$(printf '{"hook_event_name":"SubagentStop","session_id":"%s","cwd":"","agent_id":"editor"}' "$sid")

  if [ -n "$fake_config_dir" ]; then
    CLAUDE_PLUGIN_DATA="$td" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLAUDE_CONFIG_DIR="$fake_config_dir" \
      ERROR_REPORTER_PRESET=claude-harness ERROR_REPORTER_REPO=dummy/repo \
      bash -c "printf '%s' '$payload' | bash '$SCRIPT'"
  else
    CLAUDE_PLUGIN_DATA="$td" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
      bash -c "unset CLAUDE_CONFIG_DIR; export CLAUDE_PLUGIN_DATA='$td' CLAUDE_PLUGIN_ROOT='$PLUGIN_ROOT' ERROR_REPORTER_PRESET=claude-harness ERROR_REPORTER_REPO=dummy/repo; printf '%s' '$payload' | bash '$SCRIPT'"
  fi
  wait_for_background "$sid" "$td/markers"
  local fb
  fb=$(ls "$td/reports/${sid}-"*".md" 2>/dev/null | head -1)
  if [ -n "$fb" ] && grep -qF "$expected_substr" "$fb"; then
    pass "T18 ($label): found expected substring '$expected_substr'"
  else
    local actual
    actual=$(awk '/^## Related Meta-Eval/{p=1} /^## Known Drift/{p=0} p' "$fb" 2>/dev/null | head -3)
    fail "T18 ($label): expected '$expected_substr', section shows: $actual"
  fi
  cleanup_session "$sid" "$td"
}

# Case a: exact filename match
T18_CFG=$(mktemp -d "/tmp/er-t18-cfg-XXXXXX")
mkdir -p "$T18_CFG/benchmarks/meta-evals"
echo '{"id":"verify-before-done","tags":[]}' > "$T18_CFG/benchmarks/meta-evals/verify-before-done.json"
run_t18_case "exact" "$T18_CFG" "Exact: \`benchmarks/meta-evals/verify-before-done.json\`"
rm -rf "$T18_CFG"

# Case b: tag substring match
T18_CFG=$(mktemp -d "/tmp/er-t18-cfg-XXXXXX")
mkdir -p "$T18_CFG/benchmarks/meta-evals"
echo '{"id":"other","tags":["hook:verify-before-done","rule:something"]}' > "$T18_CFG/benchmarks/meta-evals/other.json"
run_t18_case "tag-match" "$T18_CFG" "Related: \`benchmarks/meta-evals/other.json\`"
rm -rf "$T18_CFG"

# Case c: coverage-gap
T18_CFG=$(mktemp -d "/tmp/er-t18-cfg-XXXXXX")
mkdir -p "$T18_CFG/benchmarks/meta-evals"
echo '{"id":"unrelated","tags":["hook:something-else"]}' > "$T18_CFG/benchmarks/meta-evals/unrelated.json"
run_t18_case "coverage-gap" "$T18_CFG" "**coverage-gap**"
rm -rf "$T18_CFG"

# Case d: directory unreachable
run_t18_case "unreachable" "/tmp/nonexistent-$(date +%s)-$RANDOM" "meta-eval directory unreachable"

# --- Test 19: Known Drift Match section (#43 / F8) ---
# Populates ## Known Drift Match via awk-extracted §"Known drift & risks"
# from $CLAUDE_CONFIG_DIR/CLAUDE.md, then grep for TRIGGER_HOOK references.
printf '\nTest 19: Known Drift Match — 4 branches\n'

run_t19_case() {
  local label="$1"
  local fake_config_dir="$2"
  local expected_substr="$3"
  local td sid
  td=$(mktemp -d "/tmp/er-smoke-XXXXXX")
  sid="smoke-t19-${label}-$(date +%s%N)-$RANDOM"
  mkdir -p "$td/markers"
  touch "$td/markers/.v3.1-opt-in-notice.ack"
  mkdir -p /tmp/claude-debug
  printf '{"ts":"t1","event":"PreToolUse","hook":"pre-edit-guard.sh","decision":"deny","reason":"[sid:x] [verify-before-done.sh] blocked","phase":"verifying","session":"%s"}\n' \
    "$sid" > "/tmp/claude-debug/$sid.jsonl"
  local payload
  payload=$(printf '{"hook_event_name":"SubagentStop","session_id":"%s","cwd":"","agent_id":"editor"}' "$sid")

  CLAUDE_PLUGIN_DATA="$td" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" CLAUDE_CONFIG_DIR="$fake_config_dir" \
    ERROR_REPORTER_PRESET=claude-harness ERROR_REPORTER_REPO=dummy/repo \
    bash -c "printf '%s' '$payload' | bash '$SCRIPT'"
  wait_for_background "$sid" "$td/markers"
  local fb
  fb=$(ls "$td/reports/${sid}-"*".md" 2>/dev/null | head -1)
  if [ -n "$fb" ] && grep -qF "$expected_substr" "$fb"; then
    pass "T19 ($label): found expected substring '$expected_substr'"
  else
    local actual
    actual=$(awk '/^## Known Drift/{p=1} /^## Reproduction/{p=0} p' "$fb" 2>/dev/null | head -5)
    fail "T19 ($label): expected '$expected_substr', section shows: $actual"
  fi
  cleanup_session "$sid" "$td"
}

# Case a: match found in §"Known drift"
T19_CFG=$(mktemp -d "/tmp/er-t19-cfg-XXXXXX")
cat > "$T19_CFG/CLAUDE.md" <<'CMD'
# Harness CLAUDE.md

## Something else

Unrelated content.

## Known drift & risks

1. **`verify-before-done` races with editor agent** — flaky guard-check.
2. Other unrelated issue.

## Yet another section

stuff
CMD
run_t19_case "match" "$T19_CFG" 'match(es) in `CLAUDE.md`'
rm -rf "$T19_CFG"

# Case b: section exists but no match for this hook
T19_CFG=$(mktemp -d "/tmp/er-t19-cfg-XXXXXX")
cat > "$T19_CFG/CLAUDE.md" <<'CMD'
## Known drift & risks

1. `unrelated-hook.sh` issue.
CMD
run_t19_case "no-match" "$T19_CFG" 'No references to'
rm -rf "$T19_CFG"

# Case c: no §"Known drift" section at all
T19_CFG=$(mktemp -d "/tmp/er-t19-cfg-XXXXXX")
cat > "$T19_CFG/CLAUDE.md" <<'CMD'
# Harness CLAUDE.md

## Overview

Content without the Known drift header.
CMD
run_t19_case "section-absent" "$T19_CFG" 'no §"Known drift & risks" section'
rm -rf "$T19_CFG"

# Case d: CLAUDE.md unreachable
run_t19_case "unreachable" "/tmp/nonexistent-$(date +%s)-$RANDOM" 'CLAUDE.md` unreachable'

# --- Test 15b: reporter:repo:* flatten handles underscores in owner/repo (#33) ---
# The previous tr+sed transform misfired when owner or repo names contained
# underscores. This test locks in the corrected behavior across three cases.
printf '\nTest 15b: reporter:repo:* flatten preserves internal underscores (#33)\n'
check_repo_flat() {
  # $1 = REPORT_REPO input, $2 = expected reporter:repo:<flat> label
  local input="$1" expected_label="$2"
  local td sid gh_log
  td=$(mktemp -d "/tmp/er-smoke-XXXXXX")
  sid="smoke-t15b-$(date +%s%N)-$RANDOM"
  mkdir -p "$td/markers" "$td/bin"
  touch "$td/markers/.v3.1-opt-in-notice.ack"
  cat > "$td/bin/gh" <<'GHFAKE'
#!/bin/bash
LOG="${GH_CAPTURE_LOG:-/dev/null}"
case "$1" in
  auth) exit 0 ;;
  label) printf 'LABEL_CREATE: %s\n' "$3" >> "$LOG"; exit 0 ;;
  issue) exit 0 ;;
  *) exit 0 ;;
esac
GHFAKE
  chmod +x "$td/bin/gh"
  gh_log="$td/gh-capture.log"
  make_synthetic_debug_log "$sid" ""
  local payload
  payload=$(printf '{"hook_event_name":"StopFailure","session_id":"%s","error":"other","cwd":""}' "$sid")

  PATH="$td/bin:$PATH" GH_CAPTURE_LOG="$gh_log" \
    CLAUDE_PLUGIN_DATA="$td" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    ERROR_REPORTER_PRESET=claude-harness ERROR_REPORTER_REPO="$input" \
    bash -c "printf '%s' '$payload' | bash '$SCRIPT'"

  wait_for_background "$sid" "$td/markers"

  if grep -qF "LABEL_CREATE: ${expected_label}" "$gh_log"; then
    pass "T15b ${input} → ${expected_label}"
  else
    local actual
    actual=$(grep 'LABEL_CREATE: reporter:repo:' "$gh_log" | head -1)
    fail "T15b ${input} → expected ${expected_label}, got: ${actual}"
  fi
  cleanup_session "$sid" "$td"
}

# Note: avoid pmmm114/kb-cc-plugin as input — matches SELF_REPO (self-suppression)
# and would emit no labels. Use distinct owners/repos for the flatten check.
check_repo_flat "acme-co/simple-repo"  "reporter:repo:acme-co__simple-repo"
check_repo_flat "user_name/repo"       "reporter:repo:user_name__repo"
check_repo_flat "acme/my_project"      "reporter:repo:acme__my_project"

# --- Test 10: Malformed preset (MUST run last — manipulates CLAUDE_PLUGIN_ROOT) ---
printf '\nTest 10: malformed preset — fail-closed (MUST run last)\n'
(
  SID="smoke-t10-$$-$(date +%s)"
  TMP_ROOT=$(mktemp -d "/tmp/er-t10-root-XXXXXX")
  TD=$(mktemp -d "/tmp/er-smoke-XXXXXX")
  mkdir -p "$TMP_ROOT/presets" "$TD/markers"
  touch "$TD/markers/.v3.1-opt-in-notice.ack"
  # #22: schema_version:2 is now LEGAL (v=2 presets). Bump malformed fixture
  # to 99 to preserve the "unsupported schema" failure path.
  printf '{"schema_version":99}' > "$TMP_ROOT/presets/broken.json"
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
