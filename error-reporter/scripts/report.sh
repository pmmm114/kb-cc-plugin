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
PRESET_SCHEMA_VERSION=""
PRESET_SEVERITY_RULES_JSON=""
PRESET_DENY_FILTER_JQ=""
PRESET_HOOK_EXTRACT_JQ='(.hook // "")'
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
# No gh call — uses git only (~11ms). Handles:
#   https://github.com/OWNER/REPO(.git)?
#   git@github.com:OWNER/REPO(.git)?
#   ssh://git@github.com(:PORT)?/OWNER/REPO(.git)?
#
# Filters out non-github hosts (gh CLI backing). Filters to two-segment paths
# (rejects nested groups like gitlab-style `group/subgroup/repo`). Accepts
# GitHub Enterprise via `*.github.*` pattern.
_resolve_repo_from_cwd() {
  local cwd="$1"
  [ -z "$cwd" ] && return 1
  [ -d "$cwd" ] || return 1
  git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1 || return 1
  local url
  url=$(git -C "$cwd" config --get remote.origin.url 2>/dev/null)
  [ -z "$url" ] && return 1

  # Parse host + path with explicit variants. BASH_REMATCH reliable on bash 3.2+.
  local host path
  if [[ "$url" =~ ^https?://([^/]+)/(.+)$ ]]; then
    host="${BASH_REMATCH[1]}"
    path="${BASH_REMATCH[2]}"
  elif [[ "$url" =~ ^ssh://git@([^:/]+)(:[0-9]+)?/(.+)$ ]]; then
    host="${BASH_REMATCH[1]}"
    path="${BASH_REMATCH[3]}"
  elif [[ "$url" =~ ^git@([^:/]+):(.+)$ ]]; then
    host="${BASH_REMATCH[1]}"
    path="${BASH_REMATCH[2]}"
  else
    return 1
  fi

  # Case-insensitive host matching (bash 3.2 compat — use tr, not ${var,,}).
  # GitHub owner/repo paths ARE case-sensitive, so we lowercase host only.
  host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')
  case "$host" in
    github.com|*.github.com|github.*|*.github.*) ;;
    *) return 1 ;;
  esac

  # Normalize path: strip trailing slash FIRST, then .git suffix — order matters
  # for URLs written as "owner/repo.git/" (slash after .git).
  path="${path%/}"
  path="${path%.git}"
  path="${path%/}"

  # Accept exactly "owner/repo" (two segments). Reject nested groups.
  case "$path" in
    */*/*) return 1 ;;
    */*) printf '%s' "$path"; return 0 ;;
    *) return 1 ;;
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
#
# P0-1 (defensive against _HOOK_CALLER upstream drift):
#   - If preset declares .hook_extraction.pattern, build $h from .reason via
#     jq capture (named group "h"), falling back to .hook field on miss.
#     Rule hook names normalized by stripping ".sh" suffix to match the bare
#     guard names typically found in the extracted bracket.
#   - If no hook_extraction, legacy $h = .hook // "".
#   - Extraction expression also exposed as $PRESET_HOOK_EXTRACT_JQ for
#     the TRIGGER_HOOK lookup downstream.
#
# Preset-author warning: because fallback strips ".sh", do NOT use a bare
# library wrapper name (e.g., "hook-lib") as a rule hook. With the harness
# _HOOK_CALLER drift active, .hook == "hook-lib.sh" → normalized "hook-lib";
# a rule keyed on "hook-lib" would incorrectly match every library-emitted
# entry whose reason lacks the guard-bracket prefix.
_build_deny_filter() {
  local rules="$PRESET_DENY_RULES_JSON"
  [ -z "$rules" ] && rules='[]'
  local count
  count=$(printf '%s' "$rules" | jq 'length' 2>/dev/null)
  count=${count:-0}

  # Build hook-extraction expression from preset (or fall back to .hook field).
  # Two modes:
  #   (A) preset.hook_extraction.pattern set → capture from .reason, fallback
  #       to .hook, strip trailing ".sh" for symmetric bare-name matching.
  #       This is the P0-1 defensive path against _HOOK_CALLER upstream drift.
  #   (B) no hook_extraction → legacy .hook verbatim. TRIGGER_HOOK preserves
  #       the pre-3.2 ".sh"-suffixed value that downstream consumers (issue
  #       title, label emission) expected. Rule hook names in the preset also
  #       stay un-normalized, so existing presets continue to match as before.
  local hook_pat=""
  if [ -n "$PRESET_HOOK_EXTRACTION_JSON" ] && [ "$PRESET_HOOK_EXTRACTION_JSON" != "null" ]; then
    hook_pat=$(printf '%s' "$PRESET_HOOK_EXTRACTION_JSON" | jq -r '.pattern // empty' 2>/dev/null)
  fi
  local normalize_rule_hook=0
  if [ -n "$hook_pat" ]; then
    local pat_lit
    pat_lit=$(printf '%s' "$hook_pat" | jq -Rs .)
    PRESET_HOOK_EXTRACT_JQ="(((((.reason // \"\") | capture($pat_lit)? | .h // \"\") // (.hook // \"\")) | sub(\"\\\\.sh$\"; \"\")))"
    normalize_rule_hook=1
  else
    PRESET_HOOK_EXTRACT_JQ='(.hook // "")'
  fi

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

    # P0-1: when preset opts into reason-prefix extraction, strip ".sh" from
    # rule hook names so comparison is bare-to-bare. Legacy presets keep the
    # ".sh" suffix verbatim (TRIGGER_HOOK / downstream labels preserved).
    local hook_bare
    if [ "$normalize_rule_hook" = "1" ]; then
      hook_bare="${hook%.sh}"
    else
      hook_bare="$hook"
    fi
    local hook_lit
    hook_lit=$(printf '%s' "$hook_bare" | jq -Rs .)

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
        ( ($PRESET_HOOK_EXTRACT_JQ) as \$h | (.phase // \"\") as \$p | ( $parts ) ) | not
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

  # #22: accept schema v1 (legacy, domain_rules present) and v2 (domain fields
  # removed, 5-axis emission). Reject all other versions as unsupported.
  local v
  v=$(jq -r '.schema_version // empty' "$file" 2>/dev/null)
  if [ "$v" != "1" ] && [ "$v" != "2" ]; then
    log_line "[$TS] status=preset_bad_schema preset=$name reason=unsupported_schema_version got=${v:-none}"
    return
  fi
  PRESET_SCHEMA_VERSION="$v"

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
  # #22: domain_rules / default_domain populated only for v=1 presets. v=2
  # presets drop these fields and rely on 5-axis emission instead. Globals
  # remain declared (empty) so `set -u` consumers don't break.
  if [ "$v" = "1" ]; then
    PRESET_DOMAIN_RULES_JSON=$(jq -c '.domain_rules // []' "$file" 2>/dev/null)
    PRESET_DEFAULT_DOMAIN=$(jq -r '.default_domain // "reporter:domain:hook"' "$file" 2>/dev/null)
  else
    PRESET_DOMAIN_RULES_JSON=""
    PRESET_DEFAULT_DOMAIN=""
  fi
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
  # P0-2: track non-zero exit when any critical config is missing.
  _SELFTEST_EXIT=0
  printf 'dependencies:\n'
  if command -v jq >/dev/null 2>&1; then
    printf '  [ok]   jq: %s\n' "$(jq --version 2>/dev/null)"
  else
    printf '  [FAIL] jq: not found — error-reporter will exit 0 silently on all events\n'
    _SELFTEST_EXIT=1
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

  # P0-2: escalate preset-missing to FAIL — Stop/SubagentStop silently skip without a preset.
  if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    printf '  [FAIL] preset: cannot check (CLAUDE_PLUGIN_ROOT unset) — Stop/SubagentStop silently skipped. See README §2.1 Setup.\n'
    _SELFTEST_EXIT=1
  else
    _resolved_preset=$(_resolve_preset_name)
    if [ -n "$_resolved_preset" ]; then
      _load_preset "$_resolved_preset"
      if [ "$PRESET_LOADED" = true ]; then
        printf '  [ok]   preset: %s (loaded)\n' "$PRESET_NAME"
      else
        printf '  [FAIL] preset: %s (bad_schema) — Stop/SubagentStop silently skipped. See README §2.1 Setup.\n' "$_resolved_preset"
        _SELFTEST_EXIT=1
      fi
    else
      printf '  [FAIL] preset: not configured — Stop/SubagentStop silently skipped. Export ERROR_REPORTER_PRESET or write $CLAUDE_PLUGIN_DATA/error-reporter/config.json. See README §2.1 Setup.\n'
      _SELFTEST_EXIT=1
    fi
  fi

  _resolve_repo
  if [ -z "$REPORT_REPO" ]; then
    printf '  [FAIL] target repo: not resolvable — set ERROR_REPORTER_REPO, write config.json, or run inside a git repo with a remote. See README §2.1 Setup.\n'
    _SELFTEST_EXIT=1
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
  # P0-2: exit non-zero when any critical config is missing (CI / onboarding gate).
  exit "${_SELFTEST_EXIT:-0}"
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

# P0-6: Self-recursion guard — if REPORT_REPO resolves to the repo this plugin
# ships from, emit a breadcrumb and exit without creating a GitHub Issue.
# Prevents infinite incident loops when operators edit error-reporter source
# (either Desktop/project/kb-cc-plugin or a /tmp/kb-cc-issue-* worktree).
# Override for forks via ERROR_REPORTER_SELF_REPO env. See kb-cc-plugin#28.
SELF_REPO="${ERROR_REPORTER_SELF_REPO:-pmmm114/kb-cc-plugin}"
if [ -n "$REPORT_REPO" ] && [ "$REPORT_REPO" = "$SELF_REPO" ]; then
  log_line "[$TS] status=self_suppress event=$EVENT sid=$SESSION cwd_repo=$REPORT_REPO"
  exit 0
fi

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
      # P0-3 + #26: session/hour-bucketed silent_skip breadcrumb. Emits at
      # most one line per session per hour so Stop-heavy sessions cannot
      # flood the 1000-line log ring buffer and displace real status=ok/fail
      # breadcrumbs. Markers live under $MARKER_DIR/.silent_skip.<sid>.<YYYYMMDDHH>
      # and are swept by the 7-day TTL find below.
      SKIP_MARKER="$MARKER_DIR/.silent_skip.${SESSION}.$(date -u +%Y%m%d%H)"
      if [ ! -f "$SKIP_MARKER" ]; then
        log_line "$(printf '[%s] status=silent_skip event=%s sid=%s reason=preset_not_loaded' \
          "$TS" "$EVENT" "$SESSION")"
        touch "$SKIP_MARKER" 2>/dev/null
      fi
      # T13: opt-in notice mechanism (one-shot per install).
      # Ack filename keeps the ".v3.1" suffix deliberately so upgraders from 3.1
      # do NOT re-receive the notice on first run of 3.2 (the ack is still valid).
      NOTICE_ACK="$MARKER_DIR/.v3.1-opt-in-notice.ack"
      if [ ! -f "$NOTICE_ACK" ]; then
        NOTICE_FILE="$REPORT_DIR/error-reporter-notice-$(date +%s).md"
        NOTICE_BODY='# error-reporter v3.2 notice

error-reporter 3.2 handles Stop/SubagentStop reporting through an opt-in preset.
Without a preset configured, these events are silently ignored (StopFailure reporting
still works, and the target repo is auto-detected from the CWD git remote since 3.2).

To enable Stop/SubagentStop reporting, configure a preset:

    export ERROR_REPORTER_PRESET=<preset name>
    # ERROR_REPORTER_REPO is optional — CWD git remote is auto-detected

Shipped presets are listed in the plugin README (section "Presets"). If you upgraded
from v3.0/3.1 and used this plugin with claude-harness, the preset you want is
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
      TRIGGER_HOOK=$(jq -r --arg aid "$AGENT_ID" "$PRESET_DENY_FILTER_JQ | select(.agent_id == \$aid or .agent_id == null) | $PRESET_HOOK_EXTRACT_JQ // empty" "$LOG_FILE" 2>/dev/null | tail -1)
    else
      BLOCK_COUNT=$(jq -r "$PRESET_DENY_FILTER_JQ | .decision" "$LOG_FILE" 2>/dev/null | wc -l | tr -d ' ')
      TRIGGER_HOOK=$(jq -r "$PRESET_DENY_FILTER_JQ | $PRESET_HOOK_EXTRACT_JQ // empty" "$LOG_FILE" 2>/dev/null | tail -1)
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

# Domain inference (#22 backcompat shim):
# - v=1 preset: preserve legacy reporter:domain:* emission via _preset_domain_lookup
# - v=2 preset: return empty — 5-axis labels (hook/phase/severity/cluster/repo)
#   replace the single domain axis
# - no preset: return empty (no fallback domain — saved queries on these labels
#   were only ever hit by smoke fixtures; see EPIC #20)
infer_domain() {
  if [ "$PRESET_LOADED" = true ] && [ "${PRESET_SCHEMA_VERSION:-}" = "1" ]; then
    if [ -n "$AGENT_ID" ]; then
      echo "reporter:domain:agent"
      return
    fi
    _preset_domain_lookup "$TRIGGER_HOOK"
    return
  fi
  # v=2 preset or no preset: no legacy domain label
  :
}
DOMAIN=$(infer_domain)

# #22: 5-axis label construction (hook / phase / severity / cluster / repo).
# Emitted unconditionally; v=1 presets ALSO emit legacy reporter:domain:*
# alongside via the block below.
_five_axis_labels() {
  local hook_label phase_label severity_label repo_label
  hook_label="reporter:hook:${TRIGGER_HOOK:-unknown}"
  phase_label="reporter:phase:${PHASE:-unknown}"
  severity_label="reporter:severity:${SEVERITY:-unknown}"
  # Cluster signature: stable 12-char sha1 over (hook, phase, severity, agent).
  # Same incident pattern → same cluster. Phase 5 will use these for escalation.
  local sig_input cluster_sig
  sig_input="${TRIGGER_HOOK:-none}:${PHASE:-none}:${SEVERITY:-none}:${AGENT_ID:-none}"
  cluster_sig=$(printf '%s' "$sig_input" | shasum 2>/dev/null | cut -c1-12)
  [ -z "$cluster_sig" ] && cluster_sig="unknown00000"
  local cluster_label="reporter:cluster:${cluster_sig}"
  # Repo label flattens owner/repo → owner__repo (GitHub labels disallow /).
  # Uses sed with '|' delimiter to substitute '/' directly, preserving any
  # underscores already present in the owner or repo segments. A previous
  # two-step (tr + sed) transform mis-flattened 'user_name/repo' as
  # 'user__name_repo' — see #33.
  local repo_flat
  if [ -n "$REPORT_REPO" ]; then
    repo_flat=$(printf '%s' "$REPORT_REPO" | sed 's|/|__|')
    repo_label="reporter:repo:${repo_flat}"
  else
    repo_label="reporter:repo:unknown"
  fi
  printf '%s\n%s\n%s\n%s\n%s\n' \
    "$hook_label" "$phase_label" "$severity_label" "$cluster_label" "$repo_label"
}
FIVE_AXIS_LABELS=$(_five_axis_labels)

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

  # Opportunistic sweep of leftovers (7-day TTL). Includes silent_skip
  # hour-bucketed markers (#26) alongside lock dirs and reported markers.
  find "$MARKER_DIR" "$LOCK_ROOT" -maxdepth 1 \( -name '*.lock' -o -name '*.reported' -o -name '.silent_skip.*' \) -mtime +7 -exec rm -rf {} + 2>/dev/null || true

  TITLE="[incident] $EVENT${AGENT_ID:+($AGENT_ID)} (${SESSION:0:8})"

  # F5 (#40): session-local base rate for TRIGGER_HOOK.
  # deny/total ratio over this session's debug log (already at $LOG_FILE).
  # Purely local computation — no cross-repo reads by default. Optional
  # git-log enrichment gated behind ERROR_REPORTER_BASE_RATES_INCLUDE_GIT=true.
  #
  # IMPORTANT: TRIGGER_HOOK is the EXTRACTED name (via PRESET_HOOK_EXTRACT_JQ
  # which may capture from `.reason` per P0-1). To count correctly we must
  # compare against the SAME extraction on each log entry — otherwise, when
  # the preset uses reason-prefix extraction, `.hook` in the log carries the
  # library wrapper ("hook-lib.sh") while TRIGGER_HOOK is the guard name.
  BASE_RATES_TEXT="(no hook context — skipping base-rate calculation)"
  if [ -n "$TRIGGER_HOOK" ] && [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ] \
     && [ -n "$PRESET_HOOK_EXTRACT_JQ" ]; then
    BR_TOTAL=$(jq -c --arg h "$TRIGGER_HOOK" \
      "select($PRESET_HOOK_EXTRACT_JQ == \$h)" "$LOG_FILE" 2>/dev/null \
      | wc -l | tr -d ' ')
    BR_DENY=$(jq -c --arg h "$TRIGGER_HOOK" \
      "select($PRESET_HOOK_EXTRACT_JQ == \$h) | select(.decision == \"deny\" or .decision == \"block\")" \
      "$LOG_FILE" 2>/dev/null | wc -l | tr -d ' ')
    BR_TOTAL=${BR_TOTAL:-0}
    BR_DENY=${BR_DENY:-0}
    if [ "$BR_TOTAL" -gt 0 ]; then
      BR_ALLOW=$((BR_TOTAL - BR_DENY))
      BR_PCT=$(awk -v d="$BR_DENY" -v t="$BR_TOTAL" 'BEGIN { printf "%.1f", (d * 100.0) / t }')
      BASE_RATES_TEXT="\`$TRIGGER_HOOK\` fired **$BR_TOTAL time(s)** this session (**$BR_DENY deny** / $BR_ALLOW allow — **${BR_PCT}% deny**)"
    else
      BASE_RATES_TEXT="(no prior activity for \`$TRIGGER_HOOK\` this session)"
    fi
  fi

  # Optional: git-log enrichment (5 most recent commits touching the hook file).
  # Read-only access to $CLAUDE_CONFIG_DIR — not a HG-5 crossing (governs writes).
  # Gated behind env opt-in so default behavior stays narrow.
  if [ "${ERROR_REPORTER_BASE_RATES_INCLUDE_GIT:-false}" = "true" ] && [ -n "$TRIGGER_HOOK" ]; then
    BR_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude-harness}"
    BR_HOOK_PATH="hooks/$TRIGGER_HOOK"
    if [ -f "$BR_CONFIG_DIR/$BR_HOOK_PATH" ] \
       && git -C "$BR_CONFIG_DIR" rev-parse --git-dir >/dev/null 2>&1; then
      BR_RECENT=$(git -C "$BR_CONFIG_DIR" log --oneline -5 -- "$BR_HOOK_PATH" 2>/dev/null)
      if [ -n "$BR_RECENT" ]; then
        BASE_RATES_TEXT="$BASE_RATES_TEXT

Recent commits on \`$BR_HOOK_PATH\`:

\`\`\`
$BR_RECENT
\`\`\`"
      fi
    fi
  fi

  # F7 (#42): Related Meta-Eval lookup.
  # Read-only enumeration of $CLAUDE_CONFIG_DIR/benchmarks/meta-evals/*.json
  # for an eval that matches TRIGGER_HOOK. Not a HG-5 crossing (reads only).
  # Outputs one of: exact pointer, tag-related pointer, coverage-gap badge,
  # or a diagnostic when the directory is unreachable.
  RELATED_EVAL_TEXT="(no hook context — skipping meta-eval lookup)"
  if [ -n "$TRIGGER_HOOK" ]; then
    ME_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude-harness}/benchmarks/meta-evals"
    HOOK_STEM="${TRIGGER_HOOK%.sh}"
    if [ ! -d "$ME_DIR" ]; then
      RELATED_EVAL_TEXT="(meta-eval directory unreachable — \`\$CLAUDE_CONFIG_DIR/benchmarks/meta-evals\` missing)"
    elif [ -f "$ME_DIR/${HOOK_STEM}.json" ]; then
      RELATED_EVAL_TEXT="Exact: \`benchmarks/meta-evals/${HOOK_STEM}.json\` — run via \`python3 benchmarks/run.py --tag hook:${HOOK_STEM}\`"
    else
      # Substring tag match: scan each .json for a "hook:<stem>" tag
      ME_MATCH=""
      for f in "$ME_DIR"/*.json; do
        [ -f "$f" ] || continue
        if grep -q "\"hook:${HOOK_STEM}\"" "$f" 2>/dev/null; then
          ME_MATCH=$(basename "$f")
          break
        fi
      done
      if [ -n "$ME_MATCH" ]; then
        RELATED_EVAL_TEXT="Related: \`benchmarks/meta-evals/${ME_MATCH}\` (tagged \`hook:${HOOK_STEM}\`)"
      else
        RELATED_EVAL_TEXT="**coverage-gap** — no meta-eval covers \`${TRIGGER_HOOK}\`. Scaffold via \`python3 error-reporter/scripts/incident-to-eval.py --issue <this-url>\`."
      fi
    fi
  fi

  # F8 (#43): Known Drift Match — grep $CLAUDE_CONFIG_DIR/CLAUDE.md
  # §"Known drift & risks" for TRIGGER_HOOK references. Read-only; HG-5 safe.
  # awk range extracts the section so matches outside the section don't leak.
  KNOWN_DRIFT_TEXT="(no hook context — skipping drift check)"
  if [ -n "$TRIGGER_HOOK" ]; then
    DRIFT_MD="${CLAUDE_CONFIG_DIR:-$HOME/.claude-harness}/CLAUDE.md"
    KD_STEM="${TRIGGER_HOOK%.sh}"
    if [ ! -f "$DRIFT_MD" ]; then
      KNOWN_DRIFT_TEXT="(\`CLAUDE.md\` unreachable at \`\$CLAUDE_CONFIG_DIR\` — cannot check drift.)"
    else
      # Extract the "## Known drift & risks" section (up to next H2)
      KD_SECTION=$(awk '
        /^## Known drift/ { in_sect = 1; next }
        /^## / && in_sect { exit }
        in_sect { print }
      ' "$DRIFT_MD")
      if [ -z "$KD_SECTION" ]; then
        KNOWN_DRIFT_TEXT="(\`CLAUDE.md\` has no §\"Known drift & risks\" section.)"
      else
        # Match either bare stem or stem.sh; limit to 3 occurrences
        KD_MATCHES=$(printf '%s\n' "$KD_SECTION" \
          | grep -nE "\`${KD_STEM}\b|\`${TRIGGER_HOOK}\`" \
          | head -3)
        if [ -z "$KD_MATCHES" ]; then
          KNOWN_DRIFT_TEXT="No references to \`${TRIGGER_HOOK}\` in \`CLAUDE.md\` §\"Known drift & risks\"."
        else
          KD_COUNT=$(printf '%s\n' "$KD_MATCHES" | wc -l | tr -d ' ')
          KNOWN_DRIFT_TEXT="Found ${KD_COUNT} match(es) in \`CLAUDE.md\` §\"Known drift & risks\":

\`\`\`
$KD_MATCHES
\`\`\`"
        fi
      fi
    fi
  fi

  # #24: extract the decisive entry — the first deny/fail line from the
  # last 50 lines of the debug log — with ±5 lines of context for signal
  # concentration. Falls back to the full tail when no match is found.
  DECISIVE_CONTEXT="(no decisive entry detected in last 50 lines)"
  if [ -n "$DEBUG_LOG_TAIL" ]; then
    DECISIVE_CONTEXT=$(printf '%s\n' "$DEBUG_LOG_TAIL" \
      | awk '
          /"decision":"(deny|block)"|"status":"fail"/ {
            found = NR
            for (i = NR - 5; i <= NR + 5; i++) ctx[i] = 1
          }
          {
            lines[NR] = $0
          }
          END {
            if (found) {
              for (i = 1; i <= NR; i++) if (ctx[i]) {
                marker = (i == found) ? "  ← decisive" : ""
                printf "%s%s\n", lines[i], marker
              }
            } else {
              for (i = 1; i <= NR; i++) print lines[i]
            }
          }
        ' 2>/dev/null)
    [ -z "$DECISIVE_CONTEXT" ] && DECISIVE_CONTEXT="$DEBUG_LOG_TAIL"
  fi

  REPORT_BODY="## Trigger

| Event | Hook | Phase | Agent | Severity | Commit |
|-------|------|-------|-------|----------|--------|
| \`$EVENT\` | \`${TRIGGER_HOOK:-—}\` | \`$PHASE\` | \`${AGENT_ID:-—}\` | \`$SEVERITY\` | \`$TRIGGER_COMMIT\` |

## Decisive Entry

\`\`\`jsonl
${DECISIVE_CONTEXT}
\`\`\`

## Counterfactual

<!-- What SHOULD have happened — fill in manually to make this observation actionable -->

## Base Rates

${BASE_RATES_TEXT}

## Related Meta-Eval

${RELATED_EVAL_TEXT}

## Known Drift Match

${KNOWN_DRIFT_TEXT}

## Reproduction

Re-run the incident context via the harness skill:

\`\`\`bash
/kb-harness --from-incident <this-issue-number> --target \$HOME/.claude-harness
\`\`\`

Related eval (fill in the eval id when one applies):

\`\`\`bash
/eval <eval-id>
\`\`\`

<details><summary>Raw data (collapsed)</summary>

### Hook Input
\`\`\`json
$INPUT
\`\`\`

### State Snapshot
\`\`\`json
${STATE_SNAPSHOT:-(unavailable)}
\`\`\`

### Debug Log (last 50 lines)
\`\`\`
${DEBUG_LOG_TAIL:-(unavailable)}
\`\`\`

### Transcript (last 20 lines)
\`\`\`
${TRANSCRIPT_TAIL:-(unavailable)}
\`\`\`

</details>"

  # #24: 10KB body cap. GitHub issue bodies accept up to 65536 chars, but
  # dashboards + reviewers suffer above ~10KB. Truncate tail (the <details>
  # collapsed block is the longest section and the least decision-dense).
  # Full payload preserved in the local .md fallback (written below).
  BODY_MAX_BYTES=10240
  BODY_BYTES=$(printf '%s' "$REPORT_BODY" | wc -c | tr -d ' ')
  if [ "${BODY_BYTES:-0}" -gt "$BODY_MAX_BYTES" ]; then
    # Reserve 160 bytes for the truncation marker, cut the rest via head -c
    # (byte-safe for multi-byte chars — unlike \${VAR:0:N} which is char-based).
    REPORT_BODY=$(printf '%s' "$REPORT_BODY" | head -c $((BODY_MAX_BYTES - 160)))
    REPORT_BODY="$REPORT_BODY

---

<!-- #24: body truncated at 10KB boundary. Full payload in local report.md. -->"
  fi

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
    # P0-5: classify as FAIL (not skip) when all 4 fallbacks (env/config/cwd/preset.repo)
    # returned empty. Local .md is always written (above) so observable trace is preserved.
    # Field order mirrors the status=ok/fail lines below so key=value log consumers
    # can parse uniformly (phase/agent/domain/commit present, plus the new reason/source/hook_cwd).
    # hook_cwd is quoted because paths with spaces would otherwise break key=value
    # tokenizers (e.g., "/Users/John Doe/proj" → "hook_cwd=/Users/John" + orphan).
    log_line "$(printf '[%s] status=fail event=%s sid=%s phase=%s agent=%s domain=%s commit=%s reason=repo_resolution_failed source=%s hook_cwd=%q local=%s' \
      "$TS" "$EVENT" "$SESSION" "$PHASE" "${AGENT_FIELD:-none}" "$DOMAIN" "$TRIGGER_COMMIT" "${REPORT_REPO_SOURCE:-unknown}" "${HOOK_CWD:-}" "$LOCAL_OK")"
  elif command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    gh label create "type:incident" --description "Immediate response needed" --color "D73A4A" --repo "$REPORT_REPO" 2>/dev/null || true
    gh label create "auto:hook-failure" --description "Auto-generated by error-reporter" --color "EDEDED" --repo "$REPORT_REPO" 2>/dev/null || true
    gh label create "severity:$SEVERITY" --description "" --color "FFA500" --repo "$REPORT_REPO" 2>/dev/null || true

    # #22: 5-axis labels (hook / phase / severity / cluster / repo).
    # Idempotent create — existing labels are silently skipped via || true.
    while IFS= read -r axis_label; do
      [ -z "$axis_label" ] && continue
      gh label create "$axis_label" --description "5-axis (error-reporter plugin)" --color "5319E7" --repo "$REPORT_REPO" 2>/dev/null || true
    done <<FIVEAXIS
$FIVE_AXIS_LABELS
FIVEAXIS

    # Legacy reporter:domain:* — emitted only when DOMAIN is non-empty,
    # which now happens only for v=1 presets (backcompat window).
    if [ -n "$DOMAIN" ]; then
      gh label create "$DOMAIN" --description "Auto-inferred domain (legacy v=1 preset)" --color "0E8A16" --repo "$REPORT_REPO" 2>/dev/null || true
    fi
    [ -n "$AGENT_FIELD" ] && gh label create "reporter:agent:${AGENT_FIELD}" --description "Agent scope (error-reporter plugin)" --color "1D76DB" --repo "$REPORT_REPO" 2>/dev/null || true

    # LABELS: base + 5-axis + legacy domain (if set) + agent (if set)
    FIVE_AXIS_CSV=$(printf '%s' "$FIVE_AXIS_LABELS" | paste -sd ',' -)
    LABELS="type:incident,auto:hook-failure,severity:${SEVERITY},${FIVE_AXIS_CSV}"
    [ -n "$DOMAIN" ] && LABELS="${LABELS},${DOMAIN}"
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
