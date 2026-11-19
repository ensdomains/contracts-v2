#!/usr/bin/env python3
"""Verify pinned IntentExecutor fixture consistency, optionally against historical RPC state.

Source matching relies on the recorded Sourcify compiler metadata and immutable references.
This command recomputes bytecode hashes and immutable normalization; it does not recompile
the upstream sources or request a new source-verifier attestation, including with --rpc.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
from urllib.request import Request, urlopen


CONTRACTS = Path(__file__).resolve().parents[2]
FIXTURES = CONTRACTS / "test/formal/hca/executor/fixtures"
SNAPSHOT = FIXTURES / "intent-executor.json"
HELPER = FIXTURES.parent / "DeployedIntentExecutor.sol"
NETWORKS = {"mainnet": 1, "sepolia": 11155111}


def require(condition: bool, message: str) -> None:
    """Raise a checked attestation failure without relying on Python assertions."""
    if not condition:
        raise ValueError(message)


def hex_bytes(value: object, label: str, length: int | None = None) -> bytes:
    """Decode a strict, byte-aligned hexadecimal field and optionally check its width."""
    require(isinstance(value, str) and re.fullmatch(r"0x(?:[0-9a-fA-F]{2})*", value) is not None,
            f"{label}: malformed hexadecimal bytes")
    data = bytes.fromhex(value[2:])
    require(length is None or len(data) == length, f"{label}: unexpected byte length {len(data)}")
    return data


def keccak(data: bytes) -> str:
    """Use the Ethereum hash implementation installed with the pinned Halmos requirements."""
    try:
        from eth_hash.auto import keccak as ethereum_keccak
    except ImportError as error:
        raise RuntimeError("Run with the Python environment from script/formal/requirements.txt") from error
    return "0x" + ethereum_keccak(data).hex()


def literal(helper: str, name: str, wrapped_slot: bool = False) -> int:
    """Read an exact address, hash, or storage-slot literal from the Solidity fixture."""
    value = r"0x([0-9a-fA-F]+)"
    if wrapped_slot:
        value = r"bytes32\s*\(\s*uint256\s*\(\s*" + value + r"\s*\)\s*\)"
    matches = re.findall(r"\bconstant\s+" + re.escape(name) + r"\s*=\s*" + value + r"\s*;", helper)
    require(len(matches) == 1, f"Missing or ambiguous Solidity constant {name}")
    return int(matches[0], 16)


def embedded_runtime(helper: str, name: str) -> bytes:
    """Accept only a runtime accessor that returns its complete literal without modification."""
    pattern = (
        r"\bfunction\s+" + re.escape(name)
        + r"\s*\(\s*\)\s+internal\s+pure\s+returns\s*\(\s*bytes\s+memory\s*\)\s*"
        + r'\{\s*return\s+hex"([0-9a-fA-F]+)"\s*;\s*\}'
    )
    matches = re.findall(pattern, helper)
    require(len(matches) == 1, f"Missing or ambiguous literal runtime accessor {name}")
    return hex_bytes("0x" + matches[0], name)


def check_code(record: dict, embedded: bytes, label: str) -> bytes:
    """Recompute both recorded hashes and compare the bytes installed by Solidity."""
    code = hex_bytes(record["runtime"], f"{label} runtime")
    require(bool(code), f"{label}: empty deployed runtime")
    require(type(record["length"]) is int and len(code) == record["length"], f"{label}: length mismatch")
    require(hashlib.sha256(code).hexdigest() == record["sha256"], f"{label}: SHA-256 mismatch")
    require(keccak(code) == record["keccak256"], f"{label}: Keccak-256 mismatch")
    require(code == embedded, f"{label}: Solidity embedded runtime differs from snapshot")
    return code


def check_immutables(snapshot: dict, implementations: dict[str, bytes]) -> dict:
    """Check every immutable slice and compare the remaining mainnet and Sepolia bytecode."""
    source = snapshot["source_verification"]["implementation"]
    references = source["immutable_references"]
    values = source["immutable_values"]
    require(bool(references) and references.keys() == values.keys(), "Immutable reference/value keys differ")
    lengths = {len(code) for code in implementations.values()}
    require(len(lengths) == 1, "Mainnet and Sepolia implementation lengths differ")
    size = lengths.pop()
    covered: set[int] = set()
    normalized = {name: bytearray(code) for name, code in implementations.items()}
    changed = []
    regions = 0
    for immutable, entries in references.items():
        require(bool(entries), f"Immutable {immutable}: no reference locations")
        require(values[immutable].keys() == NETWORKS.keys(), f"Immutable {immutable}: network keys differ")
        for name in NETWORKS:
            require(len(values[immutable][name]) == len(entries), f"Immutable {immutable}: value count differs")
        for index, entry in enumerate(entries):
            start, length = entry["start"], entry["length"]
            require(type(start) is int and type(length) is int and 0 <= start and 0 < length <= size - start,
                    f"Immutable {immutable}: invalid byte range")
            positions = set(range(start, start + length))
            require(not covered.intersection(positions), f"Immutable {immutable}: overlapping reference ranges")
            covered.update(positions)
            regions += 1
            for name, code in implementations.items():
                recorded = hex_bytes(values[immutable][name][index], f"{name} immutable {immutable}", length)
                require(code[start:start + length] == recorded, f"{name} immutable {immutable}: value mismatch")
                require(values[immutable][name][index] == values[immutable][name][0],
                        f"{name} immutable {immutable}: inconsistent repeated value")
                normalized[name][start:start + length] = bytes(length)
        if values[immutable]["mainnet"] != values[immutable]["sepolia"]:
            changed.append(immutable)
    require(normalized["mainnet"] == normalized["sepolia"],
            "Mainnet and Sepolia implementations differ outside declared immutable references")
    require(source["mainnet_diff_outside_immutables"] is False, "Recorded immutable normalization result differs")
    return {
        "immutable_regions": regions,
        "changed_immutable_ids": sorted(changed),
        "normalized_implementation_keccak256": keccak(bytes(normalized["mainnet"])),
    }


def rpc(endpoint: str, method: str, params: list) -> object:
    """Issue a read-only JSON-RPC request with a finite timeout and reject RPC errors."""
    require(endpoint.startswith("https://"), "Pinned RPC endpoint must use HTTPS")
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    request = Request(endpoint, data=body, headers={
        "Content-Type": "application/json", "User-Agent": "HCA-formal-verification/1.0",
    })
    with urlopen(request, timeout=30) as response:
        payload = json.load(response)
    require(isinstance(payload, dict) and payload.get("id") == 1, f"{method}: malformed RPC envelope")
    require("error" not in payload and "result" in payload, f"{method}: RPC failure {payload.get('error')!r}")
    return payload["result"]


def check_rpc(name: str, network: dict) -> None:
    """Verify chain, historical block, runtime and proxy slots, then reconfirm the block hash."""
    endpoint = network["rpc"]
    block_tag = hex(network["block_number"])
    require(int(rpc(endpoint, "eth_chainId", []), 16) == network["chain_id"], f"{name}: RPC chain ID mismatch")

    def check_block() -> None:
        block = rpc(endpoint, "eth_getBlockByNumber", [block_tag, False])
        require(isinstance(block, dict), f"{name}: historical block unavailable")
        require(int(block["number"], 16) == network["block_number"], f"{name}: RPC block number mismatch")
        require(block["hash"].lower() == network["block_hash"].lower(), f"{name}: pinned block hash mismatch")
        require(int(block["timestamp"], 16) == network["block_timestamp"], f"{name}: block timestamp mismatch")

    check_block()
    for kind in ("proxy", "implementation"):
        record = network[kind]
        actual = rpc(endpoint, "eth_getCode", [record["address"], block_tag])
        require(hex_bytes(actual, f"{name} RPC {kind}") == hex_bytes(record["runtime"], kind),
                f"{name}: RPC {kind} runtime mismatch")
    for slot, expected in network["proxy"]["storage"].items():
        actual = rpc(endpoint, "eth_getStorageAt", [network["proxy"]["address"], slot, block_tag])
        require(hex_bytes(actual, f"{name} RPC slot {slot}", 32) == hex_bytes(expected, slot, 32),
                f"{name}: RPC proxy storage mismatch at {slot}")
    check_block()


def verify(snapshot_path: Path = SNAPSHOT, helper_path: Path = HELPER, live_rpc: bool = False) -> dict:
    """Attest local consistency; optional RPC checking independently rechecks the recorded deployment."""
    snapshot = json.loads(snapshot_path.read_text())
    helper = helper_path.read_text()
    require(snapshot["format"] == 1, "Unsupported executor snapshot format")
    require(snapshot["networks"].keys() == NETWORKS.keys(), "Snapshot must contain exactly mainnet and Sepolia")
    slots = {
        literal(helper, "IMPLEMENTATION_SLOT", True): literal(helper, "IMPLEMENTATION"),
        literal(helper, "OWNER_SLOT", True): literal(helper, "PROXY_OWNER"),
    }
    require(len(slots) == 2, "Implementation and owner storage slots overlap")
    proxy = embedded_runtime(helper, "proxyRuntime")
    implementations = {}
    networks = {}
    for name, chain in NETWORKS.items():
        network = snapshot["networks"][name]
        require(type(network["chain_id"]) is int and network["chain_id"] == chain, f"{name}: invalid chain ID")
        require(type(network["block_number"]) is int and network["block_number"] > 0, f"{name}: invalid pinned block")
        hex_bytes(network["block_hash"], f"{name} block hash", 32)
        for kind, constant in (("proxy", "PROXY"), ("implementation", "IMPLEMENTATION")):
            address = hex_bytes(network[kind]["address"], f"{name} {kind} address", 20)
            require(int.from_bytes(address) == literal(helper, constant), f"{name}: {kind} address mismatch")
        check_code(network["proxy"], proxy, f"{name} proxy")
        implementations[name] = check_code(network["implementation"], embedded_runtime(helper, f"{name}Runtime"),
                                          f"{name} implementation")
        require(int(network["proxy"]["keccak256"], 16) == literal(helper, "PROXY_CODE_HASH"),
                f"{name}: proxy code hash constant mismatch")
        require(int(network["implementation"]["keccak256"], 16) == literal(helper, f"{name.upper()}_CODE_HASH"),
                f"{name}: implementation code hash constant mismatch")
        storage = {int(slot, 16): int.from_bytes(hex_bytes(value, f"{name} proxy storage", 32))
                   for slot, value in network["proxy"]["storage"].items()}
        require(storage == slots, f"{name}: proxy control storage differs from helper constants")
        networks[name] = {key: network[key] for key in ("chain_id", "block_number", "block_hash")}
        networks[name].update({f"{kind}_keccak256": network[kind]["keccak256"] for kind in ("proxy", "implementation")})
    immutable_report = check_immutables(snapshot, implementations)
    if live_rpc:
        for name, network in snapshot["networks"].items():
            check_rpc(name, network)
    return {
        "passed": True, "mode": "rpc" if live_rpc else "offline",
        "snapshot_sha256": hashlib.sha256(snapshot_path.read_bytes()).hexdigest(),
        "helper_sha256": hashlib.sha256(helper_path.read_bytes()).hexdigest(),
        "source_matching": {
            "recompiled": False,
            "source_verifier_requeried": False,
            "assumption": "Recorded Sourcify compiler metadata correctly identifies the immutable byte ranges.",
            "recorded_verifier_results": {
                kind: {
                    "url": snapshot["source_verification"][kind]["url"],
                    "runtime_match": snapshot["source_verification"][kind]["runtime_match"],
                    "compiler_version": snapshot["source_verification"][kind]["compiler"]["compilerVersion"],
                }
                for kind in ("proxy", "implementation")
            },
        },
        "networks": networks, **immutable_report,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rpc", action="store_true", help="Also recheck both recorded historical deployments using their public RPCs")
    parser.add_argument("--json-output", type=Path, help="Write the attestation report, including any failure")
    args = parser.parse_args()
    try:
        report = verify(live_rpc=args.rpc)
    except (OSError, ValueError, TypeError, KeyError, RuntimeError) as error:
        report = {"passed": False, "mode": "rpc" if args.rpc else "offline", "problem": f"{type(error).__name__}: {error}"}
    if args.json_output:
        args.json_output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    if report["passed"]:
        method = "pinned RPC state" if args.rpc else "offline snapshot consistency"
        print(f"IntentExecutor {method} verified for mainnet and Sepolia; {report['immutable_regions']} immutable regions checked.")
    else:
        print(f"FAIL: IntentExecutor attestation: {report['problem']}", file=sys.stderr)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
