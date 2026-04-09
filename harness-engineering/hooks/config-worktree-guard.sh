#!/usr/bin/env bash
# PreToolUse hook: Enforce worktree isolation for config file modifications
#
# Matchers: Edit|Write (file_path check), Bash (command pattern check)
# Sources hook-lib.sh for is_config_path and is_write_to_config

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT=$(cat)
export HOOK_INPUT="$INPUT"
# Source host core (state machine) + plugin config (path detection)
source "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/hook-lib-core.sh"
source "${CLAUDE_PLUGIN_ROOT}/hooks/hook-lib-config.sh"

if is_bypass_mode; then exit 0; fi

# Narrow escape hatch for /kb-cc-config bootstrap operations.
# The skill must create the worktree and set phase state BEFORE the worktree
# exists, so the worktree guard would otherwise self-block those steps.
# Only the specific bootstrap-critical operations are exempted:
#   - git worktree add / git branch targeting a config/* branch
#   - writes to session state files (/tmp/claude-session/*.json)
# Arbitrary config-file edits are NOT exempted — this is intentionally narrow.
if is_skill_context "kb-cc-config"; then
  _TOOL_NAME_EARLY=$(echo "$INPUT" | jq -r '.tool_name // ""')
  if [ "$_TOOL_NAME_EARLY" = "Bash" ]; then
    _CMD_EARLY=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
    # git worktree add or git branch (create) targeting config/* branch.
    # Branch deletion (-d, -D, --delete) and read-only flags (-l, --list, --show-current, -v, --verbose) are excluded.
    if echo "$_CMD_EARLY" | grep -qE '(git[[:space:]]+worktree[[:space:]]+add|git[[:space:]]+branch)[[:space:]].*config/' && \
       ! echo "$_CMD_EARLY" | grep -qE 'git[[:space:]]+branch[[:space:]]+(-d|-D|--delete|-l|--list|--show-current|-v|--verbose)[[:space:]]'; then
      exit 0
    fi
    # Write to session state file
    if echo "$_CMD_EARLY" | grep -qE '/tmp/claude-session/[^/]+\.json'; then
      exit 0
    fi
  fi
  # Edit/Write to session state file
  if [ "$_TOOL_NAME_EARLY" = "Edit" ] || [ "$_TOOL_NAME_EARLY" = "Write" ]; then
    _FILE_EARLY=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')
    if echo "$_FILE_EARLY" | grep -qE '^(/private)?/tmp/claude-session/[^/]+\.json$'; then
      exit 0
    fi
  fi
fi

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""')

# --- Determine if target is a config file ---
TARGET_IS_CONFIG=false

if [ "$TOOL_NAME" = "Edit" ] || [ "$TOOL_NAME" = "Write" ]; then
  FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')
  if [ -n "$FILE_PATH" ] && is_config_path "$FILE_PATH"; then
    TARGET_IS_CONFIG=true
  fi
elif [ "$TOOL_NAME" = "Bash" ]; then
  # Any active skill marker (new-style or legacy /pr) means the Bash command
  # is part of a skill workflow (e.g., `gh pr create` from /pr skill).
  # Bypass the config-write check entirely — the narrow kb-cc-config escape
  # hatch above still handles bootstrap ops; this is the broader skill escape.
  COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
  if is_skill_context any && ! is_write_to_config "$COMMAND"; then exit 0; fi
  if is_write_to_config "$COMMAND"; then
    TARGET_IS_CONFIG=true
  fi
  # Detect config worktree/branch creation outside config phases.
  # Branch deletion (-d, -D, --delete) and read-only flags (-l, --list, --show-current, -v, --verbose) are excluded.
  if echo "$COMMAND" | grep -qE '(git[[:space:]]+worktree[[:space:]]+add|git[[:space:]]+branch)[[:space:]].*config/' && \
     ! echo "$COMMAND" | grep -qE 'git[[:space:]]+branch[[:space:]]+(-d|-D|--delete|-l|--list|--show-current|-v|--verbose)[[:space:]]'; then
    STATE=$(read_state)
    PHASE=$(get_phase "$STATE")
    case "$PHASE" in
      config_planning|config_plan_review|config_editing|config_verifying) ;;
      *)
        emit_deny_json "$(format_deny_message "[config-worktree-guard]" "Config worktree/branch creation blocked in phase '$PHASE'. Config changes require /kb-cc-config. Use \`/kb-cc-config <description>\` to start a config workflow." "rules/config.md#worktree-isolation")"
        exit 0
        ;;
    esac
  fi
fi

[ "$TARGET_IS_CONFIG" = "false" ] && exit 0

# --- Config target: check worktree ---
CWD=$(echo "$INPUT" | jq -r '.cwd // ""')
GIT_DIR=$(git -C "$CWD" rev-parse --git-dir 2>/dev/null)
GIT_COMMON_DIR=$(git -C "$CWD" rev-parse --git-common-dir 2>/dev/null)

if [ -z "$GIT_DIR" ]; then
  emit_deny_json "$(format_deny_message "[config-worktree-guard]" "Config file modification blocked. Not inside a git repository.\n\nTo proceed:\n  1. git branch config/<domain>-<name> main\n  2. git worktree add /tmp/claude-config-<name> config/<domain>-<name>\n  3. Work inside the worktree directory" "rules/config.md#worktree-isolation")"
  exit 0
fi

if [ "$GIT_DIR" = "$GIT_COMMON_DIR" ] || [ "$GIT_DIR" = ".git" ]; then
  emit_deny_json "$(format_deny_message "[config-worktree-guard]" "Config file modification blocked in main working tree.\n\nConfig changes must be made in a dedicated worktree.\n\nTo proceed:\n  1. git branch config/<domain>-<name> main\n  2. git worktree add /tmp/claude-config-<name> config/<domain>-<name>\n  3. Work inside the worktree directory" "rules/config.md#worktree-isolation")"
  exit 0
fi

exit 0
