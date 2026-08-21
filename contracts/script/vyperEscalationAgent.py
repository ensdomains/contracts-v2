#!/usr/bin/env python3
"""Model-diverse escalation for stubborn Vyper parity failures."""

from __future__ import annotations

import json
import sys
from pathlib import Path

import vyperCompletionAgent as core
import vyperCompletionAgentFast as fast

REPORT = core.REPORT


def collect() -> str:
    parts = []
    for name in (
        "full-validation.json", "audit-fast.json", "vyper-compile.log", "forge-fast.log",
    ):
        p = REPORT / name
        if p.exists():
            text = p.read_text(errors="replace")
            parts.append(f"===== {name} =====\n" + (text if len(text) < 30000 else "\n".join(text.splitlines()[-700:])))
    full = REPORT / "full-validation"
    if full.exists():
        for p in sorted(full.rglob("output.log")):
            text = p.read_text(errors="replace")
            parts.append(f"===== {p.relative_to(REPORT)} =====\n" + "\n".join(text.splitlines()[-900:]))
    return core.cap("\n\n".join(parts), 130_000)


def commit(label: str) -> None:
    rc, status = core.shell("git status --porcelain", 30)
    dirty = status.split("STDOUT:\n", 1)[-1].strip() if rc == 0 else ""
    if dirty:
        core.shell(f"git add -A && git commit -m 'experiment(vyper): escalation {label}'", 240)


def run(model: str, label: str, directive: str, ordinal: int) -> None:
    result = fast.quick_audit()
    evidence = collect()
    original_system = core.SYSTEM
    original_context = core.failure_context
    core.SYSTEM = original_system + f"\n\nYou are the independent {label} escalation reviewer. {directive} Do not merely comment: edit, run focused tests and commit repairs."
    core.failure_context = lambda _result: evidence
    try:
        core.coding_round(ordinal, result, [model])
    finally:
        core.SYSTEM = original_system
        core.failure_context = original_context
    commit(label)


def main() -> int:
    available = core.choose_models()
    preferences = [
        ("openai/gpt-5.1-codex-max", "compiler-evm", "Trace exact compiler, ABI, bytecode, storage and first Forge failures. Simplify production architecture where needed while preserving parity and EIP-170."),
        ("anthropic/claude-sonnet-4.5", "architecture-security", "Independently inspect unresolved design and security semantics, especially proxies, callbacks, signatures, account abstraction, DNS/CCIP and cross-contract rollback. Repair root causes."),
        ("openai/gpt-5", "integration-measurement", "Drive Hardhat/E2E deployment wiring and controlled gas/size evidence to green. Treat raw tests and receipts as authoritative."),
        ("openai/gpt-4.1", "fallback-review", "Perform a fresh failure-oriented review and repair anything the prior models missed."),
    ]
    selected = []
    for preferred, label, directive in preferences:
        match = preferred if preferred in available else None
        if match is None:
            for candidate in available:
                if candidate not in [x[0] for x in selected]:
                    match = candidate
                    break
        if match and match not in [x[0] for x in selected]:
            selected.append((match, label, directive))
        if len(selected) >= 3:
            break
    for index, (model, label, directive) in enumerate(selected, 1):
        run(model, label, directive, index)
    ready = fast.quick_audit().complete
    (REPORT / "ESCALATION_STATUS").write_text("READY_FOR_VALIDATION\n" if ready else "INCOMPLETE\n")
    return 0 if ready else 1


if __name__ == "__main__":
    sys.exit(main())
