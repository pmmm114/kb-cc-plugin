# harness-engineering

Claude Code configuration management, benchmarking, and governance plugin.

## Components

| Type | Name | Description |
|------|------|-------------|
| Agent | config-planner | Analyzes config landscape, produces CRUD plans |
| Agent | config-editor | Executes approved plans in isolated worktree |
| Agent | config-guardian | Runs benchmarks, produces KEEP/REVERT recommendations |
| Skill | kb-cc-config | Config workflow entry point (`/kb-cc-config`) |
| Skill | benchmark | Full benchmark suite (`/benchmark`) |
| Skill | eval | Single eval runner (`/eval`) |
| Rule | config.md | Config evaluation constraints and harness engineering principles |

## Host Dependency

This plugin requires host hook scripts installed at `~/.claude/hooks/`:

- `config-worktree-guard.sh`
- `config-guardian-worktree-guard.sh`
- `config-agent-dispatch-guard.sh`
- `subagent-validate-config.sh`
- `hook-lib.sh` (and `hook-lib-core.sh`, `hook-lib-config.sh`)

These scripts manage a shared state machine (`/tmp/claude-session/*.json`) used by both code-domain and config-domain workflows. The plugin's `hooks.json` references them via `${CLAUDE_CONFIG_DIR}/hooks/`.

**Why not bundled?** Both domains share a unified FSM and state file. Duplicating `hook-lib-core.sh` would risk schema migration conflicts and version skew. See [pmmm114/kb-cc-plugin#4](https://github.com/pmmm114/kb-cc-plugin/issues/4) for the migration roadmap.

### Future: Phase 3.5

The planned decoupling involves:
1. Splitting `hook-lib-core.sh` into `hook-lib-state.sh` (shared) + domain-specific libs
2. Bundling config-domain hooks inside the plugin via `${CLAUDE_PLUGIN_ROOT}`
3. Eliminating the host dependency

## Install

```bash
claude plugin install harness-engineering@kb-cc-plugin
```

## Benchmark Runner

The `bin/` directory contains the benchmark infrastructure:

| Script | Purpose |
|--------|---------|
| `run.py` | Single-eval runner with parallel trials |
| `bench.py` | Unified CLI (eval + workflow subcommands) |
| `workflow_runner.py` | Multi-stage workflow eval runner |
| `lib.py` | Shared utilities (grading, metrics, workspace management) |

### Eval Definitions

Place eval JSON files in `bin/evals/` and workflow eval JSON files in `bin/workflow-evals/`. These directories are empty by default — populate them with your project-specific eval definitions.
