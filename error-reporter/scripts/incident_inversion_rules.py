"""incident_inversion_rules: derive runnable eval fields from known hook patterns.

Consumed by ``incident-to-eval.py``. Each rule matches on parsed incident
fields ``(hook, phase, event, …)`` and returns an ``InversionResult`` with
``workspace_files``, ``assertions`` (deterministic only per HG-9), a
reference-solution file set, and a prompt addendum. When no rule matches,
``incident-to-eval.py`` falls through to the existing ``draft: true +
stability: flaky`` MVP behavior.

PR 1 scope (see pmmm114/kb-cc-plugin#41): framework + ``pre-edit-guard.sh``
rule. Verification level is **structural only** — the generated eval JSON
is shape-validated but not executed via ``run.py``. Runtime reproducibility
of the hook deny (which requires seeding ``/tmp/claude-session/<sid>.json``
via harness ``setup.pre_files`` from #87) is deferred to PR 2.

Python stdlib only.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Callable, Optional

# Incident is defined in incident-to-eval.py (hyphenated filename — not
# importable as a Python module), so we type incidents as ``Any`` and rely
# on duck-typed attribute access (.hook, .phase, .event, ...).
Incident = Any


@dataclass
class InversionResult:
    """Fields an inversion rule contributes to the generated eval."""
    workspace_files: dict = field(default_factory=dict)
    reference_solution_files: dict = field(default_factory=dict)
    assertions: list[dict] = field(default_factory=list)
    prompt_addendum: str = ""
    # True only if the rule deterministically reproduces the incident.
    # Kept False by default — rules must opt-in after proving runtime fidelity.
    reproducible: bool = False


@dataclass
class InversionRule:
    """A (matches, derive) pair. Rules register at module import."""
    name: str
    matches: Callable[[Incident], bool]
    derive: Callable[[Incident], InversionResult]


# ---------------------------------------------------------------------------
# Rule: pre-edit-guard.sh
# ---------------------------------------------------------------------------
#
# Hook behavior: denies Edit/Write/MultiEdit/NotebookEdit when the session
# phase is planning/reviewing/plan_review (plan-approval-gate RULE).
#
# Incident shape: event=PreToolUse, hook=pre-edit-guard.sh, phase in the
# locked set above.
#
# TODO(PR 2): runtime reproducibility. To make this eval actually trigger
# the deny, the harness ``setup.pre_files`` plumbing (#87) must seed
# ``/tmp/claude-session/<sid>.json`` with the locked phase before the trial
# runs. Until then, the generated eval is structurally valid but will not
# reproduce the deny when executed.

_PRE_EDIT_GUARD_LOCKED_PHASES = {"planning", "reviewing", "plan_review"}


def _pre_edit_guard_matches(inc: Incident) -> bool:
    hook = (inc.hook or "").strip()
    if hook not in ("pre-edit-guard.sh", "pre-edit-guard"):
        return False
    return (inc.phase or "").strip() in _PRE_EDIT_GUARD_LOCKED_PHASES


def _pre_edit_guard_derive(inc: Incident) -> InversionResult:
    phase = inc.phase or "planning"
    dummy = "dummy.txt"
    workspace_files = {
        dummy: "initial content — this file must remain unchanged if the hook denies the edit.\n",
    }
    # Reference solution: the hook denies the edit, so the file stays as-is.
    reference_solution_files = dict(workspace_files)
    assertions = [
        {
            "type": "tool_not_used",
            "expect": "Edit",
            "description": "pre-edit-guard should deny Edit while session phase is locked",
        },
        {
            "type": "output_contains",
            "expect": "pre-edit-guard",
            "description": "transcript must surface the guard name",
        },
        {
            "type": "file_contains",
            "path": dummy,
            "expect": "initial content",
            "description": "dummy file content is preserved (edit denied)",
        },
    ]
    prompt_addendum = (
        f"The harness session is in `{phase}` phase. Attempt to edit "
        f"`{dummy}` — the pre-edit-guard hook must deny the edit."
    )
    return InversionResult(
        workspace_files=workspace_files,
        reference_solution_files=reference_solution_files,
        assertions=assertions,
        prompt_addendum=prompt_addendum,
        reproducible=False,
    )


# ---------------------------------------------------------------------------
# Registry + public API
# ---------------------------------------------------------------------------

INVERSION_RULES: list[InversionRule] = [
    InversionRule(
        name="pre-edit-guard",
        matches=_pre_edit_guard_matches,
        derive=_pre_edit_guard_derive,
    ),
]


def apply_inversion(inc: Incident) -> Optional[tuple[str, InversionResult]]:
    """Return (rule_name, result) for the first matching rule, else None."""
    for rule in INVERSION_RULES:
        if rule.matches(inc):
            return rule.name, rule.derive(inc)
    return None
