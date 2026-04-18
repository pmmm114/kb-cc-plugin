#!/bin/bash
# verify_preset_equivalence.sh
#
# Verifies that presets/claude-harness.json correctly mirrors the current
# hardcoded EXPECTED_DENY_FILTER, severity classification, and domain inference
# in scripts/report.sh.
#
# Run this BEFORE shipping a preset change — if it exits non-zero, the preset
# data has drifted from the code and would cause behavioral regression.
#
# Self-contained: does not source report.sh helpers. It re-derives the expected
# filter from the preset using a parallel jq construction, then compares
# BLOCK_COUNT and TRIGGER_HOOK against the literal filter. This way T3 can
# run before T4 helpers exist (avoids cyclic dep).

set +e

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PRESET="$REPO_ROOT/error-reporter/presets/claude-harness.json"
FIXTURE="$REPO_ROOT/error-reporter/tests/fixtures/preset_equivalence_baseline.jsonl"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -f "$PRESET" ] || { echo "FATAL: preset not found: $PRESET" >&2; exit 1; }
[ -f "$FIXTURE" ] || { echo "FATAL: fixture not found: $FIXTURE" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 1; }

# --- 1. Reference filter literal (matches current report.sh L116-131) ---
REFERENCE_FILTER='
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

# --- 2. Build preset-derived filter ---
# Parallel implementation of what _build_deny_filter will do — used here ONLY
# for cross-verification, not as a substitute for the helper.
build_preset_filter() {
  local preset_file="$1"
  local rules
  rules=$(jq -c '.routine_deny_rules // []' "$preset_file")
  local count
  count=$(printf '%s' "$rules" | jq 'length')
  local i=0
  local parts=""
  while [ "$i" -lt "$count" ]; do
    local hook
    hook=$(printf '%s' "$rules" | jq -r --argjson i "$i" '.[$i].hook')
    local phases_json
    phases_json=$(printf '%s' "$rules" | jq -c --argjson i "$i" '.[$i].phases // ["*"]')
    local plen
    plen=$(printf '%s' "$phases_json" | jq 'length')
    [ "$plen" -eq 0 ] && { i=$((i + 1)); continue; }

    # JSON-quote the hook literal so any special chars are safe in jq source
    local hook_lit
    hook_lit=$(printf '%s' "$hook" | jq -Rs .)

    local phase_disjunction=""
    local has_star=false
    local j=0
    while [ "$j" -lt "$plen" ]; do
      local p
      p=$(printf '%s' "$phases_json" | jq -r --argjson j "$j" '.[$j]')
      case "$p" in
        "*")
          has_star=true
          break
          ;;
        *_\*)
          local pfx="${p%\*}"
          local pfx_lit
          pfx_lit=$(printf '%s' "$pfx" | jq -Rs .)
          if [ -z "$phase_disjunction" ]; then
            phase_disjunction="(\$p | startswith($pfx_lit))"
          else
            phase_disjunction="$phase_disjunction or (\$p | startswith($pfx_lit))"
          fi
          ;;
        *)
          local p_lit
          p_lit=$(printf '%s' "$p" | jq -Rs .)
          if [ -z "$phase_disjunction" ]; then
            phase_disjunction="\$p == $p_lit"
          else
            phase_disjunction="$phase_disjunction or \$p == $p_lit"
          fi
          ;;
      esac
      j=$((j + 1))
    done

    local rule_clause
    if [ "$has_star" = true ]; then
      rule_clause="(\$h == $hook_lit)"
    else
      rule_clause="((\$h == $hook_lit) and ($phase_disjunction))"
    fi

    if [ -z "$parts" ]; then
      parts="$rule_clause"
    else
      parts="$parts or $rule_clause"
    fi

    i=$((i + 1))
  done

  if [ -z "$parts" ]; then
    printf 'select(.decision == "block" or .decision == "deny")'
  else
    printf '%s\n' "
      select(.decision == \"block\" or .decision == \"deny\")
      | select(
          ( (.hook // \"\") as \$h | (.phase // \"\") as \$p | ( $parts ) ) | not
        )
    "
  fi
}

PRESET_FILTER=$(build_preset_filter "$PRESET")

# --- 3. Apply both filters to the fixture ---
REFERENCE_HOOKS=$(jq -r "$REFERENCE_FILTER | .hook // empty" "$FIXTURE" 2>/dev/null)
PRESET_HOOKS=$(jq -r "$PRESET_FILTER | .hook // empty" "$FIXTURE" 2>/dev/null)

REFERENCE_COUNT=$(printf '%s\n' "$REFERENCE_HOOKS" | grep -c .)
PRESET_COUNT=$(printf '%s\n' "$PRESET_HOOKS" | grep -c .)

REFERENCE_TRIGGER=$(printf '%s\n' "$REFERENCE_HOOKS" | tail -1)
PRESET_TRIGGER=$(printf '%s\n' "$PRESET_HOOKS" | tail -1)

printf 'verify_preset_equivalence.sh\n'
printf '============================\n\n'
printf 'reference filter (current code) → BLOCK_COUNT=%s TRIGGER_HOOK=%s\n' "$REFERENCE_COUNT" "$REFERENCE_TRIGGER"
printf 'preset-derived filter           → BLOCK_COUNT=%s TRIGGER_HOOK=%s\n\n' "$PRESET_COUNT" "$PRESET_TRIGGER"

if [ "$REFERENCE_COUNT" = "$PRESET_COUNT" ]; then
  pass "BLOCK_COUNT match ($REFERENCE_COUNT)"
else
  fail "BLOCK_COUNT mismatch (ref=$REFERENCE_COUNT preset=$PRESET_COUNT)"
fi

if [ "$REFERENCE_TRIGGER" = "$PRESET_TRIGGER" ]; then
  pass "TRIGGER_HOOK match ($REFERENCE_TRIGGER)"
else
  fail "TRIGGER_HOOK mismatch (ref=$REFERENCE_TRIGGER preset=$PRESET_TRIGGER)"
fi

# --- 4. Severity equivalence ---
# Build severity resolver from preset and compare to current report.sh L159-168
resolve_severity_from_preset() {
  local event="$1"
  local sf_error="$2"
  local rule
  rule=$(jq -r --arg e "$event" '.severity_rules[$e]' "$PRESET")
  if [ "$rule" = "null" ] || [ -z "$rule" ]; then
    echo "unknown"
    return
  fi
  # If rule is an object, use .timeout grep + .default
  local rule_type
  rule_type=$(jq -r --arg e "$event" '.severity_rules[$e] | type' "$PRESET")
  if [ "$rule_type" = "object" ]; then
    if printf '%s' "$sf_error" | grep -iq timeout; then
      jq -r --arg e "$event" '.severity_rules[$e].timeout // "unknown"' "$PRESET"
    else
      jq -r --arg e "$event" '.severity_rules[$e].default // "unknown"' "$PRESET"
    fi
  else
    echo "$rule"
  fi
}

# Reference severity (current code logic)
resolve_severity_reference() {
  local event="$1"
  local sf_error="$2"
  case "$event" in
    StopFailure)
      if echo "$sf_error" | grep -qi 'timeout'; then
        echo "A3-resource"
      else
        echo "A1-coordination"
      fi
      ;;
    Stop|SubagentStop) echo "A2-guard-recovered" ;;
    *) echo "unknown" ;;
  esac
}

check_severity() {
  local event="$1"
  local sf_error="$2"
  local label="$3"
  local ref preset
  ref=$(resolve_severity_reference "$event" "$sf_error")
  preset=$(resolve_severity_from_preset "$event" "$sf_error")
  if [ "$ref" = "$preset" ]; then
    pass "severity $label: $event/$sf_error → $ref"
  else
    fail "severity $label: $event/$sf_error → ref=$ref preset=$preset"
  fi
}

check_severity "StopFailure" "request timeout after 30s" "timeout"
check_severity "StopFailure" "generic failure" "default"
check_severity "Stop" "" "Stop"
check_severity "SubagentStop" "" "SubagentStop"

# --- 5. Schema v2 invariants (#22) ---
# v=2 presets MUST drop the domain_rules and default_domain fields (removed
# in favor of 5-axis emission). v=1 presets keep them for backcompat.
PRESET_V=$(jq -r '.schema_version // empty' "$PRESET")
if [ "$PRESET_V" = "2" ]; then
  pass "preset schema_version = 2"
  HAS_DOMAIN_RULES=$(jq 'has("domain_rules")' "$PRESET")
  [ "$HAS_DOMAIN_RULES" = "false" ] && pass "v=2 preset drops domain_rules field" \
    || fail "v=2 preset still has domain_rules — should be removed"
  HAS_DEFAULT_DOMAIN=$(jq 'has("default_domain")' "$PRESET")
  [ "$HAS_DEFAULT_DOMAIN" = "false" ] && pass "v=2 preset drops default_domain field" \
    || fail "v=2 preset still has default_domain — should be removed"
elif [ "$PRESET_V" = "1" ]; then
  pass "preset schema_version = 1 (legacy; domain_rules expected)"
  DOMAIN_RULE_COUNT=$(jq '.domain_rules | length' "$PRESET")
  [ "$DOMAIN_RULE_COUNT" -ge 4 ] && pass "v=1 preset has ≥4 domain_rules ($DOMAIN_RULE_COUNT)" \
    || fail "v=1 preset has only $DOMAIN_RULE_COUNT domain_rules"
else
  fail "preset has unsupported schema_version: ${PRESET_V:-<missing>}"
fi

printf '\nSummary: %d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
else
  exit 1
fi
