#!/usr/bin/env bash
# bridge.sh — Unified entry point for forwarding Claude Code hook events
# to the dashboard via Unix socket.
#
# Dispatches by event type:
#   SubagentStart/Stop → stack management + relay
#   SessionEnd         → stack cleanup + relay
#   Tool events        → enrichment + relay
#   Everything else    → relay as-is

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SOCKET="${CLAUDE_PLUGIN_OPTION_SOCKET_PATH:-${SOCKET:-/tmp/claude-dashboard.sock}}"

# Exit early if dashboard not running (before reading stdin)
[ -S "$SOCKET" ] || exit 0

INPUT=$(cat)

# Single jq call to extract all needed fields
_relay_passthrough() {
    source "$PLUGIN_ROOT/scripts/lib/socket-relay.sh"
    relay_to_socket "$INPUT" "$SOCKET"
    exit 0
}

if ! command -v jq &>/dev/null; then
    _relay_passthrough
fi

eval "$(echo "$INPUT" | jq -r '@sh "EVENT=\(.hook_event_name // "") SESSION_ID=\(.session_id // "default") CWD=\(.cwd // "") AGENT_TYPE=\(.agent_type // "")"' 2>/dev/null)" || _relay_passthrough

# Source lib modules
source "$PLUGIN_ROOT/scripts/lib/stack-tracker.sh"
source "$PLUGIN_ROOT/scripts/lib/enrichment.sh"
source "$PLUGIN_ROOT/scripts/lib/socket-relay.sh"

# Dispatch by event type
case "$EVENT" in
    SubagentStart)
        [ -n "$AGENT_TYPE" ] && stack_push "$SESSION_ID" "$AGENT_TYPE" "$CWD"
        relay_to_socket "$INPUT" "$SOCKET"
        ;;
    SubagentStop)
        [ -n "$AGENT_TYPE" ] && stack_pop "$SESSION_ID" "$AGENT_TYPE" "$CWD"
        relay_to_socket "$INPUT" "$SOCKET"
        ;;
    SessionEnd)
        stack_cleanup "$SESSION_ID"
        relay_to_socket "$INPUT" "$SOCKET"
        ;;
    PreToolUse|PostToolUse|PostToolUseFailure)
        ENRICHED=$(enrich_tool_event "$INPUT" "$SESSION_ID" "$EVENT" "$CWD")
        relay_to_socket "$ENRICHED" "$SOCKET"
        ;;
    *)
        relay_to_socket "$INPUT" "$SOCKET"
        ;;
esac

exit 0
