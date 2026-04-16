#!/bin/bash
# unit_preset_helpers.sh
#
# Unit tests for preset helpers defined in scripts/report.sh:
#   - Section A: _build_deny_filter edge cases (D1)
#   - Section B: _resolve_severity timeout / default branches (E6)
#   - Section C: run verify_preset_equivalence.sh (R4 / C1)
#
# These tests source report.sh's helper functions WITHOUT triggering the main
# event-processing path. To do so, the test sets a sentinel that makes report.sh
# return early (via the --self-test branch), but we then call the helpers
# directly in the test process.

set +e

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/error-reporter/scripts/report.sh"
PRESET="$REPO_ROOT/error-reporter/presets/claude-harness.json"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

# --- Helper sourcing technique ---
# report.sh starts with `set +e` then defines globals + helpers, then enters
# either the self-test branch (line ~210) or the main path. To source ONLY the
# helpers, extract the lines from line 1 through the line BEFORE the self-test
# `if [ "${1:-}" = "--self-test" ]` block. We use awk to slice out that range.
HELPERS_TMP=$(mktemp)
trap 'rm -f "$HELPERS_TMP"' EXIT
awk '
  /^# === Self-test mode/ { exit }
  { print }
' "$SCRIPT" > "$HELPERS_TMP"

# shellcheck disable=SC1090
source "$HELPERS_TMP"

# Sanity: confirm helpers exist
type _build_deny_filter >/dev/null 2>&1 || { echo "FATAL: _build_deny_filter not loaded" >&2; exit 1; }
type _load_preset      >/dev/null 2>&1 || { echo "FATAL: _load_preset not loaded" >&2;     exit 1; }
type _resolve_severity >/dev/null 2>&1 || { echo "FATAL: _resolve_severity not loaded" >&2; exit 1; }

printf 'unit_preset_helpers.sh\n'
printf '======================\n\n'

# ============================================================================
# Section A: _build_deny_filter edge cases
# ============================================================================
printf 'Section A: _build_deny_filter edge cases\n'

# Case 1: Empty phases skip
PRESET_DENY_RULES_JSON='[{"hook":"a.sh","phases":[]},{"hook":"b.sh","phases":["*"]}]'
_build_deny_filter
if printf '%s' "$PRESET_DENY_FILTER_JQ" | grep -qF '"a.sh"'; then
  fail "case 1: empty-phases rule should be skipped (a.sh found in filter)"
else
  pass "case 1a: empty-phases rule for a.sh skipped"
fi
if printf '%s' "$PRESET_DENY_FILTER_JQ" | grep -qF '"b.sh"'; then
  pass "case 1b: wildcard rule for b.sh emitted"
else
  fail "case 1b: b.sh missing from filter"
fi
# Outer prelude check
if printf '%s' "$PRESET_DENY_FILTER_JQ" | grep -qF 'select(.decision == "block" or .decision == "deny")'; then
  pass "case 1c: outer prelude preserved"
else
  fail "case 1c: outer prelude missing"
fi

# Case 2: * wildcard
PRESET_DENY_RULES_JSON='[{"hook":"c.sh","phases":["*"]}]'
_build_deny_filter
if printf '%s' "$PRESET_DENY_FILTER_JQ" | grep -qF '($h == "c.sh")'; then
  pass "case 2a: wildcard emits ($h == \"c.sh\")"
else
  fail "case 2a: wildcard emission incorrect"
fi
if printf '%s' "$PRESET_DENY_FILTER_JQ" | grep -qE 'startswith|\$p =='; then
  fail "case 2b: wildcard should not include phase constraint"
else
  pass "case 2b: no phase constraint for wildcard"
fi

# Case 3: Prefix glob (literal + prefix_* + literal)
PRESET_DENY_RULES_JSON='[{"hook":"d.sh","phases":["x","y_*","z"]}]'
_build_deny_filter
if printf '%s' "$PRESET_DENY_FILTER_JQ" | grep -qF '$p == "x"' && \
   printf '%s' "$PRESET_DENY_FILTER_JQ" | grep -qF 'startswith("y_")' && \
   printf '%s' "$PRESET_DENY_FILTER_JQ" | grep -qF '$p == "z"'; then
  pass "case 3a: phase disjunction emitted (literal + prefix + literal)"
else
  fail "case 3a: phase disjunction missing components"
fi
# 3-layer parens: (($h == "d.sh") and (...))
if printf '%s' "$PRESET_DENY_FILTER_JQ" | grep -qF '(($h == "d.sh") and ('; then
  pass "case 3b: 3-layer parenthesization present"
else
  fail "case 3b: 3-layer parens missing — operator precedence risk"
fi

# Case 4: Quote injection (E8 byte-pinning)
hook='e".sh'
phase=$'p$x`z\\n'
# Build JSON safely via jq (avoid bash interpolation hazards)
PRESET_DENY_RULES_JSON=$(jq -nc --arg h "$hook" --arg p "$phase" '[{hook: $h, phases: [$p]}]')
_build_deny_filter
# Assertion 4: jq must compile the resulting filter without error
if echo "$PRESET_DENY_FILTER_JQ" | jq -cn . >/dev/null 2>&1; then
  pass "case 4a: jq compiles filter with quote-injection payload"
else
  fail "case 4a: jq failed to compile injected filter"
fi
# Assertion 5: semantic — the matching record should be filtered OUT
INJECT_INPUT=$(jq -nc --arg h "$hook" --arg p "$phase" '{decision: "deny", hook: $h, phase: $p}')
RESULT=$(printf '%s\n' "$INJECT_INPUT" | jq -c "$PRESET_DENY_FILTER_JQ" 2>/dev/null)
if [ -z "$RESULT" ]; then
  pass "case 4b: injected record filtered as routine (empty output)"
else
  fail "case 4b: injected record passed through filter (got: $RESULT)"
fi

# ============================================================================
# Section B: _resolve_severity timeout branch
# ============================================================================
printf '\nSection B: _resolve_severity timeout branch\n'

# Load the real preset for severity tests
_load_preset claude-harness 2>/dev/null
if [ "$PRESET_LOADED" != true ]; then
  fail "Section B precondition: failed to load claude-harness preset"
else
  # Case 1: timeout substring match → A3-resource
  RESULT=$(_resolve_severity "StopFailure" "request timeout after 30s")
  if [ "$RESULT" = "A3-resource" ]; then
    pass "case B1: timeout substring → A3-resource"
  else
    fail "case B1: expected A3-resource, got $RESULT"
  fi

  # Case 2: default fallback
  RESULT=$(_resolve_severity "StopFailure" "generic failure")
  if [ "$RESULT" = "A1-coordination" ]; then
    pass "case B2: default fallback → A1-coordination"
  else
    fail "case B2: expected A1-coordination, got $RESULT"
  fi
fi

# ============================================================================
# Section C: verify_preset_equivalence.sh
# ============================================================================
printf '\nSection C: verify_preset_equivalence.sh (preset data correctness)\n'
if bash "$REPO_ROOT/error-reporter/tests/verify_preset_equivalence.sh" >/dev/null 2>&1; then
  pass "Section C: verify_preset_equivalence.sh exit 0"
else
  fail "Section C: verify_preset_equivalence.sh exit non-zero"
fi

# ============================================================================
# Summary
# ============================================================================
printf '\nSummary: %d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
else
  exit 1
fi
