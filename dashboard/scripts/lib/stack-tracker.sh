#!/bin/bash
# stack-tracker.sh — Sourceable library for agent stack management.
#
# Maintains a per-session stack file tracking active agents and their cwds.
# Uses mkdir-based locking (POSIX-portable, atomic on all filesystems).
#
# Stack file: /tmp/claude-agent-stack/<session_id>
# Lock dir:   /tmp/claude-agent-stack/<session_id>.lock
#
# Usage:
#   source stack-tracker.sh
#   stack_push  <session_id> <agent_type> <cwd>
#   stack_pop   <session_id> <agent_type> <cwd>
#   stack_cleanup <session_id>

STACK_DIR="/tmp/claude-agent-stack"
MAX_LOCK_RETRIES=50

_stack_lock() {
  local session_id="$1"
  local lock_dir="$STACK_DIR/${session_id}.lock"
  local tries=0
  mkdir -p "$STACK_DIR"
  while ! mkdir "$lock_dir" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -ge "$MAX_LOCK_RETRIES" ]; then
      # Stale lock — force remove once, then retry
      rm -rf "$lock_dir"
      if ! mkdir "$lock_dir" 2>/dev/null; then
        echo "stack-tracker: failed to acquire lock after forced removal" >&2
        return 1
      fi
      return 0
    fi
    sleep 0.01
  done
}

_stack_unlock() {
  local session_id="$1"
  rmdir "$STACK_DIR/${session_id}.lock" 2>/dev/null || true
}

stack_push() {
  local session_id="$1" agent_type="$2" cwd="$3"
  local stack_file="$STACK_DIR/$session_id"
  local entry="${agent_type}|${cwd}"

  _stack_lock "$session_id" || return 1
  echo "$entry" >> "$stack_file"
  _stack_unlock "$session_id"
}

stack_pop() {
  local session_id="$1" agent_type="$2" cwd="$3"
  local stack_file="$STACK_DIR/$session_id"
  local entry="${agent_type}|${cwd}"

  [ ! -f "$stack_file" ] && return 0

  _stack_lock "$session_id" || return 1
  if [ -f "$stack_file" ]; then
    local tmp="${stack_file}.tmp.$$"
    grep -vxF "$entry" "$stack_file" > "$tmp" || true
    mv "$tmp" "$stack_file"
  fi
  _stack_unlock "$session_id"
}

stack_cleanup() {
  local session_id="$1"
  rm -f "$STACK_DIR/${session_id}"
  rm -rf "$STACK_DIR/${session_id}.lock"
}
