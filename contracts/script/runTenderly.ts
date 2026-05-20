#!/usr/bin/env bun
/**
 * Deploy ENSv2 to a Tenderly Virtual TestNet that forks Sepolia.
 *
 * ## What this script does
 *
 * 1. Connects to your Tenderly VNet RPC (`TENDERLY_RPC_URL`).
 * 2. Verifies the chain id is Sepolia (11155111).
 * 3. Funds and impersonates:
 *    - the `deployer` account (mnemonic account #0 by default), and
 *    - the Sepolia ENS operational owner (`0x0F32…`, controls Root / BaseRegistrar / NameWrapper).
 * 4. Copies existing Sepolia ENS v1 contract addresses into Rocketh deployment records
 *    (so v1 contracts are not redeployed).
 * 5. Deploys missing Sepolia v1.7 pieces (`RegistrarSecurityController`, `WrappedETHRegistrarController`)
 *    and transfers BaseRegistrar ownership to the security controller when needed.
 * 6. Deploys all ENSv2 contracts from `contracts/deploy/`.
 * 7. Runs `activateV2`: wires Graveyard + ETHRenewerV1 as .eth controllers and retires v1 paths.
 * 8. Prints address tables and writes artifacts to `contracts/deployments/tenderly-sepolia-11155111/`.
 *
 * ## Prerequisites
 *
 * - Compiled contracts: `bun run compile` (from `contracts/`).
 * - Tenderly Virtual TestNet forked from **Sepolia** with **Admin RPC** / state overrides enabled
 *   (needed for `tenderly_setBalance` / `tenderly_impersonateAccount`).
 * - `TENDERLY_RPC_URL` in the environment (from the Tenderly dashboard).
 *
 * ## Usage
 *
 * ```sh
 * cd contracts
 * bun run compile
 * TENDERLY_RPC_URL="https://…" bun run tenderly
 * ```
 *
 * Optional environment variables:
 * - `DEPLOYER_PRIVATE_KEY` — hex private key for deployer (overrides mnemonic).
 * - `DEPLOYER_MNEMONIC` — BIP-39 mnemonic (default: standard Anvil test mnemonic).
 * - `SKIP_V17_UPGRADE=1` — skip RegistrarSecurityController / Wrapped controller install.
 * - `SKIP_ACTIVATE=1` — skip post-deploy controller handoff.
 * - `RESET_DEPLOYMENTS=0` — keep existing `deployments/tenderly-sepolia-*` folder.
 *
 * @see script/tenderly/deploy.ts for the implementation.
 */

import { parseArgs } from "node:util";
import { getAddress, isHex } from "viem";

import { deployToTenderlySepoliaFork } from "./tenderly/deploy.js";

const args = parseArgs({
  args: process.argv.slice(2),
  options: {
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
      '  TENDERLY_RPC_URL="https://virtual…" bun run tenderly\n',
  );
  process.exit(1);
}

const deployerPrivateKey = process.env.DEPLOYER_PRIVATE_KEY;
if (deployerPrivateKey && !isHex(deployerPrivateKey)) {
  console.error("DEPLOYER_PRIVATE_KEY must be a 0x-prefixed hex string");
  process.exit(1);
}

const t0 = Date.now();
console.log("ENSv2 Tenderly Sepolia-fork deploy");
console.log(`  RPC: ${rpcUrl}`);

const result = await deployToTenderlySepoliaFork({
  rpcUrl,
  mnemonic: process.env.DEPLOYER_MNEMONIC,
  deployerPrivateKey: deployerPrivateKey as `0x${string}` | undefined,
  resetDeployments: !args.values["no-reset"] && process.env.RESET_DEPLOYMENTS !== "0",
  skipV17Upgrade:
    args.values["skip-v17"] || process.env.SKIP_V17_UPGRADE === "1",
  skipActivate:
    args.values["skip-activate"] || process.env.SKIP_ACTIVATE === "1",
});

console.log();
console.log("Named accounts");
console.table([
  { Role: "deployer", Address: result.namedAccounts.deployer },
  { Role: "owner (Sepolia ops)", Address: result.namedAccounts.owner },
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
