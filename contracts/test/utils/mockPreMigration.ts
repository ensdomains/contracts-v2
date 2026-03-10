import { writeFileSync } from "node:fs";
import { keccak256, toHex, zeroAddress, type Address } from "viem";
import type { DevnetEnvironment, Deployment } from "../../script/setup.js";
import { STATUS } from "../../script/deploy-constants.js";

const DEPLOYER_PRIVATE_KEY =
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" as const;

export async function setupBaseRegistrarController(
  deployment: Deployment,
  namedAccounts: DevnetEnvironment["namedAccounts"],
) {
  const deployer = namedAccounts.deployer;
  const owner = namedAccounts.owner;
  await deployment.contracts.ETHRegistrarV1.write.addController(
    [deployer.address],
    { account: owner },
  );
}

export async function registerV1Name(
  deployment: Deployment,
  label: string,
  ownerAddress: Address,
  durationSeconds: number,
) {
  const tokenId = BigInt(keccak256(toHex(label)));
  await deployment.contracts.ETHRegistrarV1.write.register([
    tokenId,
    ownerAddress,
    BigInt(durationSeconds),
  ]);
  const expiry = await deployment.contracts.ETHRegistrarV1.read.nameExpires([
    tokenId,
  ]);
  return expiry;
}

export async function renewV1Name(
  deployment: Deployment,
  label: string,
  additionalDuration: number,
) {
  const tokenId = BigInt(keccak256(toHex(label)));
  await deployment.contracts.ETHRegistrarV1.write.renew([
    tokenId,
    BigInt(additionalDuration),
  ]);
  const expiry = await deployment.contracts.ETHRegistrarV1.read.nameExpires([
    tokenId,
  ]);
  return expiry;
}

const CSV_HEADER =
  "node,name,labelHash,owner,parentName,parentLabelHash,labelName,registrationDate,expiryDate";

export function createCSVFile(filePath: string, labels: string[]) {
  const rows = labels.map(
    (label) => `,,,,,,${label},,`,
  );
  const content = [CSV_HEADER, ...rows].join("\n");
  writeFileSync(filePath, content);
}

export function getBatchRegistrarAddress(deployment: Deployment): Address {
  return deployment.env.get("BatchRegistrar").address;
}

export function getENSV1ResolverAddress(deployment: Deployment): Address {
  return deployment.env.get("ENSV1Resolver").address;
}

export function buildMainArgs(
  deployment: Deployment,
  csvFilePath: string,
  overrides: {
    dryRun?: boolean;
    limit?: number;
    continue?: boolean;
    minExpiryDays?: number;
    batchSize?: number;
  } = {},
): string[] {
  const rpcUrl = `http://${deployment.hostPort}`;
  const registryAddress = deployment.contracts.ETHRegistry.address;
  const batchRegistrarAddress = getBatchRegistrarAddress(deployment);
  const v1ResolverAddress = getENSV1ResolverAddress(deployment);
  const chainId = String(deployment.client.chain!.id);

  const args = [
    "node",
    "script",
    "--rpc-url",
    rpcUrl,
    "--registry",
    registryAddress,
    "--batch-registrar",
    batchRegistrarAddress,
    "--private-key",
    DEPLOYER_PRIVATE_KEY,
    "--csv-file",
    csvFilePath,
    "--v1-resolver",
    v1ResolverAddress,
    "--mainnet-rpc-url",
    rpcUrl,
    "--chain-id",
    chainId,
    "--min-expiry-days",
    String(overrides.minExpiryDays ?? 0),
    "--v1-base-registrar",
    deployment.contracts.ETHRegistrarV1.address,
  ];

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
  deployment: Deployment,
  label: string,
): Promise<{
  status: number;
  expiry: bigint;
  latestOwner: Address;
}> {
  const labelId = BigInt(keccak256(toHex(label)));
  const state = await deployment.contracts.ETHRegistry.read.getState([labelId]);
  return {
    status: state.status,
    expiry: state.expiry,
    latestOwner: state.latestOwner,
  };
}
