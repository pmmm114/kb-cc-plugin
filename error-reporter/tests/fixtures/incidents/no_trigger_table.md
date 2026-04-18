# Legacy issue body (pre-#24 format)

This body has no Trigger table — it predates the body restructure in PR #35.
incident-to-eval should still be able to handle it gracefully by extracting
whatever fields it can and producing a draft eval.

## Counterfactual

The reporter should have filed this with the current body schema. The
absence of the Trigger table means tag inference is limited, but the tool
should still scaffold an eval with an empty tags list and the raw body as
context.
