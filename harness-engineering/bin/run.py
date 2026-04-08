#!/usr/bin/env python3
"""
Claude Code Configuration Benchmark Runner

Follows Anthropic's eval methodology:
- Headless execution via `claude -p --output-format stream-json`
- Multiple trials per eval (pass@k, pass^k metrics)
- Deterministic grading by default, LLM grading via --llm-grade
- Outcome-based assertions (not tool-call order)

Usage:
    python3 run.py                          # Run all evals
    python3 run.py --eval plan-before-act   # Run specific eval
    python3 run.py --llm-grade              # Include LLM-based grading
    python3 run.py --save-baseline          # Save results as baseline
    python3 run.py --compare                # Compare with baseline
    python3 run.py --trials 5               # Override trial count
    python3 run.py --workers 8              # Parallel workers (default: 4)
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from pathlib import Path

from lib import (
    BENCH_DIR,
    EVALS_DIR,
    RESULTS_DIR,
    WORKSPACE_DIR,
    BASELINE_FILE,
    setup_workspace,
    run_trial,
    grade_deterministic,
    grade_llm,
    compute_pass_at_k,
    compute_pass_pow_k,
    compare_with_baseline,
    verify_reference_solution,
    compute_eval_hash,
    verify_reference_solutions_cached,
    get_git_commit_hash,
    check_baseline_freshness,
    load_checkpoint,
    save_checkpoint,
    complete_checkpoint,
    init_checkpoint,
)


def _detect_hook_dir() -> str | None:
    """Auto-detect HOOK_DIR when running inside a git worktree."""
    # Explicit env var takes precedence
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
            # We're in a worktree — derive hooks path from repo root
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


def _run_single_trial(eval_def: dict, trial_num: int, original_files: dict,
                      llm_grade: bool, verbose: bool = False) -> dict:
    """Run and grade a single trial. Designed for parallel execution."""
    workspace = setup_workspace(eval_def, trial_num)
    trial = run_trial(eval_def, workspace, trial_num, verbose=verbose)
    trial["_original_files"] = original_files

    grades = []
    all_passed = True

    for assertion in eval_def.get("assertions", []):
        if assertion["type"] == "deterministic":
            grade = grade_deterministic(assertion, trial, workspace)
        elif assertion["type"] == "llm" and llm_grade:
            grade = grade_llm(assertion, trial, eval_def)
        elif assertion["type"] == "llm" and not llm_grade:
            grade = {
                "assertion_id": assertion["id"],
                "text": assertion["text"],
                "type": "llm",
                "passed": None,
                "evidence": "Skipped (use --llm-grade to enable)",
            }
        else:
            continue

        grades.append(grade)
        if grade["passed"] is False:
            all_passed = False

    del trial["_original_files"]

    status = "PASS" if all_passed else "FAIL"
    print(f"    trial {trial_num}: {status} ({trial['duration_s']}s, {trial['total_tokens_real']} tokens)")

    return {
        **trial,
        "grades": grades,
        "all_passed": all_passed,
    }


def run_eval(eval_def: dict, num_trials: int, llm_grade: bool, workers: int = 1,
             verbose: bool = False) -> dict:
    """Run all trials for one eval and grade them."""
    eval_id = eval_def["id"]
    config_trials = eval_def.get("config", {}).get("trials", 3)
    trials_to_run = num_trials or config_trials

    print(f"  {eval_id}: running {trials_to_run} trial(s) (workers={workers})...")

    original_files = {}
    for fname, content in eval_def.get("workspace_files", {}).items():
        original_files[fname] = content

    if workers > 1:
        trial_results_map = {}
        with ThreadPoolExecutor(max_workers=min(workers, trials_to_run)) as executor:
            futures = {
                executor.submit(_run_single_trial, eval_def, t, original_files, llm_grade, verbose): t
                for t in range(1, trials_to_run + 1)
            }
            for future in as_completed(futures):
                t = futures[future]
                trial_results_map[t] = future.result()
        # Maintain trial order
        trial_results = [trial_results_map[t] for t in range(1, trials_to_run + 1)]
    else:
        trial_results = []
        for t in range(1, trials_to_run + 1):
            result = _run_single_trial(eval_def, t, original_files, llm_grade, verbose)
            trial_results.append(result)

    trial_passed = [tr["all_passed"] for tr in trial_results]

    # Compute metrics
    pass_at_1 = compute_pass_at_k(trial_passed, 1)
    pass_at_k = compute_pass_at_k(trial_passed, trials_to_run)
    pass_pow_k = compute_pass_pow_k(trial_passed, trials_to_run)
    avg_tokens = sum(t["total_tokens_real"] for t in trial_results) / len(trial_results) if trial_results else 0
    avg_duration = sum(t["duration_s"] for t in trial_results) / len(trial_results) if trial_results else 0

    return {
        "eval_id": eval_id,
        "eval_hash": compute_eval_hash(eval_def),
        "description": eval_def.get("description", ""),
        "trials_run": trials_to_run,
        "trials_passed": sum(trial_passed),
        "pass_at_1": round(pass_at_1, 3),
        "pass_at_k": round(pass_at_k, 3),
        "pass_pow_k": round(pass_pow_k, 3),
        "avg_tokens": round(avg_tokens),
        "avg_duration_s": round(avg_duration, 2),
        "trials": trial_results,
    }


def main():
    parser = argparse.ArgumentParser(description="Claude Code Configuration Benchmark Runner")
    parser.add_argument("--eval", type=str, help="Run a specific eval by ID")
    parser.add_argument("--llm-grade", action="store_true", help="Enable LLM-based grading (costs tokens)")
    parser.add_argument("--trials", type=int, default=0, help="Override trial count (0 = use eval default)")
    parser.add_argument("--save-baseline", action="store_true", help="Save results as baseline")
    parser.add_argument("--compare", action="store_true", help="Compare with baseline")
    parser.add_argument("--verify-refs", action="store_true", help="Verify reference solutions pass all deterministic assertions")
    parser.add_argument("--workers", type=int, default=4, help="Max parallel workers for trials within each eval (default: 4)")
    parser.add_argument("--force-rerun", action="store_true", help="Force re-run all evals even if hash matches baseline")
    parser.add_argument("--tag", action="append", default=None,
                        help="Filter evals by tag (e.g. --tag skill:gh-cli --tag rule:core). Multiple tags are OR'd.")
    parser.add_argument("--config-dir", type=str, default=None,
                        help="Path to a worktree/config directory. Temporarily swaps settings.json and hooks/ into ~/.claude/ for testing.")
    parser.add_argument("--resume", action="store_true",
                        help="Resume from last checkpoint if available")
    parser.add_argument("--verbose", action="store_true",
                        help="Pass --verbose to claude CLI (increases token usage, useful for debugging)")
    args = parser.parse_args()

    timestamp = datetime.now().strftime("%Y-%m-%dT%H:%M:%S")
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)

    print("=== Claude Code Configuration Benchmark ===")
    print(f"Timestamp: {timestamp}")
    if args.llm_grade:
        print("LLM grading: ENABLED (haiku)")
    else:
        print("LLM grading: DISABLED (deterministic only, use --llm-grade to enable)")
    print(f"Workers: {args.workers}")
    if args.tag:
        print(f"Tag filter: {', '.join(args.tag)} (OR)")
    print()

    # Auto-detect HOOK_DIR for worktree testing
    hook_dir = _detect_hook_dir()
    if args.config_dir:
        # --config-dir also sets HOOK_DIR
        config_hooks = Path(args.config_dir) / "hooks"
        if config_hooks.is_dir():
            hook_dir = str(config_hooks)
    if hook_dir:
        os.environ["HOOK_DIR"] = hook_dir
        print(f"HOOK_DIR: {hook_dir}")
        print()

    # Load evals
    eval_files = sorted(EVALS_DIR.glob("*.json"))
    eval_defs = []
    for f in eval_files:
        eval_def = json.loads(f.read_text())
        if args.eval and eval_def["id"] != args.eval:
            continue
        eval_defs.append(eval_def)

    if args.tag:
        eval_defs = [e for e in eval_defs if any(t in e.get("tags", []) for t in args.tag)]

    if not eval_defs:
        print("No evals found.")
        return

    # Verify reference solutions before any run (with caching)
    print(f"Verifying reference solutions for {len(eval_defs)} eval(s)...")
    force_verify = bool(args.verify_refs)
    ref_ok, _messages = verify_reference_solutions_cached(eval_defs, force=force_verify)

    if not ref_ok:
        print()
        print("ERROR: Reference solution verification failed.")
        print("Fix the reference_solution or assertions before running benchmarks.")
        print("This ensures assertions are not broken — see Anthropic's eval integrity guidelines.")
        sys.exit(1)
    print()

    if args.verify_refs:
        print("All reference solutions verified. Exiting (--verify-refs mode).")
        return

    print(f"Running {len(eval_defs)} eval(s)...")
    print()

    # Config dir override: temporarily swap settings.json + hooks/ for worktree testing.
    # claude always reads from ~/.claude/, so we must physically swap the files.
    config_backups = {}  # {dest_path: original_content_or_None}
    claude_dir = Path.home() / ".claude"
    if args.config_dir:
        config_dir = Path(args.config_dir)
        if not config_dir.is_dir():
            print(f"ERROR: Config directory not found: {config_dir}")
            sys.exit(1)

        # Swap settings.json
        src_settings = config_dir / "settings.json"
        dst_settings = claude_dir / "settings.json"
        if src_settings.exists():
            config_backups[str(dst_settings)] = dst_settings.read_text() if dst_settings.exists() else None
            shutil.copy2(src_settings, dst_settings)
            print(f"  settings.json swapped from {config_dir}")

        # Swap hooks/ directory — copy each script individually
        src_hooks = config_dir / "hooks"
        dst_hooks = claude_dir / "hooks"
        if src_hooks.is_dir():
            dst_hooks.mkdir(exist_ok=True)
            for hook_file in src_hooks.iterdir():
                if hook_file.is_file():
                    dst = dst_hooks / hook_file.name
                    config_backups[str(dst)] = dst.read_text() if dst.exists() else None
                    shutil.copy2(hook_file, dst)
            print(f"  hooks/ swapped from {config_dir}")

        # Swap agents/ — copy each *.md individually
        src_agents = config_dir / "agents"
        dst_agents = claude_dir / "agents"
        if src_agents.is_dir():
            dst_agents.mkdir(exist_ok=True)
            for agent_file in src_agents.glob("*.md"):
                dst = dst_agents / agent_file.name
                config_backups[str(dst)] = dst.read_text() if dst.exists() else None
                shutil.copy2(agent_file, dst)
            print(f"  agents/ swapped from {config_dir}")

        # Swap rules/ — copy each *.md individually
        src_rules = config_dir / "rules"
        dst_rules = claude_dir / "rules"
        if src_rules.is_dir():
            dst_rules.mkdir(exist_ok=True)
            for rule_file in src_rules.glob("*.md"):
                dst = dst_rules / rule_file.name
                config_backups[str(dst)] = dst.read_text() if dst.exists() else None
                shutil.copy2(rule_file, dst)
            print(f"  rules/ swapped from {config_dir}")

        # Swap skills/ — copy each */SKILL.md individually
        src_skills = config_dir / "skills"
        dst_skills = claude_dir / "skills"
        if src_skills.is_dir():
            for skill_dir in src_skills.iterdir():
                if skill_dir.is_dir():
                    skill_file = skill_dir / "SKILL.md"
                    if skill_file.exists():
                        dst_skill_dir = dst_skills / skill_dir.name
                        dst_skill_dir.mkdir(parents=True, exist_ok=True)
                        dst = dst_skill_dir / "SKILL.md"
                        config_backups[str(dst)] = dst.read_text() if dst.exists() else None
                        shutil.copy2(skill_file, dst)
            print(f"  skills/ swapped from {config_dir}")

        print()

    def _restore_config_backups():
        for dest_path, original in config_backups.items():
            p = Path(dest_path)
            if original is not None:
                p.write_text(original)
            elif p.exists():
                p.unlink()
        if config_backups:
            print("Config restored to original.")

    # Load baseline for incremental compare (hash-based skip)
    baseline_by_id = {}
    if args.compare and BASELINE_FILE.exists() and not args.force_rerun:
        try:
            baseline_data = json.loads(BASELINE_FILE.read_text())
            baseline_by_id = {e["eval_id"]: e for e in baseline_data.get("evals", [])}
        except (json.JSONDecodeError, KeyError):
            pass

    # Checkpoint: load or create (only when --resume is set)
    checkpoint = None
    use_checkpoint = args.resume
    if use_checkpoint and not args.force_rerun:
        git_commit = get_git_commit_hash()
        eval_ids = [ed["id"] for ed in eval_defs]
        checkpoint = load_checkpoint(git_commit, args, eval_ids=eval_ids)
        if checkpoint:
            n = len(checkpoint.get("completed_evals", {}))
            print(f"Resuming from checkpoint ({n} eval(s) already completed)")
            print()
        else:
            checkpoint = init_checkpoint(git_commit, args, eval_ids, [])
    completed_evals = checkpoint.get("completed_evals", {}) if checkpoint else {}

    try:
        # Run evals sequentially, trials in parallel within each eval.
        # Nested parallelism (evals + trials) causes workspace race conditions
        # when multiple claude -p processes compete for system resources.
        eval_results = []
        for eval_def in eval_defs:
            eval_id = eval_def["id"]

            # Checkpoint resume: skip already-completed evals
            if completed_evals.get(eval_id):
                print(f"  {eval_id}: resumed from checkpoint")
                eval_results.append(completed_evals[eval_id])
                continue

            current_hash = compute_eval_hash(eval_def)
            baseline_entry = baseline_by_id.get(eval_id)

            if (baseline_entry
                    and baseline_entry.get("eval_hash") == current_hash):
                print(f"  {eval_id}: reused from baseline (hash match)")
                reused = {**baseline_entry, "reused_from_baseline": True}
                eval_results.append(reused)
                if checkpoint is not None:
                    checkpoint["completed_evals"][eval_id] = reused
                    save_checkpoint(checkpoint)
            else:
                result = run_eval(eval_def, args.trials, args.llm_grade, args.workers,
                                  verbose=args.verbose)
                eval_results.append(result)
                if checkpoint is not None:
                    checkpoint["completed_evals"][eval_id] = result
                    save_checkpoint(checkpoint)
        print()
    finally:
        _restore_config_backups()

    # Aggregate metrics
    total_trials = sum(e["trials_run"] for e in eval_results)
    total_passed = sum(e["trials_passed"] for e in eval_results)
    avg_pass_at_1 = sum(e["pass_at_1"] for e in eval_results) / len(eval_results) if eval_results else 0

    report = {
        "timestamp": timestamp,
        "git_commit": get_git_commit_hash(),
        "llm_grading": args.llm_grade,
        "summary": {
            "total_evals": len(eval_results),
            "total_trials": total_trials,
            "total_passed": total_passed,
            "avg_pass_at_1": round(avg_pass_at_1, 3),
        },
        "evals": eval_results,
    }

    # Save results
    result_file = RESULTS_DIR / f"{timestamp.replace(':', '-')}.json"
    result_file.write_text(json.dumps(report, indent=2, default=str))

    # Print summary
    print("--- Summary ---")
    for e in eval_results:
        print(f"  {e['eval_id']:25s} pass@1={e['pass_at_1']:.1%}  pass^k={e['pass_pow_k']:.1%}  "
              f"avg_tokens_real={e['avg_tokens']}  avg_time={e['avg_duration_s']}s")
    print()

    # Flaky eval reporting
    flaky_evals = [e for e in eval_results
                   if any(ed.get("stability") == "flaky"
                          for ed in eval_defs if ed["id"] == e["eval_id"])]
    if flaky_evals:
        flaky_with_fails = [e for e in flaky_evals if e["pass_at_1"] < 1.0]
        if flaky_with_fails:
            print("--- Flaky Evals (known variance, not counted as regression) ---")
            for e in flaky_with_fails:
                print(f"  {e['eval_id']:25s} pass@1={e['pass_at_1']:.1%}  (stability: flaky)")
            print()

    print(f"Overall avg pass@1: {avg_pass_at_1:.1%}")
    print(f"Results: {result_file}")

    # Baseline operations
    if args.save_baseline:
        # Merge with existing baseline to preserve coverage
        existing_baseline = {}
        if BASELINE_FILE.exists():
            try:
                existing_baseline = json.loads(BASELINE_FILE.read_text())
            except (json.JSONDecodeError, KeyError):
                pass

        if existing_baseline.get("evals"):
            # Merge: keep existing entries, update with new results
            existing_by_id = {e["eval_id"]: e for e in existing_baseline.get("evals", [])}
            for e in eval_results:
                existing_by_id[e["eval_id"]] = e
            report["evals"] = list(existing_by_id.values())

        BASELINE_FILE.write_text(json.dumps(report, indent=2, default=str))
        print(f"Baseline saved: {BASELINE_FILE}")
        if args.tag:
            print(f"  (merged with existing baseline — {len(report['evals'])} total evals)")

    if args.compare and BASELINE_FILE.exists():
        baseline = json.loads(BASELINE_FILE.read_text())
        is_fresh, freshness_msg = check_baseline_freshness(baseline)
        if not is_fresh:
            print(f"\nWARNING: {freshness_msg}")
            print("Comparison results may not accurately reflect the delta from your change.\n")
        comparison = compare_with_baseline(report, baseline)
        print()
        print("--- Baseline Comparison ---")
        # Build stability lookup
        stability_by_id = {ed["id"]: ed.get("stability", "stable") for ed in eval_defs}
        has_regression = False
        for c in comparison["comparisons"]:
            is_flaky = stability_by_id.get(c["eval_id"], "stable") == "flaky"
            effective_status = c["status"]
            if is_flaky and c["status"] == "REGRESSED":
                effective_status = "FLAKY"  # Don't count as regression
            symbol = {"IMPROVED": "+", "REGRESSED": "-", "STABLE": "=", "NEW": "*", "FLAKY": "~"}[effective_status]
            print(f"  [{symbol}] {c['eval_id']:25s} {effective_status}", end="")
            if "delta_pass_at_1" in c:
                print(f"  (pass@1: {c['baseline_pass_at_1']:.1%} → {c['current_pass_at_1']:.1%})", end="")
            if "baseline_ci" in c and "current_ci" in c:
                b_ci = c["baseline_ci"]
                cur_ci = c["current_ci"]
                print(f"  CI=[{b_ci[0]:.0%}-{b_ci[1]:.0%}]→[{cur_ci[0]:.0%}-{cur_ci[1]:.0%}]", end="")
            if is_flaky and effective_status != "FLAKY":
                print(f"  (flaky)", end="")
            if effective_status == "REGRESSED":
                has_regression = True
            print()

        if has_regression:
            print()
            print("WARNING: Regressions detected. Review changes before keeping.")

        # Save comparison in results
        report["comparison"] = comparison
        result_file.write_text(json.dumps(report, indent=2, default=str))

    if use_checkpoint:
        complete_checkpoint(checkpoint)

    # Cleanup eval-specific workspace subdirectories (not the shared parent)
    for eval_def in eval_defs:
        eval_workspace = WORKSPACE_DIR / eval_def["id"]
        if eval_workspace.exists():
            shutil.rmtree(eval_workspace)
    # Remove parent only if empty
    if WORKSPACE_DIR.exists():
        try:
            WORKSPACE_DIR.rmdir()
        except OSError:
            pass


if __name__ == "__main__":
    main()
