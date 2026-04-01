#!/usr/bin/env bash
# bridge_test.sh — Tests for scripts/bridge.sh hook-to-socket forwarder
# Run: bash tests/bridge_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BRIDGE="$SCRIPT_DIR/../scripts/bridge.sh"
SOCKET="/tmp/claude-dashboard-test.sock"
PASS=0
FAIL=0

cleanup() {
    rm -f "$SOCKET"
    # Kill any background socat
    if [ -n "${LISTENER_PID:-}" ]; then
        kill "$LISTENER_PID" 2>/dev/null || true
        wait "$LISTENER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $desc (expected='$expected', actual='$actual')"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        echo "PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $desc (expected to contain '$needle', got '$haystack')"
        FAIL=$((FAIL + 1))
    fi
}

# --- Test 1: Script is executable ---
if [ -x "$BRIDGE" ]; then
    echo "PASS: bridge.sh is executable"
    PASS=$((PASS + 1))
else
    echo "FAIL: bridge.sh is not executable"
    FAIL=$((FAIL + 1))
fi

# --- Test 2: Exits 0 when socket does not exist ---
rm -f "$SOCKET"
echo '{"test":true}' | SOCKET="$SOCKET" bash "$BRIDGE"
EXIT_CODE=$?
assert_eq "exits 0 when socket does not exist" "0" "$EXIT_CODE"

# --- Test 3: Exits 0 with empty stdin and no socket ---
echo -n "" | SOCKET="$SOCKET" bash "$BRIDGE"
EXIT_CODE=$?
assert_eq "exits 0 with empty stdin and no socket" "0" "$EXIT_CODE"

# --- Test 4: Forwards JSON to socket when listener is active ---
OUTPUT_FILE=$(mktemp)
socat UNIX-LISTEN:"$SOCKET",fork OPEN:"$OUTPUT_FILE",creat,append &
LISTENER_PID=$!
sleep 0.5  # let listener start

TEST_JSON='{"hook_event_name":"PreToolUse","tool_name":"Read","session_id":"abc123"}'
echo "$TEST_JSON" | SOCKET="$SOCKET" bash "$BRIDGE"
sleep 0.5  # let data arrive

RECEIVED=$(cat "$OUTPUT_FILE")
assert_contains "forwards JSON to socket" "PreToolUse" "$RECEIVED"
assert_contains "JSON is complete" "abc123" "$RECEIVED"

kill "$LISTENER_PID" 2>/dev/null || true
wait "$LISTENER_PID" 2>/dev/null || true
unset LISTENER_PID
rm -f "$SOCKET" "$OUTPUT_FILE"

# --- Test 5: Exits 0 when socket exists but listener is gone (broken pipe) ---
# Create a socket file that nobody is listening on
socat UNIX-LISTEN:"$SOCKET" /dev/null &
TEMP_PID=$!
sleep 0.2
kill "$TEMP_PID" 2>/dev/null || true
wait "$TEMP_PID" 2>/dev/null || true
# Socket file may still exist but no one is listening
echo '{"test":"broken"}' | SOCKET="$SOCKET" bash "$BRIDGE"
EXIT_CODE=$?
assert_eq "exits 0 on broken pipe / dead socket" "0" "$EXIT_CODE"
rm -f "$SOCKET"

# --- Test 6: Handles large JSON payload ---
OUTPUT_FILE2=$(mktemp)
socat UNIX-LISTEN:"$SOCKET",fork OPEN:"$OUTPUT_FILE2",creat,append &
LISTENER_PID=$!
sleep 0.3

# Generate ~10KB JSON
LARGE_PAYLOAD=$(python3 -c "import json; print(json.dumps({'data': 'x' * 10000, 'event': 'large'}))")
echo "$LARGE_PAYLOAD" | SOCKET="$SOCKET" bash "$BRIDGE"
sleep 0.3

RECEIVED2=$(cat "$OUTPUT_FILE2")
assert_contains "handles large JSON payload" "large" "$RECEIVED2"

kill "$LISTENER_PID" 2>/dev/null || true
wait "$LISTENER_PID" 2>/dev/null || true
unset LISTENER_PID
rm -f "$SOCKET" "$OUTPUT_FILE2"

# --- Test 7: Performance — common path under 50ms ---
rm -f "$SOCKET"
START=$(python3 -c "import time; print(int(time.time() * 1000))")
echo '{"test":true}' | SOCKET="$SOCKET" bash "$BRIDGE"
END=$(python3 -c "import time; print(int(time.time() * 1000))")
ELAPSED=$((END - START))
if [ "$ELAPSED" -lt 50 ]; then
    echo "PASS: no-socket path completes in ${ELAPSED}ms (<50ms)"
    PASS=$((PASS + 1))
else
    echo "FAIL: no-socket path took ${ELAPSED}ms (expected <50ms)"
    FAIL=$((FAIL + 1))
fi

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
