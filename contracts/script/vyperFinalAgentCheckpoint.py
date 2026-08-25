#!/usr/bin/env python3
from __future__ import annotations

import subprocess
from pathlib import Path

import vyperFinalAgent as agent

ROOT = Path(__file__).resolve().parents[2]
_original_tool_call = agent.tool_call
_tool_count = 0
_checkpoint_count = 0


def checkpoint() -> None:
    global _checkpoint_count
    _checkpoint_count += 1
    subprocess.run(["git", "config", "user.name", "github-actions[bot]"], cwd=ROOT, check=False)
    subprocess.run(["git", "config", "user.email", "41898282+github-actions[bot]@users.noreply.github.com"], cwd=ROOT, check=False)
    subprocess.run(["git", "add", "-A"], cwd=ROOT, check=False)
    diff = subprocess.run(["git", "diff", "--cached", "--quiet"], cwd=ROOT, check=False)
    if diff.returncode != 0:
        subprocess.run(
            ["git", "commit", "-m", f"experiment: Vyper completion checkpoint {_checkpoint_count} [vyper-final-agent]"],
            cwd=ROOT,
            check=False,
        )
        subprocess.run(["git", "push", "origin", "HEAD:experiment/vyper-a971bd6"], cwd=ROOT, check=False)


def tool_call(name: str, args: dict) -> str:
    global _tool_count
    result = _original_tool_call(name, args)
    _tool_count += 1
    if _tool_count % 24 == 0:
        checkpoint()
    return result


agent.tool_call = tool_call
try:
    agent.main()
finally:
    checkpoint()
