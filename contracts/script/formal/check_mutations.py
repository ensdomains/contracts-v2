#!/usr/bin/env python3
"""Require selected HCA proofs to detect deliberate defects in an isolated copy."""

from __future__ import annotations

from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shutil
import sys

from run_hca import CONTRACTS, diagnostics, digest, run_logged, write_json


CASES = [
    {
        "name": "owner_gate",
        "source": "src/hca/StandaloneSingleOwnerHCA.sol",
        "contract": "HCAAccountStateTest",
        "test": "check_revokeExactlyWhenOwner(address,address,uint96)",
        "file": "HCAAccountState.t.sol",
        "before": "function revokeSessions() external onlyOwner {",
        "after": "function revokeSessions() external {",
    },
    {
        "name": "session_nonce_increment",
        "source": "src/hca/StandaloneSingleOwnerHCA.sol",
        "contract": "HCAAccountStateTest",
        "test": "check_nonceWrapPreservesOwner(address)",
        "file": "HCAAccountState.t.sol",
        "before": "sessionNonce = ++_sessionNonce;",
        "after": "sessionNonce = _sessionNonce;",
    },
    {
        "name": "upgrade_target_approval",
        "source": "src/hca/StandaloneSingleOwnerHCA.sol",
        "contract": "HCAAccountUpgradesTest",
        "test": "check_revokingTargetApprovalBlocksUpgrade(address,uint96)",
        "file": "HCAAccountUpgrades.t.sol",
        "before": "        if (!UPGRADE_SET.includes(newImplementation)) {\n"
                  "            revert UpgradeTargetNotApproved(newImplementation);\n"
                  "        }",
        "after": "",
    },
    {
        "name": "factory_implementation_approval",
        "source": "src/hca/StandaloneHCAFactory.sol",
        "contract": "HCAFactoryTest",
        "test": "check_deploymentApprovalTruthTable(address,bool)",
        "file": "HCAFactory.t.sol",
        "before": "        if (!approvedImplementations[hcaImplementation]) {\n"
                  "            revert HCAImplementationNotApproved(hcaImplementation);\n"
                  "        }",
        "after": "",
    },
]


def snapshot(workspace: Path) -> None:
    """Copy production and selected proof sources; share only immutable dependencies."""
    workspace.mkdir()
    shutil.copytree(CONTRACTS / "src", workspace / "src")
    (workspace / "lib").symlink_to(CONTRACTS / "lib", target_is_directory=True)
    for name in ("foundry.toml", "halmos.toml", "remappings.txt"):
        shutil.copy2(CONTRACTS / name, workspace / name)
    scripts = workspace / "script" / "formal"
    scripts.mkdir(parents=True)
    for name in ("run_hca.py", "requirements.txt", "check_intent_executor.py"):
        shutil.copy2(CONTRACTS / "script" / "formal" / name, scripts / name)
    proofs = workspace / "test" / "formal" / "hca"
    proofs.mkdir(parents=True)
    shutil.copytree(CONTRACTS / "test/formal/hca/account", proofs / "account")
    executor = proofs / "executor"
    executor.mkdir()
    shutil.copy2(CONTRACTS / "test/formal/hca/executor/DeployedIntentExecutor.sol", executor)
    shutil.copytree(CONTRACTS / "test/formal/hca/executor/fixtures", executor / "fixtures")
    for name in {case["file"] for case in CASES}:
        shutil.copy2(CONTRACTS / "test/formal/hca" / name, proofs / name)


def invoke(workspace: Path, output: Path, contracts: set[str], tests: set[str]) -> tuple[int, Path]:
    command = [
        sys.executable, str(workspace / "script/formal/run_hca.py"),
        "--match-contract", "^(?:" + "|".join(re.escape(c) for c in sorted(contracts)) + ")$",
        "--match-test", "^(?:" + "|".join(re.escape(t) for t in sorted(tests)) + ")$",
        "--timeout", "600",
    ]
    code = run_logged(command, output, dict(os.environ), 960)
    reports = sorted((workspace / "out/hca-formal-reports").glob("*/summary.json"))
    if not reports:
        raise RuntimeError("Verification runner did not produce a summary")
    return code, reports[-1].parent


def require_counterexample(case: dict, report: Path) -> dict:
    """A build error, unknown result, or blocked path cannot kill a mutation."""
    payload = json.loads((report / "halmos.json").read_text())
    identity = f"test/formal/hca/{case['file']}:{case['contract']}"
    groups = payload.get("test_results", {})
    if payload.get("exitcode") != 1 or set(groups) != {identity} or len(groups[identity]) != 1:
        raise RuntimeError(f"{case['name']}: missing unique counterexample result")
    result = groups[identity][0]
    paths = result.get("num_paths")
    models = result.get("models", [])
    if (
        result.get("name") != case["test"]
        or result.get("exitcode") != 1
        or not models
        or result.get("num_models") != len(models)
        or not all(model.get("is_valid") is True for model in models)
        or result.get("num_bounded_loops") != 0
        or not isinstance(paths, list)
        or len(paths) != 3
        or paths[0] <= 0
        or paths[2] != 0
    ):
        raise RuntimeError(f"{case['name']}: failure is not a complete, valid counterexample")
    problems, _ = diagnostics((report / "halmos.log").read_text())
    if problems:
        raise RuntimeError(f"{case['name']}: engine diagnostics: {problems}")
    summary = json.loads((report / "summary.json").read_text())
    if any("changed during verification" in issue for issue in summary["problems"]):
        raise RuntimeError(f"{case['name']}: proof inputs changed during verification")
    return result


def main() -> int:
    output = CONTRACTS / "out/hca-formal-mutations" / datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    output.mkdir(parents=True)
    workspace = output / "workspace"
    summary = {"passed": False, "mutations": [], "problems": []}
    originals = {case["source"]: digest(CONTRACTS / case["source"]) for case in CASES}
    try:
        snapshot(workspace)
        code, baseline = invoke(
            workspace, output / "baseline.log", {case["contract"] for case in CASES}, {case["test"] for case in CASES}
        )
        summary["baseline_report"] = str(baseline)
        if code != 0 or not json.loads((baseline / "summary.json").read_text())["passed"]:
            raise RuntimeError("Unmodified baseline did not pass the strict result gate")
        for case in CASES:
            path = workspace / case["source"]
            original = path.read_text()
            if original.count(case["before"]) != 1:
                raise RuntimeError(f"{case['name']}: mutation anchor is not unique")
            path.write_text(original.replace(case["before"], case["after"]))
            try:
                mutated_hash = digest(path)
                code, report = invoke(workspace, output / f"{case['name']}.log", {case["contract"]}, {case["test"]})
                if code != 1:
                    raise RuntimeError(f"{case['name']}: expected runner failure, got exitcode {code}")
                result = require_counterexample(case, report)
                summary["mutations"].append({**case, "sha256": mutated_hash, "report": str(report), "result": result})
                print(f"Detected mutation: {case['name']}", flush=True)
            finally:
                path.write_text(original)
        summary["passed"] = True
    except (OSError, ValueError, RuntimeError) as error:
        summary["problems"].append(f"{type(error).__name__}: {error}")
    finally:
        for source, checksum in originals.items():
            if digest(CONTRACTS / source) != checksum:
                summary["passed"] = False
                summary["problems"].append(f"Original source changed: {source}")
        write_json(output / "summary.json", summary)
    for problem in summary["problems"]:
        print(f"FAIL: {problem}", file=sys.stderr)
    print(f"Mutation summary: {output / 'summary.json'}")
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
