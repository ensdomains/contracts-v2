#!/usr/bin/env bun
/**
 * Deploy ENSv2 to a Tenderly Virtual TestNet that forks Sepolia.
 *
 * ## What this script does
 *
 * 1. Connects to your Tenderly VNet RPC (`TENDERLY_RPC_URL`).
 * 2. Verifies the chain id is Sepolia (11155111).
 * 3. Funds and **impersonates your wallet** — no private key required. All ENSv2
 *    deploys run as that address (`deployer` + `owner` in Rocketh).
 * 4. Also impersonates the Sepolia v1 ops EOA (`0x0F32…`) for the handful of fork
 *    steps that must run as the on-chain owner of Root / BaseRegistrar / NameWrapper.
 * 5. Copies existing Sepolia ENS v1 contract addresses into Rocketh deployment records.
 * 6. Installs missing Sepolia v1.7 pieces, then hands `RegistrarSecurityController`
 *    ownership to your wallet.
 * 7. Deploys all ENSv2 contracts from `contracts/deploy/`.
 * 8. Runs `activateV2` (v2 controllers on .eth; your wallet can register via the SC).
 * 9. Prints address tables and writes artifacts to `contracts/deployments/tenderly-sepolia-11155111/`.
 *
 * ## Prerequisites
 *
 * - Compiled contracts: `bun run compile` (from `contracts/`).
 * - Tenderly Virtual TestNet forked from **Sepolia** with **Admin RPC** enabled
 *   (`tenderly_setBalance`, `tenderly_impersonateAccount`).
 * - `TENDERLY_RPC_URL` and your wallet address (see below).
 *
 * ## Usage
 *
 * ```sh
 * cd contracts
 * bun run compile
 * TENDERLY_RPC_URL="https://…" \
 * IMPERSONATE_ADDRESS="0xYourTestWallet" \
 * bun run tenderly
 *
 * # or
 * TENDERLY_RPC_URL="https://…" bun run tenderly -- --wallet 0xYourTestWallet
 * ```
 *
 * Optional environment variables:
 * - `SKIP_V17_UPGRADE=1` / `--skip-v17` — skip RegistrarSecurityController install.
 * - `SKIP_ACTIVATE=1` / `--skip-activate` — skip post-deploy controller handoff.
 * - `RESET_DEPLOYMENTS=0` / `--no-reset` — keep existing deployment artifacts.
 *
 * @see script/tenderly/deploy.ts for the implementation.
 */

import { parseArgs } from "node:util";
import { getAddress, isAddress } from "viem";

import { deployToTenderlySepoliaFork } from "./tenderly/deploy.js";

const args = parseArgs({
  args: process.argv.slice(2),
  options: {
    wallet: { type: "string" },
    "skip-v17": { type: "boolean", default: false },
    "skip-activate": { type: "boolean", default: false },
    "no-reset": { type: "boolean", default: false },
  },
  strict: true,
});

const rpcUrl = process.env.TENDERLY_RPC_URL;
if (!rpcUrl) {
  console.error(
    "Missing TENDERLY_RPC_URL.\n\n" +
      "Copy the RPC URL from your Tenderly Virtual TestNet (must be a Sepolia fork).\n" +
      "Example:\n" +
      '  TENDERLY_RPC_URL="https://virtual…" IMPERSONATE_ADDRESS="0x…" bun run tenderly\n',
  );
  process.exit(1);
}

const walletRaw = args.values.wallet ?? process.env.IMPERSONATE_ADDRESS;
if (!walletRaw) {
  console.error(
    "Missing wallet address.\n\n" +
      "Pass the address to impersonate (your test wallet, no private key needed):\n" +
      '  IMPERSONATE_ADDRESS="0x…" bun run tenderly\n' +
      '  bun run tenderly -- --wallet 0x…\n',
  );
  process.exit(1);
}

if (!isAddress(walletRaw)) {
  console.error(`Invalid wallet address: ${walletRaw}`);
  process.exit(1);
}

const wallet = getAddress(walletRaw);

const t0 = Date.now();
console.log("ENSv2 Tenderly Sepolia-fork deploy");
console.log(`  RPC: ${rpcUrl}`);
console.log(`  Wallet: ${wallet}`);

const result = await deployToTenderlySepoliaFork({
  rpcUrl,
  wallet,
  resetDeployments: !args.values["no-reset"] && process.env.RESET_DEPLOYMENTS !== "0",
  skipV17Upgrade:
    args.values["skip-v17"] || process.env.SKIP_V17_UPGRADE === "1",
  skipActivate:
    args.values["skip-activate"] || process.env.SKIP_ACTIVATE === "1",
});

console.log();
console.log("Named accounts");
console.table([
  { Role: "deployer (your wallet)", Address: result.namedAccounts.deployer },
  { Role: "owner (your wallet)", Address: result.namedAccounts.owner },
  {
    Role: "Sepolia v1 owner (impersonated for fork steps only)",
    Address: result.namedAccounts.sepoliaV1Owner,
  },
]);

console.log();
console.log("Deployed contracts");
console.table(
  Object.entries(result.rocketh.deployments)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([name, { address }]) => ({
      Contract: name,
      Address: getAddress(address),
    })),
);

console.log();
console.log("Artifacts saved to:", result.deploymentsDir);
console.log(`Done in ${Date.now() - t0}ms`);
