import { getContract, zeroAddress } from "viem";

import { artifacts } from "@rocketh";
import { splitName, idFromLabel } from "../../test/utils/utils.js";
import type { DevnetEnvironment } from "../setup.js";

/**
 * Create a UserRegistry contract instance
 */
export function getRegistryContract(
  env: DevnetEnvironment,
  registryAddress: `0x${string}`,
) {
  return getContract({
    address: registryAddress,
    abi: artifacts.UserRegistry.abi,
    client: env.deployment.client,
  });
}

/**
 * Traverse the registry hierarchy to find data for a name
 */
export async function traverseRegistry(
  env: DevnetEnvironment,
  name: string,
): Promise<{
  owner?: `0x${string}`;
  expiry?: bigint;
  resolver?: `0x${string}`;
  subregistry?: `0x${string}`;
  registry?: `0x${string}`;
} | null> {
  const nameParts = splitName(name);

  if (nameParts[nameParts.length - 1] !== "eth") {
    return null;
  }

  let currentRegistry = env.deployment.contracts.ETHRegistry;

  // Traverse from right to left: e.g., ["sub1", "sub2", "parent", "eth"]
  for (let i = nameParts.length - 2; i >= 0; i--) {
    const label = nameParts[i];

    const [state, resolver, subregistry] = await Promise.all([
      currentRegistry.read.getState([idFromLabel(label)]),
      currentRegistry.read.getResolver([label]),
      currentRegistry.read.getSubregistry([label]),
    ]);

    if (i === 0) {
      // This is the final name/subname
      const owner = await currentRegistry.read.ownerOf([state.tokenId]);
      return {
        owner,
        expiry: state.expiry,
        resolver,
        subregistry,
        registry: currentRegistry.address,
      };
    }

    // Move to the subregistry
    if (subregistry === zeroAddress) {
      return null;
    }
    currentRegistry = getRegistryContract(env, subregistry) as any;
  }

  return null;
}

/**
 * Get parent name data and validate it has a subregistry
 */
export async function getParentWithSubregistry(
  env: DevnetEnvironment,
  parentName: string,
): Promise<{
  data: NonNullable<Awaited<ReturnType<typeof traverseRegistry>>>;
  registry: ReturnType<typeof getRegistryContract>;
}> {
  const data = await traverseRegistry(env, parentName);
  if (!data || data.owner === zeroAddress) {
    throw new Error(`${parentName} does not exist or has no owner`);
  }

  if (!data.subregistry || data.subregistry === zeroAddress) {
    throw new Error(`${parentName} has no subregistry`);
  }

  return {
    data,
    registry: getRegistryContract(env, data.subregistry),
  };
}
