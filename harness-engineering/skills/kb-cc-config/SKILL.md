---
name: kb-cc-config
description: >
  Entry point for Claude Code configuration changes. Invoked via /kb-cc-config <description>.
  Creates an isolated git worktree, sets config_planning phase, and dispatches config-planner.
  This is the ONLY authorized way to start a config change workflow.
---

# Config Workflow Entry

The single entry point for all Claude Code configuration changes.

## When to Invoke

- User wants to modify agents, rules, skills, hooks, plugins, settings, or CLAUDE.md
- User explicitly says `/kb-cc-config`
- The orchestrator determines the request is a config change (not app config)

## When NOT to Invoke

- App/project configuration changes (`.env`, `tsconfig.json`, database config) — these are code tasks
- Questions about config (how hooks work, what agents exist) — answer directly
- Product/code development — use the code workflow

## Protocol

### Step 0: Create Skill Marker

Before any other operation, create a skill marker so the `config-worktree-guard`
hook recognizes this as a trusted /kb-cc-config bootstrap context and allows
the `git branch` / `git worktree add` / state-file operations that must happen
before the worktree exists.

Detect the session ID from the most-recently-modified state file (platform
limitation — `$CLAUDE_SESSION_ID` is not injected into Bash tool context):

```bash
mkdir -p /tmp/claude-skill-markers
STATE_FILE=$(ls -t /tmp/claude-session/*.json 2>/dev/null | head -1)
SID=$([ -n "$STATE_FILE" ] && basename "$STATE_FILE" .json || echo "default")
touch "/tmp/claude-skill-markers/${SID}.kb-cc-config.active"
```

### Step 1: Phase Gate

Check the current workflow phase. If not `idle`, block with:

> "Complete or reset the current workflow first. Current phase: `<phase>`"

Do NOT proceed if a workflow is already active.

### Step 2: Validate Input

If no description was provided with the invocation, ask the user:

> "What config change do you want to make?"

Wait for a response before proceeding.

### Step 3: Create Worktree

Immediately create an isolated worktree for this config change:

```bash
# Ensure main is up to date
git fetch origin main

# Create branch and worktree
git branch config/<descriptive-name> origin/main
git worktree add /tmp/claude-config-<name> config/<descriptive-name>
```

- Branch naming: `config/<descriptive-name>` derived from the user's description
- Worktree location: `/tmp/claude-config-<name>`

### Step 4: Set Phase

Transition the phase to `config_planning` with `flow_type=config`.

After the phase is set, remove the skill marker — the bootstrap window is closed
and the worktree now exists for all subsequent config edits:

```bash
rm -f "/tmp/claude-skill-markers/${SID}.kb-cc-config.active"
```

### Step 5: Dispatch config-planner

Dispatch the `config-planner` agent inside the worktree with the user's description.

Pass the worktree path as the working directory. If an intake summary exists at the handoff directory, include the path in the prompt.

### Parallel Sub-Worktree Strategy

When `config-planner` produces parallel tasks in `tasks.json`:

1. Each parallel task gets a sub-worktree branched from the config branch
2. Sub-worktrees only modify domain-specific files (NOT CLAUDE.md)
3. After all sub-worktrees merge back, CLAUDE.md is synced once at the end
4. If tasks have overlapping file scopes, fall back to sequential execution

### Phase Lifecycle

This skill manages the following phase transitions:

```
idle -> config_planning -> config_plan_review -> config_editing -> config_verifying -> idle
```

The skill initiates `idle -> config_planning`. Subsequent transitions are handled by hooks (`subagent-validate.sh`) and the orchestrator.

## Hard Constraints

- Phase MUST be `idle` before starting — no exceptions
- Worktree MUST be created before dispatching any agent
- All config editing happens inside the worktree, never in the main tree
- CLAUDE.md sync is always the last step (after all domain edits merge)
