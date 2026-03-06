import { type TransactionReceipt, getContract, zeroAddress } from "viem";

import { artifacts } from "@rocketh";
import { MAX_EXPIRY, ROLES, STATUS } from "../deploy-constants.js";
import {
  splitName,
  dnsEncodeName,
  idFromLabel,
  getLabelAt,
  getParentName,
} from "../../test/utils/utils.js";
import type { DevnetEnvironment } from "../setup.js";
import { deployResolverWithRecords } from "./resolver.js";

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
 * Traverse the registry hierarchy to find data for a name.
 * Uses UniversalResolverV2.findRegistries() to locate the parent registry,
 * then reads state directly from it.
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
  const label = getLabelAt(name);
  if (!label) return null;

  // findRegistries returns [exactRegistry, parentRegistry, ..., rootRegistry]
  // Index 1 is the registry where this name is registered
  const registries =
    await env.deployment.contracts.UniversalResolverV2.read.findRegistries([
      dnsEncodeName(name),
    ]);

  // Index 1 is the parent registry (where this name's token lives)
  const parentRegistryAddress = registries[1];
  if (!parentRegistryAddress || parentRegistryAddress === zeroAddress) {
    return null;
  }

  const parentRegistry = getRegistryContract(env, parentRegistryAddress);

  const [state, resolver, subregistry] = await Promise.all([
    parentRegistry.read.getState([idFromLabel(label)]),
    parentRegistry.read.getResolver([label]),
    parentRegistry.read.getSubregistry([label]),
  ]);

  const owner = await parentRegistry.read.ownerOf([state.tokenId]);

  return {
    owner,
    expiry: state.expiry,
    resolver,
    subregistry,
    registry: parentRegistryAddress,
  };
}

/**
 * Get parent name data and validate it has a subregistry.
 * Uses UniversalResolverV2.findRegistries() — index 0 is the exact registry (child registry).
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

  // findRegistries returns [exactRegistry, parentRegistry, ..., rootRegistry]
  // Index 0 is the exact registry — the subregistry for children of this name
  const registries =
    await env.deployment.contracts.UniversalResolverV2.read.findRegistries([
      dnsEncodeName(parentName),
    ]);

  const childRegistry = registries[0];
  if (!childRegistry || childRegistry === zeroAddress) {
    throw new Error(`${parentName} has no subregistry`);
  }

  return {
    data,
    registry: getRegistryContract(env, childRegistry),
  };
}

/**
 * Create a subname (and all parent registries if they don't exist)
 */
export async function createSubname(
  env: DevnetEnvironment,
  fullName: string,
  account = env.namedAccounts.owner,
): Promise<string[]> {
  const createdNames: string[] = [];

  const parts = splitName(fullName);

  // Start from the parent name (e.g., "parent.eth")
  const parentLabel = parts[parts.length - 2];
  const parentName = `${parentLabel}.eth`;

  console.log(`\nCreating subname: ${fullName}`);
  console.log(`Parent name: ${parentName}`);

  // Get parent tokenId (assumes parent.eth already exists)
  const parentTokenId =
    await env.deployment.contracts.ETHRegistry.read.getTokenId([
      idFromLabel(parentLabel),
    ]);

  // For each level of subnames, create UserRegistry and register
  let currentParentTokenId = parentTokenId;
  let currentRegistryAddress: `0x${string}` =
    env.deployment.contracts.ETHRegistry.address;
  let currentName = parentName;

  // Process subname parts from right to left (parent to child)
  // e.g., for "sub1.sub2.parent.eth", process in order: sub2, sub1
  for (let i = parts.length - 3; i >= 0; i--) {
    const label = parts[i];
    currentName = `${label}.${currentName}`;

    console.log(`\nProcessing level: ${currentName}`);

    // Check if current parent has a subregistry
    let subregistryAddress: `0x${string}`;

    if (
      currentRegistryAddress === env.deployment.contracts.ETHRegistry.address
    ) {
      // Parent is in ETHRegistry
      subregistryAddress =
        await env.deployment.contracts.ETHRegistry.read.getSubregistry([
          parts[i + 1],
        ]);
    } else {
      // Parent is in a UserRegistry
      const parentRegistry = getRegistryContract(env, currentRegistryAddress);
      subregistryAddress = await parentRegistry.read.getSubregistry([
        parts[i + 1],
      ]);
    }

    // Deploy UserRegistry if it doesn't exist
    if (subregistryAddress === zeroAddress) {
      console.log(`Deploying UserRegistry for ${currentName}...`);

      const userRegistry = await env.deployment.deployUserRegistry({
        account,
      });
      subregistryAddress = userRegistry.address;

      // Set as subregistry on parent
      if (
        currentRegistryAddress === env.deployment.contracts.ETHRegistry.address
      ) {
        await env.deployment.contracts.ETHRegistry.write.setSubregistry(
          [currentParentTokenId, subregistryAddress],
          { account },
        );
      } else {
        const parentRegistry = getRegistryContract(env, currentRegistryAddress);
        await parentRegistry.write.setSubregistry(
          [currentParentTokenId, subregistryAddress],
          { account },
        );
      }

      console.log(`✓ UserRegistry deployed at ${subregistryAddress}`);
    }

    // Register the subname in the UserRegistry
    const userRegistry = getRegistryContract(env, subregistryAddress);

    // Check if already registered and if it's expired
    const state = await userRegistry.read.getState([idFromLabel(label)]);

    if (state.status === STATUS.REGISTERED) {
      console.log(`✓ ${currentName} already exists and is not expired`);
    } else {
      if (state.latestOwner !== zeroAddress) {
        console.log(
          `${currentName} exists but is expired, re-registering with MAX_EXPIRY...`,
        );
      } else {
        console.log(`Registering ${currentName}...`);
      }

      // Deploy resolver for this subname
      const resolver = await deployResolverWithRecords(
        env,
        account,
        currentName,
        {
          description: currentName,
          address: account.address,
        },
      );
      console.log(`✓ Resolver deployed at ${resolver.address}`);

      await userRegistry.write.register(
        [
          label,
          account.address,
          zeroAddress, // no nested subregistry yet
          resolver.address,
          ROLES.ALL,
          MAX_EXPIRY,
        ],
        { account },
      );

      console.log(`✓ Registered ${currentName}`);
      createdNames.push(currentName);
    }

    // Update for next iteration
    currentParentTokenId = state.tokenId;
    currentRegistryAddress = subregistryAddress;
  }
  return createdNames;
}

/**
 * Link a name to appear under a different parent by pointing to the same subregistry.
 * This creates multiple "entry points" into the same child namespace.
 *
 * @param sourceName - The existing name whose subregistry we want to link (e.g., "sub1.sub2.parent.eth")
 * @param targetParentName - The parent under which we want to create a linked entry (e.g., "parent.eth")
 * @param linkLabel - The label for the linked name
 *
 * Example:
 *   linkName(env, "sub1.sub2.parent.eth", "parent.eth", "linked")
 *   Creates "linked.parent.eth" that shares children with "sub1.sub2.parent.eth"
 */
export async function linkName(
  env: DevnetEnvironment,
  sourceName: string,
  targetParentName: string,
  linkLabel: string,
  account = env.namedAccounts.owner,
) {
  console.log(`\nLinking name: ${sourceName} to parent: ${targetParentName}`);

  const sourceLabel = getLabelAt(sourceName);
  const sourceParentName = getParentName(sourceName);

  if (splitName(sourceName).length === 2) {
    throw new Error(
      `Cannot link second-level names directly. Source must be a subname.`,
    );
  }

  // Get source name data
  const sourceData = await traverseRegistry(env, sourceName);
  if (!sourceData || sourceData.owner === zeroAddress) {
    throw new Error(`Source name ${sourceName} does not exist or has no owner`);
  }

  // Get source parent registry and validate
  const { registry: sourceRegistry } = await getParentWithSubregistry(
    env,
    sourceParentName,
  );
  const subregistry = await sourceRegistry.read.getSubregistry([sourceLabel]);

  if (subregistry === zeroAddress) {
    throw new Error(`Source name ${sourceName} has no subregistry to link`);
  }

  console.log(`Source subregistry: ${subregistry}`);

  // Get target parent registry and validate
  const { registry: targetRegistry } = await getParentWithSubregistry(
    env,
    targetParentName,
  );
  const linkedName = `${linkLabel}.${targetParentName}`;

  console.log(`Creating linked name: ${linkedName}`);

  // Check if the label already exists in the target registry
  const existingTokenId = await targetRegistry.read.getTokenId([
    idFromLabel(linkLabel),
  ]);
  const existingOwner = await targetRegistry.read.ownerOf([existingTokenId]);

  if (existingOwner !== zeroAddress) {
    console.log(
      `Warning: ${linkedName} already exists. Updating its subregistry...`,
    );
    await targetRegistry.write.setSubregistry([existingTokenId, subregistry], {
      account,
    });
    console.log(`✓ Updated ${linkedName} to point to shared subregistry`);
  } else {
    console.log(`Deploying resolver for ${linkedName}...`);
    const resolver = await deployResolverWithRecords(env, account, linkedName, {
      description: `Linked to ${sourceName}`,
      address: account.address,
    });
    console.log(`✓ Resolver deployed at ${resolver.address}`);

    await targetRegistry.write.register(
      [
        linkLabel,
        account.address,
        subregistry,
        resolver.address,
        ROLES.ALL,
        MAX_EXPIRY,
      ],
      { account },
    );

    console.log(`✓ Registered ${linkedName} with shared subregistry`);
  }

  console.log(`\n✓ Link complete!`);
  console.log(
    `Children of ${sourceName} and ${linkedName} now resolve to the same place.`,
  );
  console.log(
    `Example: wallet.${sourceName} and wallet.${linkedName} are the same token.`,
  );
}

/**
 * Transfer a name to a new owner
 */
export async function transferName(
  env: DevnetEnvironment,
  name: string,
  newOwner: `0x${string}`,
  account = env.namedAccounts.owner,
) {
  const label = getLabelAt(name);

  const tokenId = await env.deployment.contracts.ETHRegistry.read.getTokenId([
    idFromLabel(label),
  ]);

  console.log(`\nTransferring ${name}...`);
  console.log(`TokenId: ${tokenId}`);
  console.log(`From: ${account.address}`);
  console.log(`To: ${newOwner}`);

  const { receipt } = await env.waitFor(
    env.deployment.contracts.ETHRegistry.write.safeTransferFrom(
      [account.address, newOwner, tokenId, 1n, "0x"],
      { account },
    ),
  );

  console.log(`✓ Transfer completed`);

  return receipt;
}

/**
 * Change roles for a name
 */
export async function changeRole(
  env: DevnetEnvironment,
  name: string,
  targetAccount: `0x${string}`,
  rolesToGrant: bigint,
  rolesToRevoke: bigint,
  account = env.namedAccounts.owner,
) {
  const label = getLabelAt(name);

  const tokenId = await env.deployment.contracts.ETHRegistry.read.getTokenId([
    idFromLabel(label),
  ]);

  console.log(
    `\nChanging roles for ${name} (TokenId: ${tokenId}, Target: ${targetAccount}, Grant: ${rolesToGrant}, Revoke: ${rolesToRevoke})`,
  );

  const receipts: TransactionReceipt[] = [];

  if (rolesToGrant > 0n) {
    const { receipt } = await env.waitFor(
      env.deployment.contracts.ETHRegistry.write.grantRoles(
        [tokenId, rolesToGrant, targetAccount],
        { account },
      ),
    );
    receipts.push(receipt);
  }

  if (rolesToRevoke > 0n) {
    const { receipt } = await env.waitFor(
      env.deployment.contracts.ETHRegistry.write.revokeRoles(
        [tokenId, rolesToRevoke, targetAccount],
        { account },
      ),
    );
    receipts.push(receipt);
  }

  const newTokenId = await env.deployment.contracts.ETHRegistry.read.getTokenId(
    [idFromLabel(label)],
  );
  console.log(`TokenId changed from ${tokenId} to ${newTokenId}`);

  return receipts;
}

/**
 * Reserve a name (registers with owner = address(0), no token minted)
 *
 * NOTE: Once PR #233 lands, reservation will use a dedicated `reserve()` function
 * with a `reservedOwner` field instead of `register(owner=0x0, roleBitmap=0)`.
 * See: https://github.com/ensdomains/contracts-v2/pull/233
 */
export async function reserveName(
  env: DevnetEnvironment,
  name: string,
  options: {
    expiry?: bigint;
    account?: any;
    registrarAccount?: any;
  } = {},
) {
  const label = getLabelAt(name);
  const account = options.account ?? env.namedAccounts.owner;
  const registrarAccount =
    options.registrarAccount ?? env.namedAccounts.deployer;

  const currentTimestamp = await env.deployment.client
    .getBlock()
    .then((b) => b.timestamp);
  const expiry = options.expiry ?? currentTimestamp + BigInt(86400);

  console.log(`\nReserving ${name}...`);

  const { receipt } = await env.waitFor(
    env.deployment.contracts.ETHRegistry.write.register(
      [
        label,
        zeroAddress, // owner = address(0) triggers reservation
        zeroAddress, // no subregistry
        zeroAddress, // no resolver
        0n, // roleBitmap must be 0 for reservations
        expiry,
      ],
      { account: registrarAccount },
    ),
  );

  const state = await env.deployment.contracts.ETHRegistry.read.getState([
    idFromLabel(label),
  ]);
  console.log(`✓ Reserved ${name} (status: ${state.status}, tokenId: ${state.tokenId})`);

  return receipt;
}

/**
 * Unregister a name (deletes it from the registry)
 */
export async function unregisterName(
  env: DevnetEnvironment,
  name: string,
  account = env.namedAccounts.deployer,
) {
  const label = getLabelAt(name);

  const tokenId = await env.deployment.contracts.ETHRegistry.read.getTokenId([
    idFromLabel(label),
  ]);

  console.log(`\nUnregistering ${name}...`);
  console.log(`TokenId: ${tokenId}`);

  const { receipt } = await env.waitFor(
    env.deployment.contracts.ETHRegistry.write.unregister([tokenId], {
      account,
    }),
  );

  const state = await env.deployment.contracts.ETHRegistry.read.getState([
    idFromLabel(label),
  ]);
  console.log(`✓ Unregistered ${name} (status: ${state.status})`);

  return receipt;
}
