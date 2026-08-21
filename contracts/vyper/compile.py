#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VYPER_ROOT = ROOT / "vyper"
OUT_ROOT = ROOT / "out" / "vyper"
VYPER_PYTHONPATH = Path(os.environ.get("VYPER_ALPHA_PATH", "/mnt/data/vyper-alpha"))


def compile_one(source: Path, optimize: str = "gas") -> Path:
    rel = source.relative_to(ROOT).as_posix()
    env = os.environ.copy()
    env["PYTHONPATH"] = f"{VYPER_PYTHONPATH}{os.pathsep}{env.get('PYTHONPATH', '')}".rstrip(os.pathsep)
    layout_path = source.with_suffix(".layout.json")
    cmd = [
        sys.executable,
        "-m",
        "vyper",
        "--evm-version",
        "cancun",
        "-O",
        optimize,
        "-p",
        str(VYPER_ROOT),
        "-f",
        "combined_json",
        rel,
    ]
    if layout_path.exists():
        cmd[3:3] = ["--storage-layout-file", str(layout_path)]
    proc = subprocess.run(cmd, cwd=ROOT, env=env, text=True, capture_output=True)
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        raise SystemExit(f"Vyper compilation failed: {rel}")
    combined = json.loads(proc.stdout)
    data = combined[rel]
    out_path = OUT_ROOT / source.relative_to(VYPER_ROOT).with_suffix(".json")
    out_path.parent.mkdir(parents=True, exist_ok=True)
    artifact = {
        "abi": data["abi"],
        "bytecode": {
            "object": data["bytecode"].removeprefix("0x"),
            "sourceMap": data.get("source_map", ""),
            "linkReferences": {},
        },
        "deployedBytecode": {
            "object": data["bytecode_runtime"].removeprefix("0x"),
            "sourceMap": data.get("source_map_runtime", ""),
            "linkReferences": {},
        },
        "methodIdentifiers": data.get("method_identifiers", {}),
        "metadata": data.get("metadata", {}),
        "storageLayout": data.get("layout"),
        "compiler": {"name": "vyper", "version": combined["version"]},
        "sourceName": rel,
    }
    out_path.write_text(json.dumps(artifact, indent=2) + "\n")
    return out_path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("sources", nargs="+")
    parser.add_argument("-O", "--optimize", default="gas", choices=("gas", "codesize", "1", "2", "3", "s"))
    args = parser.parse_args()
    for raw in args.sources:
        source = Path(raw)
        if not source.is_absolute():
            candidate = ROOT / source
            if not candidate.exists():
                candidate = VYPER_ROOT / source
            source = candidate
        print(compile_one(source.resolve(), args.optimize).relative_to(ROOT))


if __name__ == "__main__":
    main()
