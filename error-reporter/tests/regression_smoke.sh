#!/bin/bash
# regression_smoke.sh
#
# Post-merge manual verification for users upgrading from error-reporter 3.0.x.
# NOT a CI test — this touches real env and real plugin data. Run once after
# upgrading to confirm the claude-harness preset path works in your environment.
#
# Usage:
#   bash error-reporter/tests/regression_smoke.sh
#
# What it checks:
#   1. Shell-profile env (ERROR_REPORTER_PRESET + ERROR_REPORTER_REPO)
#   2. --self-test output shows preset loaded + target repo reachable
#   3. Synthetic Stop incident: fake jsonl + fake session → fallback .md
#      created, marker touched (uses fake gh; does NOT touch real repo)
#   4. Preset unset: Stop becomes no-op (opt-in notice fires once)

set +e
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/error-reporter/scripts/report.sh"
PLUGIN_ROOT="$REPO_ROOT/error-reporter"

PASS=0
FAIL=0
WARN=0
pass() { printf '  [OK] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
warn() { printf '  [WARN] %s\n' "$1"; WARN=$((WARN + 1)); }

printf 'error-reporter v3.1 regression smoke\n'
printf '=====================================\n\n'

# --- 1. Shell-profile env ---
printf '1. Shell profile env vars:\n'
if [ -n "${ERROR_REPORTER_PRESET:-}" ]; then
  pass "ERROR_REPORTER_PRESET=$ERROR_REPORTER_PRESET"
else
  warn "ERROR_REPORTER_PRESET not set — Stop/SubagentStop reporting disabled"
fi
if [ -n "${ERROR_REPORTER_REPO:-}" ]; then
  pass "ERROR_REPORTER_REPO=$ERROR_REPORTER_REPO"
else
  warn "ERROR_REPORTER_REPO not set — gh-skip mode (local archive only)"
fi

# --- 2. --self-test output ---
printf '\n2. --self-test output:\n'
OUT=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$SCRIPT" --self-test 2>&1)
RC=$?
[ "$RC" -eq 0 ] && pass "self-test exit 0" || fail "self-test exit $RC"
if printf '%s\n' "$OUT" | grep -qF "[ok]   preset: ${ERROR_REPORTER_PRESET:-claude-harness} (loaded)"; then
  pass "preset line shows loaded"
elif printf '%s\n' "$OUT" | grep -q 'preset: none'; then
  warn "preset line shows generic mode — env var missing?"
else
  fail "unexpected preset line"
fi
if printf '%s\n' "$OUT" | grep -q 'target repo reachable:'; then
  pass "target repo reachable"
elif printf '%s\n' "$OUT" | grep -q 'target repo: not configured'; then
  warn "target repo: not configured (gh-skip active)"
else
  warn "target repo unreachable (gh not authenticated or repo private?)"
fi

# --- 3. Synthetic incident injection (preset path) ---
printf '\n3. Synthetic Stop incident (preset path, fake gh):\n'
SID="regression-smoke-$$-$(date +%s)"
TD=$(mktemp -d "/tmp/er-regression-XXXXXX")
mkdir -p "$TD/markers" "$TD/bin" /tmp/claude-debug
touch "$TD/markers/.v3.1-opt-in-notice.ack"
# Fake gh — rejects everything except auth
cat > "$TD/bin/gh" <<'GH'
#!/bin/bash
case "$1" in auth) exit 0 ;; *) echo "regression-smoke fake gh: $*" >&2; exit 1 ;; esac
GH
chmod +x "$TD/bin/gh"
printf '{"ts":"2026-04-16T00:00:00Z","event":"PreToolUse","hook":"verify-before-done.sh","decision":"deny","reason":"smoke test","phase":"verifying","session":"%s"}\n' "$SID" \
  > "/tmp/claude-debug/$SID.jsonl"
INPUT=$(printf '{"hook_event_name":"Stop","session_id":"%s","transcript_path":""}' "$SID")

CLAUDE_PLUGIN_DATA="$TD" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  ERROR_REPORTER_PRESET=claude-harness ERROR_REPORTER_REPO=regression/dummy \
  PATH="$TD/bin:$PATH" \
  bash -c "printf '%s' '$INPUT' | bash '$SCRIPT'"

# Wait for fork
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -f "$TD/markers/$SID.reported" ] && break
  sleep 1
done

FALLBACK=$(ls "$TD/reports/${SID}-"*".md" 2>/dev/null | head -1)
[ -n "$FALLBACK" ] && pass "fallback .md written: $FALLBACK" || fail "no fallback .md"
[ -f "$TD/markers/$SID.reported" ] && pass "session marker touched" || fail "marker not touched"

rm -rf "$TD" "/tmp/claude-debug/$SID.jsonl"

# --- 4. Preset unset → opt-in notice ---
printf '\n4. Preset unset → opt-in notice path (one-shot):\n'
SID="regression-notice-$$-$(date +%s)"
TD=$(mktemp -d "/tmp/er-regression-XXXXXX")
INPUT=$(printf '{"hook_event_name":"Stop","session_id":"%s","transcript_path":""}' "$SID")

CLAUDE_PLUGIN_DATA="$TD" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
  bash -c "unset ERROR_REPORTER_PRESET ERROR_REPORTER_REPO; printf '%s' '$INPUT' | bash '$SCRIPT'"
sleep 1

NOTICE=$(find "$TD/reports" -type f -name 'error-reporter-notice-*.md' 2>/dev/null | head -1)
[ -n "$NOTICE" ] && pass "opt-in notice created at $NOTICE" || fail "notice not created"
[ -f "$TD/markers/.v3.1-opt-in-notice.ack" ] && pass "ack marker created" || fail "ack marker missing"
rm -rf "$TD"

# --- Summary ---
printf '\nSummary: %d OK, %d WARN, %d FAIL\n' "$PASS" "$WARN" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
  printf 'Regression smoke passed. Your v3.1 upgrade is functional.\n'
  exit 0
else
  printf 'Regression smoke FAILED. Investigate before relying on incident reporting.\n'
  exit 1
fi
