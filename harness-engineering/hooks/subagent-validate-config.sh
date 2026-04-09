#!/usr/bin/env bash
# SubagentStop hook: Validate config agent outputs and drive config phase transitions
#
# Handles: config-guardian, config-planner, config-editor
# Extracted from subagent-validate.sh to isolate config-domain logic.
# All phase changes are gated by validate_transition() to prevent ghost
# SubagentStop events from corrupting state after workflow interruption.

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT=$(cat)
export HOOK_INPUT="$INPUT"
# Source host core (state machine) + plugin config (path detection)
source "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/hook-lib-core.sh"
source "${CLAUDE_PLUGIN_ROOT}/hooks/hook-lib-config.sh"

if is_bypass_mode; then exit 0; fi

STOP_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')
[ "$STOP_ACTIVE" = "true" ] && exit 0

AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // ""')
LAST_MSG=$(echo "$INPUT" | jq -r '.last_assistant_message // ""')

STATE=$(read_state)
PHASE=$(get_phase "$STATE")

# --- Reusable validation: tasks.json structure ---
# Usage: _validate_tasks_json <json_string>
# Emits error and exits 2 if invalid; writes tasks.json handoff on success.
_validate_tasks_json() {
  local tasks_json="$1"
  local errors=()
  local task_count
  task_count=$(echo "$tasks_json" | jq '.tasks | length')
  if [ "$task_count" -lt 1 ]; then
    errors+=("tasks array is empty")
  fi
  if ! echo "$tasks_json" | jq -e '.execution_order' >/dev/null 2>&1; then
    errors+=("missing execution_order")
  fi
  if ! echo "$tasks_json" | jq -e '.target_branch' >/dev/null 2>&1; then
    errors+=("missing target_branch")
  fi
  local missing_fields
  missing_fields=$(echo "$tasks_json" | jq -r '
    .tasks[] | .id as $id |
    (
      (if (.id | type) != "string" or (.id | length) == 0 then "id" else empty end),
      (if (.title | type) != "string" or (.title | length) == 0 then "title" else empty end),
      (if (.scope | type) != "array" then "scope" else empty end),
      (if (.acceptance_criteria | type) != "array" or (.acceptance_criteria | length) == 0 then "acceptance_criteria" else empty end),
      (if .depends_on == null or (.depends_on | type) != "array" then "depends_on" else empty end),
      (if .action == null or (.action | type) != "string" then "action" else empty end)
    ) | "Task \($id): missing \(.)"
  ' 2>/dev/null)
  if [ -n "$missing_fields" ]; then
    while IFS= read -r line; do
      errors+=("$line")
    done <<< "$missing_fields"
  fi
  if [ "${#errors[@]}" -gt 0 ]; then
    local err_msg
    err_msg=$(printf '%s; ' "${errors[@]}")
    emit_block "tasks.json validation failed: ${err_msg%. }. Fix tasks.json and re-run."
    exit 2
  fi
  write_handoff "tasks.json" "$tasks_json"
}

# --- Reusable validation: plan.md required headers ---
# Usage: _validate_plan_headers <content> <header1> [<header2> ...]
# Emits error and exits 2 if any header is missing.
_validate_plan_headers() {
  local content="$1"
  shift
  local missing=()
  local hdr
  for hdr in "$@"; do
    # Match ## or ### followed by the header text
    local pattern
    pattern="^#{2,3} ${hdr#\#\# }"
    echo "$content" | grep -qE "$pattern" || missing+=("$hdr")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    local missing_list
    missing_list=$(printf '%s, ' "${missing[@]}")
    emit_block "Missing required headers in plan: ${missing_list%, }. Add the missing sections and re-run."
    exit 2
  fi
}

case "$AGENT_TYPE" in
  config-guardian)
    transition_phase "$PHASE" "idle"
    exit 0
    ;;

  config-planner)
    # Config planner produces a CRUD plan
    if echo "$LAST_MSG" | grep -qiE '(crud plan|create|update|delete|config.*plan)'; then
      write_handoff "config-plan.md" "$LAST_MSG"
      # Validate required headers in config-plan.md
      _validate_plan_headers "$LAST_MSG" "## Goal" "## Current State" "## CRUD Plan"
      # Extract tasks.json if present — validate structure
      TASKS_JSON=$(echo "$LAST_MSG" | sed -n '/```json/,/```/p' | sed '1d;$d')
      if [ -n "$TASKS_JSON" ] && echo "$TASKS_JSON" | jq -e '.tasks' >/dev/null 2>&1; then
        _validate_tasks_json "$TASKS_JSON"
        TASKS_FOUND=true
      else
        TASKS_FOUND=false
      fi
      # Initialize task tracking from tasks.json (synthetic T0 if absent)
      TASKS_FILE="$(handoff_dir)/tasks.json"
      init_tasks "$TASKS_FILE"
      if validate_transition "$PHASE" "config_plan_review"; then
        mutate_state '.workflow.phase = "config_plan_review" | .workflow.last_agent = "config-planner"' \
          || log_mutation_failure "subagent-validate-config.sh:config_planner_review" "${MUTATE_STATE_LAST_REASON:-unknown}"
      fi
      if [ "$TASKS_FOUND" = true ]; then
        emit_guidance "[CONFIG PLAN COMPLETE] Plan written to $(handoff_dir)/config-plan.md (tasks.json extracted). Present the config plan to the user for approval."
      else
        emit_guidance "[CONFIG PLAN COMPLETE] Plan written to $(handoff_dir)/config-plan.md (no tasks.json). Present the config plan to the user for approval."
      fi
      exit 0
    fi
    emit_block "Config plan not found in config-planner output. Expected a CRUD plan with Create/Update/Delete sections."
    exit 2
    ;;

  config-editor)
    # Config editor applies the plan — transition to verification
    if validate_transition "$PHASE" "config_verifying"; then
      mutate_state '.workflow.phase = "config_verifying" | .workflow.last_agent = "config-editor"' \
        || log_mutation_failure "subagent-validate-config.sh:config_editor_verifying" "${MUTATE_STATE_LAST_REASON:-unknown}"
    fi
    emit_guidance "[CONFIG EDIT COMPLETE] Changes applied. Delegate to config-guardian for benchmarking."
    exit 0
    ;;

  *)
    exit 0
    ;;
esac
