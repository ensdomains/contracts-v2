#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import re
import shlex
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
CONTRACTS = ROOT / "contracts"
REPORT = ROOT / "reports" / "vyper" / "final-agent"
FINAL = ROOT / "reports" / "vyper" / "final"
REPORT.mkdir(parents=True, exist_ok=True)
FINAL.mkdir(parents=True, exist_ok=True)
TOKEN = os.environ["GITHUB_MODELS_TOKEN"]
ENDPOINT = "https://models.github.ai/inference/chat/completions"
PREFERRED_MODELS = [
    os.environ.get("VYPER_AGENT_MODEL", "openai/gpt-5.6-codex"),
    "openai/gpt-5.5-codex",
    "openai/gpt-5.4",
    "openai/gpt-5",
    "anthropic/claude-opus-4.1",
]
MAX_TOOL_OUTPUT = 30000

SYSTEM = """You are the sole senior protocol engineer responsible for completing a real Solidity-to-Vyper rewrite of ENS contracts-v2. Work directly in the checkout. Do not merely plan, report, or create placeholders. Keep iterating through code, compilation, original tests, integration wiring, gas measurement, and repair until the strict completion gate passes.

Baseline commit: a971bd6449154045e2b26ff13d0e56027452f407.
Compiler target: Vyper 0.5.0a3, Cancun.

Non-negotiable requirements:
1. Every executable contract or library implementation under contracts/src must have a genuine Vyper counterpart recorded in contracts/vyper/port-manifest.json. Interfaces may remain Solidity test interfaces, but production behavior may not delegate, proxy, or fall through to the original Solidity implementation.
2. Preserve external ABI, selectors, custom-error payloads, event topics/order, storage and proxy compatibility, access control, revert behavior, receiver callbacks, and important gas/size constraints.
3. Reuse the repository's pre-existing tests. Create Vyper-wired copies/adapters only to replace deployment with Vyper artifacts; do not weaken assertions. A run saying “No tests found” is failure, not success.
4. Run focused original Forge suites while implementing. Then run a full Vyper-wired Forge suite with a nonzero test count, Hardhat integration against Vyper artifacts, and E2E against a Vyper deployment.
5. Produce paired equivalent-state Solidity/Vyper measurements in reports/vyper/final/gas.csv, gas.json, gas.md and bytecode-sizes.csv/md. Enforce EIP-170 for every deployable runtime.
6. Remove stale generated pyc files and misleading completion-agent evidence. Keep useful source/test/report files.
7. Only write exactly COMPLETE to reports/vyper/final/FINAL_STATUS after every gate genuinely passes. Otherwise leave it INCOMPLETE and continue working.

Use tools aggressively. Read the existing code and tests before implementing. Favor composable Vyper modules and exact raw ABI/error encoding where required. Never substitute a superficial stub for semantics. Work for the entire available job, committing no final claim until verified."""

TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "read_file",
            "description": "Read a UTF-8 file with optional 1-based line range.",
            "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "start": {"type": "integer"}, "end": {"type": "integer"}}, "required": ["path"]},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "write_file",
            "description": "Create or completely replace a UTF-8 file. Parent directories are created.",
            "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "content": {"type": "string"}}, "required": ["path", "content"]},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "list_files",
            "description": "List files matching a glob relative to the repository.",
            "parameters": {"type": "object", "properties": {"pattern": {"type": "string"}}, "required": ["pattern"]},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "grep",
            "description": "Search repository text with ripgrep. Query is a regex; optional glob filters files.",
            "parameters": {"type": "object", "properties": {"query": {"type": "string"}, "glob": {"type": "string"}}, "required": ["query"]},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "run_command",
            "description": "Run a shell command in the repository. Use this for compilation, tests, scripts, diffs, and file transformations. Timeout is capped at 1200 seconds.",
            "parameters": {"type": "object", "properties": {"command": {"type": "string"}, "timeout": {"type": "integer"}}, "required": ["command"]},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "completion_audit",
            "description": "Run and persist the strict source/manifest/compile/test/report audit, returning current blockers.",
            "parameters": {"type": "object", "properties": {}},
        },
    },
]


def safe_path(raw: str) -> Path:
    p = (ROOT / raw).resolve()
    if p != ROOT and ROOT not in p.parents:
        raise ValueError("path escapes repository")
    return p


def trim(text: str, limit: int = MAX_TOOL_OUTPUT) -> str:
    if len(text) <= limit:
        return text
    half = limit // 2
    return text[:half] + f"\n... <truncated {len(text)-limit} chars> ...\n" + text[-half:]


def run(command: str, timeout: int = 300) -> dict[str, Any]:
    timeout = max(1, min(timeout, 1200))
    started = time.time()
    try:
        p = subprocess.run(["bash", "-lc", command], cwd=ROOT, text=True, capture_output=True, timeout=timeout)
        return {"rc": p.returncode, "seconds": round(time.time() - started, 2), "stdout": trim(p.stdout), "stderr": trim(p.stderr)}
    except subprocess.TimeoutExpired as e:
        return {"rc": 124, "seconds": round(time.time() - started, 2), "stdout": trim(e.stdout or ""), "stderr": trim((e.stderr or "") + f"\nTIMEOUT after {timeout}s")}


def implementation_sources() -> list[dict[str, Any]]:
    roots: list[dict[str, Any]] = []
    for p in sorted((CONTRACTS / "src").rglob("*.sol")):
        text = p.read_text(errors="replace")
        decls = re.findall(r"(?m)^\s*(?:abstract\s+)?(contract|library)\s+([A-Za-z_]\w*)", text)
        if decls:
            roots.append({"source": p.relative_to(CONTRACTS / "src").as_posix(), "declarations": [name for _, name in decls]})
    return roots


def audit() -> dict[str, Any]:
    roots = implementation_sources()
    vyper_root = CONTRACTS / "vyper"
    manifest_path = vyper_root / "port-manifest.json"
    manifest_entries: list[dict[str, Any]] = []
    manifest_error = None
    if manifest_path.exists():
        try:
            raw = json.loads(manifest_path.read_text())
            manifest_entries = raw.get("ports", raw if isinstance(raw, list) else [])
        except Exception as exc:
            manifest_error = repr(exc)
    by_source = {x.get("source"): x for x in manifest_entries if isinstance(x, dict) and x.get("source")}
    missing = []
    invalid = []
    mapped = []
    for root in roots:
        entry = by_source.get(root["source"])
        if not entry:
            missing.append(root)
            continue
        paths = entry.get("vyper_files", entry.get("vyper", []))
        if isinstance(paths, str):
            paths = [paths]
        resolved = []
        for raw_path in paths:
            p = safe_path(raw_path if raw_path.startswith("contracts/") else f"contracts/{raw_path}")
            resolved.append(p)
        if not resolved or not all(p.exists() for p in resolved):
            invalid.append({"source": root["source"], "entry": entry, "missing_files": [str(p.relative_to(ROOT)) for p in resolved if not p.exists()]})
        else:
            mapped.append({"source": root["source"], "entry": entry})

    concrete = []
    for p in sorted(vyper_root.rglob("*.vy")):
        rel = p.relative_to(ROOT).as_posix()
        text = p.read_text(errors="replace")
        if "/test/" in rel or "@abstract" in text and not re.search(r"@override\(", text):
            continue
        concrete.append(rel)

    compile_failures = []
    size_failures = []
    for rel in concrete:
        result = run(f"python -m vyper --evm-version cancun -O gas -p contracts/vyper -f bytecode_runtime {shlex.quote(rel)}", 120)
        if result["rc"] != 0:
            compile_failures.append({"file": rel, "error": trim(result["stderr"] + result["stdout"], 4000)})
            continue
        hexcode = result["stdout"].strip().splitlines()[-1].removeprefix("0x") if result["stdout"].strip() else ""
        if hexcode and len(hexcode) // 2 > 24576:
            size_failures.append({"file": rel, "runtime_bytes": len(hexcode) // 2})

    test_files = sorted((CONTRACTS / "test" / "vyper").rglob("*.t.sol")) if (CONTRACTS / "test" / "vyper").exists() else []
    gas_required = [FINAL / "gas.csv", FINAL / "gas.json", FINAL / "gas.md", FINAL / "bytecode-sizes.csv", FINAL / "bytecode-sizes.md"]
    report = {
        "baseline": "a971bd6449154045e2b26ff13d0e56027452f407",
        "implementation_roots": len(roots),
        "manifest_entries": len(manifest_entries),
        "mapped": len(mapped),
        "missing": missing,
        "invalid": invalid,
        "manifest_error": manifest_error,
        "vyper_files": len(list(vyper_root.rglob("*.vy"))) if vyper_root.exists() else 0,
        "concrete_compile_failures": compile_failures,
        "eip170_failures": size_failures,
        "vyper_test_files": [x.relative_to(ROOT).as_posix() for x in test_files],
        "missing_reports": [x.relative_to(ROOT).as_posix() for x in gas_required if not x.exists() or x.stat().st_size == 0],
        "final_status": (FINAL / "FINAL_STATUS").read_text().strip() if (FINAL / "FINAL_STATUS").exists() else None,
    }
    (REPORT / "audit.json").write_text(json.dumps(report, indent=2) + "\n")
    md = ["# Strict Vyper completion audit", "", f"- Implementation roots: **{len(roots)}**", f"- Manifest mapped: **{len(mapped)}**", f"- Missing: **{len(missing)}**", f"- Invalid mappings: **{len(invalid)}**", f"- Concrete compile failures: **{len(compile_failures)}**", f"- EIP-170 failures: **{len(size_failures)}**", f"- Vyper-wired Forge files: **{len(test_files)}**", f"- Missing reports: **{len(report['missing_reports'])}**", f"- FINAL_STATUS: **{report['final_status']}**", "", "## Missing roots"]
    md += [f"- `{x['source']}` ({', '.join(x['declarations'])})" for x in missing]
    md += ["", "## Compile failures"] + [f"- `{x['file']}`" for x in compile_failures]
    (REPORT / "audit.md").write_text("\n".join(md) + "\n")
    return report


def tool_call(name: str, args: dict[str, Any]) -> str:
    try:
        if name == "read_file":
            p = safe_path(args["path"])
            lines = p.read_text(errors="replace").splitlines()
            start = max(1, int(args.get("start", 1)))
            end = min(len(lines), int(args.get("end", len(lines))))
            return trim("\n".join(f"{i+1}: {lines[i]}" for i in range(start - 1, end)))
        if name == "write_file":
            p = safe_path(args["path"])
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(args["content"])
            return f"wrote {p.relative_to(ROOT)} ({len(args['content'])} chars)"
        if name == "list_files":
            paths = sorted(ROOT.glob(args["pattern"]))
            return trim("\n".join(str(p.relative_to(ROOT)) for p in paths[:3000]))
        if name == "grep":
            glob_arg = f" -g {shlex.quote(args['glob'])}" if args.get("glob") else ""
            return json.dumps(run(f"rg -n --hidden --glob '!node_modules/**' --glob '!.git/**'{glob_arg} -- {shlex.quote(args['query'])} .", 120))
        if name == "run_command":
            return json.dumps(run(args["command"], int(args.get("timeout", 300))))
        if name == "completion_audit":
            return trim(json.dumps(audit(), indent=2))
        return f"unknown tool {name}"
    except Exception as exc:
        return f"TOOL ERROR {type(exc).__name__}: {exc}"


def request_model(model: str, messages: list[dict[str, Any]]) -> dict[str, Any]:
    body = json.dumps({"model": model, "messages": messages, "tools": TOOLS, "tool_choice": "auto", "temperature": 0.1, "max_tokens": 16000}).encode()
    req = urllib.request.Request(ENDPOINT, data=body, headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json", "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=180) as response:
        return json.loads(response.read())


def pick_model(messages: list[dict[str, Any]]) -> tuple[str, dict[str, Any]]:
    errors = []
    for model in dict.fromkeys(PREFERRED_MODELS):
        try:
            return model, request_model(model, messages)
        except Exception as exc:
            errors.append(f"{model}: {exc}")
    raise RuntimeError("all models failed: " + " | ".join(errors))


def compact(messages: list[dict[str, Any]]) -> list[dict[str, Any]]:
    # Preserve system, initial task, and the latest tool-driven context. The checkout is canonical memory.
    if len(messages) < 100:
        return messages
    return [messages[0], messages[1], {"role": "user", "content": "Continue from the current checkout. Re-read reports/vyper/final-agent/audit.md, git diff, and recent test logs; the repository is canonical. Keep implementing and testing until COMPLETE."}] + messages[-36:]


def main() -> None:
    (FINAL / "FINAL_STATUS").write_text("INCOMPLETE\n")
    initial_audit = audit()
    messages: list[dict[str, Any]] = [
        {"role": "system", "content": SYSTEM},
        {"role": "user", "content": "Begin now. Inspect the current candidate port, original Solidity sources, and existing tests. The strict initial audit is:\n" + trim(json.dumps(initial_audit, indent=2), 18000)},
    ]
    chosen_model = None
    transcript = REPORT / "transcript.jsonl"
    for iteration in range(1, 301):
        messages = compact(messages)
        try:
            if chosen_model is None:
                chosen_model, data = pick_model(messages)
                (REPORT / "model.txt").write_text(chosen_model + "\n")
            else:
                data = request_model(chosen_model, messages)
        except Exception as exc:
            (REPORT / "fatal-model-error.txt").write_text(repr(exc) + "\n")
            break
        choice = data["choices"][0]
        msg = choice["message"]
        messages.append(msg)
        with transcript.open("a") as fh:
            fh.write(json.dumps({"iteration": iteration, "message": msg}) + "\n")
        calls = msg.get("tool_calls") or []
        if calls:
            for call in calls:
                name = call["function"]["name"]
                try:
                    args = json.loads(call["function"].get("arguments") or "{}")
                except json.JSONDecodeError as exc:
                    result = f"invalid tool JSON: {exc}"
                else:
                    result = tool_call(name, args)
                messages.append({"role": "tool", "tool_call_id": call["id"], "content": result})
        else:
            current = audit()
            complete = (
                not current["missing"] and not current["invalid"] and not current["concrete_compile_failures"]
                and not current["eip170_failures"] and current["vyper_test_files"] and not current["missing_reports"]
                and current["final_status"] == "COMPLETE"
            )
            if complete:
                break
            messages.append({"role": "user", "content": "The strict gate still does not pass. Do not stop or summarize. Run completion_audit, inspect blockers and test logs, then continue implementing and repairing the port."})
        if iteration % 12 == 0:
            current = audit()
            messages.append({"role": "user", "content": "Periodic strict audit:\n" + trim(json.dumps(current, indent=2), 16000) + "\nContinue with code and tests."})
    final_audit = audit()
    (REPORT / "final-audit.json").write_text(json.dumps(final_audit, indent=2) + "\n")
    # Fail closed: a model-written COMPLETE is reset unless structural gates pass.
    structural = (
        not final_audit["missing"] and not final_audit["invalid"] and not final_audit["concrete_compile_failures"]
        and not final_audit["eip170_failures"] and bool(final_audit["vyper_test_files"]) and not final_audit["missing_reports"]
    )
    if not structural:
        (FINAL / "FINAL_STATUS").write_text("INCOMPLETE\n")


if __name__ == "__main__":
    main()
