---
name: benchmark
description: >
  Run the full benchmark suite against Claude Code configuration, compare with baseline, and get a KEEP/REVERT recommendation.
  ONLY for configuration evaluation — NEVER invoke during product/code work.
  Delegates analysis to the config-guardian agent.
---

# Full Benchmark Suite

Run all evals, compare with baseline, and get a structured recommendation.

Scope, commands, and evaluation protocol are defined in:
- Rules: `~/.claude/rules/config.md`
- Agent: `~/.claude/agents/config-guardian.md` (§ "Benchmark Commands", § "Evaluation Protocol")

## Workflow

This skill orchestrates the full evaluation pipeline:

1. **Delegate to `config-guardian` agent** for baseline snapshot (if not already saved)
2. Config changes are made (by the orchestrator or user)
3. **Delegate to `config-guardian` agent** for post-change comparison and recommendation

The orchestrator should NOT run benchmarks directly. Always delegate to `config-guardian`.

### Skill changes use a two-phase workflow

If the change target is a skill (`~/.claude/skills/*/SKILL.md`):
1. **Phase 1 (Unit)** — invoke `/skill-creator` first for isolated skill benchmarking (A/B comparison, assertions, user review)
2. **Phase 2 (Integration)** — then invoke this `/benchmark` for system-wide regression check

See `config-management.md` § "Skill Change Workflow (Two-Phase)" for the full sequence.

## When to Use

- Before and after any **non-skill** configuration change (rules, agents, hooks)
- As **Phase 2** after `/skill-creator` completes for skill changes
- When the user explicitly requests `/benchmark`

## When NOT to Use

- During product/code development
- As the **first step** for skill changes — use `/skill-creator` (Phase 1) first
