#!/usr/bin/env python3
"""Fast repair phase for the strict Vyper completion workflow.

Long Forge/Hardhat/E2E validation runs in parallel downstream jobs. This phase keeps
model time focused on source repair by compiling all Vyper and running the copied Vyper
Forge corpus, while retaining the strict inventory, EIP-170 and gas-artifact checks.
"""

from __future__ import annotations

import json
import os
import sys
import time
from dataclasses import asdict
from pathlib import Path

import vyperCompletionAgent as core

REPORT = core.REPORT
MAX_ROUNDS = int(os.environ.get("VYPER_FAST_ROUNDS", "5"))


def quick_audit() -> core.AuditResult:
    source = core.executable_solidity()
    missing = [str(p.relative_to(core.CONTRACTS / "src")) for p in source if not core.find_vyper_for(p)]
    compile_rc, compile_failures, sizes = core.compile_vyper()
    forge_rc, _ = core.shell(
        "cd contracts && timeout 3600 forge test --match-path 'test/vyper/**/*.t.sol' -vv",
        3_700,
        REPORT / "forge-fast.log",
    )
    gas_csv, gas_json, gas_md = core.validate_gas_artifacts()
    forbidden = core.scan_forbidden()
    rc, out = core.shell("git rev-parse HEAD", 30)
    head = out.split("STDOUT:\n", 1)[-1].splitlines()[0].strip() if rc == 0 else "unknown"
    ready = (
        not missing and compile_rc == 0 and forge_rc == 0 and gas_csv and gas_json and gas_md
        and not sizes and not forbidden
    )
    result = core.AuditResult(
        timestamp=int(time.time()), baseline=core.BASELINE, head=head,
        source_executables=len(source),
        vyper_sources=len(list((core.CONTRACTS / "vyper").rglob("*.vy"))),
        missing_ports=missing, compile_rc=compile_rc, compile_failures=compile_failures,
        forge_rc=forge_rc, hardhat_rc=-1, e2e_rc=-1,
        gas_csv_ok=gas_csv, gas_json_ok=gas_json, gas_md_ok=gas_md,
        eip170_failures=sizes, forbidden_patterns=forbidden, complete=ready,
    )
    (REPORT / "audit-fast.json").write_text(json.dumps(asdict(result), indent=2) + "\n", encoding="utf-8")
    lines = [
        "# Fast Vyper repair audit", "", f"- Ready for full validation: **{ready}**", "",
        "```json", json.dumps(asdict(result), indent=2), "```", "",
        "Long Forge/Hardhat/E2E validation is performed by downstream parallel jobs.",
    ]
    (REPORT / "audit-fast.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return result


def quick_failure_context(result: core.AuditResult) -> str:
    chunks = [json.dumps(asdict(result), indent=2)]
    for name in ("vyper-compile.log", "forge-fast.log", "forge.log", "hardhat.log", "e2e.log"):
        path = REPORT / name
        if path.exists():
            text = path.read_text(errors="replace")
            chunks.append(f"\n===== {name} TAIL =====\n" + "\n".join(text.splitlines()[-400:]))
    return core.cap("\n".join(chunks), 100_000)


def coding_round(round_no: int, result: core.AuditResult, models: list[str]) -> None:
    original = core.failure_context
    core.failure_context = quick_failure_context
    try:
        core.coding_round(round_no, result, models)
    finally:
        core.failure_context = original


def main() -> int:
    core.SYSTEM += r"""

This invocation is the fast repair phase. Long full validation runs in downstream jobs.
Your immediate gate is reports/vyper/completion/audit-fast.json: complete inventory,
all Vyper compilation, EIP-170, forbidden-pattern scan, gas artifacts and the entire
copied test/vyper Forge corpus. Also inspect committed full-validation logs from prior
passes and repair their Hardhat/E2E failures before asking for another full validation.
"""
    models = core.choose_models()
    result = quick_audit()
    for round_no in range(1, MAX_ROUNDS + 1):
        if result.complete:
            break
        coding_round(round_no, result, models)
        rc, status = core.shell("git status --porcelain", 30)
        dirty = status.split("STDOUT:\n", 1)[-1].strip() if rc == 0 else ""
        if dirty:
            core.shell(f"git add -A && git commit -m 'experiment(vyper): fast repair round {round_no}'", 240)
        result = quick_audit()
    (REPORT / "FAST_STATUS").write_text("READY_FOR_FULL_VALIDATION\n" if result.complete else "INCOMPLETE\n", encoding="utf-8")
    return 0 if result.complete else 1


if __name__ == "__main__":
    sys.exit(main())
