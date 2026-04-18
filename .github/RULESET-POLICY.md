# Branch Ruleset Policy

This repository uses GitHub branch rulesets to enforce CI gating on protected
branches. This document records the policy so that future contributors know
how to add workflows without breaking the gate.

## Protected branches

- `main`
- `develop` (exact match — not `develop/**`)
- `base/**` (glob — for release-train branches)

## Required status checks

The ruleset requires ALL of the following to pass before merge:

| Context                              | Workflow                             | integration_id |
|--------------------------------------|--------------------------------------|----------------|
| `ShellCheck`                         | `.github/workflows/shellcheck.yml`   | `15368` (github-actions) |
| `error-reporter end-to-end smoke`    | `.github/workflows/tests.yml`        | `15368` (github-actions) |

`integration_id: 15368` pins the check to the GitHub Actions app, preventing
a third-party app from spoofing a check-run with a matching name.

## Other rules

- **Pull-request required**: `required_approving_review_count: 0` (solo
  maintainer; CI is the gate, not human review).
- **`allowed_merge_methods: ["squash"]`**: every merge is a squash commit.
  Preserves a linear history and keeps release-note generation simple.
- **`non_fast_forward: true`**: prevents force-pushes to protected branches.
- **`bypass_actors: []`**: no admin bypass — the maintainer follows the same
  gate as everyone else.

## Adding a new PR-triggered workflow

**Every new workflow that gates merges MUST be added to the ruleset's
`required_status_checks` list.** Otherwise GitHub does not know to wait
for it, and a PR can merge even if the new workflow is failing.

Procedure:

1. Add the workflow under `.github/workflows/<name>.yml`. Include `on: push`
   and `on: pull_request` WITHOUT `paths:` filters — the ruleset's
   `strict_required_status_checks_policy` expects checks to report on every
   PR, and `paths:` filters cause "Expected — Waiting for status to be
   reported" blocks.
2. Note the `name:` (or the job's `name:` if using matrix). That string is
   the `context` field the ruleset will match.
3. Update the ruleset via:
   ```bash
   gh api repos/pmmm114/kb-cc-plugin/rulesets/<RULESET_ID> --method PATCH \
     --input <new-required-status-checks.json>
   ```
   (or via the Repository → Rules UI on GitHub).
4. Land the PR that adds the workflow. Verify the new check appears on the
   next PR's merge-queue view.

## Workflows explicitly NOT in the gate

- `plugin-label.yml` — triggered by `issues` events, never `pull_request`.
  Adding it to `required_status_checks` would cause PRs to wait forever for
  a check-run that only fires on issue creation.

## Rollback

If the ruleset breaks merges and needs removal:

```bash
gh api repos/pmmm114/kb-cc-plugin/rulesets/<RULESET_ID> -X DELETE
```

Delete the ruleset first, then classic branch protection (if any). The
inventory of live protections can always be captured via:

```bash
gh api repos/pmmm114/kb-cc-plugin/branches/main/protection > classic.json
gh api repos/pmmm114/kb-cc-plugin/rulesets > rulesets.json
```
