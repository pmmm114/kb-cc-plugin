#!/usr/bin/env python3
"""incident-to-eval: scaffold a meta-eval JSON from an auto-filed incident.

Closes the incident → meta-eval gap (<RULE name="no-config-without-eval">).
Today every incident is human-triaged into a manual eval; this script
auto-scaffolds a meta-eval JSON from the incident body so triage can
focus on the `reference_solution.files` rather than boilerplate.

Input: one of --issue <gh-url> | --file <path> | --stdin
Output: benchmarks/meta-evals/incident-<sid8>.json on stdout unless --out is given

Refuse-to-generate (exit 2): Counterfactual section is empty placeholder.
This is a deterministic check on the body — does NOT violate HG-9 since
no eval is created at all, no scoring is affected.

Draft fallback: when reference_solution.files cannot be derived from the
body, emit the eval with `stability: flaky` + `draft: true` so a human
must gate it before it contributes to scoring.

Python stdlib only (no third-party deps).
"""
from __future__ import annotations
import argparse
import json
import os
import re
import sys
import urllib.request
import urllib.error
from dataclasses import dataclass, field
from typing import Optional

# Sibling module — added to sys.path below so it resolves regardless of cwd.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import incident_inversion_rules  # noqa: E402


# ---------------------------------------------------------------------------
# Body parsing
# ---------------------------------------------------------------------------

COUNTERFACTUAL_PLACEHOLDER_PATTERN = re.compile(
    r"<!--\s*What SHOULD have happened[^>]*-->",
    re.IGNORECASE,
)

TRIGGER_ROW_PATTERN = re.compile(
    r"^\|\s*`(?P<event>[^`]*)`\s*\|"
    r"\s*`(?P<hook>[^`]*)`\s*\|"
    r"\s*`(?P<phase>[^`]*)`\s*\|"
    r"\s*`(?P<agent>[^`]*)`\s*\|"
    r"\s*`(?P<severity>[^`]*)`\s*\|"
    r"\s*`(?P<commit>[^`]*)`\s*\|",
    re.MULTILINE,
)

SECTION_PATTERN = re.compile(r"^##\s+(.+?)\s*$", re.MULTILINE)


@dataclass
class Incident:
    """Parsed fields from the issue body. Missing fields → empty strings."""
    event: str = ""
    hook: str = ""
    phase: str = ""
    agent: str = ""
    severity: str = ""
    commit: str = ""
    counterfactual_filled: bool = False
    sections: list[str] = field(default_factory=list)
    raw_body: str = ""


def parse_body(body: str) -> Incident:
    """Extract structured fields from the issue body."""
    inc = Incident(raw_body=body)

    # Trigger table row
    m = TRIGGER_ROW_PATTERN.search(body)
    if m:
        for name in ("event", "hook", "phase", "agent", "severity", "commit"):
            val = m.group(name)
            if val == "—":
                val = ""
            setattr(inc, name, val)

    # Section inventory
    inc.sections = [m.group(1) for m in SECTION_PATTERN.finditer(body)]

    # Counterfactual filled detection: look at the body chunk between
    # "## Counterfactual" and the next "##" header; if the only meaningful
    # content is the placeholder HTML comment, treat as empty.
    cf_match = re.search(
        r"##\s+Counterfactual\s*\n(.*?)(?=\n##\s+|\Z)",
        body,
        re.DOTALL,
    )
    if cf_match:
        cf_body = cf_match.group(1).strip()
        cf_body_no_placeholder = COUNTERFACTUAL_PLACEHOLDER_PATTERN.sub("", cf_body).strip()
        inc.counterfactual_filled = bool(cf_body_no_placeholder)

    return inc


# ---------------------------------------------------------------------------
# Input resolution
# ---------------------------------------------------------------------------

def read_input(args: argparse.Namespace) -> str:
    """Resolve --issue / --file / --stdin into the raw body text."""
    if args.issue:
        return fetch_issue_body(args.issue)
    if args.file:
        with open(args.file, "r", encoding="utf-8") as f:
            return f.read()
    if args.stdin:
        return sys.stdin.read()
    raise SystemExit("one of --issue <url> | --file <path> | --stdin is required")


def fetch_issue_body(url: str) -> str:
    """Fetch issue body via GitHub REST API.

    Accepts either https://github.com/<owner>/<repo>/issues/<n> or
    https://api.github.com/repos/<owner>/<repo>/issues/<n>.
    """
    m = re.match(r"https?://github\.com/([^/]+)/([^/]+)/issues/(\d+)", url)
    if m:
        api_url = (
            f"https://api.github.com/repos/{m.group(1)}/{m.group(2)}"
            f"/issues/{m.group(3)}"
        )
    elif url.startswith("https://api.github.com/"):
        api_url = url
    else:
        raise SystemExit(f"unrecognized issue URL shape: {url}")

    req = urllib.request.Request(
        api_url,
        headers={"Accept": "application/vnd.github+json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        raise SystemExit(f"github API error {e.code}: {e.reason}")
    except urllib.error.URLError as e:
        raise SystemExit(f"github API unreachable: {e.reason}")

    body = data.get("body")
    if body is None:
        raise SystemExit(f"issue has no body: {api_url}")
    return body


# ---------------------------------------------------------------------------
# Eval construction
# ---------------------------------------------------------------------------

def derive_tags(inc: Incident) -> list[str]:
    """Namespaced tags from the incident. Empty fields are skipped."""
    tags: list[str] = []
    if inc.hook:
        hook_stem = inc.hook[:-3] if inc.hook.endswith(".sh") else inc.hook
        tags.append(f"hook:{hook_stem}")
    if inc.phase:
        tags.append(f"phase:{inc.phase}")
    if inc.severity:
        tags.append(f"severity:{inc.severity}")
    if inc.agent:
        tags.append(f"agent:{inc.agent}")
    return tags


def derive_assertions(inc: Incident) -> list[dict]:
    """Deterministic assertions only (HG-9 — no score inflation).

    Emits:
    - tool_was_used / tool_not_used based on EVENT
    - output_contains for a narrow keyword signal
    """
    assertions: list[dict] = []
    if inc.hook:
        # The eval transcript MUST mention the hook name somewhere
        hook_stem = inc.hook[:-3] if inc.hook.endswith(".sh") else inc.hook
        assertions.append({
            "type": "output_contains",
            "expect": hook_stem,
            "description": f"transcript references `{inc.hook}`",
        })
    if inc.event:
        # The transcript SHOULD show the triggering event at least once
        assertions.append({
            "type": "output_contains",
            "expect": inc.event,
            "description": f"transcript mentions `{inc.event}` event",
        })
    return assertions


def build_eval(
    inc: Incident,
    issue_sid_hint: Optional[str],
    inversion_enabled: bool = True,
) -> tuple[dict, list[str]]:
    """Build the meta-eval JSON. Returns (eval_dict, warnings)."""
    warnings: list[str] = []

    sid8 = issue_sid_hint or extract_sid8(inc)
    eval_id = f"incident-{sid8}"

    tags = derive_tags(inc)
    assertions = derive_assertions(inc)

    # Default: MVP safety fallback — draft:true + empty workspace/reference.
    # An inversion rule (see incident_inversion_rules.py) can flip off draft
    # if it deterministically derives workspace_files + reference_solution.
    workspace_files: dict = {}
    reference_solution_files: dict = {}
    reference_solution_description = (
        "See the original incident issue body. Reviewer should fill "
        "in the minimum file state that satisfies the assertions "
        "above before removing `draft: true`."
    )
    prompt = _prompt(inc)
    draft = True

    inversion_hit: Optional[tuple[str, incident_inversion_rules.InversionResult]] = None
    if inversion_enabled:
        inversion_hit = incident_inversion_rules.apply_inversion(inc)

    if inversion_hit is not None:
        rule_name, result = inversion_hit
        workspace_files = dict(result.workspace_files)
        reference_solution_files = dict(result.reference_solution_files)
        # Merge rule-supplied assertions in front of the generic ones so
        # deterministic checks are the primary failure signal. Dedupe by
        # (type, expect, path) tuple — generic derive_assertions() often
        # re-emits the same hook-stem output_contains that rules already
        # supply, which would bloat the eval with redundant checks.
        merged = list(result.assertions) + assertions
        seen: set = set()
        assertions = []
        for a in merged:
            key = (a.get("type"), a.get("expect"), a.get("path"))
            if key in seen:
                continue
            seen.add(key)
            assertions.append(a)
        if result.prompt_addendum:
            prompt = prompt + "\n\n" + result.prompt_addendum
        reference_solution_description = (
            f"Auto-derived by inversion rule `{rule_name}`. "
            f"The file state above reproduces the post-deny workspace "
            f"(hook denies the edit → files remain unchanged)."
        )
        draft = False
        warnings.append(
            f"inversion rule `{rule_name}` matched — draft:false, "
            f"stability:flaky retained until ≥3 successful runs prove "
            f"runtime fidelity (tracked in #41 PR 2+)."
        )
    else:
        warnings.append(
            "draft:true + stability:flaky because no inversion rule "
            "matched. A human must fill reference_solution.files before "
            "this eval contributes to scoring."
        )

    eval_obj: dict = {
        "id": eval_id,
        "description": _description(inc),
        "tags": tags,
        "prompt": prompt,
        "workspace_files": workspace_files,
        "assertions": assertions,
        "reference_solution": {
            "description": reference_solution_description,
            "files": reference_solution_files,
        },
        "config": {
            "trials": 1,
            "max_turns": 8,
            "max_budget_usd": 0.2,
            "model": "haiku",
        },
        "stability": "flaky",
        "draft": draft,
    }
    return eval_obj, warnings


def _description(inc: Incident) -> str:
    parts = ["Incident-derived eval."]
    if inc.hook:
        parts.append(f"Fired from `{inc.hook}`.")
    if inc.phase:
        parts.append(f"Session phase at time of deny: `{inc.phase}`.")
    if inc.severity:
        parts.append(f"Severity classification: `{inc.severity}`.")
    return " ".join(parts)


def _prompt(inc: Incident) -> str:
    """Generate a prompt that re-creates the conditions of the incident."""
    pieces = [
        "Investigate the following incident pattern and demonstrate the correct handling.",
    ]
    if inc.event and inc.hook:
        pieces.append(f"Reproduce conditions that fire `{inc.hook}` on `{inc.event}`.")
    if inc.phase:
        pieces.append(f"Current session phase: `{inc.phase}`.")
    pieces.append(
        "Your output transcript must reference the hook name above at least once."
    )
    return "\n\n".join(pieces)


def extract_sid8(inc: Incident) -> str:
    """Best-effort 8-char session-id extractor from the commit field or title-like content."""
    if inc.commit and re.match(r"^[0-9a-f]+$", inc.commit):
        return inc.commit[:8]
    # Look for `(xxxxxxxx)` token in the body (matches title format from report.sh)
    m = re.search(r"\(([0-9a-f]{8})\)", inc.raw_body)
    if m:
        return m.group(1)
    return "unknown0"


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(
        description="Scaffold a meta-eval JSON from an auto-filed incident.",
    )
    src = parser.add_mutually_exclusive_group(required=True)
    src.add_argument("--issue", help="GitHub issue URL")
    src.add_argument("--file", help="local file containing the issue body")
    src.add_argument("--stdin", action="store_true", help="read body from stdin")
    parser.add_argument("--out", help="write output to file (default: stdout)")
    parser.add_argument(
        "--sid",
        help="override session-id hint used for the eval id",
    )
    parser.add_argument(
        "--allow-empty-counterfactual",
        action="store_true",
        help=(
            "skip the empty-counterfactual refuse-to-generate guard. "
            "Use only when back-filling historical incidents."
        ),
    )
    parser.add_argument(
        "--no-inversion",
        action="store_true",
        help=(
            "disable inversion rule matching — forces draft:true MVP "
            "fallback even when a known hook pattern would otherwise "
            "auto-derive workspace/reference_solution."
        ),
    )
    args = parser.parse_args()

    body = read_input(args)
    inc = parse_body(body)

    # Refuse-to-generate guard: empty Counterfactual section is a hard exit 2.
    if not inc.counterfactual_filled and not args.allow_empty_counterfactual:
        print(
            "refuse-to-generate: `## Counterfactual` section is empty or contains only the placeholder comment.\n"
            "Fill it in (describe what SHOULD have happened) and rerun, or pass --allow-empty-counterfactual for backfills.",
            file=sys.stderr,
        )
        return 2

    eval_obj, warnings = build_eval(
        inc,
        args.sid,
        inversion_enabled=not args.no_inversion,
    )
    for w in warnings:
        print(f"warning: {w}", file=sys.stderr)

    rendered = json.dumps(eval_obj, indent=2) + "\n"
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(rendered)
        print(f"wrote {args.out}", file=sys.stderr)
    else:
        sys.stdout.write(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
