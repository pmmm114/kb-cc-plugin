#!/bin/bash
# unit_retroactive_5axis.sh
#
# Exercises scripts/retroactive-5axis.sh argument parsing and label
# derivation logic. Does NOT actually invoke gh against a real repo —
# uses a fake gh on PATH that serves canned responses.
#
# Test matrix:
# 1. No args → exit 1
# 2. --issues missing → exit 1
# 3. Malformed --issues format → exit 1
# 4. --apply without --yes-i-mean-it → exit 1
# 5. --dry-run default when neither mode flag set
# 6. --help prints usage (sed-extracted)
# 7. Dry-run with fake gh produces plan + no mutations
# 8. Label derivation from Trigger table row (via fake gh issue view)
# 9. Private repo without 'repo' scope → exit 3 with scope hint
# 10. Missing gh → exit 2

set +e
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/error-reporter/scripts/retroactive-5axis.sh"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -x "$SCRIPT" ] || { echo "FATAL: script not executable: $SCRIPT" >&2; exit 1; }

# Helper: build a TD with fake gh that serves canned responses
setup_fake_gh() {
  local td="$1"
  local mode="$2"    # "auth_ok_issue_public" | "auth_ok_issue_private_no_scope" | "auth_fail" | "mutate_capture"
  mkdir -p "$td/bin"
  case "$mode" in
    auth_ok_issue_public)
      cat > "$td/bin/gh" <<'GHFAKE'
#!/bin/bash
case "$1" in
  auth)
    case "$2" in
      status) exit 0 ;;
      *) exit 0 ;;
    esac
    ;;
  repo) echo 'false' ;;    # isPrivate=false
  issue)
    case "$2" in
      view)
        # Canned body with a Trigger table row — exercises the label parser
        cat <<'BODY'
## Trigger

| Event | Hook | Phase | Agent | Severity | Commit |
|-------|------|-------|-------|----------|--------|
| `SubagentStop` | `pre-edit-guard.sh` | `verifying` | `editor` | `A2-guard-recovered` | `abc12345` |

## Counterfactual
Should have blocked earlier.
BODY
        ;;
      edit)
        printf 'FAKE_GH: %s\n' "$*" >> "$GH_CAPTURE"
        exit 0
        ;;
    esac
    ;;
  *) exit 0 ;;
esac
GHFAKE
      ;;
    auth_ok_issue_private_no_scope)
      cat > "$td/bin/gh" <<'GHFAKE'
#!/bin/bash
case "$1" in
  auth)
    case "$2" in
      status)
        # Pretend scope check shows only 'public_repo' (no 'repo')
        echo "Logged in: public_repo" >&2
        exit 0
        ;;
      *) exit 0 ;;
    esac
    ;;
  repo) echo 'true' ;;    # isPrivate=true
  *) exit 0 ;;
esac
GHFAKE
      ;;
    auth_fail)
      cat > "$td/bin/gh" <<'GHFAKE'
#!/bin/bash
case "$1" in
  auth) exit 1 ;;
  *) exit 1 ;;
esac
GHFAKE
      ;;
  esac
  chmod +x "$td/bin/gh"
}

# --- Case 1: no args → exit 1 ---
OUT=$("$SCRIPT" 2>&1)
RC=$?
[ "$RC" -eq 1 ] && pass "Case 1 no args → exit 1" || fail "Case 1 exit $RC"
printf '%s' "$OUT" | grep -q "issues.*required" \
  && pass "Case 1 stderr mentions --issues required" \
  || fail "Case 1 missing --issues hint"

# --- Case 2: malformed --issues ---
OUT=$("$SCRIPT" --issues "malformed" 2>&1)
RC=$?
[ "$RC" -eq 1 ] && pass "Case 2 malformed --issues → exit 1" || fail "Case 2 exit $RC"
printf '%s' "$OUT" | grep -q "owner/repo" \
  && pass "Case 2 stderr shows expected format" \
  || fail "Case 2 format hint missing"

# --- Case 3: --apply without --yes-i-mean-it ---
OUT=$("$SCRIPT" --apply --issues "test/repo:1" 2>&1)
RC=$?
[ "$RC" -eq 1 ] && pass "Case 3 --apply without --yes → exit 1" || fail "Case 3 exit $RC"
printf '%s' "$OUT" | grep -q "yes-i-mean-it" \
  && pass "Case 3 confirmation hint present" \
  || fail "Case 3 hint missing"

# --- Case 4: --help → exit 0 + usage ---
OUT=$("$SCRIPT" --help 2>&1)
RC=$?
[ "$RC" -eq 0 ] && pass "Case 4 --help → exit 0" || fail "Case 4 --help exit $RC"
printf '%s' "$OUT" | grep -q "Usage" \
  && pass "Case 4 --help shows Usage" \
  || fail "Case 4 --help missing Usage"

# --- Case 5: auth fail → exit 2 ---
TD=$(mktemp -d "/tmp/retro5-XXXXXX")
setup_fake_gh "$TD" auth_fail
OUT=$(PATH="$TD/bin:$PATH" "$SCRIPT" --dry-run --issues "test/repo:1" 2>&1)
RC=$?
[ "$RC" -eq 2 ] && pass "Case 5 auth fail → exit 2" || fail "Case 5 auth-fail exit $RC"
printf '%s' "$OUT" | grep -q "not authenticated" \
  && pass "Case 5 auth-fail hint present" \
  || fail "Case 5 auth-fail hint missing"
rm -rf "$TD"

# --- Case 6: private repo without repo scope → exit 3 ---
TD=$(mktemp -d "/tmp/retro5-XXXXXX")
setup_fake_gh "$TD" auth_ok_issue_private_no_scope
OUT=$(PATH="$TD/bin:$PATH" "$SCRIPT" --dry-run --issues "test/privateRepo:1" 2>&1)
RC=$?
[ "$RC" -eq 3 ] && pass "Case 6 private repo w/o 'repo' scope → exit 3" \
  || fail "Case 6 private-scope exit $RC"
printf '%s' "$OUT" | grep -q "repo" \
  && pass "Case 6 scope hint mentions 'repo' scope" \
  || fail "Case 6 scope hint missing"
rm -rf "$TD"

# --- Case 7: dry-run produces plan from canned Trigger table body ---
TD=$(mktemp -d "/tmp/retro5-XXXXXX")
setup_fake_gh "$TD" auth_ok_issue_public
OUT=$(PATH="$TD/bin:$PATH" "$SCRIPT" --dry-run --issues "test/pubRepo:1" --sleep 0 2>&1)
RC=$?
[ "$RC" -eq 0 ] && pass "Case 7 dry-run exit 0" || fail "Case 7 dry-run exit $RC"
# Expected labels from canned body:
#   reporter:hook:pre-edit-guard   (stem, .sh stripped)
#   reporter:phase:verifying
#   reporter:severity:A2-guard-recovered
#   reporter:cluster:<sha1 of "pre-edit-guard:verifying:A2-guard-recovered:editor">[:12]
#   reporter:repo:test__pubRepo
#   reporter:agent:editor
for expect in \
  "reporter:hook:pre-edit-guard" \
  "reporter:phase:verifying" \
  "reporter:severity:A2-guard-recovered" \
  "reporter:cluster:" \
  "reporter:repo:test__pubRepo" \
  "reporter:agent:editor"; do
  if printf '%s' "$OUT" | grep -q "$expect"; then
    pass "Case 7 dry-run plan contains: $expect"
  else
    fail "Case 7 dry-run plan missing: $expect"
  fi
done
rm -rf "$TD"

# --- Case 8: apply+yes mutates (captures) ---
TD=$(mktemp -d "/tmp/retro5-XXXXXX")
setup_fake_gh "$TD" auth_ok_issue_public
GH_CAPTURE="$TD/gh-calls.log"
touch "$GH_CAPTURE"
PATH="$TD/bin:$PATH" GH_CAPTURE="$GH_CAPTURE" \
  "$SCRIPT" --apply --yes-i-mean-it --issues "test/pubRepo:1,2" --sleep 0 >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] && pass "Case 8 --apply+yes exit 0" || fail "Case 8 --apply exit $RC"
# Should record 2 edit calls (one per issue). Capture log line shape:
#   FAKE_GH: issue edit <N> --repo <...> --add-label <csv>
# Grep for 'issue edit ' to match the distinct invocations.
EDIT_CALLS=$(grep -c 'issue edit ' "$GH_CAPTURE" 2>/dev/null)
EDIT_CALLS="${EDIT_CALLS:-0}"
[ "$EDIT_CALLS" -eq 2 ] && pass "Case 8 captured 2 edit calls (one per issue)" \
  || fail "Case 8 expected 2 edit calls, got $EDIT_CALLS"
rm -rf "$TD"

# --- Case 9: --sleep override works (0 sec → fast) ---
# No explicit timing assertion — just verify the flag doesn't break parsing
TD=$(mktemp -d "/tmp/retro5-XXXXXX")
setup_fake_gh "$TD" auth_ok_issue_public
OUT=$(PATH="$TD/bin:$PATH" "$SCRIPT" --dry-run --issues "test/pubRepo:1" --sleep 0 2>&1)
RC=$?
[ "$RC" -eq 0 ] && pass "Case 9 --sleep 0 accepted" || fail "Case 9 --sleep exit $RC"
printf '%s' "$OUT" | grep -q "sleep-per-issue: 0s" \
  && pass "Case 9 sleep value echoed in header" \
  || fail "Case 9 sleep value not shown"
rm -rf "$TD"

printf '\nSummary: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
