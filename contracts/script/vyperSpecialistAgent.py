#!/usr/bin/env python3
"""Run serial, failure-directed coding specialists for Vyper parity.

Unlike the broad completion loop, each specialist receives one committed failing gate
and its raw log. This reduces repeated analysis and forces focused source, Hardhat, E2E
or benchmark repairs before the standard full validator runs again.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import vyperCompletionAgent as core
import vyperCompletionAgentFast as fast

ROOT = core.ROOT
REPORT = core.REPORT
FULL = REPORT / "full-validation.json"


def tail(path: Path, lines: int = 650) -> str:
    if not path.exists():
        return "MISSING LOG"
    return "\n".join(path.read_text(errors="replace").splitlines()[-lines:])


def latest_suite_log(name: str) -> Path:
    candidates = list((REPORT / "full-validation").rglob(f"validation-{name}/output.log"))
    if not candidates:
        candidates = list((REPORT / "full-validation").rglob("output.log"))
        candidates = [p for p in candidates if f"validation-{name}" in str(p)]
    return sorted(candidates)[-1] if candidates else REPORT / f"{name}.missing.log"


def load_validation() -> dict:
    if FULL.exists():
        try:
            return json.loads(FULL.read_text())
        except Exception:
            pass
    return {"fast_status": "INCOMPLETE", "forge_vyper_rc": 999, "hardhat_rc": 999, "e2e_rc": 999, "complete": False}


def run_specialist(label: str, objective: str, evidence: str, models: list[str], ordinal: int) -> None:
    audit = fast.quick_audit()
    original_context = core.failure_context
    original_system = core.SYSTEM

    def context(_result: core.AuditResult) -> str:
        return core.cap(
            f"SPECIALIST: {label}\n\nOBJECTIVE:\n{objective}\n\nCOMMITTED FAILURE EVIDENCE:\n{evidence}\n\nFAST AUDIT:\n{json.dumps(audit.__dict__, indent=2)}",
            110_000,
        )

    core.failure_context = context
    core.SYSTEM = original_system + f"\n\nYou are the {label} specialist. Do not broaden scope until the stated objective is green. Inspect current git history and preserve prior green work."
    try:
        core.coding_round(ordinal, audit, models)
    finally:
        core.failure_context = original_context
        core.SYSTEM = original_system
    rc, status = core.shell("git status --porcelain", 30)
    dirty = status.split("STDOUT:\n", 1)[-1].strip() if rc == 0 else ""
    if dirty:
        core.shell(f"git add -A && git commit -m 'experiment(vyper): {label} specialist repair'", 240)


def main() -> int:
    validation = load_validation()
    models = core.choose_models()
    ordinal = 1

    fast_audit = fast.quick_audit()
    if not fast_audit.complete or int(validation.get("forge_vyper_rc", 999)) != 0:
        evidence = tail(REPORT / "vyper-compile.log") + "\n\n" + tail(REPORT / "forge-fast.log") + "\n\n" + tail(latest_suite_log("forge-vyper"))
        run_specialist(
            "compiler-and-forge",
            "Make the executable-source inventory complete, compile every Vyper module/contract, satisfy EIP-170, remove forbidden stubs, complete gas artifacts, and make the unchanged copied test/vyper Forge corpus pass. Work through exact first failures rather than hiding or skipping them.",
            evidence,
            models,
            ordinal,
        )
        ordinal += 1

    validation = load_validation()
    if int(validation.get("hardhat_rc", 999)) != 0:
        run_specialist(
            "hardhat-integration",
            "Repair Vyper artifact generation, deployment scripts, fixtures, ABI/storage/proxy wiring and implementation behavior so the repository's pre-existing Hardhat integration suite runs against the Vyper graph without weakening tests. Run focused Vitest/Hardhat cases and then the whole suite.",
            tail(latest_suite_log("hardhat"), 1000),
            models,
            ordinal,
        )
        ordinal += 1

    validation = load_validation()
    if int(validation.get("e2e_rc", 999)) != 0:
        run_specialist(
            "e2e",
            "Repair the complete Vyper deployment graph and cross-contract behavior required by the existing E2E suite: migration, registration/renewal, resolvers, reverse records, DNS/CCIP, HCA/account abstraction, proxy upgrades and rollback semantics. Keep all original E2E assertions and execute focused failures before the whole suite.",
            tail(latest_suite_log("e2e"), 1200),
            models,
            ordinal,
        )
        ordinal += 1

    # Always give the measurement specialist a focused pass if artifacts are absent or
    # malformed; it must use receipts rather than estimates.
    csv_ok, json_ok, md_ok = core.validate_gas_artifacts()
    if not (csv_ok and json_ok and md_ok):
        run_specialist(
            "gas-and-bytecode",
            "Create reproducible paired Solidity/Vyper deployment and call benchmarks from identical state/caller/calldata/value. Produce reports/vyper/gas-comparison.csv, .json and .md with raw receipt references, absolute/percentage deltas, runtime and creation byte sizes, compiler versions and honest exclusions.",
            "Current gas artifact validation: " + json.dumps({"csv": csv_ok, "json": json_ok, "md": md_ok}),
            models,
            ordinal,
        )

    final_fast = fast.quick_audit()
    (REPORT / "SPECIALIST_STATUS").write_text("READY_FOR_VALIDATION\n" if final_fast.complete else "INCOMPLETE\n")
    return 0 if final_fast.complete else 1


if __name__ == "__main__":
    sys.exit(main())
