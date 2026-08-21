#!/usr/bin/env python3
"""Bounded GitHub Models coding loop for the Vyper parity experiment.

This script is intentionally repository-local and auditable. It exposes a small set
of filesystem and command tools to a model, keeps all writes inside the checkout,
and records the complete interaction under reports/vyper/model-agent/.
"""

from __future__ import annotations

import json
import os
import shlex
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
REPORT_DIR = ROOT / "reports" / "vyper" / "model-agent"
REPORT_DIR.mkdir(parents=True, exist_ok=True)
TOKEN = os.environ.get("GITHUB_TOKEN", "")
if not TOKEN:
    raise SystemExit("GITHUB_TOKEN is required")

MAX_STEPS = int(os.environ.get("VYPER_AGENT_MAX_STEPS", "140"))
COMMAND_TIMEOUT = int(os.environ.get("VYPER_AGENT_COMMAND_TIMEOUT", "600"))
MAX_TOOL_OUTPUT = 28_000

SYSTEM = r"""
You are a senior EVM compiler engineer operating directly in ensdomains/contracts-v2.
Your task is a real parity experiment, not a design document.

Baseline: a971bd6449154045e2b26ff13d0e56027452f407.
Branch: experiment/vyper-a971bd6.

Finish the next largest coherent tranche of the full Solidity-to-Vyper rewrite under
contracts/src. Preserve original Solidity for side-by-side benchmarks. Inspect all
existing contracts/vyper and contracts/test/vyper work first and rerun it rather than
assuming previous prose claims are true.

This run's priority is the registry core:
- ERC1155Singleton behavior required by the registries;
- PermissionedRegistry;
- UserRegistry and exact UUPS/storage behavior;
- WrapperRegistry, including NameWrapper receiver/migration behavior, virtual-owner EAC,
  fuse restrictions, approval handling, resolver fallback, and EIP-170 runtime size.
If that cluster is already genuinely green, continue immediately into the resolver
cluster rather than stopping early.

Non-negotiable rules:
1. Use Vyper 0.5.0a3 where abstract modules and compile-time overrides reduce duplication.
   Existing stable-0.4.3 green contracts may stay on 0.4.3 unless migration is necessary.
2. No stubs, delegatecalls to the original Solidity implementation, test-only behavior,
   or skipped assertions. A Vyper contract must contain the production logic.
3. Copy existing Forge tests and alter only deployment/artifact wiring. Keep assertions,
   fuzzing, events, errors and scenarios intact. Run all applicable copied tests.
4. Preserve function selectors, tuple layouts, event topics, exact custom-error bytes,
   callback and revert bubbling semantics, ERC165 IDs, proxy slots and UUPS authorization.
5. Check runtime bytecode against EIP-170. Do not call a >24,576-byte implementation done.
6. Commit every coherent green tranche locally. Do not rewrite or delete prior green work.
7. Keep reports/vyper/model-agent/status.md current with exact commands and pass/fail counts.
8. Work through compiler/test failures. Do not exit merely because the first build fails.

Available tooling:
- Foundry and Bun are installed by the workflow.
- Vyper 0.5.0a3 is available as `python -m vyper`.
- The checkout includes recursive submodules and dependencies.

Use tools aggressively to inspect source/tests and run focused tests. Finish with a local
commit and a precise status report. Do not claim anything that was not rerun in this checkout.
"""

TOOLS: list[dict[str, Any]] = [
    {
        "type": "function",
        "function": {
            "name": "list_files",
            "description": "List files under a repository-relative directory.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string"},
                    "max_depth": {"type": "integer", "minimum": 0, "maximum": 8},
                },
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "read_file",
            "description": "Read a line range from a repository-relative UTF-8 file.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string"},
                    "start_line": {"type": "integer", "minimum": 1},
                    "end_line": {"type": "integer", "minimum": 1},
                },
                "required": ["path"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "search_text",
            "description": "Search repository text with ripgrep.",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {"type": "string"},
                    "path": {"type": "string"},
                    "glob": {"type": "string"},
                },
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "write_file",
            "description": "Create or completely replace a repository-relative UTF-8 file.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string"},
                    "content": {"type": "string"},
                },
                "required": ["path", "content"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "apply_patch",
            "description": "Apply a unified diff from the repository root using git apply.",
            "parameters": {
                "type": "object",
                "properties": {"patch": {"type": "string"}},
                "required": ["patch"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "run_command",
            "description": "Run a shell command from the repository root. Use focused bounded commands.",
            "parameters": {
                "type": "object",
                "properties": {
                    "command": {"type": "string"},
                    "timeout": {"type": "integer", "minimum": 1, "maximum": 1200},
                },
                "required": ["command"],
            },
        },
    },
]


def safe_path(raw: str) -> Path:
    path = (ROOT / raw).resolve()
    if path != ROOT and ROOT not in path.parents:
        raise ValueError(f"path escapes repository: {raw}")
    return path


def limit(value: str) -> str:
    if len(value) <= MAX_TOOL_OUTPUT:
        return value
    half = MAX_TOOL_OUTPUT // 2
    return value[:half] + "\n... <tool output truncated> ...\n" + value[-half:]


def run_tool(name: str, args: dict[str, Any]) -> str:
    try:
        if name == "list_files":
            base = safe_path(args["path"])
            depth = int(args.get("max_depth", 3))
            if not base.exists():
                return "NOT FOUND"
            lines: list[str] = []
            base_parts = len(base.parts)
            for item in sorted(base.rglob("*")):
                if len(item.parts) - base_parts > depth:
                    continue
                rel = item.relative_to(ROOT)
                suffix = "/" if item.is_dir() else ""
                lines.append(str(rel) + suffix)
                if len(lines) >= 1500:
                    lines.append("... listing capped ...")
                    break
            return limit("\n".join(lines))

        if name == "read_file":
            path = safe_path(args["path"])
            text = path.read_text(encoding="utf-8")
            lines = text.splitlines()
            start = max(1, int(args.get("start_line", 1)))
            end = min(len(lines), int(args.get("end_line", start + 500)))
            body = "\n".join(f"{idx}: {lines[idx - 1]}" for idx in range(start, end + 1))
            return limit(body)

        if name == "search_text":
            query = str(args["query"])
            path = str(args.get("path", "."))
            glob = args.get("glob")
            command = ["rg", "-n", "--hidden", "--glob", "!.git/**"]
            if glob:
                command += ["--glob", str(glob)]
            command += [query, path]
            proc = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, timeout=90)
            return limit(f"exit={proc.returncode}\n{proc.stdout}{proc.stderr}")

        if name == "write_file":
            path = safe_path(args["path"])
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(str(args["content"]), encoding="utf-8")
            return f"wrote {path.relative_to(ROOT)} ({path.stat().st_size} bytes)"

        if name == "apply_patch":
            patch_file = REPORT_DIR / "pending.patch"
            patch_file.write_text(str(args["patch"]), encoding="utf-8")
            proc = subprocess.run(
                ["git", "apply", "--whitespace=nowarn", str(patch_file)],
                cwd=ROOT,
                text=True,
                capture_output=True,
                timeout=120,
            )
            return limit(f"exit={proc.returncode}\n{proc.stdout}{proc.stderr}")

        if name == "run_command":
            timeout = min(int(args.get("timeout", COMMAND_TIMEOUT)), 1200)
            command = str(args["command"])
            proc = subprocess.run(
                ["bash", "-lc", command],
                cwd=ROOT,
                text=True,
                capture_output=True,
                timeout=timeout,
                env={**os.environ, "PYTHONUNBUFFERED": "1"},
            )
            return limit(f"exit={proc.returncode}\nSTDOUT:\n{proc.stdout}\nSTDERR:\n{proc.stderr}")

        return f"unknown tool: {name}"
    except subprocess.TimeoutExpired as exc:
        out = (exc.stdout or "") + (exc.stderr or "")
        return limit(f"TIMEOUT\n{out}")
    except Exception as exc:  # noqa: BLE001 - tool errors belong in the transcript
        return f"ERROR {type(exc).__name__}: {exc}"


def request_json(url: str, payload: dict[str, Any] | None = None) -> Any:
    data = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "Authorization": f"Bearer {TOKEN}",
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": "ens-vyper-parity-agent",
        },
        method="GET" if payload is None else "POST",
    )
    last: Exception | None = None
    for attempt in range(6):
        try:
            with urllib.request.urlopen(req, timeout=180) as response:
                return json.loads(response.read())
        except urllib.error.HTTPError as exc:
            last = exc
            body = exc.read().decode(errors="replace")
            if exc.code in {408, 429, 500, 502, 503, 504}:
                time.sleep(min(2**attempt, 30))
                continue
            raise RuntimeError(f"HTTP {exc.code}: {body}") from exc
        except Exception as exc:  # noqa: BLE001
            last = exc
            time.sleep(min(2**attempt, 30))
    raise RuntimeError(f"request failed: {last}")


def choose_models() -> list[str]:
    preferred = [
        "openai/gpt-5.1-codex-max",
        "openai/gpt-5.1-codex",
        "openai/gpt-5",
        "anthropic/claude-sonnet-4.5",
        "anthropic/claude-sonnet-4",
        "openai/gpt-4.1",
    ]
    try:
        catalog = request_json("https://models.github.ai/catalog/models")
        ids = {entry.get("id") for entry in catalog if isinstance(entry, dict)}
        selected = [model for model in preferred if model in ids]
        # Add any unanticipated code-specialized frontier model.
        for model in sorted(ids):
            low = str(model).lower()
            if model and ("codex" in low or "sonnet" in low or "gpt-5" in low) and model not in selected:
                selected.append(str(model))
        if selected:
            return selected
    except Exception as exc:  # noqa: BLE001
        (REPORT_DIR / "catalog-error.txt").write_text(str(exc), encoding="utf-8")
    return preferred


def normalize_message(message: dict[str, Any]) -> dict[str, Any]:
    result: dict[str, Any] = {"role": message.get("role", "assistant")}
    if message.get("content") is not None:
        result["content"] = message.get("content")
    if message.get("tool_calls"):
        result["tool_calls"] = message["tool_calls"]
    return result


def main() -> int:
    models = choose_models()
    messages: list[dict[str, Any]] = [
        {"role": "system", "content": SYSTEM},
        {
            "role": "user",
            "content": (
                "Begin by inventorying contracts/src, contracts/vyper, test/vyper and git history. "
                "Rerun existing focused tests, then implement the registry tranche to green. "
                "Use tools rather than describing hypothetical edits."
            ),
        },
    ]
    transcript = REPORT_DIR / "transcript.jsonl"
    chosen: str | None = None

    for step in range(MAX_STEPS):
        payload_base = {
            "messages": messages,
            "tools": TOOLS,
            "tool_choice": "auto",
            "temperature": 0.1,
            "max_tokens": 16_384,
        }
        response: dict[str, Any] | None = None
        errors: list[str] = []
        for model in ([chosen] if chosen else models):
            if not model:
                continue
            try:
                response = request_json(
                    "https://models.github.ai/inference/chat/completions",
                    {**payload_base, "model": model},
                )
                chosen = model
                break
            except Exception as exc:  # noqa: BLE001
                errors.append(f"{model}: {exc}")
        if response is None:
            (REPORT_DIR / "fatal-model-errors.txt").write_text("\n".join(errors), encoding="utf-8")
            return 2

        choice = response["choices"][0]
        message = normalize_message(choice["message"])
        messages.append(message)
        with transcript.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps({"step": step, "model": chosen, "message": message}) + "\n")

        tool_calls = message.get("tool_calls") or []
        if not tool_calls:
            final = str(message.get("content") or "")
            (REPORT_DIR / "final-response.md").write_text(final, encoding="utf-8")
            # Give the model one chance to continue if it stopped at analysis without a commit/status.
            status = ROOT / "reports" / "vyper" / "model-agent" / "status.md"
            dirty = subprocess.run(["git", "status", "--porcelain"], cwd=ROOT, text=True, capture_output=True).stdout
            if step + 1 < MAX_STEPS and (not status.exists() or dirty):
                messages.append(
                    {
                        "role": "user",
                        "content": (
                            "Do not stop at a prose checkpoint. There are uncommitted changes or no verified status report. "
                            "Continue using tools until the tranche is tested and committed."
                        ),
                    }
                )
                continue
            break

        for call in tool_calls:
            fn = call.get("function", {})
            name = fn.get("name", "")
            try:
                args = json.loads(fn.get("arguments") or "{}")
            except json.JSONDecodeError as exc:
                result = f"invalid JSON arguments: {exc}"
            else:
                result = run_tool(name, args)
            tool_message = {
                "role": "tool",
                "tool_call_id": call.get("id", ""),
                "content": result,
            }
            messages.append(tool_message)
            with transcript.open("a", encoding="utf-8") as handle:
                handle.write(json.dumps({"step": step, "tool": name, "result": result}) + "\n")

        # Keep context bounded while retaining the system prompt, initial task and recent work.
        if len(messages) > 150:
            messages = messages[:2] + [
                {
                    "role": "user",
                    "content": (
                        "Context was compacted. Inspect git diff/status and reports/vyper/model-agent/transcript.jsonl "
                        "for prior work. Continue the same registry parity tranche; do not redo green work."
                    ),
                }
            ] + messages[-100:]

    (REPORT_DIR / "model.txt").write_text(chosen or "none", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
