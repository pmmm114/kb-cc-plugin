#!/usr/bin/env bash
# PreToolUse hook (matcher: Agent): Enforce worktree isolation for config-guardian
#
# When the Agent tool is invoked to spawn config-guardian, this hook checks
# whether the current directory is a git worktree. If not, it blocks the call
# and instructs Claude to create a worktree first.
#
# Detection: checks tool_input.subagent_type only — avoids false positives
# when other agents mention "config-guardian" in their prompt text.

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT=$(cat)
export HOOK_INPUT="$INPUT"
# Source host core (state machine) + plugin config (path detection)
source "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/hook-lib-core.sh"
source "${CLAUDE_PLUGIN_ROOT}/hooks/hook-lib-config.sh"

TOOL_INPUT=$(echo "$INPUT" | jq -r '.tool_input // ""')
if [ -z "$TOOL_INPUT" ] || [ "$TOOL_INPUT" = "" ]; then
  exit 0
fi

# Check if this Agent call targets config-guardian (subagent_type only)
SUBAGENT_TYPE=$(echo "$TOOL_INPUT" | jq -r '.subagent_type // ""' 2>/dev/null)

if ! echo "$SUBAGENT_TYPE" | grep -qi 'config-guardian'; then
  exit 0
fi

# Verify we're inside a git worktree
GIT_DIR=$(git rev-parse --git-dir 2>/dev/null)
GIT_COMMON_DIR=$(git rev-parse --git-common-dir 2>/dev/null)

if [ -z "$GIT_DIR" ]; then
  _DENY_SUFFIX=""
  _CURRENT_PHASE=$(read_state | jq -r '.workflow.phase // "idle"')
  if [ "$_CURRENT_PHASE" = "config_verifying" ]; then
    mutate_state '.workflow.phase = "config_editing"' && \
      _DENY_SUFFIX="\n\nPhase rolled back to config_editing — fix the worktree issue and re-dispatch."
  fi
  emit_deny_json "$(format_deny_message "[config-guardian-worktree-guard]" "config-guardian requires a git repository. Current directory is not a git repo.\n\nNavigate to a git repository first, then create a worktree.${_DENY_SUFFIX}" "rules/config.md#worktree-isolation")"
  exit 0
fi

# In a worktree, git-dir differs from git-common-dir
# (e.g., git-dir = ../../.git/worktrees/foo, git-common-dir = ../../.git)
if [ "$GIT_DIR" = "$GIT_COMMON_DIR" ] || [ "$GIT_DIR" = ".git" ]; then
  _DENY_SUFFIX=""
  _CURRENT_PHASE=$(read_state | jq -r '.workflow.phase // "idle"')
  if [ "$_CURRENT_PHASE" = "config_verifying" ]; then
    mutate_state '.workflow.phase = "config_editing"' && \
      _DENY_SUFFIX="\n\nPhase rolled back to config_editing — fix the worktree issue and re-dispatch."
  fi
  emit_deny_json "$(format_deny_message "[config-guardian-worktree-guard]" "config-guardian must run inside a git worktree, not the main working tree.\n\nTo proceed:\n  1. Use EnterWorktree to create an isolated worktree\n  2. Then re-invoke config-guardian from within the worktree\n\nRationale: Each config change must be benchmarked in isolation (one change = one branch = one worktree).${_DENY_SUFFIX}" "rules/config.md#worktree-isolation")"
  exit 0
fi

# We're in a worktree — allow the call
exit 0
