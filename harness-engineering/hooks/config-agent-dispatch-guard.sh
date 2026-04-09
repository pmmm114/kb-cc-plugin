#!/usr/bin/env bash
# PreToolUse hook (matcher: Agent): Block config agent dispatch without /kb-cc-config
#
# Gates config-planner and config-editor dispatch to ensure they only run
# inside a config workflow phase (started by /kb-cc-config skill).
# config-guardian is already gated by config-guardian-worktree-guard.sh.
#
# Detection: checks tool_input.subagent_type only.

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT=$(cat)
export HOOK_INPUT="$INPUT"
# Source host core (state machine) + plugin config (path detection)
source "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/hook-lib-core.sh"
source "${CLAUDE_PLUGIN_ROOT}/hooks/hook-lib-config.sh"

if is_bypass_mode; then exit 0; fi

# --- Only gate config-planner and config-editor ---
TOOL_INPUT=$(echo "$INPUT" | jq -r '.tool_input // ""')
[ -z "$TOOL_INPUT" ] || [ "$TOOL_INPUT" = "" ] && exit 0

SUBAGENT_TYPE=$(echo "$TOOL_INPUT" | jq -r '.subagent_type // ""' 2>/dev/null)

case "$SUBAGENT_TYPE" in
  config-planner|config-editor) ;;
  *) exit 0 ;;
esac

# --- Phase check: only allow in config workflow phases ---
STATE=$(read_state)
PHASE=$(get_phase "$STATE")

case "$PHASE" in
  config_planning|config_plan_review|config_editing|config_verifying)
    # Valid config phase — allow dispatch
    exit 0
    ;;
  *)
    DENY_BODY="Cannot dispatch $SUBAGENT_TYPE in phase '$PHASE'."
    DENY_BODY="$DENY_BODY Config changes require /kb-cc-config."
    DENY_BODY="$DENY_BODY Use \`/kb-cc-config <description>\` to start a config workflow."
    emit_deny_json "$(format_deny_message "[config-agent-dispatch-guard]" "$DENY_BODY" "rules/config.md#worktree-isolation")"
    exit 0
    ;;
esac
