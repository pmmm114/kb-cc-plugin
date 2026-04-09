#!/usr/bin/env bash
# hook-lib-config.sh — Config-path detection functions
#
# Separation rationale: these three functions are CONFIG-domain concerns.
# Everything else (FSM, state I/O, locking, tasks, handoff) lives in
# hook-lib-core.sh. Keeping config-path detection here allows unit testing
# and future replacement without touching the core state machine.
#
# Do NOT source hook-lib-core.sh here — hook-lib.sh (the stub) handles
# the sourcing order: core first, then this file.
#
# Functions exported:
#   is_config_path <path>          — returns 0 if path is a config file
#   is_write_to_config <command>   — returns 0 if command writes to config
#   _command_targets_config <cmd> <config_home>  — internal helper

is_config_path() {
  local path="$1"
  local ch="$HOME/.claude"
  # State files: block agent Edit/Write/Bash at PreToolUse boundary.
  # hook-internal write_state() bypasses this entirely because hooks call
  # write_state directly — no PreToolUse gate is traversed.
  local sd="${STATE_DIR:-/tmp/claude-session}"
  path="${path/#\~/$HOME}"
  # macOS /tmp <-> /private/tmp symlink: normalize both sides for comparison
  local path_alt="$path" sd_alt="$sd"
  case "$path" in /tmp/*) path_alt="/private$path" ;; /private/tmp/*) path_alt="${path#/private}" ;; esac
  case "$sd"   in /tmp/*) sd_alt="/private$sd" ;;   /private/tmp/*) sd_alt="${sd#/private}" ;;   esac
  case "$path" in
    "$sd"/*.json|"$sd"/*.lock|"$sd"/*.lock/*) return 0 ;;
    "$sd_alt"/*.json|"$sd_alt"/*.lock|"$sd_alt"/*.lock/*) return 0 ;;
  esac
  case "$path_alt" in
    "$sd"/*.json|"$sd"/*.lock|"$sd"/*.lock/*) return 0 ;;
    "$sd_alt"/*.json|"$sd_alt"/*.lock|"$sd_alt"/*.lock/*) return 0 ;;
  esac
  case "$path" in
    "$ch"/rules/*|"$ch"/agents/*|"$ch"/skills/*|"$ch"/hooks/*|"$ch"/plugins/*) return 0 ;;
    "$ch"/benchmarks/evals/*|"$ch"/benchmarks/workflow-evals/*|"$ch"/benchmarks/tests/*) return 0 ;;
    "$ch"/settings.json|"$ch"/CLAUDE.md) return 0 ;;
  esac
  echo "$path" | grep -qE '/\.claude/(settings|hooks|skills|agents|rules)' && return 0
  return 1
}

is_write_to_config() {
  local command="$1"
  local ch="$HOME/.claude"

  # --- Redirects: check if redirect TARGET is a config path ---
  # Vector 5 (heredoc): cat << EOF > <config-path> is caught here because the
  # sed pattern matches the single > redirect regardless of whether << heredoc
  # syntax precedes it. No additional handling required.
  local segment redirect_target
  while IFS= read -r segment; do
    redirect_target=$(echo "$segment" | sed -nE 's/.*[^>]>([^>].*)/\1/p' | sed 's/^[[:space:]]*//' | awk '{print $1}')
    if [ -n "$redirect_target" ]; then
      redirect_target="${redirect_target/#\~/$HOME}"
      is_config_path "$redirect_target" && return 0
    fi
  done < <(echo "$command" | sed 's/&&/\n/g; s/;/\n/g')

  # --- cd into config dir + any write ---
  local cd_path
  cd_path=$(echo "$command" | sed -nE 's/.*cd[[:space:]]+([^ &;|]+).*/\1/p')
  if [ -n "$cd_path" ]; then
    cd_path="${cd_path/#\~/$HOME}"
    { echo "$cd_path" | grep -qF "$ch" || echo "$cd_path" | grep -qF '.claude'; } && return 0
  fi

  # --- Segment-aware write-verb check ---
  _command_targets_config "$command" "$ch" && return 0

  return 1
}

# Helper: segment-aware config path detection.
# Splits the command on shell separators (;, &&, ||, |) and for each segment
# checks only if the HEAD command is a write verb before scanning arguments.
# This prevents false positives where a read-only verb (ls, cat) has a config
# path as its argument — only write verbs can actually modify config files.
#
# Command-substitution flattening: $(...) and backtick substitutions are
# promoted to sibling segments so that hidden write verbs like
# `echo $(rm ~/.claude/hooks/x.sh)` are caught. A single flatten pass covers
# the common case; deeply nested $(...) are extremely rare in practice.
_command_targets_config() {
  local command="$1" ch="$2"

  # Flatten $(...) and backtick substitutions into sibling segments so that
  # write verbs hidden inside command substitutions are not missed.
  local command_flat
  command_flat=$(echo "$command" | sed -E 's/\$\(/; /g; s/\)/; /g; s/`/; /g')

  # Split on ; && || | into segments
  local seg
  while IFS= read -r seg; do
    # Strip leading/trailing whitespace
    seg="${seg#"${seg%%[! ]*}"}"
    seg="${seg%"${seg##*[! ]}"}"
    [ -z "$seg" ] && continue

    # Strip leading variable assignments like FOO=bar VAR=baz cmd ...
    local head="$seg"
    while echo "$head" | grep -qE '^[A-Z_][A-Za-z0-9_]*='; do
      head="${head#*=}"
      # Remove the value token (up to next space)
      head="${head#[^ ]* }"
      head="${head#"${head%%[! ]*}"}"
    done

    # Extract the head command (first word)
    local verb
    verb="${head%% *}"
    verb="${verb##*/}"  # strip any path prefix

    # Determine if this segment's verb is a write verb.
    # Case arms are grouped by category:
    #   1. Unconditional write verbs (always write when invoked)
    #   2. Conditional write verbs — file/network tools (write only under specific flags)
    #   3. Git subcommands (write depends on subcommand + flags)
    #   4. Shell dispatch wrappers (recurse into inner command)
    #   5. Archive/patch extraction tools
    local is_write=0
    case "$verb" in

      # ---- 1. Unconditional write verbs ----
      cp|mv|touch|tee|rm|chmod|install|mkdir|rsync)
        is_write=1
        ;;

      # ---- 2. Conditional write verbs — file/network tools ----
      sed|perl)
        # Only write if in-place flag present
        if echo "$seg" | grep -qE '(sed[[:space:]]+-i|sed[[:space:]]+--in-place|perl[[:space:]]+-[a-zA-Z]*[pi])'; then
          is_write=1
        fi
        # perl -e with file-write patterns targeting config
        if [ "$is_write" -eq 0 ] && echo "$seg" | grep -qE 'perl[[:space:]]+-[eE]' && \
           echo "$seg" | grep -qE '(open\s*\(.*[">]|File::Copy|copy\s*\(|move\s*\()' && \
           echo "$seg" | grep -qF "$ch"; then
          is_write=1
        fi
        ;;
      python|python3)
        # Only write if -c with open(...'w'...)
        if echo "$seg" | grep -qE 'python3?[[:space:]]+-c.*open.*w'; then
          is_write=1
        fi
        ;;
      ln)
        # Vector 2: symlink creation — ln / ln -s / ln -sf <src> <target>.
        # The target (last arg) determines where the write lands.
        local ln_last
        ln_last=$(echo "$seg" | awk '{print $NF}')
        ln_last="${ln_last/#\~/$HOME}"
        if is_config_path "$ln_last"; then
          is_write=1
        fi
        ;;
      node)
        # Vector 3a: node -e "...writeFile/fs.write..." targeting a config path.
        # Only flag when the -e string contains a write indicator AND a config path.
        if echo "$seg" | grep -qE 'node[[:space:]]+-e' && \
           echo "$seg" | grep -qE '(writeFile|fs\.write|createWriteStream)' && \
           echo "$seg" | grep -qF "$ch"; then
          is_write=1
        fi
        ;;
      ruby)
        # Vector 3b: ruby -e "...File.write/File.open.*w..." targeting a config path.
        if echo "$seg" | grep -qE 'ruby[[:space:]]+-e' && \
           echo "$seg" | grep -qE '(File\.write|File\.open.*['"'"'"]w['"'"'"])' && \
           echo "$seg" | grep -qF "$ch"; then
          is_write=1
        fi
        ;;
      dd)
        # Vector 4: dd of=<config-path>.
        if echo "$seg" | grep -qE 'of='; then
          local dd_of
          dd_of=$(echo "$seg" | grep -oE 'of=[^ ]+' | sed 's/^of=//')
          dd_of="${dd_of/#\~/$HOME}"
          if is_config_path "$dd_of"; then
            is_write=1
          fi
        fi
        ;;
      awk|gawk|mawk)
        # awk -i inplace modifies files in-place (like sed -i)
        if echo "$seg" | grep -qE '(awk|gawk|mawk)[[:space:]].*-i[[:space:]]*inplace'; then
          is_write=1
        fi
        ;;
      curl)
        # Vector 7: curl -o / --output <config-path>.
        # Detects file download targeting a config path via the output flag.
        local curl_out
        curl_out=$(echo "$seg" | grep -oE '(-o[[:space:]]*|--output[= ])[^ ]+' | awk '{print $NF}')
        if [ -n "$curl_out" ]; then
          curl_out="${curl_out/#\~/$HOME}"
          if is_config_path "$curl_out"; then
            is_write=1
          fi
        fi
        ;;
      wget)
        # Vector 8: wget -O / --output-document <config-path>.
        local wget_out
        wget_out=$(echo "$seg" | grep -oE '(-O[[:space:]]*|--output-document[= ])[^ ]+' | awk '{print $NF}')
        if [ -n "$wget_out" ]; then
          wget_out="${wget_out/#\~/$HOME}"
          if is_config_path "$wget_out"; then
            is_write=1
          fi
        fi
        ;;

      # ---- 3. Git subcommands ----
      git)
        # Vector 1: git checkout/restore/apply targeting config paths.
        # git checkout main or git restore . are NOT flagged (no config path in args).
        # git checkout HEAD -- ~/.claude/hooks/x.sh IS flagged.
        # Fix #3: also check for literal '.claude/' because $ch contains the
        # expanded path ($HOME/.claude) and won't match a tilde-prefixed arg
        # like ~/.claude/hooks/x.sh that the shell hasn't yet expanded.
        # Vector 14: git reset --hard — unconditionally overwrites the working tree.
        # Vector 15: git clean -f / -fd — deletes untracked files; requires -f flag.
        local git_sub
        git_sub=$(echo "$seg" | awk '{print $2}')
        case "$git_sub" in
          checkout|restore|apply)
            if echo "$seg" | grep -qF "$ch" || echo "$seg" | grep -qF '.claude/'; then
              is_write=1
            fi
            ;;
          reset)
            # Only --hard rewrites tracked files; --soft and --mixed do not touch working tree.
            # Return immediately — reset --hard affects all tracked files in CWD, so no
            # config-path argument is required; the verb alone is sufficient to block.
            if echo "$seg" | grep -qE '(^|[[:space:]])--hard([[:space:]]|$)'; then
              return 0
            fi
            ;;
          clean)
            # Requires -f (force) flag to actually delete; -fd removes directories too.
            # Only flag when a config path is targeted explicitly or the CWD is inside config.
            if echo "$seg" | grep -qE '(^|[[:space:]])-[a-zA-Z]*f[a-zA-Z]*([[:space:]]|$)'; then
              if echo "$seg" | grep -qF "$ch" || echo "$seg" | grep -qF '.claude/'; then
                is_write=1
              fi
            fi
            ;;
        esac
        ;;

      # ---- 4. Shell dispatch wrappers (recurse into inner command) ----
      sh|bash|zsh)
        # Vector 6: sh -c / bash -c / zsh -c — extract the -c argument and
        # recursively check it. Recursion is limited to 2 levels via
        # _IWTC_DEPTH to cover double-nested invocations like
        # sh -c 'bash -c "..."' without unbounded recursion.
        # Note: env -u _IWTC_DEPTH could reset the counter and bypass the limit,
        # but Claude generates these commands (not external attackers), so this
        # is an acceptable risk — document rather than over-engineer.
        if echo "$seg" | grep -qE '[[:space:]]+-c[[:space:]]'; then
          local inner_cmd depth
          depth="${_IWTC_DEPTH:-0}"
          if [ "$depth" -lt 2 ]; then
            # Extract everything after -c (strip optional surrounding quotes)
            inner_cmd=$(echo "$seg" | sed -nE "s/.*[[:space:]]-c[[:space:]]+['\"]?([^'\"]+)['\"]?.*/\1/p")
            if [ -n "$inner_cmd" ]; then
              _IWTC_DEPTH=$(( depth + 1 )) is_write_to_config "$inner_cmd" && is_write=1
            fi
          fi
        fi
        ;;
      env)
        # Vector 9: env [FLAGS] [KEY=VALUE...] <cmd> [args] — strip leading dash-flags
        # and KEY=VALUE tokens to find the real command, then re-check recursively.
        # Covers: env sh -c '...', env FOO=bar bash -c '...', env -S 'bash -c ...'
        local env_rest depth
        depth="${_IWTC_DEPTH:-0}"
        if [ "$depth" -lt 2 ]; then
          env_rest="$seg"
          # Strip the leading 'env' word
          env_rest="${env_rest#env}"
          env_rest="${env_rest#"${env_rest%%[! ]*}"}"
          # Strip leading flags (e.g. -i, -u VAR, -S 'cmd') and KEY=VALUE tokens
          while true; do
            local token
            token="${env_rest%% *}"
            case "$token" in
              -*) env_rest="${env_rest#* }"; env_rest="${env_rest#"${env_rest%%[! ]*}"}" ;;
              *=*) env_rest="${env_rest#* }"; env_rest="${env_rest#"${env_rest%%[! ]*}"}" ;;
              *) break ;;
            esac
          done
          # env_rest now starts with the real command; recurse if non-empty
          if [ -n "$env_rest" ]; then
            _IWTC_DEPTH=$(( depth + 1 )) is_write_to_config "$env_rest" && is_write=1
          fi
        fi
        ;;
      xargs)
        # Vector 10: xargs ... sh -c 'cmd' — detect shell dispatch inside xargs args.
        # We only care if the xargs command itself is dispatching a shell with -c,
        # not the items piped to xargs. If shell dispatch is found, extract the
        # -c argument and recurse.
        local depth
        depth="${_IWTC_DEPTH:-0}"
        if [ "$depth" -lt 2 ]; then
          if echo "$seg" | grep -qE '(sh|bash|zsh)[[:space:]]+-c[[:space:]]'; then
            local inner_cmd
            inner_cmd=$(echo "$seg" | sed -nE "s/.*(sh|bash|zsh)[[:space:]]+-c[[:space:]]+['\"]?([^'\"]+)['\"]?.*/\2/p")
            if [ -n "$inner_cmd" ]; then
              _IWTC_DEPTH=$(( depth + 1 )) is_write_to_config "$inner_cmd" && is_write=1
            fi
          fi
        fi
        ;;

      # ---- 5. Archive/patch extraction tools ----
      tar)
        # Vector 11: tar -xf / tar xf — extraction that writes to a config path.
        # Flags to detect: -x or x mode (extract), plus either -C config_path or
        # a config path appearing as an extraction destination argument.
        if echo "$seg" | grep -qE 'tar[[:space:]]+[^ ]*x'; then
          # Check for -C <config_path>
          local tar_C
          tar_C=$(echo "$seg" | grep -oE '(-C|--directory)[[:space:]]+[^ ]+' | awk '{print $NF}')
          if [ -n "$tar_C" ]; then
            tar_C="${tar_C/#\~/$HOME}"
            if is_config_path "$tar_C"; then
              is_write=1
            fi
          fi
          # Also check if any arg directly references a config path
          if [ "$is_write" -eq 0 ] && { echo "$seg" | grep -qF "$ch" || echo "$seg" | grep -qF '.claude/'; }; then
            is_write=1
          fi
        fi
        ;;
      unzip)
        # Vector 12: unzip -d <config_path> — extraction targeting a config directory.
        local unzip_d
        unzip_d=$(echo "$seg" | grep -oE '(-d|--directory)[[:space:]]+[^ ]+' | awk '{print $NF}')
        if [ -n "$unzip_d" ]; then
          unzip_d="${unzip_d/#\~/$HOME}"
          if is_config_path "$unzip_d"; then
            is_write=1
          fi
        fi
        # Also catch unzip directly into a config path without -d flag
        if [ "$is_write" -eq 0 ] && { echo "$seg" | grep -qF "$ch" || echo "$seg" | grep -qF '.claude/'; }; then
          is_write=1
        fi
        ;;
      patch)
        # Vector 13: patch targeting a config path — patch <file> or patch -o <file>.
        if echo "$seg" | grep -qF "$ch" || echo "$seg" | grep -qF '.claude/'; then
          is_write=1
        fi
        ;;
    esac

    [ "$is_write" -eq 0 ] && continue

    # Scan args of this segment for config paths
    local word
    for word in $seg; do
      word="${word/#\~/$HOME}"
      is_config_path "$word" && return 0
    done

    # Fallback: check if .claude appears as substring in segment (handles quoted python -c paths)
    echo "$seg" | grep -qF "$ch" && return 0

  done < <(echo "$command_flat" | sed 's/||/\n/g; s/&&/\n/g; s/|/\n/g; s/;/\n/g')

  return 1
}
