#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import subprocess
import urllib.request
from pathlib import Path

import vyperFinalAgent as agent

ROOT = Path(__file__).resolve().parents[2]
TOKEN = os.environ["GITHUB_MODELS_TOKEN"]

# Discover the actual model IDs granted to this repository, then rank capable coding/reasoning models.
try:
    req = urllib.request.Request(
        "https://models.github.ai/catalog/models",
        headers={"Authorization": f"Bearer {TOKEN}", "Accept": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=60) as response:
        catalog = json.loads(response.read())
    rows = catalog if isinstance(catalog, list) else catalog.get("models", catalog.get("value", []))
    ids = [str(x.get("id") or x.get("name") or "") for x in rows if isinstance(x, dict)]
    def rank(model_id: str) -> tuple[int, str]:
        s = model_id.lower()
        score = 0
        if "codex" in s: score += 1000
        if "gpt-5.6" in s: score += 950
        elif "gpt-5.5" in s: score += 900
        elif "gpt-5.4" in s: score += 850
        elif "gpt-5" in s: score += 800
        if "opus" in s: score += 700
        if "sonnet" in s: score += 600
        if "gpt-4.1" in s: score += 500
        if "mini" in s or "nano" in s: score -= 300
        if "embed" in s or "audio" in s or "image" in s: score -= 2000
        return (-score, model_id)
    discovered = sorted((x for x in ids if x), key=rank)
except Exception as exc:
    discovered = []
    (agent.REPORT / "catalog-error.txt").write_text(repr(exc) + "\n")

agent.PREFERRED_MODELS = list(dict.fromkeys(discovered + [
    "openai/gpt-5.6-codex",
    "openai/gpt-5.5-codex",
    "openai/gpt-5.4",
    "openai/gpt-5",
    "openai/gpt-4.1",
    "openai/gpt-4o",
    "anthropic/claude-opus-4.1",
    "anthropic/claude-sonnet-4",
]))
(agent.REPORT / "candidate-models.json").write_text(json.dumps(agent.PREFERRED_MODELS, indent=2) + "\n")

_original_tool_call = agent.tool_call
_tool_count = 0
_checkpoint_count = 0


def checkpoint() -> None:
    global _checkpoint_count
    _checkpoint_count += 1
    subprocess.run(["git", "config", "user.name", "github-actions[bot]"], cwd=ROOT, check=False)
    subprocess.run(["git", "config", "user.email", "41898282+github-actions[bot]@users.noreply.github.com"], cwd=ROOT, check=False)
    subprocess.run(["git", "add", "-A"], cwd=ROOT, check=False)
    if subprocess.run(["git", "diff", "--cached", "--quiet"], cwd=ROOT, check=False).returncode != 0:
        subprocess.run(["git", "commit", "-m", f"experiment: Vyper completion checkpoint {_checkpoint_count} [vyper-final-agent]"], cwd=ROOT, check=False)
        subprocess.run(["git", "push", "origin", "HEAD:experiment/vyper-a971bd6"], cwd=ROOT, check=False)


def tool_call(name: str, args: dict) -> str:
    global _tool_count
    value = _original_tool_call(name, args)
    _tool_count += 1
    if _tool_count % 20 == 0:
        checkpoint()
    return value


agent.tool_call = tool_call
try:
    agent.main()
finally:
    checkpoint()
