# Config Rules

Constraints for Claude Code configuration evaluation and authoring.
Loaded exclusively by config-domain agents (config-planner, config-editor, config-guardian).

> Every rule here encodes an assumption about what the model cannot reliably do on its own.
> Re-validate each rule when the underlying model is updated — remove scaffolding that is no longer needed.

---

## 1. Scope & Isolation

<!-- HARD-GATE retained: domain crossover (using code agents for config, or config tools for code) requires semantic judgment that no deterministic hook can express. The false-positive cost of blocking all `run.py` invocations unconditionally is too high. -->
<HARD-GATE>
The benchmarking system (`config-guardian` agent, `/eval` skill, `/benchmark` skill, `benchmarks/run.py`) exists EXCLUSIVELY for evaluating Claude Code configuration.

NEVER invoke any of these during product/code work:
- Do NOT run `benchmarks/run.py` when the user is developing application code
- Do NOT delegate to `config-guardian` for code reviews, feature work, or bug fixes
- Do NOT trigger `/eval` or `/benchmark` for changes to project source files

Conversely, product/code agents must NEVER be used for configuration evaluation:
- Do NOT delegate config evaluation to `planner` or `tdd-implementer` agents
- Do NOT use `core.md` rules for config changes

The two domains are completely separate. No crossover.
</HARD-GATE>

### Configuration File Scope

Configuration files are any files under:
- `~/.claude/rules/*.md`
- `~/.claude/agents/*.md`
- `~/.claude/skills/*/SKILL.md`
- `~/.claude/plugins/` (installed plugins — agents, skills, MCP bundled via plugin system)
- `~/.claude/settings.json`, `~/.claude/settings.local.json`
- `~/.claude/CLAUDE.md`
- `~/.claude/benchmarks/evals/*.json`
- Project-level `.claude/` directories

### Worktree Isolation

<RULE name="config-worktree-isolation">
Each configuration change MUST be developed in its own git branch and worktree.
This prevents concurrent config changes from contaminating each other's benchmarks.

**One change = one branch = one worktree.**

A "change" is scoped to a single config domain:
- One agent (`agents/<name>.md`)
- One rule (`rules/<name>.md`)
- One skill (`skills/<name>/SKILL.md`)
- One hook (`hooks/<name>.sh` + `settings.json` hook entry)
- One plugin configuration change

#### Enforcement by the orchestrator

The orchestrator MUST use git worktree isolation for every config change.

- Branch naming: `config/<domain>-<name>` (e.g., `config/agent-planner`, `config/rule-workflow`)
- Worktree location: `/tmp/claude-config-<name>` (disposable, outside main tree)
- When spawning subagents: use `isolation: "worktree"` — this is the **only** permitted way to make config edits
- All edits happen exclusively in the worktree. The main working tree stays clean.
- After KEEP recommendation: push branch, create PR via `gh pr create`, merge via `gh pr merge`, clean up worktree
- After REVERT recommendation: close via `gh pr close`, clean up worktree

#### Parallel config work

When multiple config changes are in flight simultaneously:
- Each change gets its own branch AND its own worktree — no exceptions
- Do NOT batch unrelated config changes in the same branch
- Each worktree runs its own baseline -> change -> compare cycle independently

#### What config-guardian checks

Before running benchmarks, config-guardian MUST verify:
- `git status` shows only files related to the current config change
- No uncommitted changes outside the intended scope
- If violations are found: **refuse to benchmark** and report which files are out of scope

**Rationale**: A benchmark result is only meaningful when it measures exactly one variable.
Mixed changes produce composite scores that cannot guide KEEP/REVERT decisions.

Enforced by hooks: `config-worktree-guard.sh` (PreToolUse Edit/Write/Bash — blocks config file edits outside worktree), `config-guardian-worktree-guard.sh` (PreToolUse Agent — enforces worktree isolation for config-guardian dispatch), `config-agent-dispatch-guard.sh` (PreToolUse Agent — blocks config-planner/config-editor dispatch without `/kb-cc-config`).
</RULE>

---

## 2. Evaluation Workflow

<!-- HARD-GATE retained: orchestrator workflow sequencing (baseline → change → benchmark → decide) cannot be enforced by hooks — it requires awareness of the full config lifecycle, not a single tool call. -->
<HARD-GATE>
When the user requests a configuration change, the orchestrator MUST follow this sequence:

0. Set up worktree (see Worktree Isolation above)
1. Ensure baseline — check if `baseline.json` exists and its `git_commit` matches the parent branch HEAD.
   If fresh -> reuse. If stale or missing -> delegate to `config-guardian` to generate via `bench.py all --save-baseline --llm-grade`
2. Make the change in the worktree — orchestrator modifies configuration files
3. Delegate to `config-guardian` in the worktree — follows staged execution (Dev -> Mid -> Final)
4. Present recommendation to the user — KEEP / KEEP WITH CAVEAT / REVERT
5. User decides:
   - **KEEP** -> push branch, create PR via `gh pr create`, merge via `gh pr merge`, clean up worktree
   - **REVERT** -> clean up worktree and delete branch
   - **REFINE** -> repeat from step 2 (Dev stage only for fast iteration)

Do NOT skip the Final stage. Do NOT self-assess change quality.

**Exception**: Skill changes follow the three-phase workflow in Section 3 instead.
</HARD-GATE>

### Staged Execution

<RULE name="staged-benchmark-execution">
Config-guardian MUST use staged execution. This is the default protocol, not an optional optimization.

**Stop at the earliest stage that reveals a problem.** Only proceed to the next stage if the current one passes.

| Stage | Command | Scope | Estimated tokens | Purpose |
|-------|---------|-------|-----------------|---------|
| Dev | `run.py --tag <domain> --trials 1` | Domain-scoped | ~0.1-0.3M | Catch "completely broken" changes |
| Mid | `run.py --tag <domain> --trials 2 --llm-grade` | Domain-scoped | ~0.3-0.6M | Stability + LLM assertions |
| Final | `bench.py all --compare --llm-grade` | Full suite | ~2-3M | Cross-domain regression check |

#### Stage progression rules

- **Dev fails** -> report failure, orchestrator fixes, re-run Dev (do NOT proceed to Mid)
- **Mid fails** -> report instability, orchestrator investigates (do NOT proceed to Final)
- **Final** -> produces KEEP/REVERT recommendation. This stage is **mandatory** for all final decisions
- During REFINE loops (step 5), only Dev stage is needed for fast iteration until the fix stabilizes

#### Domain tag mapping

Determine `<domain>` from the changed files:

| Changed file pattern | Tag to use |
|---------------------|------------|
| `rules/core.md` | `rule:core` |
| `rules/config.md` | `rule:config` |
| `rules/agent-handoff.md` | `rule:agent-handoff` |
| `rules/ui-test-layers.md` | `rule:ui-test-layers` |
| `agents/planner.md` | `agent:planner` |
| `agents/tdd-implementer.md` | `agent:tdd-implementer` |
| `skills/<name>/SKILL.md` | `skill:<name>` |

#### Baseline management

- Baselines include a `git_commit` field recording the commit at save time
- A baseline is **fresh** if its `git_commit` matches the current parent branch HEAD
- Fresh baselines are reused — no need to re-run the full suite
- `--compare` with hash-based caching automatically skips unchanged evals
- Only the Final stage result should be used for `--save-baseline`

#### Model routing

Evals specify a `model` field in their config to control which Claude model runs them:
- `haiku` — trigger-check evals (e.g., skill invocation detection). ~1/12 cost of default
- `sonnet` — code generation and rule compliance evals. ~1/3 cost of default
- (no model field) — uses the default model for complex reasoning evals

This is applied automatically by the benchmark runner. No manual intervention needed.
</RULE>

---

## 3. Skill Change Workflow

Skill changes use a 3-layer evaluation strategy matching the benchmark architecture:
- Phase 1: Unit (skill-creator) -> skill-specific quality
- Phase 2: Skill-level (run_skill_bench.py) -> trigger accuracy + output quality
- Phase 3: Integration (config-guardian) -> system-wide regression check

<!-- HARD-GATE retained: the 3-phase skill workflow involves multi-step sequencing across skill-creator, run_skill_bench.py, and config-guardian. No hook covers this orchestration path — a hook would only see individual tool calls, not the full 3-phase arc. -->
<HARD-GATE>
When creating or modifying a skill (`~/.claude/skills/*/SKILL.md`), the orchestrator MUST follow all three phases in order.

### Phase 1: Unit — skill-creator benchmarking

Validates the skill in isolation. Invoke `/skill-creator` and follow its evaluation loop:

1. Define test prompts (2-3 realistic user queries the skill should handle)
2. Run with-skill vs without-skill (new skill) or new vs old (existing skill) in parallel
3. Grade with assertions + user qualitative review via the eval viewer
4. Iterate until the user confirms the skill is satisfactory

**Exit criteria**: User explicitly approves the skill quality.
If the user says the skill is not ready, do NOT proceed to Phase 2.

### Phase 2: Skill-level — trigger accuracy + output quality

Validates the skill triggers correctly and produces quality output:

1. If the skill is high-ROI (auto-trigger or complex output), a ground truth fixture MUST exist at `~/.claude/benchmarks/skill-bench/ground-truth/<skill-name>.json`
2. If no fixture exists, create one with positive cases (should trigger), negative cases (should not trigger), and quality checks (keyword-based)
3. Run `python3 ~/.claude/benchmarks/skill-bench/run_skill_bench.py --skill <name>`
4. Verify: precision >= 80%, recall >= 80%, composite >= 70%

**Exit criteria**: Skill meets trigger accuracy thresholds.
If false positives or false negatives are detected, fix the skill description or logic before Phase 3.

**When to skip Phase 2:**
- Low-ROI skills (static reference, simple workflow) — user explicitly says "skip skill bench"
- Metadata-only changes (frontmatter fields with no behavioral impact)

### Phase 3: Integration — config-guardian benchmarking

Validates the skill does not regress the overall system:

1. Delegate to `config-guardian` — saves baseline via `run.py --save-baseline --llm-grade`
2. Apply the skill change (already done in Phase 1)
3. Delegate to `config-guardian` again — runs `run.py --compare --llm-grade`
4. Present recommendation — KEEP / KEEP WITH CAVEAT / REVERT
5. User decides — if REVERT, roll back the skill change

### When to skip Phase 1

Phase 1 may be skipped ONLY when:
- The change is metadata-only (description wording, frontmatter fields) with no behavioral impact
- The user explicitly requests skipping ("just run the integration check")
</HARD-GATE>

---

## 4. Eval Standards

### Eval Coverage

There are two distinct eval layers. Each serves a different purpose — do not conflate them.

| Layer | Tool | Location | What it tests |
|-------|------|----------|---------------|
| **Unit** | skill-creator | `<skill>-workspace/` | Does this skill produce correct outputs? (A/B comparison, assertions, qualitative review) |
| **Integration** | config-guardian | `~/.claude/benchmarks/evals/` | Does this change regress system-wide behavior? (pass@1, pass^k, token efficiency) |

<RULE name="no-config-without-eval">
When adding or modifying a configuration:

**For skills** (`~/.claude/skills/*/SKILL.md`):
1. Phase 1 (skill-creator) satisfies unit-level eval coverage — test prompts, assertions, and user review
2. `benchmarks/evals/` requires an integration eval focused on **triggering accuracy and system interaction**, not skill output quality (that is Phase 1's job)
3. If no integration eval exists, create one before Phase 2

**For agents and rules** (`~/.claude/agents/*.md`, `~/.claude/rules/*.md`):
1. Check `~/.claude/benchmarks/evals/` for a corresponding eval
2. If none exists, create one before considering the change complete
3. The eval must have at least one deterministic assertion and one LLM assertion
4. Run the new eval to verify it works before saving as baseline

A configuration without a corresponding eval is incomplete.
</RULE>

### Eval Integrity

<!-- HARD-GATE retained: determining whether an eval modification inflates scores requires comparing old vs new assertions and reference solutions — a judgment call no deterministic hook can make reliably. -->
<HARD-GATE>
Eval modifications follow strict rules to prevent score inflation:

**When eval input/assertions MAY be modified:**
- pass@1 = 0% across 3+ trials (0% pass@100 rule — eval is likely broken, not the agent)
- Reference solution fails assertions (assertion is provably wrong)
- Runner infrastructure bug (eval never executes properly)

**When eval input/assertions MUST NOT be modified:**
- pass@1 > 0% but < 100% (agent inconsistency — fix the config/rules, not the eval)
- To make the agent's alternative approach pass (that's teaching to the test)
- To relax assertions because they're "too strict" (strictness is the point)

**Procedure for permitted modifications:**
1. Document the specific failure that justifies the change
2. Verify the reference solution passes all assertions BEFORE and AFTER
3. Run `python3 run.py --verify-refs` to confirm
4. The change must not lower the bar — only fix broken grading

Modifying eval criteria to inflate scores is the eval equivalent of overfitting.
</HARD-GATE>

### Reference Solutions

<RULE name="reference-solution-required">
Every eval MUST include a `reference_solution` field containing:
- `description`: What the correct outcome looks like
- `files`: The expected file state after a correct execution

The reference solution serves as the ground truth:
- `run.py` verifies it against all deterministic assertions before every benchmark run
- If the reference solution fails, the benchmark is blocked until fixed
- When modifying assertions, the reference solution must still pass — this prevents silent breakage

Run `python3 run.py --verify-refs` to validate without running trials.
</RULE>

### Assertion Type Selection

<RULE name="deterministic-over-llm">
LLM assertions are for judgments that cannot be expressed programmatically:
- Output quality, relevance, coherence -> LLM appropriate
- Tool call ordering, existence, count -> deterministic required
- File content pattern matching -> deterministic required

When a high-variance eval (pass^k < 0.5) has LLM assertions as the primary failure source,
recommend converting to deterministic assertions.
</RULE>

### Pattern Coverage

<RULE name="pattern-robustness">
`file_contains` patterns must cover the majority of valid implementations:
- List 3+ ways a developer might implement the same intent
- Test the pattern against each variant mentally before committing
- If the pattern is fragile (only matches one style), prefer a functional assertion
  (run the code and check behavior) over regex matching

Example — checking "email contains @":
  Bad:  `includes\('@'\)`  (misses match, test, indexOf)
  Good: `@.*email|email.*@|includes.*@|indexOf.*@|test.*@|match.*@`
  Best: Run `node -e "..."` to call the function and check it throws
</RULE>

### Variance Diagnosis

<RULE name="variance-classification">
When pass^k < 0.5 for any eval, classify the root cause:

1. **Agent non-determinism** — the eval correctly detects inconsistent agent behavior.
   Action: no eval change needed. Report as agent reliability issue.

2. **Eval design flaw** — assertion is too narrow, LLM grader is unreliable, or pattern misses valid implementations.
   Action: recommend specific assertion/pattern changes.

3. **Infrastructure issue** — workspace deletion, grader crash, timeout.
   Action: recommend run.py or environment fix.

Always report the classification. Do NOT attribute all variance to the agent
when eval design or infrastructure could be the cause.
</RULE>

### Eval Completeness

<RULE name="eval-input-sufficiency">
Each eval's workspace must provide enough context for the agent to succeed:
- If the task mentions tests, include a test file and package.json with test runner
- If the task requires reading code, include realistic code (not empty stubs)
- The prompt must be unambiguous about what "done" looks like

If an eval consistently fails across config changes, check the eval itself first.
</RULE>

---

## 5. Harness Engineering

Principles for writing effective Claude Code configuration (skills, agents, rules, hooks).
Derived from Anthropic's "Harness design for long-running application development" (2026.03).

### Self-Assessment Bias

Claude tends to overrate its own output and rationalize problems as minor.
Configuration that relies on Claude's self-judgment alone will have blind spots.

<RULE name="external-verification-over-self-review">
When designing configuration (skills, agents, hooks):
- Prefer deterministic verification (hooks, scripts, assertions) over instructions that say "review your work"
- If a skill instructs Claude to "check quality", pair it with a concrete checklist or a verification script
- Agent workflows should include explicit verification steps (Read modified files, run tests) — not just "confirm correctness"
- Recognize that "verify before done" instructions degrade under context pressure; hooks enforce reliably
</RULE>

### Gradable Quality Criteria

Vague instructions like "write good code" or "produce high-quality output" have no effect.
Quality criteria must be specific, verifiable, and weighted toward areas where the model is weak.

<RULE name="gradable-criteria">
When writing skill or agent instructions:
- Define completion criteria as observable behaviors, not subjective qualities
- Bad: "Ensure the output is clean and professional"
- Good: "Output must pass `npm run lint` with zero warnings and include tests for all new functions"
- Weight criteria toward known weak areas (design coherence, edge case handling) over areas the model handles well (syntax correctness, basic functionality)
- For eval assertions: every criterion must be checkable by a script or an independent LLM grader — if a human is the only way to verify it, it is not a criterion, it is a hope
</RULE>

### AI Slop Prevention

Without explicit constraints, Claude produces safe, predictable, but generic output.
Configuration files are especially susceptible: boilerplate instructions, redundant directives, and cargo-culted structure.

<RULE name="no-slop">
Applies to skill/agent prompt instructions and eval definitions, not to rule files themselves (which use MUST/NEVER as semantic enforcement markers tied to HARD-GATE/RULE tags).

When writing or reviewing configuration content:
- Remove instructions that restate what the model already does by default
- Replace heavy-handed directives with explanations of *why* — the model responds better to reasoning than to shouting
- Avoid templated structure for its own sake — if a section adds no information, delete it
- Watch for these config-specific slop patterns:
  - Skills with 10+ steps where 3 would suffice
  - Agent definitions that list every possible edge case instead of explaining the core task
  - Eval assertions that test obvious things (file exists) while missing meaningful things (file content is correct)
</RULE>

### Specify Deliverables, Leave Implementation Open

Over-specifying implementation details in configuration causes brittle behavior.
Tell the model *what* to achieve, not *how* to achieve it step-by-step.

<RULE name="what-not-how">
When writing skills and agent instructions:
- Define the **output shape** (what files to produce, what format, what the user sees) concretely
- Leave the **implementation path** flexible — don't prescribe which tools to call in which order unless ordering genuinely matters
- Specify **completion criteria** (Definition of Done) for each deliverable
- Bad: "First run `git diff`, then run `git log`, then extract the ticket number using regex `[A-Z]+-\d+`"
- Good: "Determine all ticket references from the branch name and commit history"
- Exception: when a specific sequence is required for correctness (e.g., "stage files before committing"), prescribe it
</RULE>

### Context Resilience

Configuration that drives long-running workflows must account for context window degradation.
As context fills, coherence drops and the model tends to rush toward completion.

<RULE name="context-resilience">
When designing multi-step workflows (agents, skills with iteration loops):
- Build in explicit handoff points — structured artifacts that capture state for resumption
- Prefer multiple focused agent invocations over one monolithic session
- Include compaction-safe anchors: if a skill's instructions are critical, register them via SessionStart hooks so they survive compaction
- Do not rely on the model "remembering" early instructions after 200k+ tokens of context — re-inject or reference explicitly
</RULE>

### Rule Hygiene

<RULE name="rule-hygiene">
- Every rule encodes a model limitation assumption — when the model improves, the rule may become dead weight
- Prefer fewer, well-explained rules over many shallow ones — each rule consumes context tokens
- If a rule requires more than 5 lines to explain, it may be doing too much — split or simplify
- Test rules via evals: a rule without a corresponding eval is an opinion, not a constraint
- When removing a rule, do not just delete it — replace it with a higher-level rule that addresses the new frontier of model limitations
</RULE>

---

## 6. Docs Reference

Claude's training data may not include the latest Claude Code features.
Fetching the relevant docs page before implementation ensures all available
options are considered — not just the ones the model already knows about.

The full documentation index is available at:
```
https://code.claude.com/docs/llms.txt
```

When unsure which page to consult, fetch the index first.

<RULE name="consult-docs-before-implementing">
Before writing or evaluating any configuration change, fetch and read the
relevant official documentation page(s) via WebFetch. This is not optional —
the docs are the source of truth for available features and correct usage.

Use this mapping to determine which page(s) to fetch:

| Config domain | Docs URL(s) | What to look for |
|---------------|-------------|------------------|
| **Hooks** | `https://code.claude.com/docs/en/hooks-guide.md` | All hook types (command, prompt, agent, http), event list, matcher patterns |
| | `https://code.claude.com/docs/en/hooks.md` | Full event schemas, JSON input/output, decision control per event |
| **Skills** | `https://code.claude.com/docs/en/skills.md` | Frontmatter fields, progressive disclosure, bundled resources, context modes |
| **Agents** | `https://code.claude.com/docs/en/sub-agents.md` | Agent definition format, tool grants, model selection, isolation modes |
| **Settings** | `https://code.claude.com/docs/en/settings.md` | Settings hierarchy, available fields, merge behavior |
| **Permissions** | `https://code.claude.com/docs/en/permissions.md` | Permission rules, allowlist format, tool-specific permissions |
| **Memory / CLAUDE.md** | `https://code.claude.com/docs/en/memory.md` | CLAUDE.md format, rules directory, loading behavior |
| **Plugins** | `https://code.claude.com/docs/en/plugins.md` | Plugin structure, hooks.json, marketplace publishing |
| | `https://code.claude.com/docs/en/plugins-reference.md` | Component reference, persistent data, environment variables |
| **MCP** | `https://code.claude.com/docs/en/mcp.md` | Server configuration, tool naming, context cost |
| **Best practices** | `https://code.claude.com/docs/en/best-practices.md` | Official recommendations for effective Claude Code usage |

### How to apply

1. **Identify the domain** of the config change (hooks, skills, agents, etc.)
2. **Fetch the relevant page(s)** listed above using WebFetch
3. **Extract available options** — enumerate all types, modes, or patterns the docs describe
4. **Select the best fit** — choose the option that matches the requirement, not the most familiar one
5. **Cite the docs** in the implementation rationale — "Using prompt-based hook per docs: judgment-based decisions should use type: prompt"

### When to fetch

<!-- HARD-GATE retained: detecting whether WebFetch was called before a config implementation requires understanding the semantic intent of the session, not just tool call presence. A hook cannot distinguish "already fetched this session" from "never fetched". -->
<HARD-GATE>
WebFetch is REQUIRED (not optional) when:
- Creating new configuration (new hook, skill, agent, plugin)
- Evaluating a config change that introduces a new pattern
- The agent is unsure which options exist for a config domain

Do NOT substitute WebFetch with local file reading. Local rules files describe
*how to use* the docs — they are not the docs themselves. The official docs at
code.claude.com contain the latest available features and correct usage patterns
that may not be in the agent's training data.
</HARD-GATE>

**Skip** WebFetch only when:
- The change is metadata-only (description wording, frontmatter reorder) with no behavioral impact
- The relevant docs were already fetched in the same session and no domain change occurred
</RULE>

### Hook Type Decision Framework

After fetching hooks docs, apply this framework:

| Requirement | Recommended hook type | Why |
|-------------|----------------------|-----|
| Deterministic check (regex, path match, exit code) | `command` | Fast, predictable, no LLM cost |
| Judgment-based decision (code quality, completeness) | `prompt` | Single-turn LLM eval, lightweight |
| Decision requiring file inspection or tool use | `agent` | Multi-turn, can read files and run commands |
| External service integration (logging, audit, CI) | `http` | No shell dependency, works in remote environments |

Without consulting docs, `command` is the default because it is the most familiar.
The docs ensure all four types are considered.

---

## 7. References

### Reference Repositories

| Priority | Repository | Notes |
|----------|-----------|-------|
| 1 | [Anthropic eval guidance](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents) | Official |
| 2 | [Claude Code best practices](https://docs.anthropic.com/en/docs/claude-code/best-practices) | Official |
| 3 | [oh-my-claudecode](https://github.com/Yeachan-Heo/oh-my-claudecode) | Community |
| 4 | [superpowers](https://github.com/obra/superpowers) | Community |
| 5 | [codingbuddy](https://github.com/JeremyDev87/codingbuddy) | Community |

### Harness Engineering

- [Harness design for long-running application development](https://www.anthropic.com/engineering/harness-design-long-running-apps) (Anthropic, 2026.03)
- [Building Effective Agents](https://www.anthropic.com/research/building-effective-agents)
- [Effective context engineering for AI agents](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)

### Documentation

- [Claude Code documentation index](https://code.claude.com/docs/llms.txt)
- [Hooks guide](https://code.claude.com/docs/en/hooks-guide.md)
- [Hooks reference](https://code.claude.com/docs/en/hooks.md)
- [Skills](https://code.claude.com/docs/en/skills.md)
- [Subagents](https://code.claude.com/docs/en/sub-agents.md)
- [Best practices](https://code.claude.com/docs/en/best-practices.md)

---

## 8. Hook Authoring

<RULE name="no-raw-exit-trap">
Hook scripts that source `hook-lib.sh` MUST NOT use `trap ... EXIT` directly.
The shared library registers an Exit Handler Registry via `_run_exit_handlers`.
Raw `trap ... EXIT` overwrites this registry, breaking debug logging and any other registered handlers.

Instead, use:
```bash
register_exit_handler my_cleanup_function
```

This chains your handler alongside existing ones (debug logger, future cleanup handlers).
</RULE>
