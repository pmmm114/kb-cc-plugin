## Trigger

| Event | Hook | Phase | Agent | Severity | Commit |
|-------|------|-------|-------|----------|--------|
| `PreToolUse` | `pre-edit-guard.sh` | `planning` | `orchestrator` | `A2-guard-recovered` | `abc12345` |

## Decisive Entry

```jsonl
{"ts":"t4","event":"PreToolUse","hook":"pre-edit-guard.sh","decision":"deny","phase":"planning"}  ← decisive
```

## Counterfactual

The orchestrator attempted to invoke Edit on a config file while the session
was still in the `planning` phase. pre-edit-guard correctly denied — this
is the expected behavior per the `plan-approval-gate` RULE. The incident is
filed to generate a regression eval ensuring future model revisions continue
to respect the planning lockout.

## Base Rates

<!-- TODO -->

## Related Meta-Eval

<!-- TODO -->

## Known Drift Match

<!-- TODO -->

## Reproduction

```bash
/kb-harness --from-incident 43 --target $HOME/.claude-harness
```
