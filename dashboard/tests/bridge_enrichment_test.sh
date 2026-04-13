#!/usr/bin/env bash
# bridge_enrichment_test.sh — Tests for bridge.sh agent context enrichment
#
# Tests verify that bridge.sh correctly enriches tool events with agent_context_type
# from the agent stack file, and passes through non-tool events unchanged.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BRIDGE="$SCRIPT_DIR/../scripts/bridge.sh"
TEST_SESSION_ID="test-session-$$"
STACK_DIR="/tmp/claude-agent-stack"
STACK_FILE="$STACK_DIR/$TEST_SESSION_ID"
TEST_SOCKET="/tmp/claude-dashboard-test-$$.sock"

PASS=0
FAIL=0

cleanup() {
  rm -f "$STACK_FILE" "$TEST_SOCKET" 2>/dev/null
  rmdir "$STACK_DIR" 2>/dev/null || true
  # Kill socat listener if running
  [ -n "${SOCAT_PID:-}" ] && kill "$SOCAT_PID" 2>/dev/null || true
  rm -f "/tmp/bridge-test-output-$$" 2>/dev/null
}
trap cleanup EXIT

start_listener() {
  rm -f "$TEST_SOCKET"
  socat UNIX-LISTEN:"$TEST_SOCKET",fork OPEN:"/tmp/bridge-test-output-$$",creat,append &
  SOCAT_PID=$!
  sleep 0.1
}

stop_listener() {
  [ -n "${SOCAT_PID:-}" ] && kill "$SOCAT_PID" 2>/dev/null || true
  wait "$SOCAT_PID" 2>/dev/null || true
  SOCAT_PID=""
  sleep 0.05
}

get_output() {
  # Normalize to compact JSON for reliable string matching
  jq -c '.' "/tmp/bridge-test-output-$$" 2>/dev/null || cat "/tmp/bridge-test-output-$$" 2>/dev/null || echo ""
}

reset_output() {
  : > "/tmp/bridge-test-output-$$"
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "    expected: $expected"
    echo "    actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "    expected to contain: $needle"
    echo "    actual: $haystack"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if ! echo "$haystack" | grep -qF "$needle"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "    expected NOT to contain: $needle"
    echo "    actual: $haystack"
    FAIL=$((FAIL + 1))
  fi
}

# Prerequisite checks
if ! command -v socat &>/dev/null; then
  echo "SKIP: socat not available for socket listener tests"
  exit 0
fi
if ! command -v jq &>/dev/null; then
  echo "SKIP: jq not available"
  exit 0
fi

mkdir -p "$STACK_DIR"

echo "=== bridge.sh enrichment tests ==="
echo ""

# --- Test 1: Tool event with matching agent in stack -> enriched ---
echo "Test 1: Tool event with matching agent in stack -> enriched"
start_listener
reset_output

echo "planner|/Users/kb/project" > "$STACK_FILE"

TOOL_EVENT=$(jq -n \
  --arg event "PreToolUse" \
  --arg session "$TEST_SESSION_ID" \
  --arg cwd "/Users/kb/project" \
  --arg tool "Read" \
  '{hook_event_name: $event, session_id: $session, cwd: $cwd, tool_name: $tool}')

echo "$TOOL_EVENT" | SOCKET="$TEST_SOCKET" bash "$BRIDGE"
sleep 0.2

OUTPUT=$(get_output)
assert_contains "agent_context_type is injected" '"agent_context_type":"planner"' "$OUTPUT"
assert_contains "original fields preserved" '"tool_name":"Read"' "$OUTPUT"
stop_listener

echo ""

# --- Test 2: Tool event with no stack file -> passthrough ---
echo "Test 2: Tool event with no stack file -> passthrough"
start_listener
reset_output

rm -f "$STACK_FILE"

TOOL_EVENT=$(jq -n \
  --arg event "PostToolUse" \
  --arg session "$TEST_SESSION_ID" \
  --arg cwd "/Users/kb/project" \
  --arg tool "Edit" \
  '{hook_event_name: $event, session_id: $session, cwd: $cwd, tool_name: $tool}')

echo "$TOOL_EVENT" | SOCKET="$TEST_SOCKET" bash "$BRIDGE"
sleep 0.2

OUTPUT=$(get_output)
assert_not_contains "no agent_context_type injected" "agent_context_type" "$OUTPUT"
assert_contains "original event forwarded" '"tool_name":"Edit"' "$OUTPUT"
stop_listener

echo ""

# --- Test 3: Tool event with no cwd match -> passthrough ---
echo "Test 3: Tool event with no cwd match -> passthrough"
start_listener
reset_output

echo "planner|/Users/kb/other-project" > "$STACK_FILE"

TOOL_EVENT=$(jq -n \
  --arg event "PostToolUseFailure" \
  --arg session "$TEST_SESSION_ID" \
  --arg cwd "/Users/kb/project" \
  --arg tool "Bash" \
  '{hook_event_name: $event, session_id: $session, cwd: $cwd, tool_name: $tool}')

echo "$TOOL_EVENT" | SOCKET="$TEST_SOCKET" bash "$BRIDGE"
sleep 0.2

OUTPUT=$(get_output)
assert_not_contains "no agent_context_type when no cwd match" "agent_context_type" "$OUTPUT"
assert_contains "original event forwarded" '"tool_name":"Bash"' "$OUTPUT"
stop_listener

echo ""

# --- Test 4: Non-tool event (SubagentStart) -> passthrough unchanged ---
echo "Test 4: Non-tool event (SubagentStart) -> passthrough unchanged"
start_listener
reset_output

echo "planner|/Users/kb/project" > "$STACK_FILE"

NON_TOOL_EVENT=$(jq -n \
  --arg event "SubagentStart" \
  --arg session "$TEST_SESSION_ID" \
  --arg cwd "/Users/kb/project" \
  --arg agent "planner" \
  '{hook_event_name: $event, session_id: $session, cwd: $cwd, agent_type: $agent}')

echo "$NON_TOOL_EVENT" | SOCKET="$TEST_SOCKET" bash "$BRIDGE"
sleep 0.2

OUTPUT=$(get_output)
assert_not_contains "no enrichment for non-tool events" "agent_context_type" "$OUTPUT"
assert_contains "original event forwarded" '"agent_type":"planner"' "$OUTPUT"
stop_listener

echo ""

# --- Test 5: Multiple agents in stack, correct cwd match ---
echo "Test 5: Multiple agents in stack, correct cwd match"
start_listener
reset_output

printf "planner|/Users/kb/project-a\ntdd-implementer|/Users/kb/project-b\nconfig-editor|/Users/kb/project-c\n" > "$STACK_FILE"

TOOL_EVENT=$(jq -n \
  --arg event "PreToolUse" \
  --arg session "$TEST_SESSION_ID" \
  --arg cwd "/Users/kb/project-b" \
  --arg tool "Grep" \
  '{hook_event_name: $event, session_id: $session, cwd: $cwd, tool_name: $tool}')

echo "$TOOL_EVENT" | SOCKET="$TEST_SOCKET" bash "$BRIDGE"
sleep 0.2

OUTPUT=$(get_output)
assert_contains "correct agent matched by cwd" '"agent_context_type":"tdd-implementer"' "$OUTPUT"
assert_contains "original fields preserved" '"tool_name":"Grep"' "$OUTPUT"
stop_listener

echo ""

# --- Test 6: PostToolUseFailure event enriched ---
echo "Test 6: PostToolUseFailure event enriched when stack matches"
start_listener
reset_output

echo "tdd-implementer|/Users/kb/project" > "$STACK_FILE"

TOOL_EVENT=$(jq -n \
  --arg event "PostToolUseFailure" \
  --arg session "$TEST_SESSION_ID" \
  --arg cwd "/Users/kb/project" \
  --arg tool "Write" \
  '{hook_event_name: $event, session_id: $session, cwd: $cwd, tool_name: $tool}')

echo "$TOOL_EVENT" | SOCKET="$TEST_SOCKET" bash "$BRIDGE"
sleep 0.2

OUTPUT=$(get_output)
assert_contains "PostToolUseFailure is enriched" '"agent_context_type":"tdd-implementer"' "$OUTPUT"
stop_listener

echo ""

# --- Test 7: Empty stack file -> passthrough ---
echo "Test 7: Empty stack file -> passthrough"
start_listener
reset_output

: > "$STACK_FILE"

TOOL_EVENT=$(jq -n \
  --arg event "PreToolUse" \
  --arg session "$TEST_SESSION_ID" \
  --arg cwd "/Users/kb/project" \
  --arg tool "Read" \
  '{hook_event_name: $event, session_id: $session, cwd: $cwd, tool_name: $tool}')

echo "$TOOL_EVENT" | SOCKET="$TEST_SOCKET" bash "$BRIDGE"
sleep 0.2

OUTPUT=$(get_output)
assert_not_contains "no enrichment with empty stack" "agent_context_type" "$OUTPUT"
stop_listener

echo ""

# --- Summary ---
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
