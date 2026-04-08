---
name: eval
description: >
  Run a single eval scenario against the current Claude Code configuration.
  ONLY for configuration evaluation — NEVER invoke during product/code work.
  Use when testing a specific behavior after a config change.
---

# Single Eval Runner

Run one eval scenario to check a specific behavior.

For available commands and flags, see `~/.claude/agents/config-guardian.md` § "Benchmark Commands".

## Usage

```bash
# Run a specific eval (deterministic grading)
python3 ~/.claude/benchmarks/run.py --eval <eval-id>

# Run with LLM grading for behavioral assertions
python3 ~/.claude/benchmarks/run.py --eval <eval-id> --llm-grade

# Run with more trials for confidence
python3 ~/.claude/benchmarks/run.py --eval <eval-id> --trials 5
```

## Available Evals

Read `~/.claude/benchmarks/evals/` to list available eval definitions.
Each `.json` file is one eval with its prompt, assertions, and config.

## When to Use

- After modifying a specific rule, agent, or skill — run the eval that tests that behavior
- When debugging a regression — run the specific failing eval with more trials
- When creating a new eval — run it once to verify it works

## When NOT to Use

- During product/code development
- For skill **output quality** testing — use `/skill-creator` (Phase 1) instead
- This skill tests **system-level integration**, not individual skill correctness
