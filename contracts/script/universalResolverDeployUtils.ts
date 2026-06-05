import type { Deployment } from "rocketh/types";
import { encodeFunctionData, getAddress, type Address } from "viem";

import artifacts from "./artifacts.js";
import { DEPLOYED_UNIVERSAL_RESOLVER_PROXY } from "./deploy-constants.js";

export const TOP_URP_CREATE3_SALT =
  "0xdeac7148fb7f566f1fc8c8d6720530de8809f3658cf10141ceee7ba0d45eef85" as const;

const KNOWN_TOP_PROXY_NETWORKS = new Set(["holesky", "mainnet", "sepolia"]);
const universalResolverProxyArtifact =
  artifacts.UpgradableUniversalResolverProxy;

export type UpgradableUniversalResolverProxyDeployment = Deployment<
  typeof universalResolverProxyArtifact.abi
>;

export async function loadKnownTopProxyDeployment(
  networkName: string,
): Promise<UpgradableUniversalResolverProxyDeployment | null> {
  if (!KNOWN_TOP_PROXY_NETWORKS.has(networkName)) {
    return null;
  }
  return {
    address: DEPLOYED_UNIVERSAL_RESOLVER_PROXY,
    argsData: "0x",
    ...universalResolverProxyArtifact,
  } as UpgradableUniversalResolverProxyDeployment;
}

export function isDeployedTopProxy(
  deployment: UpgradableUniversalResolverProxyDeployment,
): boolean {
  return (
    getAddress(deployment.address) ===
    getAddress(DEPLOYED_UNIVERSAL_RESOLVER_PROXY)
  );
}

export function logUpgradeCalldata(
  label: string,
  target: Address,
  implementation: Address,
  ownerLabel = "DAO",
) {
  const calldata = encodeFunctionData({
    abi: universalResolverProxyArtifact.abi,
    functionName: "upgradeTo",
    args: [implementation],
  });
  console.log(`${label} requires a ${ownerLabel} transaction`);
  console.log(`  target: ${target}`);
  console.log(`  calldata: ${calldata}`);
}

export function externalTopProxyOwnerLabel(tags: Record<string, unknown>) {
  return tags.hasDao ? "DAO" : tags.sepolia ? "top URP owner" : undefined;
}

export async function setProxyImplementationIfNeeded({
  read,
  write,
  deployment,
  implementation,
  account,
  label,
}: {
  read: any;
  write: any;
  deployment: UpgradableUniversalResolverProxyDeployment;
  implementation: Address;
  account: string;
  label: string;
}) {
  const currentImplementation = await read(deployment, {
    functionName: "implementation",
  }) as Address;
  if (getAddress(currentImplementation) === getAddress(implementation)) {
    console.log(`${label}: already ${implementation}`);
    return;
  }

  console.log(`${label}: ${currentImplementation} -> ${implementation}`);
  await write(deployment, {
    functionName: "upgradeTo",
    args: [implementation],
    account,
  });
}
