#!/bin/bash
# socket-relay.sh — Sourceable library for Unix socket relay.
#
# Sends JSON payloads to a Unix domain socket, preferring socat over nc.
# Always returns 0 (fire-and-forget semantics).
#
# Usage:
#   source socket-relay.sh
#   relay_to_socket "$json_payload" "/tmp/claude-dashboard.sock"

relay_to_socket() {
  local input_json="$1"
  local socket_path="$2"

  [ -S "$socket_path" ] || return 0

  if command -v socat &>/dev/null; then
    echo "$input_json" | socat -t1 - UNIX-CONNECT:"$socket_path" 2>/dev/null
  elif command -v nc &>/dev/null; then
    echo "$input_json" | nc -U "$socket_path" -w1 2>/dev/null
  fi

  return 0
}
