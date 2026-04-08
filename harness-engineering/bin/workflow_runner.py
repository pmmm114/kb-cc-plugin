#!/usr/bin/env python3
"""
Multi-stage workflow benchmark runner.

Executes E2E workflow evals that test delegation chains
(e.g., planner → tdd-implementer → review) by running stages sequentially
and grading both per-stage and cross-stage assertions.

Usage (via bench.py):
    python3 bench.py workflow
    python3 bench.py workflow --id e2e-plan-then-implement
    python3 bench.py workflow --stage plan  # run up to plan stage only
"""

import json
import re
import shutil
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

from lib import (
    WORKFLOW_EVALS_DIR,
    WORKSPACE_DIR,
    setup_workspace,
    run_stage,
    grade_deterministic,
    grade_llm,
    grade_assertion,
    snapshot_workspace,
    diff_snapshots,
    compute_pass_at_k,
    compute_pass_pow_k,
    compute_eval_hash,
)

MAX_OUTPUT_CHARS = 8000


def resolve_prompt(template: str, stage_results: dict[str, dict]) -> str:
    """Replace {stages.<id>.text_output} placeholders with actual outputs.

    Truncates to last MAX_OUTPUT_CHARS characters if too long.
    """
    for stage_id, result in stage_results.items():
        placeholder = f"{{stages.{stage_id}.text_output}}"
        text = result.get("text_output", "")
        if len(text) > MAX_OUTPUT_CHARS:
            text = f"[...truncated, showing last {MAX_OUTPUT_CHARS} chars...]\n" + text[-MAX_OUTPUT_CHARS:]
        template = template.replace(placeholder, text)
    return template


def grade_workflow_assertion(assertion: dict, stage_results: dict[str, dict],
                             eval_def: dict, llm_grade: bool) -> dict:
    """Grade a single workflow-level assertion.

    Supports cross-stage deterministic checks (stage_tool_not_used, etc.)
    and LLM assertions that reference multiple stages.
    """
    check = assertion.get("check", "")

    # --- Workflow-specific deterministic checks ---
    if assertion["type"] == "deterministic":
        if check == "stage_tool_not_used":
            stage_id = assertion["stage"]
            tool = assertion["tool"]
            stage = stage_results.get(stage_id, {})
            used = any(tc["tool"] == tool for tc in stage.get("tool_calls", []))
            return {
                "assertion_id": assertion["id"],
                "text": assertion["text"],
                "type": "deterministic",
                "passed": not used,
                "evidence": (f"Tool '{tool}' was not used in stage '{stage_id}' (as expected)"
                             if not used else
                             f"Tool '{tool}' WAS used in stage '{stage_id}' (should not be)"),
            }

        elif check == "stage_tool_was_used":
            stage_id = assertion["stage"]
            tool = assertion["tool"]
            stage = stage_results.get(stage_id, {})
            used = any(tc["tool"] == tool for tc in stage.get("tool_calls", []))
            return {
                "assertion_id": assertion["id"],
                "text": assertion["text"],
                "type": "deterministic",
                "passed": used,
                "evidence": (f"Tool '{tool}' was used in stage '{stage_id}'"
                             if used else
                             f"Tool '{tool}' was NOT used in stage '{stage_id}'"),
            }

        elif check == "stage_output_contains":
            stage_id = assertion["stage"]
            pattern = assertion["pattern"]
            stage = stage_results.get(stage_id, {})
            text = stage.get("text_output", "")
            if re.search(pattern, text):
                return {
                    "assertion_id": assertion["id"],
                    "text": assertion["text"],
                    "type": "deterministic",
                    "passed": True,
                    "evidence": f"Pattern '{pattern}' found in stage '{stage_id}' output",
                }
            return {
                "assertion_id": assertion["id"],
                "text": assertion["text"],
                "type": "deterministic",
                "passed": False,
                "evidence": f"Pattern '{pattern}' NOT found in stage '{stage_id}' output",
            }

        # Unknown check type
        return {
            "assertion_id": assertion["id"],
            "text": assertion["text"],
            "type": "deterministic",
            "passed": False,
            "evidence": f"Unknown workflow check type: {check}",
        }

    # --- LLM assertions with cross-stage context ---
    if assertion["type"] == "llm":
        if not llm_grade:
            return {
                "assertion_id": assertion["id"],
                "text": assertion["text"],
                "type": "llm",
                "passed": None,
                "evidence": "Skipped (use --llm-grade to enable)",
            }

        # Build context from referenced stages
        referenced_stages = assertion.get("stages", list(stage_results.keys()))
        context_parts = []
        for sid in referenced_stages:
            sr = stage_results.get(sid, {})
            text = sr.get("text_output", "")[-3000:]
            tools = [tc["tool"] for tc in sr.get("tool_calls", [])]
            context_parts.append(
                f"### Stage: {sid} (agent: {sr.get('agent', 'default')})\n"
                f"Output (last 3000 chars):\n{text}\n\n"
                f"Tools used: {json.dumps(tools)}"
            )

        combined_context = "\n\n".join(context_parts)

        # Build a synthetic trial+eval_def for grade_llm
        synthetic_trial = {
            "text_output": combined_context,
            "tool_calls": [],
        }
        synthetic_eval = {
            "prompt": f"Workflow eval: {eval_def.get('description', '')}",
        }
        return grade_llm(assertion, synthetic_trial, synthetic_eval)

    return {
        "assertion_id": assertion["id"],
        "text": assertion["text"],
        "type": assertion.get("type", "unknown"),
        "passed": False,
        "evidence": f"Unsupported assertion type: {assertion.get('type')}",
    }


def run_workflow_trial(workflow_def: dict, trial_num: int, llm_grade: bool,
                       stop_after_stage: str | None = None,
                       verbose: bool = False) -> dict:
    """Execute one full trial of a workflow (all stages sequentially).

    Args:
        workflow_def: Workflow eval definition
        trial_num: Trial number (1-based)
        llm_grade: Enable LLM grading
        stop_after_stage: If set, stop after this stage (for debugging)
    """
    eval_id = workflow_def["id"]
    workspace = setup_workspace(workflow_def, trial_num)

    # Track original files for max_files_changed assertions
    original_files = {}
    for fname, content in workflow_def.get("workspace_files", {}).items():
        original_files[fname] = content

    stage_results = {}
    snap_before = snapshot_workspace(workspace) if workspace else {}
    aborted = False

    for stage_def in workflow_def.get("stages", []):
        stage_id = stage_def["id"]

        if aborted:
            stage_results[stage_id] = {
                "stage_id": stage_id,
                "agent": stage_def.get("agent"),
                "aborted": True,
                "exit_code": -1,
                "duration_s": 0,
                "total_tokens": 0,
                "tool_calls": [],
                "text_output": "",
                "event_sequence": [],
                "grades": [],
                "all_passed": False,
                "files_changed": {"added": [], "modified": [], "deleted": []},
            }
            continue

        # Resolve prompt
        if "prompt_template" in stage_def:
            prompt = resolve_prompt(stage_def["prompt_template"], stage_results)
        else:
            prompt = stage_def["prompt"]

        # Execute stage
        config = stage_def.get("config", {})
        agent = stage_def.get("agent")

        result = run_stage(
            prompt=prompt,
            workspace=workspace,
            config=config,
            agent=agent,
            stage_id=f"{stage_id}_trial_{trial_num}",
            eval_id=eval_id,
            verbose=verbose,
        )

        # Track file changes for this stage
        snap_after = snapshot_workspace(workspace) if workspace else {}
        result["files_changed"] = diff_snapshots(snap_before, snap_after)
        snap_before = snap_after

        # Add metadata
        result["stage_id"] = stage_id
        result["agent"] = agent
        result["aborted"] = False

        # Grade stage-level assertions
        # Inject _original_files for max_files_changed
        result["_original_files"] = original_files
        grades = []
        all_passed = True

        for assertion in stage_def.get("assertions", []):
            grade = grade_assertion(assertion, result, workspace, workflow_def, llm_grade)
            if grade:
                grades.append(grade)
                if grade["passed"] is False:
                    all_passed = False

        if "_original_files" in result:
            del result["_original_files"]

        result["grades"] = grades
        result["all_passed"] = all_passed
        stage_results[stage_id] = result

        status = "PASS" if all_passed else "FAIL"
        print(f"      stage '{stage_id}' ({agent or 'default'}): {status} "
              f"({result['duration_s']}s, {result['total_tokens']} tokens)")

        # Check failure strategy
        if not all_passed and stage_def.get("failure_strategy") == "abort":
            print(f"      → aborting remaining stages (failure_strategy=abort)")
            aborted = True

        # Stop early if debugging a specific stage
        if stop_after_stage and stage_id == stop_after_stage:
            break

    # Grade workflow-level assertions
    workflow_grades = []
    for assertion in workflow_def.get("workflow_assertions", []):
        grade = grade_workflow_assertion(assertion, stage_results, workflow_def, llm_grade)
        workflow_grades.append(grade)

    # Compute overall pass/fail
    stage_all_passed = all(
        sr.get("all_passed", False) for sr in stage_results.values()
        if not sr.get("aborted", False)
    )
    workflow_all_passed = all(
        g["passed"] is not False for g in workflow_grades
    )
    all_passed = stage_all_passed and workflow_all_passed

    # Compute totals
    total_tokens = sum(sr.get("total_tokens", 0) for sr in stage_results.values())
    total_duration = sum(sr.get("duration_s", 0) for sr in stage_results.values())
    per_stage_tokens = {
        sid: sr.get("total_tokens", 0) for sid, sr in stage_results.items()
    }

    return {
        "trial": trial_num,
        "stages": stage_results,
        "workflow_grades": workflow_grades,
        "all_stages_passed": stage_all_passed,
        "all_workflow_assertions_passed": workflow_all_passed,
        "all_passed": all_passed,
        "total_tokens": total_tokens,
        "total_duration_s": round(total_duration, 2),
        "per_stage_tokens": per_stage_tokens,
    }


def run_workflow_eval(workflow_def: dict, num_trials: int, llm_grade: bool,
                      workers: int = 1, stop_after_stage: str | None = None,
                      verbose: bool = False) -> dict:
    """Run all trials for one workflow eval and compute metrics."""
    eval_id = workflow_def["id"]
    config = workflow_def.get("config", {})
    config_trials = config.get("trials", 2)
    trials_to_run = num_trials or config_trials

    print(f"  {eval_id}: running {trials_to_run} trial(s)...")

    # Workflow trials run sequentially (stages within a trial are sequential,
    # and workspace is shared per trial)
    trial_results = []
    for t in range(1, trials_to_run + 1):
        print(f"    trial {t}:")
        result = run_workflow_trial(workflow_def, t, llm_grade, stop_after_stage, verbose=verbose)
        status = "PASS" if result["all_passed"] else "FAIL"
        print(f"    trial {t} overall: {status} "
              f"({result['total_duration_s']}s, {result['total_tokens']} tokens)")
        trial_results.append(result)

    trial_passed = [tr["all_passed"] for tr in trial_results]

    # Compute metrics
    pass_at_1 = compute_pass_at_k(trial_passed, 1)
    pass_at_k = compute_pass_at_k(trial_passed, trials_to_run)
    pass_pow_k = compute_pass_pow_k(trial_passed, trials_to_run)
    avg_tokens = sum(t["total_tokens"] for t in trial_results) / len(trial_results) if trial_results else 0
    avg_duration = sum(t["total_duration_s"] for t in trial_results) / len(trial_results) if trial_results else 0

    # Per-stage summary
    stage_ids = []
    if workflow_def.get("stages"):
        stage_ids = [s["id"] for s in workflow_def["stages"]]

    per_stage_summary = {}
    for sid in stage_ids:
        stage_tokens = [
            tr["per_stage_tokens"].get(sid, 0) for tr in trial_results
        ]
        stage_durations = [
            tr["stages"].get(sid, {}).get("duration_s", 0) for tr in trial_results
        ]
        stage_passed = [
            tr["stages"].get(sid, {}).get("all_passed", False) for tr in trial_results
            if not tr["stages"].get(sid, {}).get("aborted", False)
        ]
        per_stage_summary[sid] = {
            "avg_tokens": round(sum(stage_tokens) / len(stage_tokens)) if stage_tokens else 0,
            "avg_duration_s": round(sum(stage_durations) / len(stage_durations), 2) if stage_durations else 0,
            "stage_pass_rate": round(sum(stage_passed) / len(stage_passed), 3) if stage_passed else 0,
        }

    return {
        "eval_id": eval_id,
        "eval_hash": compute_eval_hash(workflow_def),
        "description": workflow_def.get("description", ""),
        "trials_run": trials_to_run,
        "trials_passed": sum(trial_passed),
        "pass_at_1": round(pass_at_1, 3),
        "pass_at_k": round(pass_at_k, 3),
        "pass_pow_k": round(pass_pow_k, 3),
        "avg_tokens": round(avg_tokens),
        "avg_duration_s": round(avg_duration, 2),
        "per_stage_summary": per_stage_summary,
        "trials": trial_results,
    }


def load_workflow_evals(eval_id: str | None = None) -> list[dict]:
    """Load workflow eval definitions from workflow-evals/ directory."""
    if not WORKFLOW_EVALS_DIR.exists():
        return []

    eval_files = sorted(WORKFLOW_EVALS_DIR.glob("*.json"))
    defs = []
    for f in eval_files:
        wf_def = json.loads(f.read_text())
        if eval_id and wf_def["id"] != eval_id:
            continue
        defs.append(wf_def)
    return defs


def cleanup_workflow_workspaces(workflow_defs: list[dict]):
    """Clean up workspace directories for workflow evals."""
    for wf_def in workflow_defs:
        wf_workspace = WORKSPACE_DIR / wf_def["id"]
        if wf_workspace.exists():
            shutil.rmtree(wf_workspace)
    if WORKSPACE_DIR.exists():
        try:
            WORKSPACE_DIR.rmdir()
        except OSError:
            pass
