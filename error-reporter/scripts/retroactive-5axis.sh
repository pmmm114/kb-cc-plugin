#!/bin/bash
# retroactive-5axis.sh
#
# User-local backfill script that applies the 5-axis labels (#22) to
# historical `auto:hook-failure` issues filed BEFORE the schema rollout.
# Specifically targets the known smoke-fixture issues that predate
# PR #32 (5-axis emission) — the claude-harness-engineering repo's
# #82, #83, #84 issues originally received only the single-axis
# `reporter:domain:*` label plus `auto:hook-failure`.
#
# Intentionally NOT wired into CI — this is a one-shot operator tool
# run locally with a user PAT that has cross-repo write access. The
# default GITHUB_TOKEN in a Workflow context cannot edit issues across
# repositories, so CI-based backfill would silently 403 with the current
# permissions model.
#
# Usage:
#   retroactive-5axis.sh --dry-run --issues <owner/repo>:<n1,n2,...>
#   retroactive-5axis.sh --apply --yes-i-mean-it --issues <owner/repo>:<n1,n2,...>
#
# Safety defaults:
#   - --dry-run is the default mode. No writes happen without --apply.
#   - --apply REQUIRES --yes-i-mean-it to actually mutate issues.
#   - --remove-old-domain (optional) additionally strips reporter:domain:*
#     from the target issues. Destructive — off by default.
#
# Exit codes:
#   0 success
#   1 argument error
#   2 missing dependency (gh, jq) or auth failure
#   3 target repo is private and PAT lacks `repo` scope
#
# Rate-limit pacing: sleep 2 seconds between issue updates. GitHub core
# rate limit is 5000/hour, but the `search` endpoint (which `gh issue list`
# uses internally) has a stricter 30 req/min cap. With 2s pacing we stay
# well under both thresholds even for multi-hundred-issue batches.

set +e

MODE="dry-run"
YES=false
REMOVE_OLD_DOMAIN=false
ISSUES_ARG=""
SLEEP_SEC=2

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)
      MODE="dry-run"
      shift
      ;;
    --apply)
      MODE="apply"
      shift
      ;;
    --yes-i-mean-it)
      YES=true
      shift
      ;;
    --remove-old-domain)
      REMOVE_OLD_DOMAIN=true
      shift
      ;;
    --issues)
      ISSUES_ARG="$2"
      shift 2
      ;;
    --sleep)
      SLEEP_SEC="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '3,35p' "$0"
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [ -z "$ISSUES_ARG" ]; then
  echo "error: --issues <owner/repo>:<n1,n2,...> is required" >&2
  exit 1
fi

# Parse --issues argument
if ! [[ "$ISSUES_ARG" =~ ^([^/]+)/([^:]+):([0-9,]+)$ ]]; then
  echo "error: --issues must be in form owner/repo:n1,n2,n3" >&2
  echo "       e.g. --issues pmmm114/claude-harness-engineering:82,83,84" >&2
  exit 1
fi
OWNER_REPO="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
IFS=',' read -ra ISSUE_NUMBERS <<< "${BASH_REMATCH[3]}"

if [ "$MODE" = "apply" ] && [ "$YES" != "true" ]; then
  echo "error: --apply requires --yes-i-mean-it as an explicit confirmation flag" >&2
  echo "       This prevents accidental issue mutation on autocomplete / shell history." >&2
  exit 1
fi

command -v gh >/dev/null 2>&1 || { echo "error: gh CLI not found" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "error: jq not found" >&2; exit 2; }

# Verify gh auth
if ! gh auth status >/dev/null 2>&1; then
  echo "error: gh is not authenticated. Run: gh auth login" >&2
  exit 2
fi

# Verify target repo reachable + detect visibility for PAT scope hint
REPO_VIS=$(gh repo view "$OWNER_REPO" --json isPrivate --jq '.isPrivate' 2>/dev/null)
if [ -z "$REPO_VIS" ]; then
  echo "error: cannot reach $OWNER_REPO (404? auth?) — check URL and PAT scopes" >&2
  exit 3
fi
if [ "$REPO_VIS" = "true" ]; then
  # For private repos, gh PAT needs full `repo` scope (not just public_repo)
  TOKEN_SCOPES=$(gh auth status 2>&1 | grep -oE "'repo'" | head -1)
  if [ -z "$TOKEN_SCOPES" ]; then
    cat >&2 <<EOT
error: $OWNER_REPO is private but your gh token does not advertise 'repo' scope.
       Run: gh auth refresh -s repo
       Then re-run this script.
EOT
    exit 3
  fi
fi

# --- Inference helpers ---
# Derive the 5-axis label VALUES for a given issue by parsing its body's
# Trigger table row (#24 format). Returns the labels on separate lines;
# empty line if parse failed.

derive_labels_for_issue() {
  local issue_num="$1"
  local body
  body=$(gh issue view "$issue_num" --repo "$OWNER_REPO" --json body --jq '.body' 2>/dev/null)
  [ -z "$body" ] && return 1

  # Extract Trigger table row — regex mirrors report.sh _five_axis_labels logic
  # The row shape: | `EVENT` | `HOOK` | `PHASE` | `AGENT` | `SEVERITY` | `COMMIT` |
  local row
  row=$(printf '%s' "$body" | grep -m1 -E '^\| `[A-Za-z]+` \| `[^`]+` \|' || true)
  if [ -z "$row" ]; then
    # Legacy body shape (pre-#24) — use field-less fallback
    echo ""
    return
  fi

  # Parse cells — only the 4 columns that feed 5-axis labels (event/commit
  # are in the Trigger table but not part of the 5-axis scheme per #22).
  local hook phase agent severity
  hook=$(printf '%s' "$row"     | awk -F '`' '{print $4}')
  phase=$(printf '%s' "$row"    | awk -F '`' '{print $6}')
  agent=$(printf '%s' "$row"    | awk -F '`' '{print $8}')
  severity=$(printf '%s' "$row" | awk -F '`' '{print $10}')

  # Emit labels (empty cells / dash cells skipped)
  local hook_stem="${hook%.sh}"
  [ "$hook" = "—" ] && hook_stem=""
  [ "$phase" = "—" ] && phase=""
  [ "$severity" = "—" ] && severity=""
  [ "$agent" = "—" ] && agent=""

  [ -n "$hook_stem" ] && printf 'reporter:hook:%s\n' "$hook_stem"
  [ -n "$phase" ]     && printf 'reporter:phase:%s\n' "$phase"
  [ -n "$severity" ]  && printf 'reporter:severity:%s\n' "$severity"
  # Cluster sig — sha1 of the same input as report.sh _five_axis_labels
  if [ -n "$hook_stem$phase$severity$agent" ]; then
    local sig_input sig
    sig_input="${hook_stem:-none}:${phase:-none}:${severity:-none}:${agent:-none}"
    sig=$(printf '%s' "$sig_input" | shasum 2>/dev/null | cut -c1-12)
    [ -n "$sig" ] && printf 'reporter:cluster:%s\n' "$sig"
  fi
  # Repo label — the repo this issue lives in (not the CWD repo at emission time)
  printf 'reporter:repo:%s\n' "$(printf '%s' "$OWNER_REPO" | sed 's|/|__|')"
  # Agent if present
  [ -n "$agent" ] && printf 'reporter:agent:%s\n' "$agent"
}

# --- Main loop ---
printf 'retroactive-5axis — repo=%s mode=%s remove_old_domain=%s\n' \
  "$OWNER_REPO" "$MODE" "$REMOVE_OLD_DOMAIN"
printf 'issues: %s\n' "$(IFS=,; echo "${ISSUE_NUMBERS[*]}")"
printf 'sleep-per-issue: %ds\n\n' "$SLEEP_SEC"

TOTAL=${#ISSUE_NUMBERS[@]}
IDX=0
APPLIED=0
SKIPPED=0
FAILED=0

for N in "${ISSUE_NUMBERS[@]}"; do
  IDX=$((IDX + 1))
  printf '[%d/%d] issue #%s\n' "$IDX" "$TOTAL" "$N"

  LABELS=$(derive_labels_for_issue "$N")
  if [ -z "$LABELS" ]; then
    printf '  skipped: could not derive labels from body (legacy format?)\n'
    SKIPPED=$((SKIPPED + 1))
    [ "$IDX" -lt "$TOTAL" ] && sleep "$SLEEP_SEC"
    continue
  fi

  # Build the --add-label CSV
  ADD_CSV=$(printf '%s' "$LABELS" | paste -sd ',' -)

  if [ "$MODE" = "dry-run" ]; then
    printf '  [dry-run] would add labels: %s\n' "$ADD_CSV"
    if [ "$REMOVE_OLD_DOMAIN" = "true" ]; then
      printf '  [dry-run] would remove any existing reporter:domain:* labels\n'
    fi
  else
    # Apply: add labels + optionally remove legacy domain labels
    if gh issue edit "$N" --repo "$OWNER_REPO" --add-label "$ADD_CSV" 2>/dev/null; then
      printf '  applied: added %s\n' "$ADD_CSV"
      APPLIED=$((APPLIED + 1))
    else
      printf '  failed: gh issue edit returned non-zero\n'
      FAILED=$((FAILED + 1))
      [ "$IDX" -lt "$TOTAL" ] && sleep "$SLEEP_SEC"
      continue
    fi

    if [ "$REMOVE_OLD_DOMAIN" = "true" ]; then
      EXISTING_DOMAINS=$(gh issue view "$N" --repo "$OWNER_REPO" --json labels --jq '.labels[] | select(.name | startswith("reporter:domain:")) | .name' 2>/dev/null)
      while IFS= read -r DL; do
        [ -z "$DL" ] && continue
        if gh issue edit "$N" --repo "$OWNER_REPO" --remove-label "$DL" 2>/dev/null; then
          printf '  removed legacy: %s\n' "$DL"
        else
          printf '  failed to remove: %s\n' "$DL"
        fi
      done <<EOF
$EXISTING_DOMAINS
EOF
    fi
  fi

  [ "$IDX" -lt "$TOTAL" ] && sleep "$SLEEP_SEC"
done

printf '\n---\n'
printf 'total=%d applied=%d skipped=%d failed=%d\n' \
  "$TOTAL" "$APPLIED" "$SKIPPED" "$FAILED"

[ "$FAILED" -gt 0 ] && exit 1
exit 0
