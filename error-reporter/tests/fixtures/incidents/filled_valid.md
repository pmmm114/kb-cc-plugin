## Trigger

| Event | Hook | Phase | Agent | Severity | Commit |
|-------|------|-------|-------|----------|--------|
| `SubagentStop` | `pre-edit-guard.sh` | `verifying` | `editor` | `A2-guard-recovered` | `def67890` |

## Decisive Entry

```jsonl
{"ts":"t3","event":"PreToolUse","hook":"pre-edit-guard.sh","decision":"deny","phase":"verifying"}  ← decisive
```

## Counterfactual

The editor agent should have entered the `verifying` phase only after the
plan was explicitly marked complete. Instead it triggered `pre-edit-guard`
while still in `reviewing`, indicating a phase-transition race with the
orchestrator.

## Base Rates

<!-- TODO -->

## Related Meta-Eval

<!-- TODO -->

## Known Drift Match

<!-- TODO -->

## Reproduction

```bash
/kb-harness --from-incident 42 --target $HOME/.claude-harness
```
