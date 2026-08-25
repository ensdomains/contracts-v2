#!/usr/bin/env python3
from __future__ import annotations

import csv
import json
import os
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
CONTRACTS = ROOT / "contracts"
VYPER = CONTRACTS / "vyper"
TESTS = CONTRACTS / "test" / "vyper"
FINAL = ROOT / "reports" / "vyper" / "final"
FINAL.mkdir(parents=True, exist_ok=True)


def run(name: str, command: str, timeout: int) -> dict[str, Any]:
    started = time.time()
    path = FINAL / f"{name}.log"
    try:
        p = subprocess.run(["bash", "-lc", command], cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
        output = p.stdout
        rc = p.returncode
    except subprocess.TimeoutExpired as exc:
        output = (exc.stdout or "") + f"\nTIMEOUT after {timeout}s\n"
        rc = 124
    path.write_text(output)
    return {"name": name, "command": command, "rc": rc, "seconds": round(time.time() - started, 2), "log": path.relative_to(ROOT).as_posix()}


def implementations() -> list[dict[str, Any]]:
    result = []
    for path in sorted((CONTRACTS / "src").rglob("*.sol")):
        text = path.read_text(errors="replace")
        decls = re.findall(r"(?m)^\s*(?:abstract\s+)?(contract|library)\s+([A-Za-z_]\w*)", text)
        if decls:
            result.append({"source": path.relative_to(CONTRACTS / "src").as_posix(), "declarations": [x[1] for x in decls]})
    return result


def main() -> int:
    status_path = FINAL / "FINAL_STATUS"
    status_path.write_text("INCOMPLETE\n")
    blockers: list[str] = []
    details: dict[str, Any] = {"baseline": "a971bd6449154045e2b26ff13d0e56027452f407", "started": time.time()}

    manifest_path = VYPER / "port-manifest.json"
    try:
        raw = json.loads(manifest_path.read_text())
        ports = raw.get("ports", raw if isinstance(raw, list) else [])
    except Exception as exc:
        ports = []
        blockers.append(f"manifest unreadable: {exc}")
    by_source = {x.get("source"): x for x in ports if isinstance(x, dict) and x.get("source")}
    impls = implementations()
    missing = []
    invalid = []
    concrete_files: set[Path] = set()
    for impl in impls:
        entry = by_source.get(impl["source"])
        if not entry:
            missing.append(impl["source"])
            continue
        paths = entry.get("vyper_files", entry.get("vyper", []))
        if isinstance(paths, str): paths = [paths]
        if not paths:
            invalid.append({"source": impl["source"], "reason": "empty vyper_files"})
            continue
        for raw_path in paths:
            path = ROOT / raw_path if str(raw_path).startswith("contracts/") else CONTRACTS / str(raw_path)
            if not path.exists():
                invalid.append({"source": impl["source"], "reason": f"missing {path.relative_to(ROOT)}"})
            elif path.suffix == ".vy":
                concrete_files.add(path)
        tested_by = entry.get("tested_by", [])
        if isinstance(tested_by, str): tested_by = [tested_by]
        if not tested_by:
            invalid.append({"source": impl["source"], "reason": "no tested_by suites"})
        else:
            for test in tested_by:
                tp = ROOT / test
                if not tp.exists(): invalid.append({"source": impl["source"], "reason": f"missing test {test}"})
    if missing: blockers.append(f"{len(missing)} implementation roots missing from manifest")
    if invalid: blockers.append(f"{len(invalid)} invalid manifest mappings")

    compile_failures = []
    sizes = []
    for path in sorted(concrete_files):
        text = path.read_text(errors="replace")
        # Standalone abstract/module-only files can be dependencies but are not deployable roots.
        entry_is_deployable = any(
            (p.get("deployable", True) and path in {
                (ROOT / x if str(x).startswith("contracts/") else CONTRACTS / str(x))
                for x in ([p.get("vyper_files", p.get("vyper", []))] if isinstance(p.get("vyper_files", p.get("vyper", [])), str) else p.get("vyper_files", p.get("vyper", [])))
            })
            for p in ports if isinstance(p, dict)
        )
        if not entry_is_deployable:
            continue
        cmd = f"python -m vyper --evm-version cancun -O gas -p contracts/vyper -f bytecode_runtime {shlex.quote(path.relative_to(ROOT).as_posix())}"
        p = subprocess.run(["bash", "-lc", cmd], cwd=ROOT, text=True, capture_output=True)
        if p.returncode:
            compile_failures.append({"file": path.relative_to(ROOT).as_posix(), "error": (p.stderr + p.stdout)[-6000:]})
            continue
        code = p.stdout.strip().splitlines()[-1].removeprefix("0x") if p.stdout.strip() else ""
        size = len(code) // 2
        sizes.append({"contract": path.relative_to(VYPER).with_suffix("").as_posix(), "vyper_runtime_bytes": size})
        if size > 24576:
            blockers.append(f"EIP-170: {path.relative_to(ROOT)} is {size} bytes")
    if compile_failures: blockers.append(f"{len(compile_failures)} Vyper deployable roots failed compilation")

    with (FINAL / "bytecode-sizes.csv").open("w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=["contract", "vyper_runtime_bytes"])
        writer.writeheader(); writer.writerows(sizes)
    (FINAL / "bytecode-sizes.md").write_text("# Vyper runtime sizes\n\n| Contract | Vyper bytes |\n|---|---:|\n" + "".join(f"| `{x['contract']}` | {x['vyper_runtime_bytes']} |\n" for x in sizes))

    if not TESTS.exists() or not any(TESTS.rglob("*.t.sol")):
        blockers.append("no Vyper-wired Forge tests")
    commands = []
    if not blockers:
        commands.append(run("forge-vyper", "cd contracts && forge test --match-path 'test/vyper/**/*.t.sol' -vv", 1500))
        forge_log = (FINAL / "forge-vyper.log").read_text(errors="replace")
        if commands[-1]["rc"] != 0 or "No tests found" in forge_log or not re.search(r"\b\d+ passed", forge_log):
            blockers.append("Vyper-wired Forge suite failed or executed zero tests")

    # These commands must be explicitly Vyper-wired. The integration layer must print the marker.
    if not blockers:
        commands.append(run("hardhat-vyper", "cd contracts && USE_VYPER=1 bun run test:hardhat", 1500))
        log = (FINAL / "hardhat-vyper.log").read_text(errors="replace")
        if commands[-1]["rc"] != 0 or "VYPER_DEPLOYMENT=1" not in log:
            blockers.append("Hardhat suite did not pass against a marked Vyper deployment")
    if not blockers:
        commands.append(run("e2e-vyper", "cd contracts && USE_VYPER=1 bun run test:e2e", 2100))
        log = (FINAL / "e2e-vyper.log").read_text(errors="replace")
        if commands[-1]["rc"] != 0 or "VYPER_DEPLOYMENT=1" not in log:
            blockers.append("E2E suite did not pass against a marked Vyper deployment")

    required_gas = [FINAL / "gas.csv", FINAL / "gas.json", FINAL / "gas.md"]
    for path in required_gas:
        if not path.exists() or path.stat().st_size == 0:
            blockers.append(f"missing {path.relative_to(ROOT)}")
    if (FINAL / "gas.csv").exists():
        rows = list(csv.DictReader((FINAL / "gas.csv").open()))
        required_cols = {"contract", "operation", "solidity_gas", "vyper_gas", "delta", "delta_percent"}
        if not rows or not required_cols.issubset(rows[0].keys()):
            blockers.append("gas.csv is empty or lacks paired measurement columns")
        elif any(not row.get("solidity_gas") or not row.get("vyper_gas") for row in rows):
            blockers.append("gas.csv contains unpaired rows")

    # Reject obvious delegation to original Solidity implementations in production Vyper roots.
    forbidden = []
    for path in VYPER.rglob("*.vy"):
        text = path.read_text(errors="replace")
        for pattern in [r"SOLIDITY_IMPLEMENTATION", r"legacy_solidity", r"delegate.*solidity"]:
            if re.search(pattern, text, re.I): forbidden.append({"file": path.relative_to(ROOT).as_posix(), "pattern": pattern})
    if forbidden: blockers.append("forbidden Solidity delegation markers found")

    details.update({
        "finished": time.time(), "implementations": len(impls), "manifest_ports": len(ports),
        "missing": missing, "invalid": invalid, "compile_failures": compile_failures,
        "sizes": sizes, "commands": commands, "forbidden": forbidden, "blockers": blockers,
        "complete": not blockers,
    })
    (FINAL / "strict-gate.json").write_text(json.dumps(details, indent=2) + "\n")
    md = ["# Strict Vyper final gate", "", f"- Complete: **{not blockers}**", f"- Solidity implementation roots: **{len(impls)}**", f"- Manifest ports: **{len(ports)}**", f"- Deployable Vyper roots compiled: **{len(sizes)}**", "", "## Blockers"]
    md += [f"- {x}" for x in blockers] or ["- None"]
    (FINAL / "strict-gate.md").write_text("\n".join(md) + "\n")
    if not blockers:
        status_path.write_text("COMPLETE\n")
        return 0
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
