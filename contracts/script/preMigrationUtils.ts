import { writeFileSync } from "node:fs";
import { keccak256, stringToBytes, type Address } from "viem";
import type { DevnetEnvironment } from "./setup.js";

// Default anvil/test-mnemonic account 0, which is the devnet deployer and the
// BatchRegistrar owner. Used to sign pre-migration reservations on the devnet.
export const DEPLOYER_PRIVATE_KEY =
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" as const;

// LibLabel.id() — the .eth token id derived from a label.
function idFromLabel(label: string): bigint {
  return BigInt(keccak256(stringToBytes(label)));
}

const CSV_HEADER =
  "node,name,labelHash,owner,parentName,parentLabelHash,labelName,registrationDate,expiryDate";

export function createCSVFile(filePath: string, labels: string[]) {
  const rows = labels.map((label) => `,,,,,,${label},,`);
  const content = [CSV_HEADER, ...rows].join("\n");
  writeFileSync(filePath, content);
}

export function buildMainArgs(
  env: DevnetEnvironment,
  csvFilePath: string,
  overrides: {
    dryRun?: boolean;
    limit?: number;
    continue?: boolean;
    bonusPeriodDays?: number;
    batchSize?: number;
    useEnvVarForPrivateKey?: boolean;
    omitPrivateKey?: boolean;
  } = {},
): string[] {
  const rpcUrl = `http://${env.hostPort}`;
  const registryAddress = env.v2.ETHRegistry.address;

  const args = [
    "node",
    "script",
    "--rpc-url",
    rpcUrl,
    "--registry",
    registryAddress,
    "--batch-registrar",
    env.rocketh.get("BatchRegistrar").address,
    "--csv-file",
    csvFilePath,
    "--v1-resolver",
    env.v2.ENSV1Resolver.address,
    "--mainnet-rpc-url",
    rpcUrl,
    "--bonus-period-days",
    String(overrides.bonusPeriodDays ?? 0),
    "--v1-base-registrar",
    env.v1.BaseRegistrar.address,
  ];

  if (overrides.useEnvVarForPrivateKey) {
    process.env.PREMIGRATION_PRIVATE_KEY = DEPLOYER_PRIVATE_KEY;
  } else if (!overrides.omitPrivateKey) {
    args.push("--private-key", DEPLOYER_PRIVATE_KEY);
  }

  if (overrides.dryRun) {
    args.push("--dry-run");
  }
  if (overrides.limit !== undefined) {
    args.push("--limit", String(overrides.limit));
  }
  if (overrides.continue) {
    args.push("--continue");
  }
  if (overrides.batchSize !== undefined) {
    args.push("--batch-size", String(overrides.batchSize));
  }

  return args;
}

export async function verifyV2State(
  env: DevnetEnvironment,
  label: string,
): Promise<{
  status: number;
  expiry: bigint;
  latestOwner: Address;
}> {
  return env.v2.ETHRegistry.read.getState([idFromLabel(label)]);
}
