#!/bin/bash
# Tests for scripts/lib/stack-tracker.sh
# Sources the library and exercises stack_push, stack_pop, stack_cleanup.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../scripts/lib/stack-tracker.sh"

TEST_SESSION="test-session-$$"
STACK_FILE="$STACK_DIR/$TEST_SESSION"
LOCK_DIR="$STACK_FILE.lock"

PASS=0
FAIL=0

cleanup() {
  rm -f "$STACK_FILE" "${STACK_FILE}.tmp."*
  rm -rf "$LOCK_DIR"
}

trap cleanup EXIT

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    expected: $(echo "$expected" | head -5)"
    echo "    actual:   $(echo "$actual" | head -5)"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_missing() {
  local label="$1" path="$2"
  if [ ! -f "$path" ]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (file exists but should not)"
    FAIL=$((FAIL + 1))
  fi
}

# --- Test 1: stack_push creates entry ---
echo "Test 1: stack_push creates entry"
cleanup
stack_push "$TEST_SESSION" "planner" "/home/user/project"
assert_eq "stack has one line" "planner|/home/user/project" "$(cat "$STACK_FILE")"

# --- Test 2: Multiple pushes ---
echo "Test 2: Multiple pushes"
cleanup
stack_push "$TEST_SESSION" "planner" "/home/user/project"
stack_push "$TEST_SESSION" "tdd-implementer" "/tmp/worktree-a"
LINES=$(wc -l < "$STACK_FILE" | tr -d ' ')
assert_eq "stack has two lines" "2" "$LINES"
assert_eq "first line is planner" "planner|/home/user/project" "$(sed -n '1p' "$STACK_FILE")"
assert_eq "second line is tdd-implementer" "tdd-implementer|/tmp/worktree-a" "$(sed -n '2p' "$STACK_FILE")"

# --- Test 3: stack_pop removes matching line ---
echo "Test 3: stack_pop removes matching line"
cleanup
stack_push "$TEST_SESSION" "planner" "/home/user/project"
stack_push "$TEST_SESSION" "tdd-implementer" "/tmp/worktree-a"
stack_pop "$TEST_SESSION" "planner" "/home/user/project"
assert_eq "stack has one line after pop" "tdd-implementer|/tmp/worktree-a" "$(cat "$STACK_FILE")"

# --- Test 4: stack_pop with no stack file is a no-op ---
echo "Test 4: stack_pop with no stack file is a no-op"
cleanup
stack_pop "$TEST_SESSION" "planner" "/home/user/project"
RC=$?
assert_eq "exit code is 0" "0" "$RC"
assert_file_missing "stack file not created" "$STACK_FILE"

# --- Test 5: stack_pop with non-matching agent leaves stack unchanged ---
echo "Test 5: stack_pop with non-matching agent leaves stack unchanged"
cleanup
stack_push "$TEST_SESSION" "planner" "/home/user/project"
stack_pop "$TEST_SESSION" "tdd-implementer" "/tmp/worktree-a"
assert_eq "stack still has planner" "planner|/home/user/project" "$(cat "$STACK_FILE")"

# --- Test 6: Pop last entry leaves empty file ---
echo "Test 6: Pop last entry leaves empty file"
cleanup
stack_push "$TEST_SESSION" "planner" "/home/user/project"
stack_pop "$TEST_SESSION" "planner" "/home/user/project"
CONTENT=$(cat "$STACK_FILE" 2>/dev/null || echo "")
CONTENT=$(echo "$CONTENT" | sed '/^$/d')
assert_eq "stack is empty after last pop" "" "$CONTENT"

# --- Test 7: Stale lock is recovered ---
echo "Test 7: Stale lock directory is recovered"
cleanup
mkdir -p "$LOCK_DIR"
stack_push "$TEST_SESSION" "planner" "/home/user/project"
assert_eq "stack has one line despite stale lock" "planner|/home/user/project" "$(cat "$STACK_FILE")"

# --- Test 8: Duplicate agents — pop removes all matching ---
echo "Test 8: Duplicate agent entries — pop removes all matching"
cleanup
stack_push "$TEST_SESSION" "tdd-implementer" "/tmp/wt-a"
stack_push "$TEST_SESSION" "tdd-implementer" "/tmp/wt-b"
stack_push "$TEST_SESSION" "tdd-implementer" "/tmp/wt-a"
stack_pop "$TEST_SESSION" "tdd-implementer" "/tmp/wt-a"
REMAINING=$(cat "$STACK_FILE" | sed '/^$/d')
assert_eq "only wt-b remains" "tdd-implementer|/tmp/wt-b" "$REMAINING"

# --- Test 9: stack_cleanup removes stack file and lock ---
echo "Test 9: stack_cleanup removes stack file and lock dir"
cleanup
stack_push "$TEST_SESSION" "planner" "/home/user/project"
mkdir -p "$LOCK_DIR"
stack_cleanup "$TEST_SESSION"
assert_file_missing "stack file removed" "$STACK_FILE"
if [ ! -d "$LOCK_DIR" ]; then
  echo "  PASS: lock dir removed"
  PASS=$((PASS + 1))
else
  echo "  FAIL: lock dir still exists"
  FAIL=$((FAIL + 1))
fi

# --- Cleanup ---
cleanup

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
