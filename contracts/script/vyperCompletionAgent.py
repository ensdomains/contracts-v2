#!/usr/bin/env python3
"""Strict, bounded model-assisted completion loop for the ENSv2 Vyper experiment.

The loop never treats prose checkpoints as evidence. After each coding cycle it runs
its own compiler/test/inventory/benchmark gate, writes machine-readable results, and
feeds exact failures back into the next cycle. All work remains in the checkout until
the workflow performs one final serialized push.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
CONTRACTS = ROOT / "contracts"
REPORT = ROOT / "reports" / "vyper" / "completion"
REPORT.mkdir(parents=True, exist_ok=True)
TOKEN = os.environ.get("GITHUB_TOKEN", "")
if not TOKEN:
    raise SystemExit("GITHUB_TOKEN is required")

MAX_ROUNDS = int(os.environ.get("VYPER_COMPLETION_ROUNDS", "4"))
MAX_STEPS = int(os.environ.get("VYPER_COMPLETION_STEPS", "150"))
TOOL_TIMEOUT = int(os.environ.get("VYPER_COMPLETION_TOOL_TIMEOUT", "900"))
MAX_OUTPUT = 36_000

BASELINE = "a971bd6449154045e2b26ff13d0e56027452f407"
BRANCH = "experiment/vyper-a971bd6"

SYSTEM = r"""
You are the implementation owner for a real ENSv2 compiler parity experiment in
ensdomains/contracts-v2. Work directly in the checkout. The exact Solidity baseline is
a971bd6449154045e2b26ff13d0e56027452f407 and the experiment branch is
experiment/vyper-a971bd6.

The user requested ALL executable Solidity contracts and libraries under contracts/src
be rewritten in Vyper, the pre-existing test corpus reused without weakened assertions,
and controlled Solidity-vs-Vyper gas and bytecode comparisons. Finish the implementation;
do not produce another project plan or prose-only checkpoint.

Ground rules:
- Treat prior assistant prose and status files as untrusted. Source, compiler output,
  receipts and test logs are evidence.
- Inspect current branch work first. Preserve and rerun genuinely green tranches.
- Use Vyper 0.5.0a3 for abstract modules, overrides and custom errors where useful.
  Existing verified 0.4.3 files may remain if they compile and pass parity tests.
- Vyper contracts must contain production logic. No stubs, unconditional success,
  delegation to the original Solidity implementation, test-address branches, skipped
  assertions or reduced fuzz coverage.
- Copy existing tests and change only deployment/artifact wiring. Preserve scenarios,
  assertions, fuzzing, exact custom-error bytes, events/topics, callback/revert bubbling,
  ERC165 IDs, storage layout, proxy slots, UUPS authorization and deterministic addresses.
- Every deployable implementation must be <=24,576 runtime bytes. If Solidity inheritance
  produces a size problem, use compile-time Vyper modules or a defensible production
  architecture, not a test shim.
- Run focused tests while editing. Commit coherent green tranches locally. Never push,
  rewrite history, delete prior green work, or touch the baseline branch.
- Complete the deployment graph and run copied Forge, Hardhat integration and E2E suites.
- Build reports/vyper/gas-comparison.csv, .json and .md from identical state/caller/
  calldata/value scenarios. Include deployment gas, runtime bytes, call gas, absolute and
  percentage deltas, compiler versions and raw receipt references.
- Read reports/vyper/completion/audit.json and the named logs on every repair round.
  Resolve all actionable failures. Do not declare completion unless audit.complete=true.

Prioritize based on actual failures, not a fixed cluster order. Use tools continuously.
"""

TOOLS: list[dict[str, Any]] = [
    {"type": "function", "function": {"name": "list_files", "description": "List repository-relative files.", "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "max_depth": {"type": "integer", "minimum": 0, "maximum": 10}}, "required": ["path"]}}},
    {"type": "function", "function": {"name": "read_file", "description": "Read a line range from a UTF-8 repository file.", "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "start_line": {"type": "integer", "minimum": 1}, "end_line": {"type": "integer", "minimum": 1}}, "required": ["path"]}}},
    {"type": "function", "function": {"name": "search_text", "description": "Search repository text with ripgrep.", "parameters": {"type": "object", "properties": {"query": {"type": "string"}, "path": {"type": "string"}, "glob": {"type": "string"}}, "required": ["query"]}}},
    {"type": "function", "function": {"name": "write_file", "description": "Create or replace a repository-relative UTF-8 file.", "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "content": {"type": "string"}}, "required": ["path", "content"]}}},
    {"type": "function", "function": {"name": "apply_patch", "description": "Apply a unified diff from repository root.", "parameters": {"type": "object", "properties": {"patch": {"type": "string"}}, "required": ["patch"]}}},
    {"type": "function", "function": {"name": "run_command", "description": "Run a bounded shell command from repository root.", "parameters": {"type": "object", "properties": {"command": {"type": "string"}, "timeout": {"type": "integer", "minimum": 1, "maximum": 1200}}, "required": ["command"]}}},
]


@dataclass
class AuditResult:
    timestamp: int
    baseline: str
    head: str
    source_executables: int
    vyper_sources: int
    missing_ports: list[str]
    compile_rc: int
    compile_failures: list[str]
    forge_rc: int
    hardhat_rc: int
    e2e_rc: int
    gas_csv_ok: bool
    gas_json_ok: bool
    gas_md_ok: bool
    eip170_failures: list[str]
    forbidden_patterns: list[str]
    complete: bool


def safe_path(raw: str) -> Path:
    p = (ROOT / raw).resolve()
    if p != ROOT and ROOT not in p.parents:
        raise ValueError(f"path escapes checkout: {raw}")
    return p


def cap(text: str, n: int = MAX_OUTPUT) -> str:
    if len(text) <= n:
        return text
    half = n // 2
    return text[:half] + "\n... <truncated> ...\n" + text[-half:]


def shell(command: str, timeout: int, log: Path | None = None) -> tuple[int, str]:
    proc = subprocess.run(
        ["bash", "-lc", command], cwd=ROOT, text=True, capture_output=True,
        timeout=timeout, env={**os.environ, "PYTHONUNBUFFERED": "1"},
    )
    out = f"STDOUT:\n{proc.stdout}\nSTDERR:\n{proc.stderr}"
    if log is not None:
        log.write_text(out, encoding="utf-8")
    return proc.returncode, out


def executable_solidity() -> list[Path]:
    result: list[Path] = []
    for path in sorted((CONTRACTS / "src").rglob("*.sol")):
        text = path.read_text(errors="replace")
        # Interfaces and error-only files do not produce executable bytecode. Libraries
        # are included because their logic must have a Vyper counterpart even when inlined.
        if re.search(r"(?m)^\s*(?:abstract\s+)?contract\s+\w+", text) or re.search(r"(?m)^\s*library\s+\w+", text):
            result.append(path)
    return result


def find_vyper_for(sol: Path) -> list[Path]:
    rel = sol.relative_to(CONTRACTS / "src")
    stem = sol.stem.lower()
    candidates = []
    for path in (CONTRACTS / "vyper").rglob("*.vy"):
        if path.stem.lower() == stem:
            candidates.append(path)
    # Allow explicit manifest mappings for architectural splits.
    manifest = ROOT / "reports" / "vyper" / "port-manifest.json"
    if manifest.exists():
        try:
            mapping = json.loads(manifest.read_text())
            for raw in mapping.get(str(rel), []):
                p = safe_path(raw)
                if p.exists() and p.suffix == ".vy":
                    candidates.append(p)
        except Exception:
            pass
    return sorted(set(candidates))


def compile_vyper() -> tuple[int, list[str], list[str]]:
    failures: list[str] = []
    size_failures: list[str] = []
    log_lines: list[str] = []
    files = sorted((CONTRACTS / "vyper").rglob("*.vy"))
    for path in files:
        rel = path.relative_to(CONTRACTS)
        # Interface/module-only files may not emit bytecode. First request ABI, then runtime.
        cmd = f"cd contracts && python -m vyper --evm-version cancun -p vyper -f abi {shlex_quote(str(rel))}"
        rc, out = shell(cmd, 180)
        log_lines.append(f"===== {rel} ABI rc={rc} =====\n{out}")
        if rc != 0:
            failures.append(str(rel))
            continue
        cmd2 = f"cd contracts && python -m vyper --evm-version cancun -p vyper -f bytecode_runtime {shlex_quote(str(rel))}"
        rc2, out2 = shell(cmd2, 180)
        log_lines.append(f"===== {rel} RUNTIME rc={rc2} =====\n{out2}")
        if rc2 == 0:
            match = re.search(r"0x([0-9a-fA-F]+)", out2)
            if match:
                size = len(match.group(1)) // 2
                if size > 24_576:
                    size_failures.append(f"{rel}: {size}")
        elif "abstract" not in out2.lower() and "interface" not in out2.lower() and "cannot be compiled" not in out2.lower():
            failures.append(str(rel))
    (REPORT / "vyper-compile.log").write_text("\n".join(log_lines), encoding="utf-8")
    return (0 if not failures else 1), failures, size_failures


def shlex_quote(value: str) -> str:
    import shlex
    return shlex.quote(value)


def validate_gas_artifacts() -> tuple[bool, bool, bool]:
    csv_path = ROOT / "reports" / "vyper" / "gas-comparison.csv"
    json_path = ROOT / "reports" / "vyper" / "gas-comparison.json"
    md_path = ROOT / "reports" / "vyper" / "gas-comparison.md"
    csv_ok = False
    json_ok = False
    md_ok = False
    if csv_path.exists():
        text = csv_path.read_text(errors="replace")
        rows = [line for line in text.splitlines() if line.strip()]
        csv_ok = len(rows) >= 3 and "solidity" in text.lower() and "vyper" in text.lower() and "delta" in text.lower()
    if json_path.exists():
        try:
            data = json.loads(json_path.read_text())
            encoded = json.dumps(data).lower()
            json_ok = bool(data) and "solidity" in encoded and "vyper" in encoded and "delta" in encoded
        except Exception:
            pass
    if md_path.exists():
        text = md_path.read_text(errors="replace").lower()
        md_ok = len(text) > 1000 and "solidity" in text and "vyper" in text and "gas" in text and "runtime" in text
    return csv_ok, json_ok, md_ok


def scan_forbidden() -> list[str]:
    hits: list[str] = []
    patterns = {
        "TODO stub": r"(?i)\bTODO\b.*(?:stub|implement|parity)",
        "unconditional test success": r"(?m)^\s*(?:return\s+True|assert\s+True)\s*(?:#.*)?$",
        "Solidity implementation delegate": r"(?i)(delegatecall|raw_call).*solidity",
        "skip marker": r"(?i)\b(skip|ignored)\b.*(?:parity|vyper|test)",
    }
    for path in sorted((CONTRACTS / "vyper").rglob("*.vy")):
        text = path.read_text(errors="replace")
        for label, pattern in patterns.items():
            if re.search(pattern, text):
                hits.append(f"{path.relative_to(ROOT)}: {label}")
    return hits


def run_audit() -> AuditResult:
    source = executable_solidity()
    missing = [str(p.relative_to(CONTRACTS / "src")) for p in source if not find_vyper_for(p)]
    compile_rc, compile_failures, sizes = compile_vyper()

    forge_rc, _ = shell(
        "cd contracts && timeout 7200 forge test --match-path 'test/vyper/**/*.t.sol' -vv",
        7_300, REPORT / "forge.log",
    )
    hardhat_rc, _ = shell(
        "cd contracts && timeout 5400 bun run test:hardhat",
        5_500, REPORT / "hardhat.log",
    )
    e2e_rc, _ = shell(
        "cd contracts && timeout 5400 bun run test:e2e",
        5_500, REPORT / "e2e.log",
    )
    gas_csv, gas_json, gas_md = validate_gas_artifacts()
    forbidden = scan_forbidden()
    head_rc, head_out = shell("git rev-parse HEAD", 30)
    head = head_out.split("STDOUT:\n", 1)[-1].splitlines()[0].strip() if head_rc == 0 else "unknown"
    complete = (
        not missing and compile_rc == 0 and forge_rc == 0 and hardhat_rc == 0 and e2e_rc == 0
        and gas_csv and gas_json and gas_md and not sizes and not forbidden
    )
    result = AuditResult(
        timestamp=int(time.time()), baseline=BASELINE, head=head,
        source_executables=len(source), vyper_sources=len(list((CONTRACTS / "vyper").rglob("*.vy"))),
        missing_ports=missing, compile_rc=compile_rc, compile_failures=compile_failures,
        forge_rc=forge_rc, hardhat_rc=hardhat_rc, e2e_rc=e2e_rc,
        gas_csv_ok=gas_csv, gas_json_ok=gas_json, gas_md_ok=gas_md,
        eip170_failures=sizes, forbidden_patterns=forbidden, complete=complete,
    )
    (REPORT / "audit.json").write_text(json.dumps(asdict(result), indent=2) + "\n", encoding="utf-8")
    write_audit_markdown(result)
    return result


def write_audit_markdown(result: AuditResult) -> None:
    fields = asdict(result)
    lines = ["# Vyper completion audit", "", f"- Complete: **{result.complete}**"]
    for key, value in fields.items():
        if key == "complete":
            continue
        lines.append(f"- `{key}`: `{json.dumps(value)}`")
    lines += ["", "## Evidence", "", "- `vyper-compile.log`", "- `forge.log`", "- `hardhat.log`", "- `e2e.log`"]
    (REPORT / "audit.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def failure_context(result: AuditResult) -> str:
    parts = [json.dumps(asdict(result), indent=2)]
    for name in ("vyper-compile.log", "forge.log", "hardhat.log", "e2e.log"):
        path = REPORT / name
        if path.exists():
            text = path.read_text(errors="replace")
            parts.append(f"\n===== {name} TAIL =====\n" + "\n".join(text.splitlines()[-350:]))
    return cap("\n".join(parts), 90_000)


def request_json(url: str, payload: dict[str, Any] | None = None) -> Any:
    data = None if payload is None else json.dumps(payload).encode()
    request = urllib.request.Request(
        url, data=data,
        headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json", "Accept": "application/json", "User-Agent": "ens-vyper-completion"},
        method="GET" if payload is None else "POST",
    )
    last: Exception | None = None
    for attempt in range(7):
        try:
            with urllib.request.urlopen(request, timeout=240) as response:
                return json.loads(response.read())
        except urllib.error.HTTPError as exc:
            last = exc
            body = exc.read().decode(errors="replace")
            if exc.code in {408, 429, 500, 502, 503, 504}:
                time.sleep(min(2 ** attempt, 45))
                continue
            raise RuntimeError(f"HTTP {exc.code}: {body}") from exc
        except Exception as exc:
            last = exc
            time.sleep(min(2 ** attempt, 45))
    raise RuntimeError(f"request failed: {last}")


def choose_models() -> list[str]:
    preferred = ["openai/gpt-5.1-codex-max", "openai/gpt-5.1-codex", "openai/gpt-5", "anthropic/claude-sonnet-4.5", "openai/gpt-4.1"]
    try:
        catalog = request_json("https://models.github.ai/catalog/models")
        ids = {entry.get("id") for entry in catalog if isinstance(entry, dict)}
        selected = [m for m in preferred if m in ids]
        for model in sorted(str(m) for m in ids if m):
            if any(word in model.lower() for word in ("codex", "gpt-5", "sonnet")) and model not in selected:
                selected.append(model)
        return selected or preferred
    except Exception as exc:
        (REPORT / "catalog-error.txt").write_text(str(exc), encoding="utf-8")
        return preferred


def run_tool(name: str, args: dict[str, Any]) -> str:
    try:
        if name == "list_files":
            base = safe_path(str(args["path"]))
            if not base.exists():
                return "NOT FOUND"
            depth = int(args.get("max_depth", 4))
            base_depth = len(base.parts)
            lines: list[str] = []
            for path in sorted(base.rglob("*")):
                if len(path.parts) - base_depth > depth:
                    continue
                lines.append(str(path.relative_to(ROOT)) + ("/" if path.is_dir() else ""))
                if len(lines) >= 2000:
                    lines.append("... capped ...")
                    break
            return cap("\n".join(lines))
        if name == "read_file":
            path = safe_path(str(args["path"]))
            lines = path.read_text(errors="replace").splitlines()
            start = max(1, int(args.get("start_line", 1)))
            end = min(len(lines), int(args.get("end_line", start + 700)))
            return cap("\n".join(f"{n}: {lines[n-1]}" for n in range(start, end + 1)))
        if name == "search_text":
            command = ["rg", "-n", "--hidden", "--glob", "!.git/**"]
            if args.get("glob"):
                command += ["--glob", str(args["glob"])]
            command += [str(args["query"]), str(args.get("path", "."))]
            proc = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, timeout=120)
            return cap(f"exit={proc.returncode}\n{proc.stdout}{proc.stderr}")
        if name == "write_file":
            path = safe_path(str(args["path"]))
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(str(args["content"]), encoding="utf-8")
            return f"wrote {path.relative_to(ROOT)} ({path.stat().st_size} bytes)"
        if name == "apply_patch":
            patch = REPORT / "agent.patch"
            patch.write_text(str(args["patch"]), encoding="utf-8")
            proc = subprocess.run(["git", "apply", "--whitespace=nowarn", str(patch)], cwd=ROOT, text=True, capture_output=True, timeout=180)
            return cap(f"exit={proc.returncode}\n{proc.stdout}{proc.stderr}")
        if name == "run_command":
            command = str(args["command"])
            lowered = command.lower()
            blocked = ("git push", "git reset --hard", "git clean -", "rm -rf /", "gh auth", "curl http", "wget http")
            if any(token in lowered for token in blocked):
                return "BLOCKED: command violates serialized/safety constraints"
            timeout = min(int(args.get("timeout", TOOL_TIMEOUT)), 1200)
            rc, out = shell(command, timeout)
            return cap(f"exit={rc}\n{out}")
        return f"unknown tool {name}"
    except subprocess.TimeoutExpired as exc:
        return cap(f"TIMEOUT\n{exc.stdout or ''}\n{exc.stderr or ''}")
    except Exception as exc:
        return f"ERROR {type(exc).__name__}: {exc}"


def normalize(message: dict[str, Any]) -> dict[str, Any]:
    out: dict[str, Any] = {"role": message.get("role", "assistant")}
    if message.get("content") is not None:
        out["content"] = message["content"]
    if message.get("tool_calls"):
        out["tool_calls"] = message["tool_calls"]
    return out


def coding_round(round_no: int, result: AuditResult, models: list[str]) -> None:
    messages: list[dict[str, Any]] = [
        {"role": "system", "content": SYSTEM},
        {"role": "user", "content": f"Repair round {round_no}/{MAX_ROUNDS}. Here is the strict audit and failure evidence:\n\n{failure_context(result)}\n\nInspect current source and use tools until these gates pass. Commit coherent green work locally; do not stop at analysis."},
    ]
    transcript = REPORT / f"round-{round_no}.jsonl"
    selected: str | None = None
    for step in range(MAX_STEPS):
        payload = {"messages": messages, "tools": TOOLS, "tool_choice": "auto", "temperature": 0.1, "max_tokens": 16_384}
        response = None
        errors: list[str] = []
        for model in ([selected] if selected else models):
            if not model:
                continue
            try:
                response = request_json("https://models.github.ai/inference/chat/completions", {**payload, "model": model})
                selected = model
                break
            except Exception as exc:
                errors.append(f"{model}: {exc}")
        if response is None:
            (REPORT / f"round-{round_no}-model-errors.txt").write_text("\n".join(errors), encoding="utf-8")
            return
        message = normalize(response["choices"][0]["message"])
        messages.append(message)
        with transcript.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps({"step": step, "model": selected, "message": message}) + "\n")
        calls = message.get("tool_calls") or []
        if not calls:
            # A prose stop is not success. Prompt once more unless the model has at least
            # committed and explicitly requests a fresh audit.
            status_rc, status_out = shell("git status --porcelain", 30)
            if step + 1 < MAX_STEPS:
                messages.append({"role": "user", "content": f"Do not stop at prose. git status is:\n{status_out}\nContinue edits/tests/commits, or explicitly state READY_FOR_AUDIT after all focused failures are resolved."})
                continue
            return
        for call in calls:
            fn = call.get("function", {})
            name = str(fn.get("name", ""))
            try:
                args = json.loads(fn.get("arguments") or "{}")
                output = run_tool(name, args)
            except Exception as exc:
                output = f"tool argument error: {exc}"
            messages.append({"role": "tool", "tool_call_id": call.get("id", ""), "content": output})
            with transcript.open("a", encoding="utf-8") as fh:
                fh.write(json.dumps({"step": step, "tool": name, "result": output}) + "\n")
        if len(messages) > 180:
            messages = messages[:2] + [{"role": "user", "content": "Context compacted. Inspect git log/status/diff and reports/vyper/completion. Continue the same repair round; do not redo green work."}] + messages[-115:]


def main() -> int:
    models = choose_models()
    result = run_audit()
    for round_no in range(1, MAX_ROUNDS + 1):
        if result.complete:
            break
        coding_round(round_no, result, models)
        # Ensure working edits are never silently lost between rounds.
        rc, status = shell("git status --porcelain", 30)
        if rc == 0 and status.split("STDOUT:\n", 1)[-1].strip():
            shell(f"git add -A && git commit -m 'experiment(vyper): completion repair round {round_no}'", 180)
        result = run_audit()
    (REPORT / "FINAL_STATUS").write_text("COMPLETE\n" if result.complete else "INCOMPLETE\n", encoding="utf-8")
    return 0 if result.complete else 1


if __name__ == "__main__":
    sys.exit(main())
