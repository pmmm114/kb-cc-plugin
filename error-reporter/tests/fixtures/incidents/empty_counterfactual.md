## Trigger

| Event | Hook | Phase | Agent | Severity | Commit |
|-------|------|-------|-------|----------|--------|
| `SubagentStop` | `pre-edit-guard.sh` | `verifying` | `editor` | `A2-guard-recovered` | `abc12345` |

## Decisive Entry

```jsonl
{"ts":"t3","event":"PreToolUse","hook":"pre-edit-guard.sh","decision":"deny","phase":"verifying"}
```

## Counterfactual

<!-- What SHOULD have happened — fill in manually to make this observation actionable -->

## Base Rates

<!-- TODO #24 follow-up: deny/total ratio -->

## Related Meta-Eval

<!-- TODO #24 follow-up: pointer -->

## Known Drift Match

<!-- TODO #24 follow-up: auto-grep -->

## Reproduction

```bash
/kb-harness --from-incident <this-issue-number> --target $HOME/.claude-harness
```
