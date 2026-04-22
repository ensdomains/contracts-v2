import { writeFileSync } from "node:fs";
import type { Address } from "viem";
import type { DevnetEnvironment } from "../../script/setup.js";
import { idFromLabel } from "./utils.js";

const DEPLOYER_PRIVATE_KEY =
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" as const;

export async function setupBaseRegistrarController(env: DevnetEnvironment) {
  const { deployer, owner } = env.namedAccounts;
  // v1.7.0: BaseRegistrar is now owned by RegistrarSecurityController
  await env.v1.RegistrarSecurityController.write.addRegistrarController(
    [deployer.address],
    { account: owner },
  );
}

export async function registerV1Name(
  env: DevnetEnvironment,
  label: string,
  ownerAddress: Address,
  durationSeconds: number,
) {
  const tokenId = idFromLabel(label);
  await env.v1.BaseRegistrar.write.register([
    tokenId,
    ownerAddress,
    BigInt(durationSeconds),
  ]);
  const expiry = await env.v1.BaseRegistrar.read.nameExpires([tokenId]);
  return expiry;
}

export async function renewV1Name(
  env: DevnetEnvironment,
  label: string,
  additionalDuration: number,
) {
  const tokenId = idFromLabel(label);
  await env.v1.BaseRegistrar.write.renew([tokenId, BigInt(additionalDuration)]);
  const expiry = await env.v1.BaseRegistrar.read.nameExpires([tokenId]);
  return expiry;
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
    gracePeriodDays?: number;
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
    "--grace-period-days",
    String(overrides.gracePeriodDays ?? 0),
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
