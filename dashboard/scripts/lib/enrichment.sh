#!/bin/bash
# enrichment.sh — Sourceable library for hook event enrichment.
#
# Reads the agent stack file and injects agent_context_type into tool events
# when the event's cwd matches an agent on the stack.
#
# Usage:
#   source enrichment.sh
#   enriched=$(enrich_tool_event "$input_json" "$session_id" "$hook_event" "$cwd")

enrich_tool_event() {
  local input_json="$1"
  local session_id="$2"
  local hook_event="$3"
  local cwd="$4"

  # Only enrich tool events; pass through everything else
  case "$hook_event" in
    PreToolUse|PostToolUse|PostToolUseFailure) ;;
    *)
      echo "$input_json"
      return 0
      ;;
  esac

  # Require jq for enrichment; pass through without it
  if ! command -v jq &>/dev/null; then
    echo "$input_json"
    return 0
  fi

  local stack_file="/tmp/claude-agent-stack/$session_id"

  if [ -z "$cwd" ] || [ ! -f "$stack_file" ] || [ ! -s "$stack_file" ]; then
    echo "$input_json"
    return 0
  fi

  # Find first agent whose cwd matches (format: agent_type|cwd)
  local agent_type=""
  while IFS='|' read -r atype acwd; do
    if [ "$acwd" = "$cwd" ]; then
      agent_type="$atype"
      break
    fi
  done < "$stack_file"

  if [ -n "$agent_type" ]; then
    echo "$input_json" | jq -c --arg at "$agent_type" '. + {agent_context_type: $at}'
  else
    echo "$input_json"
  fi
}
