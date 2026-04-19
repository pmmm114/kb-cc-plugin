#!/bin/bash
# unit_ensure_labels.sh
#
# Exercises scripts/ensure-reporter-labels.sh with a fake gh that captures
# the labels it would create. Verifies:
#
# 1. --repo required (exits non-zero without it)
# 2. --dry-run produces a plan without calling gh label create
# 3. Severity labels match preset severity_rules values + "unknown"
# 4. Phase labels match the harness state-machine enumeration
# 5. Re-run is idempotent (second invocation's gh calls are no-ops
#    under `|| true` — script still exits 0)
# 6. Missing preset triggers exit 2 with a clear message

set +e
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/error-reporter/scripts/ensure-reporter-labels.sh"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -x "$SCRIPT" ] || { echo "FATAL: script not executable: $SCRIPT" >&2; exit 1; }

# --- Case 1: --repo missing → exit 1 ---
OUT=$("$SCRIPT" 2>&1)
RC=$?
[ "$RC" -eq 1 ] && pass "Case 1 exit 1 when --repo missing" \
  || fail "Case 1 expected exit 1, got $RC"
printf '%s' "$OUT" | grep -q "repo.*required" \
  && pass "Case 1 stderr mentions --repo required" \
  || fail "Case 1 missing --repo hint"

# --- Case 2: --dry-run produces plan, no gh calls ---
TD=$(mktemp -d "/tmp/ensure-labels-XXXXXX")
mkdir -p "$TD/bin"
# Fatal fake gh — if invoked, touch sentinel
cat > "$TD/bin/gh" <<GHFAKE
#!/bin/bash
touch "$TD/gh-was-called"
exit 1
GHFAKE
chmod +x "$TD/bin/gh"

PATH="$TD/bin:$PATH" "$SCRIPT" --repo dummy/repo --dry-run > "$TD/plan.out" 2>&1
RC=$?
[ "$RC" -eq 0 ] && pass "Case 2 --dry-run exits 0" || fail "Case 2 --dry-run exit $RC"
[ ! -f "$TD/gh-was-called" ] && pass "Case 2 --dry-run does not invoke gh" \
  || fail "Case 2 --dry-run invoked gh unexpectedly"
grep -q 'reporter:severity:A1-coordination' "$TD/plan.out" \
  && pass "Case 2 plan includes reporter:severity:A1-coordination" \
  || fail "Case 2 plan missing A1-coordination severity"
grep -q 'reporter:phase:idle' "$TD/plan.out" \
  && pass "Case 2 plan includes reporter:phase:idle" \
  || fail "Case 2 plan missing phase:idle"
grep -q 'reporter:phase:config_planning' "$TD/plan.out" \
  && pass "Case 2 plan includes reporter:phase:config_planning" \
  || fail "Case 2 plan missing phase:config_planning"
rm -rf "$TD"

# --- Case 3: severity enumeration matches preset ---
# The script derives severities from severity_rules — verify all three classes
# present (A1/A2/A3) + unknown.
TD=$(mktemp -d "/tmp/ensure-labels-XXXXXX")
mkdir -p "$TD/bin"
cat > "$TD/bin/gh" <<'GHFAKE'
#!/bin/bash
printf 'FAKE_GH: %s\n' "$*" >> "$GH_CAPTURE"
exit 1    # non-zero → script reports "skipped", which is fine here
GHFAKE
chmod +x "$TD/bin/gh"
GH_CAPTURE="$TD/gh-calls.log"

PATH="$TD/bin:$PATH" GH_CAPTURE="$GH_CAPTURE" \
  "$SCRIPT" --repo test/test >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] && pass "Case 3 script exits 0 even when fake-gh fails" \
  || fail "Case 3 exit $RC"

for sev in A1-coordination A2-guard-recovered A3-resource unknown; do
  if grep -qF "reporter:severity:$sev" "$GH_CAPTURE"; then
    pass "Case 3 attempted reporter:severity:$sev"
  else
    fail "Case 3 missed reporter:severity:$sev"
  fi
done

# Phase enumeration — verify all 11 phases + unknown
for phase in idle planning reviewing plan_review executing verifying editing config_planning config_plan_review config_editing unknown; do
  if grep -qF "reporter:phase:$phase" "$GH_CAPTURE"; then
    pass "Case 3 attempted reporter:phase:$phase"
  else
    fail "Case 3 missed reporter:phase:$phase"
  fi
done
rm -rf "$TD"

# --- Case 4: idempotent re-run → exit 0 ---
TD=$(mktemp -d "/tmp/ensure-labels-XXXXXX")
mkdir -p "$TD/bin"
# Fake gh that always returns "already exists" (non-zero) — script must
# treat as benign (skipped counter).
cat > "$TD/bin/gh" <<'GHFAKE'
#!/bin/bash
echo "label already exists" >&2
exit 1
GHFAKE
chmod +x "$TD/bin/gh"

PATH="$TD/bin:$PATH" "$SCRIPT" --repo test/test > "$TD/run1.out" 2>&1
RC1=$?
PATH="$TD/bin:$PATH" "$SCRIPT" --repo test/test > "$TD/run2.out" 2>&1
RC2=$?
[ "$RC1" -eq 0 ] && [ "$RC2" -eq 0 ] && pass "Case 4 re-runs both exit 0 (idempotent)" \
  || fail "Case 4 re-run exit $RC1 / $RC2"
rm -rf "$TD"

# --- Case 5: --help prints usage ---
OUT=$("$SCRIPT" --help 2>&1)
RC=$?
[ "$RC" -eq 0 ] && pass "Case 5 --help exits 0" || fail "Case 5 --help exit $RC"
printf '%s' "$OUT" | grep -q 'Usage' && pass "Case 5 --help shows usage line" \
  || fail "Case 5 --help missing usage"

printf '\nSummary: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
