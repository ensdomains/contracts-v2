#!/usr/bin/env bun
import { execFileSync } from "node:child_process";
import {
  cpSync,
  existsSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { keccak256, toBytes } from "viem";

// Submits every deployed contract of a network for source-code verification on
// Etherscan and Sourcify via @rocketh/verifier.
//
// The verifier rebuilds the solc standard-json input from each artifact's
// recorded metadata, which requires the literal source content of every input
// file. Hardhat-compiled artifacts embed that content, but forge-compiled ones
// record only each source's hash and URLs, leaving the verifier unable to
// reconstruct the input. To make verification work regardless of which compiler
// produced an artifact, this backfills any missing source content from disk —
// keyed by the metadata source paths and checked against the recorded hash — into
// a throwaway copy of the deployment set before handing off to the verifier.

const contractsDir = resolve(dirname(fileURLToPath(import.meta.url)), "..");

type Backend = "etherscan" | "sourcify";

function parseArgs(argv: string[]) {
  let network: string | undefined;
  let backends: Backend[] = ["etherscan", "sourcify"];
  let skipV1 = false;
  const passthrough: string[] = [];
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--network" || arg === "-n" || arg === "-e") {
      network = argv[++i];
    } else if (arg === "--etherscan-only") {
      backends = ["etherscan"];
    } else if (arg === "--sourcify-only") {
      backends = ["sourcify"];
    } else if (arg === "--skip-v1") {
      skipV1 = true;
    } else {
      passthrough.push(arg);
    }
  }
  if (!network) {
    throw new Error(
      "usage: bun ./script/verify.ts --network <name> [--etherscan-only|--sourcify-only] [--skip-v1] [<extra rocketh-verify args>] (do not separate extra args with --; they are forwarded as-is)",
    );
  }
  return { network, backends, skipV1, passthrough };
}

// The deployed metadata records source paths under solc's source unit prefix
// (e.g. `project/src/...`, `project/lib/...`); the foundry project root maps to
// the contracts directory, so the prefix is stripped to resolve the file.
function diskPathForSource(sourceKey: string) {
  return resolve(contractsDir, sourceKey.replace(/^project\//, ""));
}

function backfillSourceContent(artifactPath: string) {
  const artifact = JSON.parse(readFileSync(artifactPath, "utf8"));
  if (typeof artifact.metadata !== "string") return false;

  const metadata = JSON.parse(artifact.metadata);
  const sources = metadata.sources ?? {};
  let patched = 0;
  for (const [sourceKey, source] of Object.entries<any>(sources)) {
    if (source.content !== undefined) continue;
    const diskPath = diskPathForSource(sourceKey);
    if (!existsSync(diskPath)) {
      throw new Error(
        `cannot backfill source for ${artifact.contractName ?? artifactPath}: ${sourceKey} not found at ${diskPath}`,
      );
    }
    const content = readFileSync(diskPath, "utf8");
    if (source.keccak256 && keccak256(toBytes(content)) !== source.keccak256) {
      throw new Error(
        `source hash mismatch for ${sourceKey} (file on disk differs from the deployed source)`,
      );
    }
    source.content = content;
    patched++;
  }
  if (patched === 0) return false;

  artifact.metadata = JSON.stringify(metadata);
  writeFileSync(artifactPath, JSON.stringify(artifact, null, 2));
  return true;
}

/// Verifies one deployment namespace.
///
/// Each namespace is staged under its own throwaway root and handed to
/// `rocketh-verify` as a flat environment name. A v1 stack lives at
/// `deployments/v1/<namespace>`, and passing that path as the environment would
/// put a separator in the name, so the leaf is staged on its own instead.
function verifyNamespace({
  srcDir,
  envName,
  label,
  backends,
  passthrough,
}: {
  srcDir: string;
  envName: string;
  label: string;
  backends: Backend[];
  passthrough: string[];
}) {
  const stagingRoot = mkdtempSync(join(tmpdir(), "rocketh-verify-"));
  const stagingDir = join(stagingRoot, envName);
  cpSync(srcDir, stagingDir, { recursive: true });

  try {
    let backfilled = 0;
    for (const file of readdirSync(stagingDir)) {
      if (!file.endsWith(".json") || file.startsWith(".")) continue;
      if (backfillSourceContent(join(stagingDir, file))) {
        console.log(
          `backfilled source content for ${file.replace(/\.json$/, "")}`,
        );
        backfilled++;
      }
    }
    if (backfilled > 0) {
      console.log(
        `backfilled ${backfilled} artifact(s) missing literal sources\n`,
      );
    }

    for (const backend of backends) {
      console.log(`\n=== verifying ${label} on ${backend} ===`);
      execFileSync(
        "bun",
        [
          "run",
          "rocketh-verify",
          "--",
          "-d",
          stagingRoot,
          "-e",
          envName,
          backend,
          ...passthrough,
        ],
        { cwd: contractsDir, stdio: "inherit", env: process.env },
      );
    }
  } finally {
    rmSync(stagingRoot, { recursive: true, force: true });
  }
}

function main() {
  const { network, backends, skipV1, passthrough } = parseArgs(
    process.argv.slice(2),
  );

  const srcDir = join(contractsDir, "deployments", network);
  if (!existsSync(srcDir)) {
    throw new Error(
      `no deployments found for network "${network}" (${srcDir})`,
    );
  }

  const targets = [{ srcDir, envName: network, label: network }];

  // A clean testnet deploys its own ENSv1 stack into `deployments/v1/<ns>`, and
  // those contracts need verifying as much as the v2 ones. Nothing distinguishes
  // that tree from a network's real v1 by inspection, so both are offered and
  // `--skip-v1` opts out; already-verified contracts are skipped by the backend
  // regardless.
  const v1Dir = join(contractsDir, "deployments", "v1", network);
  if (!skipV1 && existsSync(v1Dir)) {
    targets.push({
      srcDir: v1Dir,
      envName: network,
      label: `${network} (ENSv1)`,
    });
  }

  console.log(
    `verifying ${targets.length} deployment set(s): ${targets
      .map((t) => t.label)
      .join(", ")}`,
  );
  for (const target of targets) {
    verifyNamespace({ ...target, backends, passthrough });
  }
}

main();
