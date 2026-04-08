#!/usr/bin/env python3
"""
Shared benchmark utilities.

Extracted from run.py to be reused by workflow_runner.py and bench.py.
"""

import glob
import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import tempfile
import threading
import time
from pathlib import Path

# ============================================================
# Constants
# ============================================================

BENCH_DIR = Path(__file__).parent
EVALS_DIR = BENCH_DIR / "evals"
WORKFLOW_EVALS_DIR = BENCH_DIR / "workflow-evals"
RESULTS_DIR = BENCH_DIR / "results"
WORKSPACE_DIR = Path("/tmp/claude-benchmarks-workspaces")
BASELINE_FILE = BENCH_DIR / "baseline.json"
REFCHECK_CACHE_FILE = BENCH_DIR / ".refcheck-cache.json"
CHECKPOINT_FILE = BENCH_DIR / ".run-checkpoint.json"

# LLM grader concurrency control
_LLM_GRADER_SEMAPHORE = threading.Semaphore(
    int(os.environ.get("CLAUDE_BENCH_LLM_CONCURRENCY", "3"))
)


def set_llm_concurrency(n: int) -> None:
    """Replace the LLM grader semaphore with a new one of value n."""
    global _LLM_GRADER_SEMAPHORE
    _LLM_GRADER_SEMAPHORE = threading.Semaphore(n)


# ============================================================
# Git utilities
# ============================================================

def get_git_commit_hash(repo_dir: Path | None = None) -> str | None:
    """Get the current HEAD commit hash of the repository.

    Returns short (8-char) hash, or None if not a git repo.
    """
    cwd = str(repo_dir) if repo_dir else str(BENCH_DIR)
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--short=8", "HEAD"],
            capture_output=True, text=True, timeout=5, cwd=cwd,
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    return None


def check_baseline_freshness(baseline: dict) -> tuple[bool, str]:
    """Check if baseline was saved from the current git state.

    Returns (is_fresh, message).
    - is_fresh=True: baseline commit matches current HEAD → safe to reuse
    - is_fresh=False: mismatch or no commit info → should re-baseline
    """
    baseline_commit = baseline.get("git_commit")
    if not baseline_commit:
        return False, "Baseline has no git_commit recorded (legacy baseline)"

    current_commit = get_git_commit_hash()
    if not current_commit:
        return False, "Cannot determine current git commit"

    if baseline_commit == current_commit:
        return True, f"Baseline matches current commit ({current_commit})"

    return False, (
        f"Baseline was saved at commit {baseline_commit}, "
        f"but current HEAD is {current_commit}. "
        f"Re-run with --save-baseline to update."
    )


# ============================================================
# Rules loading
# ============================================================

REPO_ROOT = BENCH_DIR.parent


def _load_rules(rule_paths: list[str]) -> str:
    """Read rule files and concatenate into a single system prompt string.

    Paths are relative to the repo root (e.g., "rules/core.md").
    """
    parts = []
    resolved_root = REPO_ROOT.resolve()
    for rel_path in rule_paths:
        full = (REPO_ROOT / rel_path).resolve()
        if not full.is_relative_to(resolved_root):
            print(f"[WARN] rule path escapes repo root, skipped: {rel_path}")
            continue
        if not full.is_file():
            print(f"[WARN] rule file not found: {rel_path}")
            continue
        parts.append(full.read_text())
    return "\n\n".join(parts)


# ============================================================
# Workspace management
# ============================================================

def setup_workspace(eval_def: dict, trial_num: int | None = None) -> Path | None:
    """Create a clean, isolated workspace for one eval trial.

    When trial_num is provided, creates a trial-specific workspace
    (eval_id/trial_N/) to allow parallel trial execution.
    Returns None if the eval has no workspace_files.
    """
    if not eval_def.get("workspace_files"):
        return None
    if trial_num is not None:
        workspace = WORKSPACE_DIR / eval_def["id"] / f"trial_{trial_num}"
    else:
        workspace = WORKSPACE_DIR / eval_def["id"]
    if workspace.exists():
        shutil.rmtree(workspace)
    workspace.mkdir(parents=True)

    for filename, content in eval_def.get("workspace_files", {}).items():
        filepath = workspace / filename
        filepath.parent.mkdir(parents=True, exist_ok=True)
        filepath.write_text(content)

    # setup_commands: optional pre-trial commands (eval JSON is trusted local input)
    for cmd in eval_def.get("setup_commands", []):
        result = subprocess.run(cmd, shell=True, cwd=str(workspace), timeout=120,
                                capture_output=True, text=True)
        if result.returncode != 0:
            print(f"[WARN] setup_command failed: {cmd}\n  stderr: {result.stderr[:500]}")

    return workspace


def snapshot_workspace(workspace: Path) -> dict[str, str]:
    """Record SHA-256 hashes of all files in a workspace.

    Used to detect file changes between workflow stages.
    Returns {relative_path: sha256_hex}.
    """
    hashes = {}
    if workspace is None or not workspace.exists():
        return hashes
    for f in workspace.rglob("*"):
        if not f.is_file():
            continue
        rel = str(f.relative_to(workspace))
        if rel.startswith(".") or rel.startswith("transcript_"):
            continue
        hashes[rel] = hashlib.sha256(f.read_bytes()).hexdigest()
    return hashes


def diff_snapshots(before: dict[str, str], after: dict[str, str]) -> dict:
    """Compare two workspace snapshots.

    Returns {added: [...], modified: [...], deleted: [...]}.
    """
    added = [f for f in after if f not in before]
    deleted = [f for f in before if f not in after]
    modified = [f for f in after if f in before and after[f] != before[f]]
    return {"added": added, "modified": modified, "deleted": deleted}


# ============================================================
# Trial execution
# ============================================================

def run_trial(eval_def: dict, workspace: Path | None, trial_num: int,
              verbose: bool = False, extra_env: dict | None = None) -> dict:
    """Execute one trial of an eval using claude -p."""
    config = eval_def.get("config", {})
    max_turns = config.get("max_turns", 10)
    max_budget = config.get("max_budget_usd", 1.0)
    model = config.get("model")
    agent = config.get("agent")

    # Determine cwd: use workspace if available, otherwise a temp directory
    temp_cwd = None
    if workspace is not None:
        cwd = str(workspace)
    else:
        temp_cwd = tempfile.mkdtemp(prefix="claude-bench-")
        cwd = temp_cwd

    # Store transcripts completely outside workspace tree so agent can't delete them
    transcript_dir = Path("/tmp/claude-bench-transcripts") / eval_def["id"]
    transcript_dir.mkdir(parents=True, exist_ok=True)
    transcript_file = transcript_dir / f"transcript_trial_{trial_num}.jsonl"

    cmd = [
        "claude", "-p", eval_def["prompt"],
        "--output-format", "stream-json",
        "--verbose",
        "--max-turns", str(max_turns),
        "--max-budget-usd", str(max_budget),
        "--dangerously-skip-permissions",
    ]
    if model:
        cmd.extend(["--model", model])
    if agent:
        cmd.extend(["--agent", agent])

    # Inject rules into the sandbox via --append-system-prompt
    rules_prompt = _load_rules(eval_def.get("rules", []))
    if rules_prompt:
        cmd.extend(["--append-system-prompt", rules_prompt])

    env = None
    if extra_env:
        env = {**os.environ, **extra_env}

    start_time = time.time()
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=300,  # 5 minute max
            stdin=subprocess.DEVNULL,
            cwd=cwd,
            env=env,
        )
        stdout = result.stdout
        stderr = result.stderr
        exit_code = result.returncode
    except subprocess.TimeoutExpired:
        stdout = ""
        stderr = "TIMEOUT"
        exit_code = -1
    finally:
        if temp_cwd and os.path.exists(temp_cwd):
            shutil.rmtree(temp_cwd)

    duration_s = time.time() - start_time

    # Save transcript (ensure dir exists — agent may have altered filesystem)
    transcript_file.parent.mkdir(parents=True, exist_ok=True)
    transcript_file.write_text(stdout)

    return _parse_stream_json(stdout, trial_num, exit_code, duration_s, transcript_file, workspace)


def run_stage(prompt: str, workspace: Path | None, config: dict,
              agent: str | None = None, stage_id: str = "stage",
              eval_id: str = "workflow", verbose: bool = False,
              extra_env: dict | None = None) -> dict:
    """Execute one stage of a workflow using claude -p.

    Like run_trial but accepts prompt directly and supports --agent flag.
    """
    max_turns = config.get("max_turns", 15)
    max_budget = config.get("max_budget_usd", 2.0)
    timeout = config.get("timeout_s", 600)
    model = config.get("model")

    temp_cwd = None
    if workspace is not None:
        cwd = str(workspace)
    else:
        temp_cwd = tempfile.mkdtemp(prefix="claude-bench-")
        cwd = temp_cwd

    transcript_dir = Path("/tmp/claude-bench-transcripts") / eval_id
    transcript_dir.mkdir(parents=True, exist_ok=True)
    transcript_file = transcript_dir / f"transcript_{stage_id}.jsonl"

    cmd = [
        "claude", "-p", prompt,
        "--output-format", "stream-json",
        "--verbose",
        "--max-turns", str(max_turns),
        "--max-budget-usd", str(max_budget),
        "--dangerously-skip-permissions",
    ]
    if model:
        cmd.extend(["--model", model])
    if agent:
        cmd.extend(["--agent", agent])

    env = None
    if extra_env:
        env = {**os.environ, **extra_env}

    start_time = time.time()
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            stdin=subprocess.DEVNULL,
            cwd=cwd,
            env=env,
        )
        stdout = result.stdout
        exit_code = result.returncode
    except subprocess.TimeoutExpired:
        stdout = ""
        exit_code = -1
    finally:
        if temp_cwd and os.path.exists(temp_cwd):
            shutil.rmtree(temp_cwd)

    duration_s = time.time() - start_time

    transcript_file.parent.mkdir(parents=True, exist_ok=True)
    transcript_file.write_text(stdout)

    return _parse_stream_json(stdout, 0, exit_code, duration_s, transcript_file, workspace)


def _parse_stream_json(stdout: str, trial_num: int, exit_code: int,
                       duration_s: float, transcript_file: Path,
                       workspace: Path | None) -> dict:
    """Parse stream-json output from claude -p into structured trial data."""
    input_tokens = 0
    output_tokens = 0
    cache_creation_tokens = 0
    cache_read_tokens = 0
    tool_calls = []
    text_output = []
    event_sequence = []

    for line in stdout.strip().split("\n"):
        if not line.strip():
            continue
        try:
            event = json.loads(line)
            msg_type = event.get("type", "")

            if msg_type == "result":
                usage = event.get("usage", {})
                input_tokens = usage.get("input_tokens", 0)
                output_tokens = usage.get("output_tokens", 0)
                cache_creation_tokens = usage.get("cache_creation_input_tokens", 0)
                cache_read_tokens = usage.get("cache_read_input_tokens", 0)
                text_output.append(event.get("result", ""))

            if msg_type == "tool_use":
                tc = {
                    "tool": event.get("tool", ""),
                    "input": event.get("input", {}),
                }
                tool_calls.append(tc)
                event_sequence.append({"kind": "tool", "tool": tc["tool"]})

            if msg_type == "assistant" and "message" in event:
                for block in event.get("message", {}).get("content", []):
                    if isinstance(block, dict):
                        if block.get("type") == "text":
                            text = block.get("text", "")
                            text_output.append(text)
                            event_sequence.append({"kind": "text", "text": text})
                        elif block.get("type") == "tool_use":
                            tc = {
                                "tool": block.get("name", ""),
                                "input": block.get("input", {}),
                            }
                            tool_calls.append(tc)
                            event_sequence.append({"kind": "tool", "tool": tc["tool"]})
        except json.JSONDecodeError:
            continue

    total_tokens = input_tokens + output_tokens
    total_tokens_real = input_tokens + cache_creation_tokens + cache_read_tokens + output_tokens

    return {
        "trial": trial_num,
        "exit_code": exit_code,
        "duration_s": round(duration_s, 2),
        "total_tokens": total_tokens,
        "total_tokens_real": total_tokens_real,
        "input_tokens": input_tokens,
        "cache_creation_tokens": cache_creation_tokens,
        "cache_read_tokens": cache_read_tokens,
        "output_tokens": output_tokens,
        "tool_calls": tool_calls,
        "text_output": "\n".join(text_output),
        "event_sequence": event_sequence,
        "transcript_file": str(transcript_file),
        "workspace": str(workspace) if workspace is not None else None,
    }


# ============================================================
# Grading
# ============================================================

def _strip_comments_and_strings(source: str) -> str:
    """Strip JS/TS line comments, block comments, and string literals from source.

    Intended for use with curated test fixture content only — naive regex-based
    stripping will mishandle nested comments and template literals with // inside.
    That is an accepted limitation for eval fixtures.
    """
    # Remove block comments /* ... */
    result = re.sub(r'/\*.*?\*/', ' ', source, flags=re.DOTALL)
    # Remove line comments // ...
    result = re.sub(r'//[^\n]*', ' ', result)
    # Remove shell line comments # ... (only for non-JS/TS — skip in JS/TS fixtures
    # where # appears in regex literals, CSS hex colors, and private class fields)
    # Disabled: all current eval fixtures are JS/TS. Re-enable with file-type detection if needed.
    # Remove double-quoted string literals
    result = re.sub(r'"(?:[^"\\]|\\.)*"', '""', result)
    # Remove single-quoted string literals
    result = re.sub(r"'(?:[^'\\]|\\.)*'", "''", result)
    # Remove template literals
    result = re.sub(r'`(?:[^`\\]|\\.)*`', '``', result)
    return result


def grade_deterministic(assertion: dict, trial: dict, workspace: Path | None) -> dict:
    """Grade a deterministic assertion against trial results."""
    check = assertion.get("check", "")
    passed = False
    evidence = ""

    if check in ("file_contains", "file_exists", "file_exists_pattern", "max_files_changed", "not_file_contains", "file_contains_code") and workspace is None:
        return {
            "assertion_id": assertion["id"],
            "text": assertion["text"],
            "type": "deterministic",
            "passed": False,
            "evidence": "No workspace — file-based assertion not applicable",
        }

    if check == "file_contains":
        filepath = workspace / assertion["file"]
        if filepath.exists():
            content = filepath.read_text()
            pattern = assertion["pattern"]
            if re.search(pattern, content):
                passed = True
                evidence = f"Pattern '{pattern}' found in {assertion['file']}"
            else:
                evidence = f"Pattern '{pattern}' NOT found in {assertion['file']}"
        else:
            evidence = f"File {assertion['file']} does not exist"

    elif check == "file_exists":
        filepath = workspace / assertion["file"]
        if filepath.exists():
            passed = True
            evidence = f"File {assertion['file']} exists"
        else:
            evidence = f"File {assertion['file']} does not exist"

    elif check == "file_exists_pattern":
        pattern = assertion["pattern"]
        matches = list(workspace.glob(pattern))
        if matches:
            passed = True
            evidence = f"Found files matching '{pattern}': {[m.name for m in matches]}"
        else:
            evidence = f"No files matching '{pattern}' found"

    elif check == "max_files_changed":
        limit = assertion["limit"]
        if not workspace.exists():
            passed = False
            evidence = "Workspace directory was deleted by agent — cannot check files changed"
            return {
                "assertion_id": assertion["id"],
                "text": assertion["text"],
                "type": "deterministic",
                "passed": passed,
                "evidence": evidence,
            }
        original_files = set()
        for fname in trial.get("_original_files", {}).keys():
            original_files.add(fname)

        changed = []
        for f in workspace.rglob("*"):
            if not f.is_file():
                continue
            rel = str(f.relative_to(workspace))
            if rel.startswith(".") or rel.startswith("transcript_"):
                continue
            original = trial.get("_original_files", {}).get(rel, None)
            current = f.read_text(errors="replace")
            if current != original:
                changed.append(rel)

        if len(changed) <= limit:
            passed = True
            evidence = f"{len(changed)} file(s) changed (limit: {limit}): {changed}"
        else:
            evidence = f"{len(changed)} file(s) changed, exceeds limit {limit}: {changed}"

    elif check == "tool_was_used":
        tool_name = assertion["tool"]
        used = any(tc["tool"] == tool_name for tc in trial.get("tool_calls", []))
        if used:
            passed = True
            evidence = f"Tool '{tool_name}' was used"
        else:
            evidence = f"Tool '{tool_name}' was NOT used"

    elif check == "output_contains":
        pattern = assertion["pattern"]
        if re.search(pattern, trial.get("text_output", "")):
            passed = True
            evidence = f"Pattern '{pattern}' found in output"
        else:
            evidence = f"Pattern '{pattern}' NOT found in output"

    elif check == "output_not_contains":
        pattern = assertion["pattern"]
        if re.search(pattern, trial.get("text_output", "")):
            passed = False
            evidence = f"Pattern '{pattern}' found in output (should be absent)"
        else:
            passed = True
            evidence = f"Pattern '{pattern}' not found in output (as expected)"

    elif check == "tool_not_used":
        tool_name = assertion["tool"]
        used = any(tc["tool"] == tool_name for tc in trial.get("tool_calls", []))
        if used:
            passed = False
            evidence = f"Tool '{tool_name}' was used (should not be)"
        else:
            passed = True
            evidence = f"Tool '{tool_name}' was not used (as expected)"

    elif check == "no_tool_call_matches":
        tool_name = assertion.get("tool")
        pattern = assertion["pattern"]
        matched = []
        for tc in trial.get("tool_calls", []):
            if tool_name and tc["tool"] != tool_name:
                continue
            input_str = json.dumps(tc.get("input", {}))
            if re.search(pattern, input_str):
                matched.append(tc["tool"])
        if matched:
            passed = False
            evidence = f"Pattern '{pattern}' matched in tool call input(s): {matched}"
        else:
            passed = True
            evidence = f"Pattern '{pattern}' not found in any tool call input (as expected)"

    elif check == "tool_call_matches":
        tool_name = assertion.get("tool")
        pattern = assertion["pattern"]
        matched = []
        for tc in trial.get("tool_calls", []):
            if tool_name and tc["tool"] != tool_name:
                continue
            input_str = json.dumps(tc.get("input", {}))
            if re.search(pattern, input_str):
                matched.append(tc["tool"])
        if matched:
            passed = True
            evidence = f"Pattern '{pattern}' matched in tool call input(s): {matched}"
        else:
            passed = False
            evidence = f"Pattern '{pattern}' NOT found in any tool call input"

    elif check == "bash_command_matches":
        # Structured Bash-call checker: inspects tc.input.command (not the full input blob).
        # Fields:
        #   command_regex      (required)  — must match tc.input.command
        #   args_must_match    (list)      — every pattern must find a hit in tc.input.command
        #   args_must_not_match (list)     — no pattern may find a hit in tc.input.command
        #   min_matches        (int, def 1) — minimum qualifying Bash calls required
        command_regex = assertion.get("command_regex")
        if not command_regex:
            return {
                "assertion_id": assertion["id"],
                "text": assertion.get("text", ""),
                "type": "deterministic",
                "passed": False,
                "evidence": "bash_command_matches: command_regex is required but missing or empty",
            }
        args_must_match = assertion.get("args_must_match", [])
        args_must_not_match = assertion.get("args_must_not_match", [])
        min_matches = assertion.get("min_matches", 1)

        qualifying = []
        rejection_notes = []
        for i, tc in enumerate(trial.get("tool_calls", [])):
            if tc.get("tool") != "Bash":
                continue
            command = tc.get("input", {}).get("command", "")
            if not re.search(command_regex, command):
                continue
            # Check positive patterns
            miss = None
            for j, pat in enumerate(args_must_match):
                if not re.search(pat, command):
                    miss = f"args_must_match[{j}]={pat!r} not found in call {i}"
                    break
            if miss:
                rejection_notes.append(miss)
                continue
            # Check negative patterns
            reject = None
            for j, pat in enumerate(args_must_not_match):
                if re.search(pat, command):
                    reject = f"args_must_not_match[{j}]={pat!r} matched in call {i}"
                    break
            if reject:
                rejection_notes.append(reject)
                continue
            qualifying.append(i)

        if len(qualifying) >= min_matches:
            passed = True
            evidence = (
                f"bash_command_matches: {len(qualifying)} qualifying call(s) "
                f"(need {min_matches}); call indices {qualifying}"
            )
        else:
            note = ("; rejection notes: " + "; ".join(rejection_notes)) if rejection_notes else ""
            evidence = (
                f"bash_command_matches: {len(qualifying)} qualifying call(s), "
                f"need {min_matches}{note}"
            )

    elif check == "functional":
        # Run a short code snippet in a sandboxed subprocess and check exit code / stdout.
        # Intended for eval-author-controlled snippets only — NOT for grading agent-generated code.
        passed, evidence = _run_functional_sandbox(assertion)

    elif check == "tool_call_count":
        tool_name = assertion["tool"]
        count = sum(1 for tc in trial.get("tool_calls", []) if tc["tool"] == tool_name)
        min_count = assertion.get("min", 0)
        max_count = assertion.get("max", float("inf"))
        if min_count <= count <= max_count:
            passed = True
            evidence = f"Tool '{tool_name}' called {count} time(s) (range: {min_count}-{max_count})"
        else:
            evidence = f"Tool '{tool_name}' called {count} time(s), outside range {min_count}-{max_count}"

    elif check == "last_tool_is":
        allowed = assertion["tools"]  # list of tool names
        tools = trial.get("tool_calls", [])
        if not tools:
            evidence = "No tool calls recorded"
        else:
            last = tools[-1]["tool"]
            if last in allowed:
                passed = True
                evidence = f"Last tool '{last}' is in allowed set {allowed}"
            else:
                evidence = f"Last tool '{last}' is NOT in allowed set {allowed}"

    elif check == "text_before_tool":
        target_tool = assertion["tool"]
        seq = trial.get("event_sequence", [])
        found_text = False
        found_tool = False
        for evt in seq:
            if evt["kind"] == "text" and not found_text:
                found_text = True
            if evt["kind"] == "tool" and evt["tool"] == target_tool:
                found_tool = True
                break
        if found_text and found_tool:
            passed = True
            evidence = f"Text output appears before first '{target_tool}' call"
        elif not found_tool:
            evidence = f"Tool '{target_tool}' was never called"
        else:
            evidence = f"No text output before first '{target_tool}' call"

    elif check == "not_file_contains":
        filepath = workspace / assertion["file"]
        if filepath.exists():
            content = filepath.read_text()
            stripped = _strip_comments_and_strings(content)
            pattern = assertion["pattern"]
            match = re.search(pattern, stripped)
            if match:
                passed = False
                start = max(0, match.start() - 30)
                end = min(len(stripped), match.end() + 30)
                snippet = stripped[start:end].strip()
                evidence = (
                    f"Pattern '{pattern}' found in stripped content of {assertion['file']}: "
                    f"...{snippet}..."
                )
            else:
                passed = True
                evidence = f"Pattern '{pattern}' not found in stripped content of {assertion['file']} (as expected)"
        else:
            # File doesn't exist → pattern is absent → pass
            passed = True
            evidence = f"File {assertion['file']} does not exist (pattern absence confirmed)"

    elif check == "file_contains_code":
        filepath = workspace / assertion["file"]
        if filepath.exists():
            content = filepath.read_text()
            stripped = _strip_comments_and_strings(content)
            pattern = assertion["pattern"]
            if re.search(pattern, stripped):
                passed = True
                evidence = f"Pattern '{pattern}' found in stripped content of {assertion['file']}"
            else:
                evidence = f"Pattern '{pattern}' NOT found in stripped content of {assertion['file']}"
        else:
            evidence = f"File {assertion['file']} does not exist"

    if assertion.get("invert", False):
        passed = not passed
        evidence = f"[inverted] {evidence}"

    return {
        "assertion_id": assertion["id"],
        "text": assertion.get("text", ""),
        "type": "deterministic",
        "passed": passed,
        "evidence": evidence,
    }


def _run_functional_sandbox(assertion: dict) -> tuple[bool, str]:
    """Run a short eval-author-controlled snippet and verify exit code / stdout.

    Sandbox guarantees:
    - shell=False, argv form (python3 -c / node -e)
    - Ephemeral tempfile.mkdtemp() cwd, removed in finally
    - Env limited to PATH + LANG only (no HOME, no PYTHONPATH, no NODE_PATH, no secrets)
    - preexec_fn sets RLIMITs on POSIX: CPU, AS=256MB, NPROC=32, FSIZE=1MB, NOFILE=64
    - timeout clamped to [0.1, 5.0] seconds
    - stdout+stderr collected via communicate(timeout=...); truncated to 1MB after collection
    - On timeout: proc.kill() fires before deadlock (OS pipe buffer 64KB << 5s timeout)

    Security caveat: functional snippets are eval-author-signed code, not agent-generated code.
    macOS has no network namespaces; network isolation is not provided.
    """
    import resource

    runtime = assertion.get("runtime", "python")
    script = assertion.get("script", "")
    raw_timeout = assertion.get("timeout_sec", 5.0)
    timeout_sec = max(0.1, min(5.0, float(raw_timeout)))
    expected_exit = assertion.get("expected_exit", 0)
    stdout_matches = assertion.get("stdout_matches")
    max_script_bytes = assertion.get("max_script_bytes", 4096)

    if len(script.encode("utf-8")) > max_script_bytes:
        return False, f"functional: script exceeds max_script_bytes={max_script_bytes}"

    if runtime == "python":
        argv = ["python3", "-c", script]
    elif runtime == "node":
        argv = ["node", "-e", script]
    else:
        return False, f"functional: unsupported runtime={runtime!r} (supported: python, node)"

    env = {}
    for key in ("PATH", "LANG"):
        val = os.environ.get(key)
        if val:
            env[key] = val

    def _setrlimits():
        # Each limit wrapped independently: one failure must not skip the others.
        # RLIMIT_AS is silently unenforced on macOS (hard limit = system max);
        # RLIMIT_FSIZE and RLIMIT_CPU are reliably enforced on both Linux and macOS.
        try: resource.setrlimit(resource.RLIMIT_CPU, (5, 5))
        except Exception: pass
        try:
            mb256 = 256 * 1024 * 1024
            resource.setrlimit(resource.RLIMIT_AS, (mb256, mb256))
        except Exception: pass  # macOS: unenforced, may raise OSError
        try: resource.setrlimit(resource.RLIMIT_NPROC, (32, 32))
        except Exception: pass
        try:
            mb1 = 1 * 1024 * 1024
            resource.setrlimit(resource.RLIMIT_FSIZE, (mb1, mb1))
        except Exception: pass
        try: resource.setrlimit(resource.RLIMIT_NOFILE, (64, 64))
        except Exception: pass

    cwd = tempfile.mkdtemp(prefix="claude-func-sandbox-")
    timed_out = False
    stdout_raw = b""
    stderr_raw = b""
    actual_exit = None

    try:
        proc = subprocess.Popen(
            argv,
            cwd=cwd,
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            shell=False,
            preexec_fn=_setrlimits,
        )
        try:
            stdout_raw, stderr_raw = proc.communicate(timeout=timeout_sec)
        except subprocess.TimeoutExpired:
            timed_out = True
            proc.kill()
            stdout_raw, stderr_raw = proc.communicate()
        actual_exit = proc.returncode
    finally:
        shutil.rmtree(cwd, ignore_errors=True)

    stdout_text = (stdout_raw[:1024 * 1024]).decode("utf-8", errors="replace")
    stderr_text = (stderr_raw[:1024 * 1024]).decode("utf-8", errors="replace")
    combined_head = (stdout_text + stderr_text)[:200]

    if timed_out:
        return False, (
            f"functional[{runtime}]: timed out after {timeout_sec}s "
            f"(script killed); stdout+stderr head: {combined_head!r}"
        )

    if actual_exit != expected_exit:
        return False, (
            f"functional[{runtime}]: exit={actual_exit} expected={expected_exit}; "
            f"stdout+stderr head: {combined_head!r}"
        )

    if stdout_matches and not re.search(stdout_matches, stdout_text):
        return False, (
            f"functional[{runtime}]: stdout_matches={stdout_matches!r} not found; "
            f"stdout head: {stdout_text[:200]!r}"
        )

    return True, (
        f"functional[{runtime}]: exit={actual_exit} (expected {expected_exit}), "
        f"stdout_matches={stdout_matches!r} OK; stdout head: {stdout_text[:200]!r}"
    )


def _truncate_tool_args_for_grader(tool_calls: list, max_len: int = 200) -> list:
    """Serialize tool calls with string args truncated for LLM grader prompts.

    LLM graders have limited context budget. String arg values longer than max_len
    chars are truncated with a '...' suffix. Non-string values pass through unchanged.

    Trial tool calls store the payload under "input" (not "args"). The output key
    is kept as "args" for grader-prompt compatibility.

    Per-tool truncation rules:
      Write     — file_path (full) + content truncated to 500 chars
      Edit      — file_path (full) + old_string/new_string truncated to 500 chars
      MultiEdit — file_path (full) + edits array with each entry truncated to 500 chars
      Other     — all string values truncated to max_len (200) chars
    """
    result = []
    for tc in tool_calls:
        tool = tc["tool"]
        raw = tc.get("input") or {}
        tool_max = 500 if tool in ("Write", "Edit", "MultiEdit") else max_len

        if tool == "Write":
            args = {
                "file_path": raw.get("file_path", ""),
                "content": (
                    raw["content"][:tool_max] + "..."
                    if isinstance(raw.get("content"), str) and len(raw["content"]) > tool_max
                    else raw.get("content", "")
                ),
            }
        elif tool == "Edit":
            args = {
                "file_path": raw.get("file_path", ""),
                "old_string": (
                    raw["old_string"][:tool_max] + "..."
                    if isinstance(raw.get("old_string"), str) and len(raw["old_string"]) > tool_max
                    else raw.get("old_string", "")
                ),
                "new_string": (
                    raw["new_string"][:tool_max] + "..."
                    if isinstance(raw.get("new_string"), str) and len(raw["new_string"]) > tool_max
                    else raw.get("new_string", "")
                ),
            }
        elif tool == "MultiEdit":
            edits = []
            for entry in raw.get("edits", []):
                edits.append({
                    k: (v[:tool_max] + "..." if isinstance(v, str) and len(v) > tool_max else v)
                    for k, v in entry.items()
                })
            args = {"file_path": raw.get("file_path", ""), "edits": edits}
        else:
            args = {
                k: (v[:max_len] + "..." if isinstance(v, str) and len(v) > max_len else v)
                for k, v in raw.items()
            }

        result.append({"tool": tool, "args": args})
    return result


def grade_llm(assertion: dict, trial: dict, eval_def: dict) -> dict:
    """Grade an assertion using LLM (claude -p with haiku model)."""
    schema = json.dumps({
        "type": "object",
        "properties": {
            "passed": {"type": "boolean"},
            "evidence": {"type": "string"},
        },
        "required": ["passed", "evidence"],
    })

    prompt = f"""You are an eval grader. Evaluate whether this assertion is true based on the agent's output.

## Assertion
{assertion['text']}

## Agent's Task
{eval_def.get('prompt', eval_def.get('description', ''))}

## Agent's Text Output (excerpt, last 3000 chars)
{trial['text_output'][-3000:]}

## Tool Calls Made (tool name + arguments — arguments matter for grading)
{json.dumps(_truncate_tool_args_for_grader(trial.get('tool_calls', [])), indent=2)}

Judge ONLY based on the evidence above. Tool arguments matter — consider what was actually passed to each tool, not just which tools were invoked. If uncertain, return passed=false.

Respond with RAW JSON only (no markdown fences, no extra text): {{"passed": <bool>, "evidence": "<one sentence>"}}"""

    try:
        with _LLM_GRADER_SEMAPHORE:
            result = subprocess.run(
                [
                    "claude", "-p", prompt,
                    "--output-format", "stream-json",
                    "--verbose",
                    "--max-turns", "2",
                    "--model", "haiku",
                    "--dangerously-skip-permissions",
                ],
                capture_output=True,
                text=True,
                timeout=60,
                stdin=subprocess.DEVNULL,
            )
        # Extract text from stream-json events
        raw = ""
        for line in result.stdout.strip().split("\n"):
            if not line.strip():
                continue
            try:
                event = json.loads(line)
                if event.get("type") == "assistant":
                    for block in event.get("message", {}).get("content", []):
                        if isinstance(block, dict) and block.get("type") == "text":
                            raw += block.get("text", "")
            except json.JSONDecodeError:
                continue
        if not raw:
            raw = "{}"
        # Strip markdown fences if present (```json ... ```)
        lines_raw = raw.strip().splitlines()
        if lines_raw and lines_raw[0].startswith("```"):
            lines_raw = lines_raw[1:]
        if lines_raw and lines_raw[-1].strip() == "```":
            lines_raw = lines_raw[:-1]
        structured = json.loads("\n".join(lines_raw).strip())

        return {
            "assertion_id": assertion["id"],
            "text": assertion["text"],
            "type": "llm",
            "passed": structured.get("passed", False),
            "evidence": structured.get("evidence", "LLM grading failed to parse"),
        }
    except Exception as e:
        return {
            "assertion_id": assertion["id"],
            "text": assertion["text"],
            "type": "llm",
            "passed": False,
            "evidence": f"LLM grading error: {str(e)}",
        }


def grade_assertion(assertion: dict, trial: dict, workspace: Path | None,
                    eval_def: dict, llm_grade: bool) -> dict:
    """Grade a single assertion (deterministic or LLM)."""
    if assertion["type"] == "deterministic":
        return grade_deterministic(assertion, trial, workspace)
    elif assertion["type"] == "llm" and llm_grade:
        return grade_llm(assertion, trial, eval_def)
    elif assertion["type"] == "llm" and not llm_grade:
        return {
            "assertion_id": assertion["id"],
            "text": assertion["text"],
            "type": "llm",
            "passed": None,
            "evidence": "Skipped (use --llm-grade to enable)",
        }
    return None


# ============================================================
# Metrics
# ============================================================

def compute_pass_at_k(results: list[bool], k: int) -> float:
    """Compute pass@k: probability of at least 1 success in k trials."""
    n = len(results)
    c = sum(results)
    if n < k:
        return float(c > 0)
    # Unbiased estimator
    if n - c < k:
        return 1.0
    return 1.0 - math.comb(n - c, k) / math.comb(n, k)


def compute_pass_pow_k(results: list[bool], k: int) -> float:
    """Compute pass^k: probability of all k trials succeeding."""
    n = len(results)
    if n == 0:
        return 0.0
    p = sum(results) / n
    return p ** k


# ============================================================
# Eval hashing
# ============================================================

def compute_eval_hash(eval_def: dict) -> str:
    """Compute a stable SHA-256 hash of an eval definition.

    Uses sorted keys to ensure key ordering does not affect the result.
    Returns a 64-character hex digest string.
    """
    serialized = json.dumps(eval_def, sort_keys=True)
    return hashlib.sha256(serialized.encode("utf-8")).hexdigest()


# ============================================================
# Reference solution verification
# ============================================================

def verify_reference_solution(eval_def: dict) -> tuple[bool, list[str]]:
    """Verify that the reference solution passes all deterministic assertions.

    Returns (passed, list_of_failure_messages).
    This is the integrity check: if the reference solution doesn't pass,
    either the assertions or the reference solution is wrong.
    """
    ref = eval_def.get("reference_solution")
    if not ref:
        return True, ["No reference_solution defined — skipped"]

    # If no workspace_files, skip workspace creation — no file-based assertions to verify
    if not eval_def.get("workspace_files"):
        return True, []

    # Create a temporary workspace with reference solution files applied
    ref_workspace = Path("/tmp/claude-bench-refcheck") / eval_def["id"]
    if ref_workspace.exists():
        shutil.rmtree(ref_workspace)
    ref_workspace.mkdir(parents=True)

    # Start with workspace_files, then overlay reference solution files
    for filename, content in eval_def.get("workspace_files", {}).items():
        filepath = ref_workspace / filename
        filepath.parent.mkdir(parents=True, exist_ok=True)
        filepath.write_text(content)
    for filename, content in ref.get("files", {}).items():
        filepath = ref_workspace / filename
        filepath.parent.mkdir(parents=True, exist_ok=True)
        filepath.write_text(content)

    # Build a fake trial for grading (only deterministic assertions need this)
    original_files = {}
    for fname, content in eval_def.get("workspace_files", {}).items():
        original_files[fname] = content
    fake_trial = {"_original_files": original_files, "tool_calls": []}

    # Behavioral assertions cannot be checked against a static reference solution.
    # bash_command_matches inspects tool_calls which are empty in the fake trial — skip it.
    # functional is NOT skipped: it runs its snippet at verify-refs time for self-validation.
    skippable_checks = {
        "tool_was_used", "tool_not_used", "tool_call_count",
        "tool_call_matches", "no_tool_call_matches",
        "output_contains", "output_not_contains", "output_does_not_contain",
        "last_tool_is", "text_before_tool",
        "bash_command_matches",
    }

    failures = []
    for assertion in eval_def.get("assertions", []):
        if assertion["type"] != "deterministic":
            continue
        if assertion.get("check", "") in skippable_checks:
            continue
        grade = grade_deterministic(assertion, fake_trial, ref_workspace)
        if not grade["passed"]:
            failures.append(f"  {assertion['id']}: {grade['evidence']}")

    # Cleanup
    shutil.rmtree(ref_workspace)

    if failures:
        return False, failures
    return True, []


# ============================================================
# Reference solution verification caching
# ============================================================

def load_refcheck_cache() -> dict:
    """Load refcheck cache from file. Returns empty dict if missing or corrupt."""
    try:
        if REFCHECK_CACHE_FILE.exists():
            return json.loads(REFCHECK_CACHE_FILE.read_text())
    except (json.JSONDecodeError, OSError):
        pass
    return {}


def save_refcheck_cache(cache: dict) -> None:
    """Write refcheck cache to file."""
    try:
        REFCHECK_CACHE_FILE.write_text(json.dumps(cache, indent=2))
    except OSError:
        pass


def verify_reference_solutions_cached(
    eval_defs: list[dict], force: bool = False
) -> tuple[bool, list[str]]:
    """Verify reference solutions with hash-based caching.

    Skips verification for evals whose hash matches the cached value.
    When force=True, ignores the cache and verifies all evals.

    Returns (all_ok, list_of_status_messages).
    """
    cache = {} if force else load_refcheck_cache()
    updated_cache = dict(cache)
    all_ok = True
    messages = []

    for eval_def in eval_defs:
        eval_id = eval_def["id"]
        current_hash = compute_eval_hash(eval_def)

        if not force and cache.get(eval_id) == current_hash:
            has_ref = eval_def.get("reference_solution") is not None
            label = "CACHED" if has_ref else "SKIP"
            msg = f"  {label:6s}  {eval_id}"
            messages.append(msg)
            print(msg)
            continue

        passed, failures = verify_reference_solution(eval_def)
        if not passed:
            all_ok = False
            msg = f"  FAIL    {eval_id}"
            messages.append(msg)
            print(msg)
            for f in failures:
                print(f"          {f}")
            # Do not cache failed verifications
            updated_cache.pop(eval_id, None)
        else:
            has_ref = eval_def.get("reference_solution") is not None
            label = "OK" if has_ref else "SKIP"
            msg = f"  {label:6s}  {eval_id}"
            messages.append(msg)
            print(msg)
            updated_cache[eval_id] = current_hash

    save_refcheck_cache(updated_cache)
    return all_ok, messages


# ============================================================
# Statistical testing
# ============================================================

def fisher_exact_test(passed_a: int, total_a: int, passed_b: int, total_b: int) -> float:
    """One-sided Fisher's exact test for regression (B worse than A).

    Returns p-value. Small p-value means B is significantly worse than A.
    Uses hypergeometric distribution via math.comb (no scipy needed).
    """
    # Build 2x2 contingency table:
    #              Pass    Fail
    #   Baseline:  a       b      (total_a)
    #   Current:   c       d      (total_b)
    a = passed_a
    b = total_a - passed_a
    c = passed_b
    d = total_b - passed_b
    n = a + b + c + d

    row1 = a + b  # baseline total
    row2 = c + d  # current total
    col1 = a + c  # total passed
    col2 = b + d  # total failed

    # P-value: sum of probabilities for all tables as extreme or more extreme
    # (where current has fewer passes)
    p_value = 0.0
    for x in range(0, c + 1):
        y = row2 - x  # current fails for this table
        aa = col1 - x  # baseline passes
        bb = row1 - aa  # baseline fails
        if aa < 0 or bb < 0 or y < 0:
            continue
        try:
            p = (math.comb(col1, x) * math.comb(col2, y)) / math.comb(n, row2)
            p_value += p
        except (ValueError, ZeroDivisionError):
            continue

    return p_value


def wilson_ci(passed: int, total: int, z: float = 1.96) -> tuple[float, float]:
    """Wilson score confidence interval for a binomial proportion.

    Returns (low, high) at the confidence level corresponding to z (default 95%).
    Handles total == 0 by returning (0.0, 1.0).
    """
    if total == 0:
        return (0.0, 1.0)
    p_hat = passed / total
    z2 = z * z
    n = total
    center = (p_hat + z2 / (2 * n)) / (1 + z2 / n)
    margin = z * math.sqrt((p_hat * (1 - p_hat) + z2 / (4 * n)) / n) / (1 + z2 / n)
    return (max(0.0, center - margin), min(1.0, center + margin))


# ============================================================
# Baseline comparison
# ============================================================

# ============================================================
# Run checkpoint (resume after interruption)
# ============================================================

# Fields in args that affect results — checkpoint is invalid if these differ.
# 'workers' is excluded because it only affects parallelism, not outcomes.
_CHECKPOINT_ARGS_KEYS = ("command", "llm_grade", "trials", "tag", "compare", "force_rerun")


def _extract_checkpoint_args(args) -> dict:
    """Extract result-affecting args from an argparse namespace."""
    return {k: getattr(args, k, None) for k in _CHECKPOINT_ARGS_KEYS}


def checkpoint_matches(checkpoint: dict, git_commit: str | None, args,
                       eval_ids: list[str] | None = None,
                       workflow_ids: list[str] | None = None) -> bool:
    """Check if a checkpoint is valid for the current run.

    Invalid when: git commit changed, result-affecting args differ,
    eval/workflow set changed, or already completed.
    """
    if checkpoint.get("status") == "completed":
        return False
    if checkpoint.get("git_commit") != git_commit:
        return False
    saved_args = checkpoint.get("args", {})
    current_args = _extract_checkpoint_args(args)
    if saved_args != current_args:
        return False
    if eval_ids is not None and checkpoint.get("eval_order") != eval_ids:
        return False
    if workflow_ids is not None and checkpoint.get("workflow_order") != workflow_ids:
        return False
    return True


def load_checkpoint(git_commit: str | None, args,
                    eval_ids: list[str] | None = None,
                    workflow_ids: list[str] | None = None) -> dict | None:
    """Load and validate a checkpoint. Returns None if missing, corrupt, or invalid."""
    try:
        if not CHECKPOINT_FILE.exists():
            return None
        checkpoint = json.loads(CHECKPOINT_FILE.read_text())
        if checkpoint_matches(checkpoint, git_commit, args, eval_ids, workflow_ids):
            return checkpoint
        return None
    except (json.JSONDecodeError, OSError):
        return None


def save_checkpoint(checkpoint: dict) -> None:
    """Atomically write checkpoint to disk (tmp + rename)."""
    tmp = CHECKPOINT_FILE.with_suffix(".tmp")
    try:
        tmp.write_text(json.dumps(checkpoint, indent=2, default=str))
        os.replace(str(tmp), str(CHECKPOINT_FILE))
    except OSError:
        pass


def complete_checkpoint(checkpoint: dict | None) -> None:
    """Mark checkpoint as completed and remove the file.

    Sets status to 'completed' before deletion so that if unlink fails,
    the stale checkpoint won't be incorrectly resumed.
    """
    if checkpoint is not None:
        checkpoint["status"] = "completed"
        save_checkpoint(checkpoint)
    try:
        if CHECKPOINT_FILE.exists():
            CHECKPOINT_FILE.unlink()
    except OSError:
        pass


def init_checkpoint(git_commit: str | None, args, eval_ids: list[str],
                    workflow_ids: list[str]) -> dict:
    """Create a fresh checkpoint for a new run."""
    from datetime import datetime
    checkpoint = {
        "run_id": f"{datetime.now().strftime('%Y-%m-%dT%H:%M:%S')}_{git_commit or 'unknown'}",
        "started_at": datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
        "git_commit": git_commit,
        "args": _extract_checkpoint_args(args),
        "completed_evals": {},
        "completed_workflows": {},
        "eval_order": eval_ids,
        "workflow_order": workflow_ids,
        "status": "in_progress",
    }
    save_checkpoint(checkpoint)
    return checkpoint


def compare_with_baseline(current: dict, baseline: dict) -> dict:
    """Compare current results with baseline."""
    comparisons = []

    # Compare single evals
    baseline_evals = {e["eval_id"]: e for e in baseline.get("evals", [])}
    for eval_result in current.get("evals", []):
        eval_id = eval_result["eval_id"]
        baseline_eval = baseline_evals.get(eval_id)

        if not baseline_eval:
            comparisons.append({
                "eval_id": eval_id,
                "status": "NEW",
                "detail": "No baseline exists for this eval",
            })
            continue

        delta_pass_at_1 = eval_result["pass_at_1"] - baseline_eval["pass_at_1"]
        delta_tokens = eval_result["avg_tokens"] - baseline_eval["avg_tokens"]

        baseline_passed = baseline_eval.get("trials_passed", round(baseline_eval["pass_at_1"] * baseline_eval["trials_run"]))
        baseline_total = baseline_eval["trials_run"]
        current_passed = eval_result.get("trials_passed", round(eval_result["pass_at_1"] * eval_result["trials_run"]))
        current_total = eval_result["trials_run"]

        min_trials_for_stats = 5
        baseline_ci = wilson_ci(baseline_passed, baseline_total)
        current_ci = wilson_ci(current_passed, current_total)
        p_value = None
        if baseline_total + current_total >= min_trials_for_stats:
            p_value = fisher_exact_test(baseline_passed, baseline_total, current_passed, current_total)
            # CI-overlap classification: non-overlap determines REGRESSED/IMPROVED
            if current_ci[0] > baseline_ci[1]:
                status = "IMPROVED"
            elif current_ci[1] < baseline_ci[0]:
                status = "REGRESSED"
            else:
                status = "STABLE"
        else:
            # Not enough data for CI-based test; fall back to |delta| > 0.34 threshold
            if abs(delta_pass_at_1) >= 0.34:
                status = "IMPROVED" if delta_pass_at_1 > 0 else "REGRESSED"
            else:
                status = "STABLE"

        entry = {
            "eval_id": eval_id,
            "status": status,
            "baseline_pass_at_1": baseline_eval["pass_at_1"],
            "current_pass_at_1": eval_result["pass_at_1"],
            "delta_pass_at_1": round(delta_pass_at_1, 3),
            "baseline_avg_tokens": baseline_eval["avg_tokens"],
            "current_avg_tokens": eval_result["avg_tokens"],
            "delta_tokens": round(delta_tokens),
            "baseline_ci": [round(baseline_ci[0], 4), round(baseline_ci[1], 4)],
            "current_ci": [round(current_ci[0], 4), round(current_ci[1], 4)],
        }
        if p_value is not None:
            entry["p_value"] = round(p_value, 4)
        comparisons.append(entry)

    # Compare workflow evals
    baseline_workflows = {e["eval_id"]: e for e in baseline.get("workflow_evals", [])}
    for wf_result in current.get("workflow_evals", []):
        eval_id = wf_result["eval_id"]
        baseline_wf = baseline_workflows.get(eval_id)

        if not baseline_wf:
            comparisons.append({
                "eval_id": eval_id,
                "status": "NEW",
                "detail": "No baseline exists for this workflow eval",
            })
            continue

        delta_pass_at_1 = wf_result["pass_at_1"] - baseline_wf["pass_at_1"]
        delta_tokens = wf_result["avg_tokens"] - baseline_wf["avg_tokens"]

        baseline_passed = baseline_wf.get("trials_passed", round(baseline_wf["pass_at_1"] * baseline_wf["trials_run"]))
        baseline_total = baseline_wf["trials_run"]
        current_passed = wf_result.get("trials_passed", round(wf_result["pass_at_1"] * wf_result["trials_run"]))
        current_total = wf_result["trials_run"]

        min_trials_for_stats = 5
        baseline_ci = wilson_ci(baseline_passed, baseline_total)
        current_ci = wilson_ci(current_passed, current_total)
        p_value = None
        if baseline_total + current_total >= min_trials_for_stats:
            p_value = fisher_exact_test(baseline_passed, baseline_total, current_passed, current_total)
            # CI-overlap classification: non-overlap determines REGRESSED/IMPROVED
            if current_ci[0] > baseline_ci[1]:
                status = "IMPROVED"
            elif current_ci[1] < baseline_ci[0]:
                status = "REGRESSED"
            else:
                status = "STABLE"
        else:
            # Not enough data for CI-based test; fall back to |delta| > 0.34 threshold
            if abs(delta_pass_at_1) >= 0.34:
                status = "IMPROVED" if delta_pass_at_1 > 0 else "REGRESSED"
            else:
                status = "STABLE"

        entry = {
            "eval_id": eval_id,
            "status": status,
            "baseline_pass_at_1": baseline_wf["pass_at_1"],
            "current_pass_at_1": wf_result["pass_at_1"],
            "delta_pass_at_1": round(delta_pass_at_1, 3),
            "baseline_avg_tokens": baseline_wf["avg_tokens"],
            "current_avg_tokens": wf_result["avg_tokens"],
            "delta_tokens": round(delta_tokens),
            "baseline_ci": [round(baseline_ci[0], 4), round(baseline_ci[1], 4)],
            "current_ci": [round(current_ci[0], 4), round(current_ci[1], 4)],
        }
        if p_value is not None:
            entry["p_value"] = round(p_value, 4)
        comparisons.append(entry)

    return {"comparisons": comparisons}
