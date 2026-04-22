#!/bin/bash
# unit_incident_to_eval.sh
#
# Exercises scripts/incident-to-eval.py against the fixtures under
# tests/fixtures/incidents/ and asserts the documented behavior:
#
# 1. Empty Counterfactual → exit 2 refuse-to-generate
# 2. Filled Counterfactual → exit 0 + valid JSON + expected tags
# 3. Missing Trigger table → exit 0 + empty tags + still a draft eval
# 4. --allow-empty-counterfactual bypass → exit 0 even on empty CF
# 5. Missing input flag → argparse error exit
# 6. JSON is parseable and has required top-level fields
# 7. stability:flaky + draft:true present (MVP always marks as draft)
# 8. Tag format: hook:<stem> / phase:<p> / severity:<s> / agent:<a>

set +e
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/error-reporter/scripts/incident-to-eval.py"
FX="$REPO_ROOT/error-reporter/tests/fixtures/incidents"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }
[ -f "$SCRIPT" ] || { echo "FATAL: script not found: $SCRIPT" >&2; exit 1; }

# --- Case 1: empty Counterfactual → exit 2 refuse-to-generate ---
OUT=$(python3 "$SCRIPT" --file "$FX/empty_counterfactual.md" 2>&1)
RC=$?
[ "$RC" -eq 2 ] && pass "Case 1 exit 2 on empty Counterfactual" \
  || fail "Case 1 expected exit 2, got $RC"
printf '%s\n' "$OUT" | grep -q 'refuse-to-generate' \
  && pass "Case 1 stderr mentions refuse-to-generate" \
  || fail "Case 1 stderr missing refuse-to-generate"

# --- Case 2: filled Counterfactual → exit 0, JSON, expected tags ---
TMP=$(mktemp "/tmp/iteval-XXXXXX.json")
python3 "$SCRIPT" --file "$FX/filled_valid.md" --out "$TMP" 2>/dev/null
RC=$?
[ "$RC" -eq 0 ] && pass "Case 2 exit 0 on filled CF" || fail "Case 2 exit $RC"
if [ -s "$TMP" ]; then
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$TMP" 2>/dev/null \
    && pass "Case 2 output is valid JSON" \
    || fail "Case 2 output is not valid JSON"
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get('id','').startswith('incident-') else 1)" "$TMP" \
    && pass "Case 2 id starts with 'incident-'" \
    || fail "Case 2 id does not start with incident-"
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if 'hook:pre-edit-guard' in d.get('tags',[]) else 1)" "$TMP" \
    && pass "Case 2 tags include hook:pre-edit-guard (stem, no .sh)" \
    || fail "Case 2 missing hook:pre-edit-guard tag"
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get('stability')=='flaky' and d.get('draft') is True else 1)" "$TMP" \
    && pass "Case 2 stability:flaky + draft:true (MVP)" \
    || fail "Case 2 missing stability/draft markers"
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get('config',{}).get('max_budget_usd')==0.2 else 1)" "$TMP" \
    && pass "Case 2 config.max_budget_usd=0.2" \
    || fail "Case 2 config.max_budget_usd mismatch"
else
  fail "Case 2 output file empty"
fi
rm -f "$TMP"

# --- Case 3: missing Trigger table → exit 0, empty tags ---
TMP=$(mktemp "/tmp/iteval-XXXXXX.json")
python3 "$SCRIPT" --file "$FX/no_trigger_table.md" --out "$TMP" 2>/dev/null
RC=$?
[ "$RC" -eq 0 ] && pass "Case 3 exit 0 on missing Trigger table" || fail "Case 3 exit $RC"
if [ -s "$TMP" ]; then
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get('tags',[])==[] else 1)" "$TMP" \
    && pass "Case 3 tags empty when Trigger table missing" \
    || fail "Case 3 tags non-empty unexpectedly"
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get('draft') is True else 1)" "$TMP" \
    && pass "Case 3 still marked draft:true" \
    || fail "Case 3 draft flag missing"
else
  fail "Case 3 output file empty"
fi
rm -f "$TMP"

# --- Case 4: --allow-empty-counterfactual bypass ---
TMP=$(mktemp "/tmp/iteval-XXXXXX.json")
python3 "$SCRIPT" --file "$FX/empty_counterfactual.md" --allow-empty-counterfactual --out "$TMP" 2>/dev/null
RC=$?
[ "$RC" -eq 0 ] && pass "Case 4 --allow-empty-counterfactual bypasses refuse-to-generate" \
  || fail "Case 4 exit $RC with bypass flag"
rm -f "$TMP"

# --- Case 5: no input source → argparse error ---
python3 "$SCRIPT" 2>/dev/null
RC=$?
[ "$RC" -ne 0 ] && pass "Case 5 missing input source exits non-zero" \
  || fail "Case 5 expected non-zero exit on missing source"

# --- Case 6: --stdin input path ---
TMP=$(mktemp "/tmp/iteval-XXXXXX.json")
cat "$FX/filled_valid.md" | python3 "$SCRIPT" --stdin --out "$TMP" 2>/dev/null
RC=$?
[ "$RC" -eq 0 ] && pass "Case 6 --stdin input exits 0" || fail "Case 6 --stdin exit $RC"
[ -s "$TMP" ] && pass "Case 6 --stdin produces output" || fail "Case 6 --stdin no output"
rm -f "$TMP"

# --- Case 7: --sid override ---
TMP=$(mktemp "/tmp/iteval-XXXXXX.json")
python3 "$SCRIPT" --file "$FX/filled_valid.md" --sid "cafef00d" --out "$TMP" 2>/dev/null
if [ -s "$TMP" ]; then
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get('id')=='incident-cafef00d' else 1)" "$TMP" \
    && pass "Case 7 --sid override produces incident-<sid>" \
    || fail "Case 7 --sid override not applied"
fi
rm -f "$TMP"

# --- Case 8: assertions structure (deterministic only per HG-9) ---
TMP=$(mktemp "/tmp/iteval-XXXXXX.json")
python3 "$SCRIPT" --file "$FX/filled_valid.md" --out "$TMP" 2>/dev/null
if [ -s "$TMP" ]; then
  python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
a = d.get('assertions', [])
# Every assertion must have 'type' field
if not all('type' in x for x in a): sys.exit(1)
# Every assertion type must be from the HG-9 deterministic allowlist
allowed = {'file_contains','not_file_contains','output_contains','output_not_contains','tool_was_used','tool_not_used','file_exists','max_files_changed','tool_call_count'}
if not all(x['type'] in allowed for x in a): sys.exit(2)
# Must have at least one assertion
if len(a) == 0: sys.exit(3)
" "$TMP"
  RC=$?
  case "$RC" in
    0) pass "Case 8 all assertions have type field + are deterministic + ≥1 exists" ;;
    1) fail "Case 8 assertion missing type field" ;;
    2) fail "Case 8 assertion uses non-deterministic type (HG-9 violation)" ;;
    3) fail "Case 8 no assertions generated" ;;
    *) fail "Case 8 unexpected exit $RC" ;;
  esac
fi
rm -f "$TMP"

# --- Case 9: inversion rule matches (pre-edit-guard + planning) → draft:false ---
TMP=$(mktemp "/tmp/iteval-XXXXXX.json")
python3 "$SCRIPT" --file "$FX/pre_edit_guard_planning.md" --out "$TMP" 2>/dev/null
RC=$?
[ "$RC" -eq 0 ] && pass "Case 9 exit 0 on pre-edit-guard+planning fixture" || fail "Case 9 exit $RC"
if [ -s "$TMP" ]; then
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get('draft') is False else 1)" "$TMP" \
    && pass "Case 9 inversion rule flips draft to false" \
    || fail "Case 9 draft is not false (inversion rule did not apply)"
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if any(a.get('type')=='tool_not_used' and a.get('expect')=='Edit' for a in d.get('assertions',[])) else 1)" "$TMP" \
    && pass "Case 9 assertion list contains tool_not_used(Edit)" \
    || fail "Case 9 missing tool_not_used(Edit) assertion"
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get('workspace_files') and d.get('reference_solution',{}).get('files') else 1)" "$TMP" \
    && pass "Case 9 workspace_files + reference_solution.files populated" \
    || fail "Case 9 workspace or reference_solution empty"
  # HG-9 guard: every assertion (including inversion-supplied ones) is deterministic
  python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
allowed = {'file_contains','not_file_contains','output_contains','output_not_contains','tool_was_used','tool_not_used','file_exists','max_files_changed','tool_call_count'}
sys.exit(0 if all(a.get('type') in allowed for a in d.get('assertions',[])) else 1)
" "$TMP" \
    && pass "Case 9 all assertions are HG-9 deterministic" \
    || fail "Case 9 non-deterministic assertion leaked"
else
  fail "Case 9 output file empty"
fi
rm -f "$TMP"

# --- Case 10: --no-inversion bypass → draft:true even on matching fixture ---
TMP=$(mktemp "/tmp/iteval-XXXXXX.json")
python3 "$SCRIPT" --file "$FX/pre_edit_guard_planning.md" --no-inversion --out "$TMP" 2>/dev/null
RC=$?
[ "$RC" -eq 0 ] && pass "Case 10 exit 0 with --no-inversion" || fail "Case 10 exit $RC"
if [ -s "$TMP" ]; then
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get('draft') is True else 1)" "$TMP" \
    && pass "Case 10 --no-inversion forces draft:true" \
    || fail "Case 10 --no-inversion did not force draft:true"
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get('workspace_files')=={} and d.get('reference_solution',{}).get('files')=={} else 1)" "$TMP" \
    && pass "Case 10 --no-inversion keeps workspace/reference empty" \
    || fail "Case 10 --no-inversion unexpectedly populated workspace"
else
  fail "Case 10 output file empty"
fi
rm -f "$TMP"

# --- Case 11: fixture with no matching rule → draft:true fallthrough ---
# filled_valid.md has phase=verifying → does NOT match pre-edit-guard rule
TMP=$(mktemp "/tmp/iteval-XXXXXX.json")
python3 "$SCRIPT" --file "$FX/filled_valid.md" --out "$TMP" 2>/dev/null
if [ -s "$TMP" ]; then
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get('draft') is True else 1)" "$TMP" \
    && pass "Case 11 non-matching rule falls through to draft:true" \
    || fail "Case 11 filled_valid.md unexpectedly matched a rule"
fi
rm -f "$TMP"

printf '\nSummary: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
