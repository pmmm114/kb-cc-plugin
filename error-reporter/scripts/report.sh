#!/bin/bash
# error-reporter: Capture error stack and create structured GitHub issues.
# Pattern: synchronous snapshot (file reads) → fork (network I/O) → immediate exit 0.
# Generic core with optional preset for log-producer-specific filtering.
# This script NEVER blocks the Claude Code hook chain.
#
# Self-test mode: `bash report.sh --self-test` runs a dependency/reachability
# probe with zero side effects — useful for on-call triage.
set +e

# === Pre-fork: globals + helpers (used by self-test and main path) ===

# --- Path layout (E3 zero-migration: preserves L274/L303 semantics) ---
ER_BASE="${CLAUDE_PLUGIN_DATA:-${HOME:-${TMPDIR:-/tmp}}/.claude/reports}"
ERROR_LOG_DIR="$ER_BASE/logs"
ERROR_LOG_FILE="$ERROR_LOG_DIR/error-reporter.log"
ERROR_LOG_MAX=1000
ERROR_LOG_KEEP=500
REPORT_DIR="$ER_BASE/reports"
MARKER_DIR="$ER_BASE/markers"
LOCK_ROOT="$ER_BASE/locks"
TS=$(date -u +%s)

# --- Preset state globals ---
PRESET_LOADED=false
PRESET_NAME=""
PRESET_DEBUG_LOG_PATH_TPL=""
PRESET_STATE_FILE_PATH_TPL=""
PRESET_DENY_RULES_JSON=""
PRESET_DOMAIN_RULES_JSON=""
PRESET_DEFAULT_DOMAIN=""
PRESET_SEVERITY_RULES_JSON=""
PRESET_DENY_FILTER_JQ=""
PRESET_REPO=""
PRESET_HOOK_EXTRACTION_JSON=""
REPORT_REPO=""
REPORT_REPO_SOURCE=""
HOOK_CWD=""

# --- log_line: append + ring-buffer trim (callable pre-fork or in-fork) ---
log_line() {
  mkdir -p "$ERROR_LOG_DIR" 2>/dev/null || return
  printf '%s\n' "$1" >> "$ERROR_LOG_FILE" 2>/dev/null || return
  chmod 600 "$ERROR_LOG_FILE" 2>/dev/null || true
  local n
  # BSD wc (macOS) prints leading whitespace — tr -d ' ' is load-bearing.
  n=$(wc -l < "$ERROR_LOG_FILE" 2>/dev/null | tr -d ' ')
  if [ "${n:-0}" -gt "$ERROR_LOG_MAX" ]; then
    { head -1 "$ERROR_LOG_FILE"; tail -$((ERROR_LOG_KEEP - 1)) "$ERROR_LOG_FILE"; } \
      > "${ERROR_LOG_FILE}.$$.tmp" 2>/dev/null \
      && mv "${ERROR_LOG_FILE}.$$.tmp" "$ERROR_LOG_FILE" 2>/dev/null
  fi
}

# --- _resolve_preset_name: env > config.json > empty ---
_resolve_preset_name() {
  if [ -n "${ERROR_REPORTER_PRESET:-}" ]; then
    printf '%s' "$ERROR_REPORTER_PRESET"
    return
  fi
  local cfg="$ER_BASE/error-reporter/config.json"
  if [ -f "$cfg" ] && command -v jq >/dev/null 2>&1; then
    local from_cfg
    from_cfg=$(jq -r '.preset // empty' "$cfg" 2>/dev/null)
    [ -n "$from_cfg" ] && { printf '%s' "$from_cfg"; return; }
  fi
}

# --- _resolve_repo_from_cwd <cwd>: extract owner/repo from git remote.origin.url ---
# Stdout: "owner/repo" on success (exit 0). Empty + exit 1 on failure.
# No gh call — uses git only (~11ms). Handles https / ssh / git@ URL variants.
_resolve_repo_from_cwd() {
  local cwd="$1"
  [ -z "$cwd" ] && return 1
  [ -d "$cwd" ] || return 1
  git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1 || return 1
  local url
  url=$(git -C "$cwd" config --get remote.origin.url 2>/dev/null)
  [ -z "$url" ] && return 1
  local slug
  slug=$(printf '%s' "$url" \
    | sed -E -e 's|^https?://[^/]+/||' \
             -e 's|^(ssh://)?git@[^:/]+[:/]||' \
             -e 's|\.git/?$||' \
             -e 's|/+$||')
  case "$slug" in
    */*) printf '%s' "$slug"; return 0 ;;
    *)   return 1 ;;
  esac
}

# --- _resolve_repo: populates REPORT_REPO + REPORT_REPO_SOURCE globals ---
# Fallback chain (EPIC #20 Design Principle 4):
#   1. env ERROR_REPORTER_REPO         (force override)
#   2. config.json .repo               (persistent user override)
#   3. hook-input .cwd → git remote    (default: current context repo)
#   4. preset.repo                     (last-resort static fallback)
#   5. empty + source="none"           (caller logs status=fail)
# Idempotent via _REPORT_REPO_CACHED. Safe to call from self-test (HOOK_CWD empty).
_resolve_repo() {
  [ "${_REPORT_REPO_CACHED:-0}" = "1" ] && return
  REPORT_REPO=""
  REPORT_REPO_SOURCE=""

  if [ -n "${ERROR_REPORTER_REPO:-}" ]; then
    REPORT_REPO="$ERROR_REPORTER_REPO"
    REPORT_REPO_SOURCE="env"
    _REPORT_REPO_CACHED=1
    return
  fi

  local cfg="$ER_BASE/error-reporter/config.json"
  if [ -f "$cfg" ] && command -v jq >/dev/null 2>&1; then
    local from_cfg
    from_cfg=$(jq -r '.repo // empty' "$cfg" 2>/dev/null)
    if [ -n "$from_cfg" ]; then
      REPORT_REPO="$from_cfg"
      REPORT_REPO_SOURCE="config"
      _REPORT_REPO_CACHED=1
      return
    fi
  fi

  if [ -n "$HOOK_CWD" ]; then
    local from_cwd
    if from_cwd=$(_resolve_repo_from_cwd "$HOOK_CWD") && [ -n "$from_cwd" ]; then
      REPORT_REPO="$from_cwd"
      REPORT_REPO_SOURCE="cwd:hook"
      _REPORT_REPO_CACHED=1
      return
    fi
  fi

  if [ "$PRESET_LOADED" = true ] && [ -n "$PRESET_REPO" ]; then
    REPORT_REPO="$PRESET_REPO"
    REPORT_REPO_SOURCE="preset"
    _REPORT_REPO_CACHED=1
    return
  fi

  REPORT_REPO=""
  REPORT_REPO_SOURCE="none"
  _REPORT_REPO_CACHED=1
}

# --- _build_deny_filter: produces $PRESET_DENY_FILTER_JQ from PRESET_DENY_RULES_JSON ---
# Spec:
#   - phases: []     → skip the rule entirely (no clause emitted)
#   - phases: ["*"]  → ($h == "<HOOK>") only, no phase constraint
#   - phases mix     → (($h == "<HOOK>") and ($p == "x" or ($p | startswith("y_"))))
#   - hooks/phases passed through `jq -Rs .` for safe JSON quoting
#   - 3-layer parens mandatory; rules joined with top-level OR
#   - outer select(.decision == "block" or .decision == "deny") prelude preserved
#   - F4: do NOT dedupe rules (one OR clause per input entry, in order)
_build_deny_filter() {
  local rules="$PRESET_DENY_RULES_JSON"
  [ -z "$rules" ] && rules='[]'
  local count
  count=$(printf '%s' "$rules" | jq 'length' 2>/dev/null)
  count=${count:-0}

  if [ "$count" -eq 0 ]; then
    PRESET_DENY_FILTER_JQ='select(.decision == "block" or .decision == "deny")'
    return
  fi

  local parts=""
  local i=0
  while [ "$i" -lt "$count" ]; do
    local hook phases_json plen
    hook=$(printf '%s' "$rules" | jq -r --argjson i "$i" '.[$i].hook')
    phases_json=$(printf '%s' "$rules" | jq -c --argjson i "$i" '.[$i].phases // ["*"]')
    plen=$(printf '%s' "$phases_json" | jq 'length')

    [ "$plen" -eq 0 ] && { i=$((i + 1)); continue; }

    local hook_lit
    hook_lit=$(printf '%s' "$hook" | jq -Rs .)

    local has_star=false
    local phase_disjunction=""
    local j=0
    while [ "$j" -lt "$plen" ]; do
      local p
      p=$(printf '%s' "$phases_json" | jq -r --argjson j "$j" '.[$j]')
      case "$p" in
        "*")
          has_star=true
          break
          ;;
        *_\*)
          local pfx="${p%\*}"
          local pfx_lit
          pfx_lit=$(printf '%s' "$pfx" | jq -Rs .)
          if [ -z "$phase_disjunction" ]; then
            phase_disjunction="(\$p | startswith($pfx_lit))"
          else
            phase_disjunction="$phase_disjunction or (\$p | startswith($pfx_lit))"
          fi
          ;;
        *)
          local p_lit
          p_lit=$(printf '%s' "$p" | jq -Rs .)
          if [ -z "$phase_disjunction" ]; then
            phase_disjunction="\$p == $p_lit"
          else
            phase_disjunction="$phase_disjunction or \$p == $p_lit"
          fi
          ;;
      esac
      j=$((j + 1))
    done

    local rule_clause
    if [ "$has_star" = true ]; then
      rule_clause="(\$h == $hook_lit)"
    else
      rule_clause="((\$h == $hook_lit) and ($phase_disjunction))"
    fi

    if [ -z "$parts" ]; then
      parts="$rule_clause"
    else
      parts="$parts or $rule_clause"
    fi

    i=$((i + 1))
  done

  PRESET_DENY_FILTER_JQ="
    select(.decision == \"block\" or .decision == \"deny\")
    | select(
        ( (.hook // \"\") as \$h | (.phase // \"\") as \$p | ( $parts ) ) | not
      )
  "
}

# --- _load_preset <name>: reads preset, validates, populates PRESET_* globals ---
# F5: resets all PRESET_* globals at entry (safe re-call)
# D10: validates {session_id} placeholder presence
# Fail-closed: log breadcrumb + return (never abort the hook chain)
_load_preset() {
  local name="$1"

  # F5 reset
  PRESET_LOADED=false
  PRESET_NAME=""
  PRESET_DEBUG_LOG_PATH_TPL=""
  PRESET_STATE_FILE_PATH_TPL=""
  PRESET_DENY_RULES_JSON=""
  PRESET_DOMAIN_RULES_JSON=""
  PRESET_DEFAULT_DOMAIN=""
  PRESET_SEVERITY_RULES_JSON=""
  PRESET_DENY_FILTER_JQ=""
  PRESET_REPO=""
  PRESET_HOOK_EXTRACTION_JSON=""

  [ -z "$name" ] && return
  command -v jq >/dev/null 2>&1 || return

  if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    log_line "[$TS] status=preset_bad_schema preset=$name reason=CLAUDE_PLUGIN_ROOT_unset"
    return
  fi

  local file="$CLAUDE_PLUGIN_ROOT/presets/${name}.json"
  if [ ! -f "$file" ]; then
    log_line "[$TS] status=preset_bad_schema preset=$name reason=file_not_found path=$file"
    return
  fi

  local v
  v=$(jq -r '.schema_version // empty' "$file" 2>/dev/null)
  if [ "$v" != "1" ]; then
    log_line "[$TS] status=preset_bad_schema preset=$name reason=unsupported_schema_version got=${v:-none}"
    return
  fi

  local debug_tpl state_tpl
  debug_tpl=$(jq -er '.debug_log_path' "$file" 2>/dev/null)
  if [ -z "$debug_tpl" ]; then
    log_line "[$TS] status=preset_bad_schema preset=$name reason=missing_field field=debug_log_path"
    return
  fi
  state_tpl=$(jq -er '.state_file_path' "$file" 2>/dev/null)
  if [ -z "$state_tpl" ]; then
    log_line "[$TS] status=preset_bad_schema preset=$name reason=missing_field field=state_file_path"
    return
  fi

  case "$debug_tpl" in
    *'{session_id}'*) ;;
    *)
      log_line "[$TS] status=preset_bad_schema preset=$name reason=missing_placeholder field=debug_log_path"
      return
      ;;
  esac
  case "$state_tpl" in
    *'{session_id}'*) ;;
    *)
      log_line "[$TS] status=preset_bad_schema preset=$name reason=missing_placeholder field=state_file_path"
      return
      ;;
  esac

  PRESET_DEBUG_LOG_PATH_TPL="$debug_tpl"
  PRESET_STATE_FILE_PATH_TPL="$state_tpl"
  PRESET_DENY_RULES_JSON=$(jq -c '.routine_deny_rules // []' "$file" 2>/dev/null)
  PRESET_DOMAIN_RULES_JSON=$(jq -c '.domain_rules // []' "$file" 2>/dev/null)
  PRESET_DEFAULT_DOMAIN=$(jq -r '.default_domain // "reporter:domain:hook"' "$file" 2>/dev/null)
  PRESET_SEVERITY_RULES_JSON=$(jq -c '.severity_rules // {}' "$file" 2>/dev/null)
  PRESET_REPO=$(jq -r '.repo // empty' "$file" 2>/dev/null)
  PRESET_HOOK_EXTRACTION_JSON=$(jq -c '.hook_extraction // null' "$file" 2>/dev/null)
  PRESET_NAME="$name"
  PRESET_LOADED=true

  _build_deny_filter
}

# --- _preset_domain_lookup <hook>: matches hook against domain_rules ---
_preset_domain_lookup() {
  local h="$1"
  if [ -z "$h" ] || [ -z "$PRESET_DOMAIN_RULES_JSON" ]; then
    printf '%s\n' "${PRESET_DEFAULT_DOMAIN:-reporter:domain:hook}"
    return
  fi
  local count i
  count=$(printf '%s' "$PRESET_DOMAIN_RULES_JSON" | jq 'length')
  i=0
  while [ "$i" -lt "$count" ]; do
    local pat dom
    pat=$(printf '%s' "$PRESET_DOMAIN_RULES_JSON" | jq -r --argjson i "$i" '.[$i].match')
    dom=$(printf '%s' "$PRESET_DOMAIN_RULES_JSON" | jq -r --argjson i "$i" '.[$i].domain')
    # Unquoted $pat is intentional — preset supplies shell case-style globs
    # (pipe-separated alternation). Quoting would force literal match.
    # shellcheck disable=SC2254
    case "$h" in
      $pat) printf '%s\n' "$dom"; return ;;
    esac
    i=$((i + 1))
  done
  printf '%s\n' "${PRESET_DEFAULT_DOMAIN:-reporter:domain:hook}"
}

# --- _resolve_severity <event> <sf_error>: preset-driven, "unknown" if no preset ---
_resolve_severity() {
  local event="$1"
  local sf_error="$2"
  if [ "$PRESET_LOADED" != true ] || [ -z "$PRESET_SEVERITY_RULES_JSON" ]; then
    printf '%s\n' "unknown"
    return
  fi
  local rule_type
  rule_type=$(printf '%s' "$PRESET_SEVERITY_RULES_JSON" | jq -r --arg e "$event" '.[$e] | type')
  case "$rule_type" in
    object)
      if printf '%s' "$sf_error" | grep -iq timeout; then
        printf '%s' "$PRESET_SEVERITY_RULES_JSON" | jq -r --arg e "$event" '.[$e].timeout // "unknown"'
      else
        printf '%s' "$PRESET_SEVERITY_RULES_JSON" | jq -r --arg e "$event" '.[$e].default // "unknown"'
      fi
      ;;
    string)
      printf '%s' "$PRESET_SEVERITY_RULES_JSON" | jq -r --arg e "$event" '.[$e]'
      ;;
    *)
      printf '%s\n' "unknown"
      ;;
  esac
}

# === Self-test mode: pure diagnostics, no side effects ===
if [ "${1:-}" = "--self-test" ]; then
  printf 'error-reporter self-test\n========================\n\n'
  # P0-5: use $PWD as HOOK_CWD proxy so repo resolution exercises the CWD path.
  HOOK_CWD="$PWD"
  printf 'dependencies:\n'
  if command -v jq >/dev/null 2>&1; then
    printf '  [ok]   jq: %s\n' "$(jq --version 2>/dev/null)"
  else
    printf '  [FAIL] jq: not found — error-reporter will exit 0 silently on all events\n'
  fi
  if command -v gh >/dev/null 2>&1; then
    printf '  [ok]   gh: %s\n' "$(gh --version 2>/dev/null | head -1)"
  else
    printf '  [WARN] gh: not found — fallback-only mode\n'
  fi
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    printf '  [ok]   gh auth: authenticated\n'
  else
    printf '  [WARN] gh auth: not authenticated — fallback-only mode\n'
  fi

  # R2 fix: soft-degradation when CLAUDE_PLUGIN_ROOT is unset
  if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    printf '  [WARN] preset: cannot check (CLAUDE_PLUGIN_ROOT unset)\n'
  else
    _resolved_preset=$(_resolve_preset_name)
    if [ -n "$_resolved_preset" ]; then
      _load_preset "$_resolved_preset"
      if [ "$PRESET_LOADED" = true ]; then
        printf '  [ok]   preset: %s (loaded)\n' "$PRESET_NAME"
      else
        printf '  [FAIL] preset: %s (bad_schema)\n' "$_resolved_preset"
      fi
    else
      printf '  [ok]   preset: none (generic mode)\n'
    fi
  fi

  _resolve_repo
  if [ -z "$REPORT_REPO" ]; then
    printf '  [WARN] target repo: not configured (gh-skip mode)\n'
  elif command -v gh >/dev/null 2>&1 && gh repo view "$REPORT_REPO" >/dev/null 2>&1; then
    printf '  [ok]   target repo: %s (source=%s, reachable)\n' "$REPORT_REPO" "$REPORT_REPO_SOURCE"
  else
    printf '  [WARN] target repo unreachable: %s (source=%s)\n' "$REPORT_REPO" "$REPORT_REPO_SOURCE"
  fi

  printf '\ndata dir:\n'
  if [ -d "$ER_BASE" ] && [ -w "$ER_BASE" ]; then
    printf '  [ok]   %s (writable)\n' "$ER_BASE"
  elif [ -d "$ER_BASE" ]; then
    printf '  [FAIL] %s (exists but not writable)\n' "$ER_BASE"
  else
    printf '  [warn] %s (will be created on first write)\n' "$ER_BASE"
  fi

  printf '\nrecent activity:\n'
  if [ -f "$ERROR_LOG_FILE" ]; then
    _SELF_TEST_LINES=$(wc -l < "$ERROR_LOG_FILE" 2>/dev/null | tr -d ' ')
    printf '  error-reporter.log: %s lines\n' "${_SELF_TEST_LINES:-0}"
    printf '  last 5 entries:\n'
    tail -5 "$ERROR_LOG_FILE" 2>/dev/null | sed 's/^/    /' || true
    printf '\n'
    _SELF_TEST_OKS=$(grep -Ec 'status=ok' "$ERROR_LOG_FILE" 2>/dev/null || echo 0)
    _SELF_TEST_FAILS=$(grep -Ec 'status=fail' "$ERROR_LOG_FILE" 2>/dev/null || echo 0)
    _SELF_TEST_SKIPS=$(grep -Ec 'status=skip' "$ERROR_LOG_FILE" 2>/dev/null || echo 0)
    _SELF_TEST_NOTICES=$(grep -Ec 'status=opt_in_notice' "$ERROR_LOG_FILE" 2>/dev/null || echo 0)
    _SELF_TEST_PRESET_ERRS=$(grep -c 'status=preset_bad_schema' "$ERROR_LOG_FILE" 2>/dev/null || echo 0)
    printf '  status tally: ok=%s fail=%s skip=%s notice=%s\n' \
      "${_SELF_TEST_OKS:-0}" "${_SELF_TEST_FAILS:-0}" "${_SELF_TEST_SKIPS:-0}" "${_SELF_TEST_NOTICES:-0}"
    printf '  preset errors: %s\n' "${_SELF_TEST_PRESET_ERRS:-0}"
  else
    printf '  error-reporter.log: missing (%s)\n' "$ERROR_LOG_FILE"
    printf '  note: empty log means the reporter has never run — not "healthy"\n'
  fi
  if [ -d "$REPORT_DIR" ]; then
    _SELF_TEST_REPORT_COUNT=$(find "$REPORT_DIR" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
    printf '  fallback .md reports: %s in %s\n' "${_SELF_TEST_REPORT_COUNT:-0}" "$REPORT_DIR"
  else
    printf '  fallback .md reports: dir absent\n'
  fi
  if [ -d "$MARKER_DIR" ]; then
    _SELF_TEST_MARKERS=$(find "$MARKER_DIR" -maxdepth 1 -name '*.reported' -type f 2>/dev/null | wc -l | tr -d ' ')
  else
    _SELF_TEST_MARKERS=0
  fi
  if [ -d "$LOCK_ROOT" ]; then
    _SELF_TEST_LOCKS=$(find "$LOCK_ROOT" -maxdepth 1 -name '*.lock' -type d 2>/dev/null | wc -l | tr -d ' ')
  else
    _SELF_TEST_LOCKS=0
  fi
  printf '  markers: %s reported, %s lockdirs\n' "${_SELF_TEST_MARKERS:-0}" "${_SELF_TEST_LOCKS:-0}"
  printf '\n(no side effects: no issues created, no files written)\n'
  exit 0
fi

# === Main path: hook event processing ===
command -v jq >/dev/null 2>&1 || { echo "error-reporter: jq not found" >&2; exit 0; }

INPUT=$(cat)
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // ""')
SESSION=$(echo "$INPUT" | jq -r '.session_id // ""')
# P0-5: hook-input .cwd is authoritative for agent-subprocess working directory.
# Used by _resolve_repo to derive target repo from current git remote.
HOOK_CWD=$(echo "$INPUT" | jq -r '.cwd // ""')

[ -z "$SESSION" ] && exit 0

# F1: pre-fork mkdir is fine here (self-test already exited above)
mkdir -p "$ERROR_LOG_DIR" "$MARKER_DIR" "$LOCK_ROOT" "$REPORT_DIR" 2>/dev/null || true

MARKER="$MARKER_DIR/${SESSION}.reported"
[ -f "$MARKER" ] && exit 0

# Resolve preset + repo before any path-dependent logic
PRESET_REQUEST=$(_resolve_preset_name)
if [ -n "$PRESET_REQUEST" ]; then
  _load_preset "$PRESET_REQUEST"
fi
_resolve_repo

TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // ""')
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // ""')

# --- Threshold checks per event ---
TRIGGER_HOOK=""
LOG_FILE=""
STATE_FILE=""
SF_ERROR=""

case "$EVENT" in
  StopFailure)
    SF_ERROR=$(echo "$INPUT" | jq -r '.error // ""')
    case "$SF_ERROR" in rate_limit|server_error) exit 0 ;; esac
    ;;
  Stop|SubagentStop)
    if [ "$PRESET_LOADED" != true ]; then
      # T13: opt-in notice mechanism (one-shot per install)
      NOTICE_ACK="$MARKER_DIR/.v3.1-opt-in-notice.ack"
      if [ ! -f "$NOTICE_ACK" ]; then
        NOTICE_FILE="$REPORT_DIR/error-reporter-notice-$(date +%s).md"
        NOTICE_BODY='# error-reporter v3.1 notice

error-reporter 3.1 handles Stop/SubagentStop reporting through an opt-in preset.
Without a preset configured, these events are silently ignored (StopFailure reporting
still works).

To enable Stop/SubagentStop reporting, configure a preset:

    export ERROR_REPORTER_PRESET=<preset name>
    export ERROR_REPORTER_REPO=<github owner/repo>

Shipped presets are listed in the plugin README (section "Presets"). If you upgraded
from v3.0 and used this plugin with claude-harness, the preset you want is
`claude-harness`.

This notice fires once per install.'
        printf '%s\n' "$NOTICE_BODY" > "$NOTICE_FILE" 2>/dev/null
        chmod 600 "$NOTICE_FILE" 2>/dev/null
        touch "$NOTICE_ACK" 2>/dev/null
        log_line "[$TS] status=opt_in_notice event=$EVENT sid=$SESSION"
      fi
      exit 0
    fi
    LOG_FILE=${PRESET_DEBUG_LOG_PATH_TPL//\{session_id\}/$SESSION}
    STATE_FILE=${PRESET_STATE_FILE_PATH_TPL//\{session_id\}/$SESSION}
    [ -f "$LOG_FILE" ] || exit 0
    [ -z "$PRESET_DENY_FILTER_JQ" ] && exit 0

    if [ "$EVENT" = "SubagentStop" ] && [ -n "$AGENT_ID" ]; then
      BLOCK_COUNT=$(jq -r --arg aid "$AGENT_ID" "$PRESET_DENY_FILTER_JQ | select(.agent_id == \$aid or .agent_id == null) | .decision" "$LOG_FILE" 2>/dev/null | wc -l | tr -d ' ')
      TRIGGER_HOOK=$(jq -r --arg aid "$AGENT_ID" "$PRESET_DENY_FILTER_JQ | select(.agent_id == \$aid or .agent_id == null) | .hook // empty" "$LOG_FILE" 2>/dev/null | tail -1)
    else
      BLOCK_COUNT=$(jq -r "$PRESET_DENY_FILTER_JQ | .decision" "$LOG_FILE" 2>/dev/null | wc -l | tr -d ' ')
      TRIGGER_HOOK=$(jq -r "$PRESET_DENY_FILTER_JQ | .hook // empty" "$LOG_FILE" 2>/dev/null | tail -1)
    fi
    [ "${BLOCK_COUNT:-0}" -lt 1 ] && exit 0
    ;;
  *)
    exit 0
    ;;
esac

# === Phase 1: Synchronous snapshot (preset-gated reads) ===
STATE_SNAPSHOT='{}'
PHASE="unknown"
DEBUG_LOG_TAIL=""
TRANSCRIPT_TAIL=""

if [ "$PRESET_LOADED" = true ] && [ -n "$STATE_FILE" ] && [ -f "$STATE_FILE" ]; then
  STATE_SNAPSHOT=$(cat "$STATE_FILE" 2>/dev/null || echo '{}')
  PHASE=$(echo "$STATE_SNAPSHOT" | jq -r '.phase // "unknown"')
fi

if [ "$PRESET_LOADED" = true ] && [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ]; then
  DEBUG_LOG_TAIL=$(tail -50 "$LOG_FILE" 2>/dev/null)
fi

[ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] && TRANSCRIPT_TAIL=$(tail -20 "$TRANSCRIPT" 2>/dev/null)

TRIGGER_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

# Severity from preset (or "unknown" if preset not loaded)
SEVERITY=$(_resolve_severity "$EVENT" "$SF_ERROR")

# Domain inference
infer_domain() {
  if [ -n "$AGENT_ID" ]; then
    echo "reporter:domain:agent"
    return
  fi
  if [ "$PRESET_LOADED" = true ]; then
    _preset_domain_lookup "$TRIGGER_HOOK"
    return
  fi
  if [ "$EVENT" = "StopFailure" ]; then
    echo "reporter:domain:infra"
  else
    echo "reporter:domain:hook"
  fi
}
DOMAIN=$(infer_domain)

AGENT_FIELD="$AGENT_ID"

# === Phase 2: Fork to background — all network I/O happens here ===
(
  LOCK_DIR="$LOCK_ROOT/${SESSION}.lock"
  # Stale-lock reclamation (>5 min mtime): SIGKILL/OOM/host crash recovery.
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    if [ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +5 2>/dev/null)" ]; then
      rmdir "$LOCK_DIR" 2>/dev/null
      mkdir "$LOCK_DIR" 2>/dev/null || exit 0
    else
      exit 0
    fi
  fi
  trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

  # Opportunistic sweep of leftovers (7-day TTL).
  find "$MARKER_DIR" "$LOCK_ROOT" -maxdepth 1 \( -name '*.lock' -o -name '*.reported' \) -mtime +7 -exec rm -rf {} + 2>/dev/null || true

  TITLE="[incident] $EVENT${AGENT_ID:+($AGENT_ID)} (${SESSION:0:8})"

  REPORT_BODY="## Observation

**Event**: \`$EVENT\`${AGENT_ID:+ | **Agent**: \`$AGENT_ID\`}
**Session ID**: \`${SESSION:0:8}\`
**Phase**: \`$PHASE\`
**Trigger Commit**: \`$TRIGGER_COMMIT\`
**Severity**: \`$SEVERITY\`
**Reproducibility**: observed once

${EVENT} event fired during phase \`$PHASE\`.${AGENT_FIELD:+ Agent \`$AGENT_FIELD\` was active.}

## Counterfactual

<!-- What SHOULD have happened — fill in manually to make this observation actionable -->

## Evidence

### Debug Log (last 50 lines)
\`\`\`
${DEBUG_LOG_TAIL:-(unavailable)}
\`\`\`

### Transcript (last 20 lines)
\`\`\`
${TRANSCRIPT_TAIL:-(unavailable)}
\`\`\`

### State Snapshot
\`\`\`json
${STATE_SNAPSHOT:-(unavailable)}
\`\`\`

### Hook Input
\`\`\`json
$INPUT
\`\`\`

## Hypothesis

<!-- Suspected root cause — fill in manually -->"

  # Always-local archive (write before gh attempt)
  FALLBACK_FILE="$REPORT_DIR/${SESSION}-$(date +%s)-$$.md"
  LOCAL_OK=false
  if printf '%s\n' "$REPORT_BODY" > "$FALLBACK_FILE" 2>/dev/null; then
    chmod 600 "$FALLBACK_FILE" 2>/dev/null || true
    LOCAL_OK=true
  fi

  # Primary sink: gh issue create — gated on REPORT_REPO non-empty
  GH_OK=false
  if [ -z "$REPORT_REPO" ]; then
    log_line "$(printf '[%s] status=skip event=%s sid=%s reason=repo_not_configured local=%s' \
      "$TS" "$EVENT" "$SESSION" "$LOCAL_OK")"
  elif command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    gh label create "type:incident" --description "Immediate response needed" --color "D73A4A" --repo "$REPORT_REPO" 2>/dev/null || true
    gh label create "auto:hook-failure" --description "Auto-generated by error-reporter" --color "EDEDED" --repo "$REPORT_REPO" 2>/dev/null || true
    gh label create "severity:$SEVERITY" --description "" --color "FFA500" --repo "$REPORT_REPO" 2>/dev/null || true
    gh label create "$DOMAIN" --description "Auto-inferred domain (error-reporter plugin)" --color "0E8A16" --repo "$REPORT_REPO" 2>/dev/null || true
    [ -n "$AGENT_FIELD" ] && gh label create "reporter:agent:${AGENT_FIELD}" --description "Agent scope (error-reporter plugin)" --color "1D76DB" --repo "$REPORT_REPO" 2>/dev/null || true

    LABELS="type:incident,auto:hook-failure,severity:${SEVERITY},${DOMAIN}"
    [ -n "$AGENT_FIELD" ] && LABELS="${LABELS},reporter:agent:${AGENT_FIELD}"

    GH_STDERR=$(gh issue create \
      --repo "$REPORT_REPO" \
      --title "$TITLE" \
      --label "$LABELS" \
      --body "$REPORT_BODY" \
      2>&1 >/dev/null)
    GH_EXIT=$?
    if [ "$GH_EXIT" -eq 0 ]; then
      log_line "$(printf '[%s] status=ok event=%s sid=%s phase=%s agent=%s domain=%s commit=%s local=%s' \
        "$TS" "$EVENT" "$SESSION" "$PHASE" "${AGENT_FIELD:-none}" "$DOMAIN" "$TRIGGER_COMMIT" "$LOCAL_OK")"
      GH_OK=true
    else
      GH_STDERR_ONELINE=$(printf '%s' "$GH_STDERR" | tr '\n\r' '  ' | cut -c1-512)
      log_line "$(printf '[%s] status=fail event=%s sid=%s phase=%s agent=%s domain=%s commit=%s local=%s exit=%d stderr=%q' \
        "$TS" "$EVENT" "$SESSION" "$PHASE" "${AGENT_FIELD:-none}" "$DOMAIN" "$TRIGGER_COMMIT" "$LOCAL_OK" "$GH_EXIT" "$GH_STDERR_ONELINE")"
    fi
  fi

  # Session-dedup marker: touch if ANY sink succeeded
  if [ "$GH_OK" = true ] || [ "$LOCAL_OK" = true ]; then
    touch "$MARKER"
  fi
) &
disown

# === Immediate return — no blocking ===
exit 0
