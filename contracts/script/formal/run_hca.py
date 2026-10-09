#!/usr/bin/env python3
"""Build the isolated HCA profile and reject incomplete Halmos property results."""

from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import threading
import time


CONTRACTS = Path(__file__).resolve().parents[2]
PROFILE = "hca-formal"
FORGE_VERSION = "1.8.5"
HALMOS_VERSION = "0.3.3"
SOLC_VERSION = "0.8.27+commit.40a35a09"
ARTIFACTS = CONTRACTS / "out" / PROFILE
REPORTS = CONTRACTS / "out" / "hca-formal-reports"
ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def capture(command: list[str], env: dict[str, str]) -> str:
    completed = subprocess.run(
        command, cwd=CONTRACTS, env=env, text=True, capture_output=True, timeout=30
    )
    if completed.returncode:
        raise RuntimeError(f"{' '.join(command)} failed:\n{completed.stdout}{completed.stderr}")
    return completed.stdout.strip()


def run_logged(command: list[str], log: Path, env: dict[str, str], timeout: int) -> int:
    """Stream a command and terminate its process group on timeout or interruption."""
    print(f"$ {' '.join(command)}", flush=True)
    with log.open("w") as output:
        process = subprocess.Popen(
            command,
            cwd=CONTRACTS,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            start_new_session=True,
            bufsize=1,
        )

        def copy_output() -> None:
            assert process.stdout is not None
            for line in process.stdout:
                output.write(line)
                output.flush()
                print(line, end="", flush=True)

        copier = threading.Thread(target=copy_output, daemon=True)
        copier.start()
        try:
            return process.wait(timeout=timeout)
        except (subprocess.TimeoutExpired, KeyboardInterrupt):
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            raise
        finally:
            copier.join()


def canonical_type(parameter: dict) -> str:
    type_name = parameter["type"]
    if type_name.startswith("tuple"):
        members = ",".join(canonical_type(item) for item in parameter["components"])
        return f"({members}){type_name[5:]}"
    return type_name


def discover(contract_pattern: str, test_pattern: str) -> tuple[set[tuple[str, str]], dict, dict]:
    """Read concrete proof-contract ABIs and preserve their compilation identities."""
    contracts = re.compile(contract_pattern)
    tests = re.compile(test_pattern)
    expected: set[tuple[str, str]] = set()
    artifacts: dict[str, str] = {}
    sources: dict[str, str] = {}
    names: dict[str, str] = {}
    for path in sorted(ARTIFACTS.rglob("*.json")):
        artifact = json.loads(path.read_text())
        metadata = artifact.get("metadata")
        if not isinstance(metadata, dict) or "abi" not in artifact:
            continue
        artifacts[str(path.relative_to(CONTRACTS))] = digest(path)
        if metadata.get("compiler", {}).get("version") != SOLC_VERSION:
            raise RuntimeError(f"Unexpected Solidity compiler in {path}")
        for source in metadata.get("sources", {}):
            source_path = CONTRACTS / source
            if not source_path.is_file():
                raise RuntimeError(f"Missing compiled source: {source}")
            sources[source] = digest(source_path)
        targets = metadata.get("settings", {}).get("compilationTarget", {})
        if len(targets) != 1:
            raise RuntimeError(f"Missing unique compilation target in {path}")
        source, name = next(iter(targets.items()))
        if not source.startswith("test/formal/hca/") or not contracts.search(name):
            continue
        if not artifact.get("bytecode", {}).get("object", "").removeprefix("0x"):
            continue
        identity = f"{source}:{name}"
        for item in artifact["abi"]:
            if item.get("type") != "function" or not item["name"].startswith("check_"):
                continue
            signature = item["name"] + "(" + ",".join(canonical_type(x) for x in item["inputs"]) + ")"
            if not tests.search(signature):
                continue
            if name in names and names[name] != identity:
                raise RuntimeError(f"Ambiguous proof-contract name: {name}")
            names[name] = identity
            key = (identity, signature)
            if key in expected:
                raise RuntimeError(f"Duplicate proof artifact: {key}")
            expected.add(key)
    if not expected:
        raise RuntimeError("No check_ properties matched the compiled HCA ABIs")
    return expected, artifacts, sources


def validate_results(expected: set[tuple[str, str]], payload: object) -> list[str]:
    """A reported pass requires an exact property set and no incomplete execution."""
    problems: list[str] = []
    if not isinstance(payload, dict):
        return ["Halmos JSON is not an object"]
    if type(payload.get("exitcode")) is not int or payload["exitcode"] != 0:
        problems.append(f"Halmos JSON exitcode is {payload.get('exitcode')!r}")
    groups = payload.get("test_results")
    if not isinstance(groups, dict):
        return problems + ["Halmos JSON has no test_results mapping"]
    seen: Counter[tuple[str, str]] = Counter()
    for contract, results in groups.items():
        if not isinstance(results, list):
            problems.append(f"Malformed results for {contract}")
            continue
        for result in results:
            if not isinstance(result, dict) or not isinstance(result.get("name"), str):
                problems.append(f"Malformed test result for {contract}")
                continue
            key = (contract, result["name"])
            seen[key] += 1
            label = f"{contract}.{result['name']}"
            if type(result.get("exitcode")) is not int or result["exitcode"] != 0:
                problems.append(f"{label}: exitcode {result.get('exitcode')!r}")
            if type(result.get("num_models")) is not int or result["num_models"] != 0 or result.get("models") != []:
                problems.append(f"{label}: counterexample or missing model status")
            paths = result.get("num_paths")
            if not isinstance(paths, list) or len(paths) != 3 or any(type(n) is not int or n < 0 for n in paths):
                problems.append(f"{label}: malformed path counts")
            else:
                total, success, blocked = paths
                if success == 0:
                    problems.append(f"{label}: no successful execution path")
                if blocked:
                    problems.append(f"{label}: {blocked} blocked execution paths")
                if total < success + blocked:
                    problems.append(f"{label}: inconsistent path counts")
            bounded = result.get("num_bounded_loops")
            if type(bounded) is not int or bounded != 0:
                problems.append(f"{label}: bounded/incomplete loops {bounded!r}")
    for contract, signature in sorted(expected - seen.keys()):
        problems.append(f"Missing property result: {contract}.{signature}")
    for contract, signature in sorted(seen.keys() - expected):
        problems.append(f"Unexpected property result: {contract}.{signature}")
    for key, count in seen.items():
        if count != 1:
            problems.append(f"Duplicate property result: {key} ({count})")
    return problems


def diagnostics(log: str) -> tuple[list[str], list[str]]:
    """Preserve metadata-only bytecode labels; reject every other engine diagnostic."""
    problems = []
    metadata_warnings = []
    for line in ANSI.sub("", log).splitlines():
        if re.match(r"^WARNING\s+unknown deployed bytecode:", line):
            # Halmos still executes this bytecode; only its source-name lookup failed.
            metadata_warnings.append(line)
        elif re.match(r"^(?:WARNING|ERROR|CRITICAL)(?::|\s)", line):
            problems.append(line)
    return problems, metadata_warnings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--match-contract", default=".*", help="Regex selecting proof contracts")
    parser.add_argument("--match-test", default="^check_", help="Regex selecting property signatures")
    parser.add_argument("--timeout", type=int, default=6000, help="Halmos wall-clock limit in seconds")
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    report = REPORTS / datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    report.mkdir(parents=True)
    print(f"HCA verification reports: {report}", flush=True)
    env = {key: value for key, value in os.environ.items() if not key.startswith("FOUNDRY_") or key == "FOUNDRY_SOLC"}
    env["FOUNDRY_PROFILE"] = PROFILE
    started = time.monotonic()
    summary: dict = {"passed": False, "problems": [], "selection": vars(args)}
    try:
        forge_version = capture(["forge", "--version"], env)
        halmos_version = capture(["halmos", "--version"], env)
        if not re.search(rf"Version:\s+{re.escape(FORGE_VERSION)}(?:\s|$)", forge_version):
            raise RuntimeError(f"Expected Foundry {FORGE_VERSION}; got {forge_version}")
        if halmos_version != f"halmos {HALMOS_VERSION}":
            raise RuntimeError(f"Expected Halmos {HALMOS_VERSION}; got {halmos_version}")
        config = json.loads(capture(["forge", "config", "--json"], env))
        required = {
            "src": "src/hca", "test": "test/formal/hca", "script": "script/formal",
            "out": "out/hca-formal", "cache_path": "cache/hca-formal",
            "auto_detect_solc": False, "evm_version": "cancun", "optimizer": True,
            "optimizer_runs": 200, "via_ir": False, "dynamic_test_linking": False,
            "ast": True, "extra_output": ["storageLayout", "metadata"],
        }
        for key, value in required.items():
            if config.get(key) != value:
                raise RuntimeError(f"Unexpected Foundry {key}: {config.get(key)!r}; expected {value!r}")
        executor_inputs = [
            CONTRACTS / "script/formal/check_intent_executor.py",
            CONTRACTS / "test/formal/hca/executor/DeployedIntentExecutor.sol",
            *sorted((CONTRACTS / "test/formal/hca/executor/fixtures").rglob("*")),
        ]
        executor_hashes = {
            str(path.relative_to(CONTRACTS)): digest(path) for path in executor_inputs if path.is_file()
        }
        attestation_path = report / "intent-executor.json"
        attestation = [sys.executable, "script/formal/check_intent_executor.py", "--json-output", str(attestation_path)]
        if run_logged(attestation, report / "intent-executor.log", env, 60):
            raise RuntimeError("Pinned IntentExecutor fixture attestation failed")
        executor_attestation = json.loads(attestation_path.read_text())
        if executor_attestation.get("passed") is not True:
            raise RuntimeError("Pinned IntentExecutor attestation did not report success")
        for path, checksum in executor_hashes.items():
            if digest(CONTRACTS / path) != checksum:
                raise RuntimeError(f"Executor attestation input changed during its verification: {path}")
        build = ["forge", "build", "--force", "--ast", "--extra-output", "storageLayout", "metadata"]
        if run_logged(build, report / "build.log", env, 300):
            raise RuntimeError("HCA compilation failed")
        expected, artifacts, sources = discover(args.match_contract, args.match_test)
        sources.update(executor_hashes)
        configuration_files = ["foundry.toml", "halmos.toml", "script/formal/run_hca.py", "script/formal/requirements.txt"]
        sources.update({path: digest(CONTRACTS / path) for path in configuration_files})
        manifest = {
            "forge": forge_version, "halmos": halmos_version, "solc": SOLC_VERSION,
            "commit": capture(["git", "rev-parse", "HEAD"], env),
            "selection": vars(args), "foundry": required,
            "halmos_config": (CONTRACTS / "halmos.toml").read_text(),
            "intent_executor_attestation": executor_attestation,
            "properties": [{"contract": c, "signature": s} for c, s in sorted(expected)],
            "artifact_sha256": artifacts, "source_sha256": sources,
        }
        write_json(report / "manifest.json", manifest)
        summary["expected_properties"] = len(expected)
        contract_regex = "^(?:" + "|".join(re.escape(c.rsplit(":", 1)[1]) for c in sorted({c for c, _ in expected})) + ")$"
        test_regex = "^(?:" + "|".join(re.escape(s) for s in sorted({s for _, s in expected})) + ")$"
        command = [
            "halmos", "--config", "halmos.toml", "--function", "check_",
            "--match-contract", contract_regex, "--match-test", test_regex,
            "--json-output", str(report / "halmos.json"),
        ]
        exitcode = run_logged(command, report / "halmos.log", env, args.timeout)
        summary["halmos_exitcode"] = exitcode
        if exitcode:
            summary["problems"].append(f"Halmos process exitcode: {exitcode}")
        result_path = report / "halmos.json"
        if result_path.is_file():
            summary["problems"].extend(validate_results(expected, json.loads(result_path.read_text())))
        else:
            summary["problems"].append("Halmos did not produce a result JSON file")
        engine_problems, metadata_warnings = diagnostics((report / "halmos.log").read_text())
        summary["problems"].extend(engine_problems)
        summary["metadata_warnings"] = metadata_warnings
        for path, checksum in {**artifacts, **sources}.items():
            source = CONTRACTS / path
            if not source.is_file() or digest(source) != checksum:
                summary["problems"].append(f"Compiled artifact or input changed during verification: {path}")
        summary["passed"] = not summary["problems"]
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        summary["problems"].append(f"{type(error).__name__}: {error}")
    finally:
        summary["elapsed_seconds"] = round(time.monotonic() - started, 3)
        write_json(report / "summary.json", summary)
    for problem in summary["problems"]:
        print(f"FAIL: {problem}", file=sys.stderr)
    if summary["passed"]:
        print(f"Verified {summary['expected_properties']} HCA properties with no incomplete paths or reached loop bounds.")
    print(f"Summary: {report / 'summary.json'}")
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
