#!/usr/bin/env python3
"""
Unified benchmark CLI for Claude Code configuration evaluation.

Combines single-eval runner (run.py) and workflow runner (workflow_runner.py)
into a single entrypoint with subcommands.

Usage:
    python3 bench.py eval                        # All single evals
    python3 bench.py eval --id plan-before-act   # Specific eval
    python3 bench.py workflow                    # All workflow evals
    python3 bench.py workflow --id e2e-plan-then-implement
    python3 bench.py workflow --stage plan       # Stop after plan stage
    python3 bench.py all                         # Both eval + workflow
    python3 bench.py all --save-baseline --llm-grade
    python3 bench.py all --compare
    python3 bench.py verify-refs                 # Verify all reference solutions
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

from lib import (
    EVALS_DIR,
    RESULTS_DIR,
    WORKSPACE_DIR,
    BASELINE_FILE,
    WORKFLOW_EVALS_DIR,
    verify_reference_solution,
    verify_reference_solutions_cached,
    compare_with_baseline,
    compute_eval_hash,
    get_git_commit_hash,
    check_baseline_freshness,
    load_checkpoint,
    save_checkpoint,
    complete_checkpoint,
    init_checkpoint,
)
from run import run_eval
from workflow_runner import (
    load_workflow_evals,
    run_workflow_eval,
    cleanup_workflow_workspaces,
)


def _detect_hook_dir() -> str | None:
    """Auto-detect HOOK_DIR when running inside a git worktree."""
    if os.environ.get("HOOK_DIR"):
        return os.environ["HOOK_DIR"]
    try:
        git_dir = subprocess.run(
            ["git", "rev-parse", "--git-dir"],
            capture_output=True, text=True, timeout=5,
        ).stdout.strip()
        git_common = subprocess.run(
            ["git", "rev-parse", "--git-common-dir"],
            capture_output=True, text=True, timeout=5,
        ).stdout.strip()
        if git_dir and git_common and git_dir != git_common and git_dir != ".git":
            toplevel = subprocess.run(
                ["git", "rev-parse", "--show-toplevel"],
                capture_output=True, text=True, timeout=5,
            ).stdout.strip()
            if toplevel:
                hooks_dir = str(Path(toplevel) / "hooks")
                if Path(hooks_dir).is_dir():
                    return hooks_dir
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    return None


def load_evals(eval_id: str | None = None) -> list[dict]:
    """Load single eval definitions."""
    eval_files = sorted(EVALS_DIR.glob("*.json"))
    defs = []
    for f in eval_files:
        eval_def = json.loads(f.read_text())
        if eval_id and eval_def["id"] != eval_id:
            continue
        defs.append(eval_def)
    return defs


def verify_all_refs(eval_defs: list[dict]) -> bool:
    """Verify reference solutions for all evals. Returns True if all pass."""
    print(f"Verifying reference solutions for {len(eval_defs)} eval(s)...")
    all_ok = True
    for eval_def in eval_defs:
        passed, messages = verify_reference_solution(eval_def)
        if not passed:
            all_ok = False
            print(f"  FAIL  {eval_def['id']}")
            for msg in messages:
                print(f"        {msg}")
        else:
            has_ref = eval_def.get("reference_solution") is not None
            print(f"  {'OK' if has_ref else 'SKIP':4s}  {eval_def['id']}")
    return all_ok


def run_single_evals(eval_defs: list[dict], args,
                     baseline_evals: dict | None = None,
                     checkpoint: dict | None = None) -> list[dict]:
    """Run single evals and return results.

    When baseline_evals is provided (dict of eval_id -> baseline result),
    evals whose hash matches the baseline are skipped and the baseline
    result is reused (with reused_from_baseline=True).

    When checkpoint is provided, evals already in completed_evals are skipped
    and their saved results are reused. Newly completed evals are saved to
    the checkpoint incrementally.
    """
    from concurrent.futures import ThreadPoolExecutor, as_completed

    force_rerun = getattr(args, "force_rerun", False)
    completed_evals = checkpoint.get("completed_evals", {}) if checkpoint else {}

    print(f"Running {len(eval_defs)} eval(s)...")
    print()

    # Separate evals into reusable vs must-run
    to_run = []
    eval_results_ordered = {}  # eval_id -> result (preserves order)

    for ed in eval_defs:
        eval_id = ed["id"]
        # Checkpoint resume: skip already-completed evals
        if completed_evals.get(eval_id):
            print(f"  {eval_id}: resumed from checkpoint")
            eval_results_ordered[eval_id] = completed_evals[eval_id]
            continue
        if baseline_evals and not force_rerun:
            baseline_entry = baseline_evals.get(eval_id)
            if baseline_entry and baseline_entry.get("eval_hash") == compute_eval_hash(ed):
                print(f"  {eval_id}: reused from baseline (hash match)")
                result = {**baseline_entry, "reused_from_baseline": True}
                eval_results_ordered[eval_id] = result
                if checkpoint is not None:
                    checkpoint["completed_evals"][eval_id] = result
                    save_checkpoint(checkpoint)
                continue
        to_run.append(ed)

    if to_run:
        if args.workers > 1 and len(to_run) > 1:
            run_results_map = {}
            with ThreadPoolExecutor(max_workers=args.workers) as executor:
                futures = {
                    executor.submit(run_eval, ed, args.trials, args.llm_grade, args.workers,
                                     verbose=getattr(args, 'verbose', False)): ed["id"]
                    for ed in to_run
                }
                for future in as_completed(futures):
                    eid = futures[future]
                    run_results_map[eid] = future.result()
                    if checkpoint is not None:
                        checkpoint["completed_evals"][eid] = run_results_map[eid]
                        save_checkpoint(checkpoint)
            for ed in to_run:
                eval_results_ordered[ed["id"]] = run_results_map[ed["id"]]
        else:
            for ed in to_run:
                result = run_eval(ed, args.trials, args.llm_grade, args.workers,
                                  verbose=getattr(args, 'verbose', False))
                eval_results_ordered[ed["id"]] = result
                if checkpoint is not None:
                    checkpoint["completed_evals"][ed["id"]] = result
                    save_checkpoint(checkpoint)

    # Return in original order
    return [eval_results_ordered[ed["id"]] for ed in eval_defs]


def run_workflow_evals(workflow_defs: list[dict], args,
                      baseline_workflows: dict | None = None,
                      checkpoint: dict | None = None) -> list[dict]:
    """Run workflow evals and return results.

    When baseline_workflows is provided (dict of eval_id -> baseline result),
    workflows whose hash matches the baseline are skipped and the baseline
    result is reused (with reused_from_baseline=True).

    When checkpoint is provided, workflows already in completed_workflows are
    skipped. Newly completed workflows are saved incrementally.
    """
    force_rerun = getattr(args, "force_rerun", False)
    completed_workflows = checkpoint.get("completed_workflows", {}) if checkpoint else {}

    print(f"Running {len(workflow_defs)} workflow eval(s)...")
    print()

    results = []
    stop_stage = getattr(args, "stage", None)
    for wf_def in workflow_defs:
        eval_id = wf_def["id"]
        # Checkpoint resume
        if completed_workflows.get(eval_id):
            print(f"  {eval_id}: resumed from checkpoint")
            results.append(completed_workflows[eval_id])
            continue
        if baseline_workflows and not force_rerun:
            baseline_entry = baseline_workflows.get(eval_id)
            if baseline_entry and baseline_entry.get("eval_hash") == compute_eval_hash(wf_def):
                print(f"  {eval_id}: reused from baseline (hash match)")
                result = {**baseline_entry, "reused_from_baseline": True}
                results.append(result)
                if checkpoint is not None:
                    checkpoint["completed_workflows"][eval_id] = result
                    save_checkpoint(checkpoint)
                continue

        result = run_workflow_eval(
            wf_def,
            num_trials=args.trials,
            llm_grade=args.llm_grade,
            workers=args.workers,
            stop_after_stage=stop_stage,
            verbose=getattr(args, 'verbose', False),
        )
        results.append(result)
        if checkpoint is not None:
            checkpoint["completed_workflows"][eval_id] = result
            save_checkpoint(checkpoint)

    return results


def print_summary(eval_results: list[dict], workflow_results: list[dict]):
    """Print combined summary table."""
    print()
    print("--- Summary ---")

    if eval_results:
        print("  [Evals]")
        for e in eval_results:
            print(f"    {e['eval_id']:30s} pass@1={e['pass_at_1']:.1%}  pass^k={e['pass_pow_k']:.1%}  "
                  f"tokens={e['avg_tokens']}  time={e['avg_duration_s']}s")

    if workflow_results:
        print("  [Workflows]")
        for w in workflow_results:
            print(f"    {w['eval_id']:30s} pass@1={w['pass_at_1']:.1%}  pass^k={w['pass_pow_k']:.1%}  "
                  f"tokens={w['avg_tokens']}  time={w['avg_duration_s']}s")
            for sid, ss in w.get("per_stage_summary", {}).items():
                print(f"      └─ {sid:26s} pass={ss['stage_pass_rate']:.1%}  "
                      f"tokens={ss['avg_tokens']}  time={ss['avg_duration_s']}s")

    # Overall
    all_results = eval_results + workflow_results
    if all_results:
        avg_pass = sum(r["pass_at_1"] for r in all_results) / len(all_results)
        print()
        print(f"Overall avg pass@1: {avg_pass:.1%}")


def build_report(timestamp: str, llm_grade: bool,
                 eval_results: list[dict], workflow_results: list[dict]) -> dict:
    """Build combined report dict."""
    all_results = eval_results + workflow_results
    total_trials = sum(r["trials_run"] for r in all_results)
    total_passed = sum(r["trials_passed"] for r in all_results)
    avg_pass = sum(r["pass_at_1"] for r in all_results) / len(all_results) if all_results else 0

    report = {
        "timestamp": timestamp,
        "git_commit": get_git_commit_hash(),
        "llm_grading": llm_grade,
        "summary": {
            "total_evals": len(eval_results),
            "total_workflow_evals": len(workflow_results),
            "total_trials": total_trials,
            "total_passed": total_passed,
            "avg_pass_at_1": round(avg_pass, 3),
        },
        "evals": eval_results,
        "workflow_evals": workflow_results,
    }
    return report


def _load_baseline_dicts(args) -> tuple[dict | None, dict | None]:
    """Load baseline and build eval/workflow lookup dicts for incremental compare.

    Returns (baseline_evals, baseline_workflows) or (None, None) if not applicable.
    """
    if not getattr(args, "compare", False) or not BASELINE_FILE.exists():
        return None, None
    if getattr(args, "force_rerun", False):
        return None, None
    try:
        baseline = json.loads(BASELINE_FILE.read_text())
        baseline_evals = {e["eval_id"]: e for e in baseline.get("evals", [])}
        baseline_workflows = {e["eval_id"]: e for e in baseline.get("workflow_evals", [])}
        return baseline_evals, baseline_workflows
    except (json.JSONDecodeError, KeyError):
        return None, None


def cmd_eval(args):
    """Handle 'eval' subcommand."""
    eval_defs = load_evals(args.id)
    if not eval_defs:
        print("No evals found.")
        return

    print(f"Verifying reference solutions for {len(eval_defs)} eval(s)...")
    ref_ok, _messages = verify_reference_solutions_cached(eval_defs)
    if not ref_ok:
        print("\nERROR: Reference solution verification failed.")
        sys.exit(1)
    print()

    checkpoint = None
    use_checkpoint = getattr(args, "resume", False)
    if use_checkpoint and not getattr(args, "force_rerun", False):
        git_commit = get_git_commit_hash()
        eval_ids = [ed["id"] for ed in eval_defs]
        checkpoint = load_checkpoint(git_commit, args, eval_ids=eval_ids)
        if checkpoint:
            n = len(checkpoint.get("completed_evals", {}))
            print(f"Resuming from checkpoint ({n} eval(s) already completed)")
            print()
        else:
            checkpoint = init_checkpoint(git_commit, args, eval_ids, [])

    baseline_evals, _ = _load_baseline_dicts(args)
    results = run_single_evals(eval_defs, args, baseline_evals=baseline_evals,
                               checkpoint=checkpoint)
    print_summary(results, [])

    timestamp = datetime.now().strftime("%Y-%m-%dT%H:%M:%S")
    report = build_report(timestamp, args.llm_grade, results, [])
    save_and_compare(report, args, timestamp)
    if use_checkpoint:
        complete_checkpoint(checkpoint)


def cmd_workflow(args):
    """Handle 'workflow' subcommand."""
    workflow_defs = load_workflow_evals(args.id)
    if not workflow_defs:
        print("No workflow evals found.")
        return

    print(f"Found {len(workflow_defs)} workflow eval(s).")
    print()

    checkpoint = None
    use_checkpoint = getattr(args, "resume", False)
    if use_checkpoint and not getattr(args, "force_rerun", False):
        git_commit = get_git_commit_hash()
        wf_ids = [wf["id"] for wf in workflow_defs]
        checkpoint = load_checkpoint(git_commit, args, workflow_ids=wf_ids)
        if checkpoint:
            n = len(checkpoint.get("completed_workflows", {}))
            print(f"Resuming from checkpoint ({n} workflow(s) already completed)")
            print()
        else:
            checkpoint = init_checkpoint(git_commit, args, [], wf_ids)

    _, baseline_workflows = _load_baseline_dicts(args)
    results = run_workflow_evals(workflow_defs, args,
                                baseline_workflows=baseline_workflows,
                                checkpoint=checkpoint)
    print_summary([], results)

    timestamp = datetime.now().strftime("%Y-%m-%dT%H:%M:%S")
    report = build_report(timestamp, args.llm_grade, [], results)
    save_and_compare(report, args, timestamp)
    if use_checkpoint:
        complete_checkpoint(checkpoint)

    cleanup_workflow_workspaces(workflow_defs)


def cmd_all(args):
    """Handle 'all' subcommand."""
    eval_defs = load_evals(args.id if hasattr(args, "id") else None)
    workflow_defs = load_workflow_evals()

    if not eval_defs and not workflow_defs:
        print("No evals or workflow evals found.")
        return

    # Verify refs for single evals
    if eval_defs:
        print(f"Verifying reference solutions for {len(eval_defs)} eval(s)...")
        ref_ok, _messages = verify_reference_solutions_cached(eval_defs)
        if not ref_ok:
            print("\nERROR: Reference solution verification failed.")
            sys.exit(1)
        print()

    checkpoint = None
    use_checkpoint = getattr(args, "resume", False)
    if use_checkpoint and not getattr(args, "force_rerun", False):
        git_commit = get_git_commit_hash()
        eval_ids = [ed["id"] for ed in eval_defs]
        wf_ids = [wf["id"] for wf in workflow_defs]
        checkpoint = load_checkpoint(git_commit, args, eval_ids=eval_ids,
                                     workflow_ids=wf_ids)
        if checkpoint:
            ne = len(checkpoint.get("completed_evals", {}))
            nw = len(checkpoint.get("completed_workflows", {}))
            print(f"Resuming from checkpoint ({ne} eval(s), {nw} workflow(s) already completed)")
            print()
        else:
            checkpoint = init_checkpoint(git_commit, args, eval_ids, wf_ids)

    # Load baseline for incremental compare
    baseline_evals, baseline_workflows = _load_baseline_dicts(args)

    # Run single evals
    eval_results = run_single_evals(eval_defs, args, baseline_evals=baseline_evals,
                                    checkpoint=checkpoint) if eval_defs else []

    # Run workflow evals
    workflow_results = run_workflow_evals(workflow_defs, args,
                                         baseline_workflows=baseline_workflows,
                                         checkpoint=checkpoint) if workflow_defs else []

    print_summary(eval_results, workflow_results)

    timestamp = datetime.now().strftime("%Y-%m-%dT%H:%M:%S")
    report = build_report(timestamp, args.llm_grade, eval_results, workflow_results)
    save_and_compare(report, args, timestamp)
    if use_checkpoint:
        complete_checkpoint(checkpoint)

    if workflow_defs:
        cleanup_workflow_workspaces(workflow_defs)

    # Cleanup single eval workspaces
    for ed in eval_defs:
        ew = WORKSPACE_DIR / ed["id"]
        if ew.exists():
            shutil.rmtree(ew)
    if WORKSPACE_DIR.exists():
        try:
            WORKSPACE_DIR.rmdir()
        except OSError:
            pass


def cmd_verify_refs(args):
    """Handle 'verify-refs' subcommand."""
    eval_defs = load_evals()
    if not eval_defs:
        print("No evals found.")
        return

    print(f"Verifying reference solutions for {len(eval_defs)} eval(s)...")
    ref_ok, _messages = verify_reference_solutions_cached(eval_defs, force=True)
    if ref_ok:
        print("\nAll reference solutions verified.")
    else:
        print("\nERROR: Some reference solutions failed.")
        sys.exit(1)


def save_and_compare(report: dict, args, timestamp: str):
    """Save results and optionally compare with baseline."""
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    result_file = RESULTS_DIR / f"{timestamp.replace(':', '-')}.json"
    result_file.write_text(json.dumps(report, indent=2, default=str))
    print(f"\nResults: {result_file}")

    if args.save_baseline:
        BASELINE_FILE.write_text(json.dumps(report, indent=2, default=str))
        print(f"Baseline saved: {BASELINE_FILE}")

    if args.compare and BASELINE_FILE.exists():
        baseline = json.loads(BASELINE_FILE.read_text())
        is_fresh, freshness_msg = check_baseline_freshness(baseline)
        if not is_fresh:
            print(f"\nWARNING: {freshness_msg}")
            print("Comparison results may not accurately reflect the delta from your change.\n")
        comparison = compare_with_baseline(report, baseline)
        print()
        print("--- Baseline Comparison ---")
        has_regression = False
        for c in comparison["comparisons"]:
            symbol = {"IMPROVED": "+", "REGRESSED": "-", "STABLE": "=", "NEW": "*"}[c["status"]]
            print(f"  [{symbol}] {c['eval_id']:30s} {c['status']}", end="")
            if "delta_pass_at_1" in c:
                print(f"  (pass@1: {c['baseline_pass_at_1']:.1%} → {c['current_pass_at_1']:.1%})", end="")
            if c["status"] == "REGRESSED":
                has_regression = True
            print()

        if has_regression:
            print()
            print("WARNING: Regressions detected. Review changes before keeping.")

        report["comparison"] = comparison
        result_file.write_text(json.dumps(report, indent=2, default=str))


def main():
    parser = argparse.ArgumentParser(
        description="Claude Code Configuration Benchmark Suite",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
    python3 bench.py eval                              # Run all single evals
    python3 bench.py workflow --id e2e-investigate-only # Run specific workflow
    python3 bench.py workflow --stage plan              # Stop after plan stage
    python3 bench.py all --save-baseline --llm-grade    # Full suite + save baseline
    python3 bench.py all --compare                      # Compare with baseline
    python3 bench.py verify-refs                        # Check reference solutions
        """,
    )

    subparsers = parser.add_subparsers(dest="command", help="Subcommand")

    # Common arguments
    def add_common_args(p):
        p.add_argument("--llm-grade", action="store_true", help="Enable LLM-based grading")
        p.add_argument("--trials", type=int, default=0, help="Override trial count (0 = use eval default)")
        p.add_argument("--workers", type=int, default=4, help="Max parallel workers (default: 4)")
        p.add_argument("--save-baseline", action="store_true", help="Save results as baseline")
        p.add_argument("--compare", action="store_true", help="Compare with baseline")
        p.add_argument("--force-rerun", action="store_true", help="Force re-run all evals even if hash matches baseline")
        p.add_argument("--resume", action="store_true", help="Resume from last checkpoint if available")
        p.add_argument("--verbose", action="store_true", help="Pass --verbose to claude CLI (increases tokens, for debugging)")

    # eval subcommand
    p_eval = subparsers.add_parser("eval", help="Run single-stage evals")
    add_common_args(p_eval)
    p_eval.add_argument("--id", type=str, help="Run specific eval by ID")

    # workflow subcommand
    p_workflow = subparsers.add_parser("workflow", help="Run workflow evals")
    add_common_args(p_workflow)
    p_workflow.add_argument("--id", type=str, help="Run specific workflow eval by ID")
    p_workflow.add_argument("--stage", type=str, help="Stop after this stage (for debugging)")

    # all subcommand
    p_all = subparsers.add_parser("all", help="Run all evals and workflow evals")
    add_common_args(p_all)

    # verify-refs subcommand
    p_verify = subparsers.add_parser("verify-refs", help="Verify reference solutions")

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        return

    print("=== Claude Code Configuration Benchmark Suite ===")
    print(f"Command: {args.command}")
    if hasattr(args, "llm_grade"):
        print(f"LLM grading: {'ENABLED' if args.llm_grade else 'DISABLED'}")
    print()

    # Auto-detect HOOK_DIR for worktree testing
    hook_dir = _detect_hook_dir()
    if hook_dir:
        os.environ["HOOK_DIR"] = hook_dir
        print(f"HOOK_DIR: {hook_dir}")
        print()

    if args.command == "eval":
        cmd_eval(args)
    elif args.command == "workflow":
        cmd_workflow(args)
    elif args.command == "all":
        cmd_all(args)
    elif args.command == "verify-refs":
        cmd_verify_refs(args)


if __name__ == "__main__":
    main()
