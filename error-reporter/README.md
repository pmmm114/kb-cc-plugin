# error-reporter

## 1. Overview

`error-reporter` turns Claude Code hook events into structured GitHub issues and
local Markdown archives. The plugin runs as three hook handlers — `StopFailure`,
`Stop`, and `SubagentStop` — and is designed to never block the hook chain:
every path exits `0` within milliseconds, with any network I/O forked to
background.

Two operating modes:

- **Generic mode** (out-of-the-box) — `StopFailure` events are reported with
  a minimal body (hook input only). `Stop` and `SubagentStop` are silently
  ignored until a preset is configured.
- **Preset mode** (opt-in) — a preset file supplies the routine-deny filter,
  hook-to-domain mapping, and severity taxonomy that make `Stop`/`SubagentStop`
  reporting meaningful for your environment.

One preset ships with the plugin as a reference: `claude-harness`. See §5 for
details.

## 2. Installation

Install via Claude Code's plugin manager:

```bash
/plugin marketplace add pmmm114/kb-cc-plugin
/plugin install error-reporter@kb-cc-plugin
```

Prerequisites:

- `jq` (required — the plugin exits `0` silently without it)
- `gh` CLI with authentication (optional — when absent or unset, only local
  Markdown archives are written)

## 2.1 Setup

### Default behavior

`error-reporter` auto-detects the target GitHub repository from the CWD's git
remote — no `ERROR_REPORTER_REPO` export required when running inside a git
repo (EPIC #20 Design Principle 4). `ERROR_REPORTER_PRESET` is still opt-in
and must be set explicitly; there is no environment default.

### Option A — per-shell env vars

```bash
export ERROR_REPORTER_PRESET=claude-harness
# ERROR_REPORTER_REPO is optional — CWD git remote auto-detected
export ERROR_REPORTER_REPO=<owner/repo>   # force override only
```

### Option B — persistent config.json

```bash
mkdir -p "$CLAUDE_PLUGIN_DATA/error-reporter"
cat > "$CLAUDE_PLUGIN_DATA/error-reporter/config.json" <<EOF
{"preset": "claude-harness"}
EOF
```

`repo` is optional; omitting it enables CWD auto-detection at runtime.

### Verify

```bash
bash "$CLAUDE_PLUGIN_ROOT/error-reporter/scripts/report.sh" --self-test
# Expected lines (on success):
#   [ok]   preset: claude-harness (loaded)
#   [ok]   target repo: pmmm114/<your-repo> (resolved from cwd)
```

`--self-test` exits non-zero when preset is missing — useful for onboarding
checks and CI integration.

## 3. Generic mode

Without any configuration, `error-reporter` handles `StopFailure` events:

1. Captures the hook input JSON (session ID, error string, transcript path).
2. Classifies severity — in generic mode every StopFailure lands as
   `severity:unknown` (see below).
3. Writes a Markdown archive at `$CLAUDE_PLUGIN_DATA/reports/<sid>-<ts>-<pid>.md`.
4. If `ERROR_REPORTER_REPO` is set, files a GitHub issue on that repo;
   otherwise skips the `gh` call and writes a `status=skip
   reason=repo_not_configured` breadcrumb to `error-reporter.log`.
5. `exit 0`, always.

`Stop` and `SubagentStop` events are ignored in generic mode — they produce a
one-shot `error-reporter-notice-<epoch>.md` on first encounter (with a dedup
marker so the notice never repeats) and then exit.

> **Generic mode emits `severity:unknown` on StopFailure events since no
> severity taxonomy is loaded. Dashboards expecting a specific severity
> vocabulary should either load a preset or filter out `severity:unknown`.**

## 4. Presets

A preset is a JSON file at `$CLAUDE_PLUGIN_ROOT/presets/<name>.json` that
injects the environment-specific knowledge the generic core lacks.

### Activation

Opt-in only — no runtime auto-detection:

```bash
export ERROR_REPORTER_PRESET=<preset name>   # env var takes precedence
# OR write to $CLAUDE_PLUGIN_DATA/error-reporter/config.json:
# { "preset": "<name>", "repo": "<owner/repo>" }
```

Without activation the plugin stays in generic mode regardless of which preset
files exist on disk.

### Schema (v1)

```json
{
  "schema_version": 1,
  "name": "<preset-name>",
  "debug_log_path": "/some/path/{session_id}.jsonl",
  "state_file_path": "/some/path/{session_id}.json",
  "hook_extraction": {
    "pattern": "<jq-regex-with-named-group-h>"
  },
  "repo": "<owner/repo>",
  "routine_deny_rules": [
    { "hook": "<filename.sh>", "phases": ["<literal>", "<prefix>_*", "*"] }
  ],
  "domain_rules": [
    { "match": "*pattern*|*alt*", "domain": "reporter:domain:<name>" }
  ],
  "default_domain": "reporter:domain:hook",
  "severity_rules": {
    "StopFailure": { "timeout": "<label>", "default": "<label>" },
    "Stop": "<label>",
    "SubagentStop": "<label>"
  }
}
```

Field notes:

- `debug_log_path` and `state_file_path` MUST contain the literal
  `{session_id}` placeholder; the plugin substitutes at runtime.
- `hook_extraction.pattern` (optional) — jq-compatible regex with a named
  group `h` that captures the real firing hook name from the debug-log
  entry's `.reason` field. Defensive against upstream loggers that record
  a library-level wrapper in `.hook` instead of the firing script (e.g.,
  the `_HOOK_CALLER` drift in claude-harness — see upstream
  pmmm114/claude-harness-engineering#99). If unset, `.hook // ""` is used
  verbatim. In both modes the extracted value is normalized by stripping
  a trailing `.sh`, and `routine_deny_rules` hook names are compared in
  the same bare form — so preset rules can be written either as
  `pre-edit-guard` or `pre-edit-guard.sh` interchangeably.
- `repo` (optional) — last-resort fallback for target repo when env var,
  `config.json.repo`, and CWD git-remote detection all miss. Use for
  ephemeral CWDs (e.g., benchmark scratch dirs).
- `routine_deny_rules.phases` supports three forms: exact literal, `prefix_*`
  (matches any phase starting with `prefix_`), and `*` (matches any phase).
  An empty array skips the rule entirely.
- `domain_rules.match` uses shell `case` pipe-glob syntax — different dialect
  from `phases`, do not conflate.
- The filter generator hardcodes JSONL field names (`ts`, `decision`, `hook`,
  `phase`, `agent_id`, `event`, `reason`); see §8.

### Shipped presets

| Name            | Description                                            |
|-----------------|--------------------------------------------------------|
| `claude-harness`| Reference implementation targeting `claude-harness`    |

## 5. Preset: claude-harness

This preset makes `error-reporter` behave like the pre-3.1 code — it mirrors
the hardcoded `EXPECTED_DENY_FILTER`, `infer_domain`, and severity case arms
from v3.0 byte-for-byte. It assumes the JSONL debug log emitted by
[claude-harness](https://github.com/pmmm114/claude-harness)'s
`hook-lib-core.sh`.

### Routine deny filter

| Hook                           | Filtered phases                                                                |
|--------------------------------|--------------------------------------------------------------------------------|
| `pre-edit-guard.sh`            | planning, reviewing, plan_review, config_planning, config_plan_review, config_editing |
| `agent-dispatch-guard.sh`      | all (routing guard)                                                            |
| `pr-template-guard.sh`         | all (`/pr` skill routing)                                                      |
| `worktree-guard.sh`            | idle, config_* (first-edit redirect)                                           |
| `guardian-worktree-guard.sh`   | all (worktree entry enforcement)                                               |

### Domain inference

| Hook name matches                                                 | Assigned domain           |
|-------------------------------------------------------------------|---------------------------|
| `*config-worktree*`, `*config-agent*`, `*config-guardian*`        | `reporter:domain:hook`    |
| `*pre-edit*`, `*verify-before*`, `*pr-template*`, `*pr-review*`   | `reporter:domain:hook`    |
| `*delegation*`, `*subagent-validate*`, `*tdd-dispatch*`           | `reporter:domain:hook`    |
| `*session-recovery*`, `*state-recovery*`, `*compact*`, `*preflight*` | `reporter:domain:infra` |
| (no match)                                                        | `reporter:domain:hook`    |

### Severity

| Event          | Condition                         | Label               |
|----------------|-----------------------------------|---------------------|
| `StopFailure`  | `.error` contains `timeout`       | `A3-resource`       |
| `StopFailure`  | otherwise                         | `A1-coordination`   |
| `Stop`         | any                               | `A2-guard-recovered`|
| `SubagentStop` | any                               | `A2-guard-recovered`|

Labels follow the [observation-log taxonomy](https://github.com/pmmm114/claude-harness/issues/37).

## 6. Upgrade from 3.0.x

v3.1 makes `Stop`/`SubagentStop` reporting opt-in. To restore v3.0 behavior,
add these exports to your shell profile:

```bash
# ~/.bashrc or ~/.zshrc
export ERROR_REPORTER_PRESET=claude-harness
export ERROR_REPORTER_REPO=pmmm114/claude-harness   # or your own repo
```

Without these exports, `Stop`/`SubagentStop` are silently ignored and on first
encounter you get a one-shot `$CLAUDE_PLUGIN_DATA/reports/error-reporter-notice-<epoch>.md`
with upgrade instructions. `StopFailure` reporting is unaffected.

### Pre-upgrade checklist

1. Back up `$CLAUDE_PLUGIN_DATA` or `$HOME/.claude/reports/{logs,reports}/` if
   you have custom tooling that parses them (the layout is preserved but a
   backup is cheap insurance).
2. End any Claude Code sessions in progress — stale `/tmp/claude-report-*.reported`
   markers from v3.0 will be invisible to v3.1's new marker path, so a session
   mid-incident may produce one duplicate GitHub issue.
3. Confirm `gh auth status` is authenticated.

### Post-upgrade verification

```bash
bash $CLAUDE_PLUGIN_ROOT/error-reporter/scripts/report.sh --self-test
```

Expected lines (abridged):

```
[ok]   preset: claude-harness (loaded)
[ok]   target repo reachable: pmmm114/claude-harness   # or your configured repo
```

If either line differs, revisit the env exports above.

## 7. Local archive, self-test, troubleshooting

### Local archive

Every incident writes a Markdown body to `$CLAUDE_PLUGIN_DATA/reports/<sid>-<ts>-<pid>.md`
BEFORE attempting the `gh` call. If `gh` fails or the target repo is unreachable,
the local archive is still there. If `gh` succeeds, both exist (redundant by design).

Paths (all under `$CLAUDE_PLUGIN_DATA` or `$HOME/.claude/reports` fallback):

- `reports/` — local Markdown archives and opt-in notice
- `logs/error-reporter.log` — diagnostic ring-buffered log (1000 lines max,
  trims to 500 keeping first line)
- `markers/` — session dedup markers and `.v3.1-opt-in-notice.ack`
- `locks/` — per-session lockdirs for background-fork serialization

### Self-test

```bash
bash report.sh --self-test
```

Diagnoses dependency health, preset status, target repo reachability, and
recent activity. Has zero side effects (no issues created, no files written).

**Exit code (breaking change vs 3.0.x)**: since 3.1, `--self-test` exits
non-zero (`1`) when any critical config is missing — `CLAUDE_PLUGIN_ROOT`
unset, preset unconfigured, preset bad schema, or target repo unresolvable.
Previously all such conditions emitted `[WARN]` and exited `0`. This makes
the self-test usable as a CI / onboarding gate. Scripts that relied on
`bash report.sh --self-test && echo ok` should either configure the preset
or explicitly tolerate the exit via `|| true` where the WARN behavior is
intended.

### Diagnostic log format

`error-reporter.log` uses a single-line key=value format:

```
[<epoch>] status=ok         event=... sid=... phase=... agent=... domain=... commit=... local=...
[<epoch>] status=fail       event=... sid=... phase=... ... exit=<N> stderr=<quoted>
[<epoch>] status=skip       event=... sid=... reason=repo_not_configured local=...
[<epoch>] status=opt_in_notice event=... sid=...
[<epoch>] status=preset_bad_schema preset=<name> reason=<...>
[<epoch>] status=silent_skip     event=... sid=... reason=preset_not_loaded
[<epoch>] status=fail            event=... sid=... reason=repo_resolution_failed source=<none|...> hook_cwd=<...> local=<true|false>
```

Additional status semantics:

- `silent_skip` — emitted **per event** when `ERROR_REPORTER_PRESET` is unset.
  Surfaces repeated silent skips to on-call without blocking the hook chain.
  Coexists with the one-shot `opt_in_notice` (which fires only on the first
  event until the ack file is deleted).
- `repo_resolution_failed` — appears on `status=fail` rows when all four
  fallbacks (env `ERROR_REPORTER_REPO`, `config.json.repo`, hook-input `.cwd` →
  git remote, preset `.repo` field) yielded an empty result. Logged as
  `status=fail` (not `status=skip`) per Phase 0 P0-5 design so it does not
  get lost in routine skip noise. `source=none` indicates no fallback matched.

## 8. Known limitations

The filter generator hardcodes JSONL field names (`ts`, `decision`, `hook`,
`phase`, `agent_id`, `event`). Alternative log producers must conform to this
schema or extend the filter generator. Out of scope for v3.1. Preset
`schema_version: 1` is a forward-compatibility hook for future schema-aware
versions.

## 9. Coupling Surface

The error-reporter core has no runtime dependency on any specific log producer
or hook framework. Core reads:

- hook input JSON via stdin (Claude Code native fields)
- `$CLAUDE_PLUGIN_DATA` or `$HOME/.claude/reports` (Claude Code native layout)
- preset files via `$CLAUDE_PLUGIN_ROOT/presets/` (plugin-local)

Core does NOT know:

- Any specific hook name, phase name, or workflow state machine
- Any specific severity taxonomy (A1/A2/A3 or otherwise)
- Any specific GitHub organization, repo, or issue label scheme
- Any specific path convention beyond `$ER_BASE` (markers and locks live
  there; the sole exception is an edge-case `$TMPDIR` fallback when both
  `$CLAUDE_PLUGIN_DATA` and `$HOME` are unset)

Preset files inject all of the above. The `claude-harness` preset is the
reference implementation; third-party presets are welcomed and documented in §4.

Known limitation: the filter generator hardcodes JSONL field names (`ts`,
`decision`, `hook`, `phase`, `agent_id`, `event`). Alternative log producers
must conform to this schema. See §8.
