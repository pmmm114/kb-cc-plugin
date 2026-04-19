#!/bin/bash
# ensure-reporter-labels.sh
#
# Pre-create the ENUMERABLE 5-axis labels that error-reporter emits so
# that runtime `gh label create ... || true` calls never race with the
# plugin-label.yml workflow or hit GitHub rate limits during a burst of
# incidents.
#
# ENUMERABLE axes:
#   - reporter:severity:<label>   — derived from presets/claude-harness.json
#   - reporter:phase:<name>       — hardcoded from hook-lib-core.sh state machine
#
# NON-ENUMERABLE axes (deliberately NOT pre-created):
#   - reporter:hook:<stem>        — open set; any hook file name can fire
#   - reporter:cluster:<12-hex>   — 48-bit hash, space too large
#   - reporter:repo:<owner__repo> — per-user repo list, unbounded
#
# Idempotent: uses `gh label create ... || true`. Safe to re-run.
#
# Usage:
#   ensure-reporter-labels.sh --repo <owner/repo> [--dry-run]
#
# Exit: 0 on success, 1 on argument error, 2 on missing dependencies.

set +e

DRY_RUN=false
REPO=""

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      REPO="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      sed -n '3,27p' "$0"
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [ -z "$REPO" ]; then
  echo "error: --repo <owner/repo> is required" >&2
  exit 1
fi

command -v gh >/dev/null 2>&1 || { echo "error: gh CLI not found" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "error: jq not found" >&2; exit 2; }

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PRESET="$SCRIPT_DIR/../presets/claude-harness.json"
[ -f "$PRESET" ] || { echo "error: preset not found at $PRESET" >&2; exit 2; }

# --- Severity labels from preset ---
# severity_rules values: {"StopFailure":{"timeout":"A3-resource","default":"A1-coordination"},"Stop":"A2-guard-recovered",...}
# Collect every scalar value (leaves of the severity_rules tree).
SEVERITIES=$(jq -r '
  .severity_rules
  | [ .. | strings ]
  | unique
  | .[]
' "$PRESET")
# Always include "unknown" — emitted when preset unloaded (generic mode).
SEVERITIES="$SEVERITIES
unknown"

# --- Phase labels (hardcoded from harness state machine) ---
# Matches hook-lib-core.sh VALID_TRANSITIONS keys.
PHASES="idle
planning
reviewing
plan_review
executing
verifying
editing
config_planning
config_plan_review
config_editing
unknown"

CREATED=0
SKIPPED=0
DRY_RUN_NOTED=0

ensure_label() {
  # $1 = label name, $2 = description, $3 = color (hex no #)
  local name="$1"
  local desc="$2"
  local color="$3"

  if [ "$DRY_RUN" = "true" ]; then
    printf '  [dry-run] would create: %s (color=%s)\n' "$name" "$color"
    DRY_RUN_NOTED=$((DRY_RUN_NOTED + 1))
    return
  fi

  if gh label create "$name" \
      --repo "$REPO" \
      --description "$desc" \
      --color "$color" 2>/dev/null; then
    printf '  created: %s\n' "$name"
    CREATED=$((CREATED + 1))
  else
    # Already exists OR transient failure — align with runtime `|| true` semantic
    printf '  skipped (exists or err): %s\n' "$name"
    SKIPPED=$((SKIPPED + 1))
  fi
}

printf 'ensure-reporter-labels — repo=%s dry_run=%s\n\n' "$REPO" "$DRY_RUN"

printf '=== reporter:severity:* ===\n'
while IFS= read -r sev; do
  [ -z "$sev" ] && continue
  ensure_label "reporter:severity:${sev}" "5-axis severity (error-reporter plugin)" "5319E7"
done <<EOF
$SEVERITIES
EOF

printf '\n=== reporter:phase:* ===\n'
while IFS= read -r ph; do
  [ -z "$ph" ] && continue
  ensure_label "reporter:phase:${ph}" "5-axis phase (error-reporter plugin)" "5319E7"
done <<EOF
$PHASES
EOF

printf '\n---\n'
if [ "$DRY_RUN" = "true" ]; then
  printf 'dry-run: %d labels would be created\n' "$DRY_RUN_NOTED"
else
  printf 'created: %d, skipped (exists or err): %d\n' "$CREATED" "$SKIPPED"
fi
