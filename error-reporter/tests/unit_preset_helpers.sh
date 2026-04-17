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
# P0-1 (legacy mode — no hook_extraction set): rule hook names stay verbatim.
# Normalization only applies when PRESET_HOOK_EXTRACTION_JSON is set (see Section D).
if printf '%s' "$PRESET_DENY_FILTER_JQ" | grep -qF '"b.sh"'; then
  pass "case 1b: wildcard rule for b.sh emitted (legacy path)"
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
  pass 'case 2a: wildcard emits ($h == "c.sh") (legacy path — no hook_extraction)'
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
# 3-layer parens: (($h == "d.sh") and (...)) — legacy path preserves .sh
if printf '%s' "$PRESET_DENY_FILTER_JQ" | grep -qF '(($h == "d.sh") and ('; then
  pass "case 3b: 3-layer parenthesization present"
else
  fail "case 3b: 3-layer parens missing — operator precedence risk"
fi

# Case 4: Quote injection (E8 byte-pinning)
hook='e".sh'
phase=$'p$x`z\\n'
# Build JSON safely via jq (avoid bash interpolation hazards)
# shellcheck disable=SC2034  # consumed by sourced _build_deny_filter on next line
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

# Load the real preset for severity tests.
# _load_preset requires CLAUDE_PLUGIN_ROOT to locate the preset file.
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT/error-reporter"
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
# Section D: hook_extraction dual-mode semantics (P0-1 defensive path)
# ============================================================================
# Locks the contract that:
#   (legacy) no hook_extraction → .hook verbatim, rule clauses keep .sh
#   (normalized) hook_extraction.pattern set → capture from .reason with
#               .hook fallback, both sides stripped for symmetric match
# ============================================================================
printf '\nSection D: hook_extraction dual-mode filter semantics\n'

# --- D1: legacy path (backward compat) ---
PRESET_HOOK_EXTRACTION_JSON='null'
PRESET_DENY_RULES_JSON='[{"hook":"pre-edit-guard.sh","phases":["planning"]}]'
_build_deny_filter
# Legacy: filter should NOT reference .reason capture
if printf '%s' "$PRESET_DENY_FILTER_JQ" | grep -q 'capture'; then
  fail "case D1a: legacy filter unexpectedly contains capture() call"
else
  pass "case D1a: legacy filter uses .hook directly (no capture)"
fi
# Legacy: .hook == "pre-edit-guard.sh" record in planning → routine (filtered out)
LEGACY_IN='{"decision":"deny","hook":"pre-edit-guard.sh","phase":"planning","reason":""}'
LEGACY_OUT=$(printf '%s\n' "$LEGACY_IN" | jq -c "$PRESET_DENY_FILTER_JQ" 2>/dev/null)
[ -z "$LEGACY_OUT" ] && pass "case D1b: legacy routine deny filtered out (pre-edit-guard.sh / planning)" \
  || fail "case D1b: legacy routine deny leaked: $LEGACY_OUT"

# --- D2: normalized path (_HOOK_CALLER drift defense) ---
PRESET_HOOK_EXTRACTION_JSON='{"pattern":"\\[sid:[^\\]]+\\] \\[(?<h>[^\\]]+)\\]"}'
PRESET_DENY_RULES_JSON='[{"hook":"pre-edit-guard","phases":["planning"]}]'
_build_deny_filter
if printf '%s' "$PRESET_DENY_FILTER_JQ" | grep -q 'capture'; then
  pass "case D2a: normalized filter uses capture() on .reason"
else
  fail "case D2a: normalized filter missing capture() call"
fi
# Normalized: record with drifted .hook (hook-lib) but real guard in .reason → filtered
DRIFT_IN='{"decision":"deny","hook":"hook-lib","phase":"planning","reason":"[sid:abc:1:hook-lib] [pre-edit-guard] plan-before-act"}'
DRIFT_OUT=$(printf '%s\n' "$DRIFT_IN" | jq -c "$PRESET_DENY_FILTER_JQ" 2>/dev/null)
[ -z "$DRIFT_OUT" ] && pass "case D2b: drifted entry (.hook=hook-lib, .reason has [pre-edit-guard]) filtered out" \
  || fail "case D2b: drifted entry leaked: $DRIFT_OUT"

# --- D3: rule written with .sh suffix works in normalized mode too (symmetric strip) ---
PRESET_HOOK_EXTRACTION_JSON='{"pattern":"\\[sid:[^\\]]+\\] \\[(?<h>[^\\]]+)\\]"}'
PRESET_DENY_RULES_JSON='[{"hook":"pre-edit-guard.sh","phases":["planning"]}]'
_build_deny_filter
DRIFT_OUT2=$(printf '%s\n' "$DRIFT_IN" | jq -c "$PRESET_DENY_FILTER_JQ" 2>/dev/null)
[ -z "$DRIFT_OUT2" ] && pass "case D3: normalized mode accepts rule 'pre-edit-guard.sh' against extracted 'pre-edit-guard'" \
  || fail "case D3: symmetric-strip broken: $DRIFT_OUT2"

# ============================================================================
# Summary
# ============================================================================
printf '\nSummary: %d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
else
  exit 1
fi
