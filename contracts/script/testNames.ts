import {
  type Address,
  type TransactionReceipt,
  decodeFunctionResult,
  encodeFunctionData,
  getContract,
  namehash,
  zeroAddress,
} from "viem";

import { artifacts } from "@rocketh";
import { MAX_EXPIRY, ROLES, STATUS } from "./deploy-constants.js";
import { dnsEncodeName, idFromLabel } from "../test/utils/utils.js";
import type { DevnetEnvironment } from "./setup.js";

// ========== Constants ==========

const ONE_DAY_SECONDS = 86400;

const OwnedResolverAbi =
  artifacts["src/resolver/OwnedResolver.sol/OwnedResolver"].abi;

// ========== Gas Tracking ==========

type GasRecord = {
  operation: string;
  gasUsed: bigint;
  effectiveGasPrice?: bigint;
  totalCost?: bigint;
};

const gasTracker: GasRecord[] = [];

async function trackGas(
  operation: string,
  receipt: TransactionReceipt,
): Promise<void> {
  const gasUsed = BigInt(receipt.gasUsed);
  const effectiveGasPrice = receipt.effectiveGasPrice
    ? BigInt(receipt.effectiveGasPrice)
    : 0n;
  gasTracker.push({
    operation,
    gasUsed,
    effectiveGasPrice,
    totalCost: gasUsed * effectiveGasPrice,
  });
}

function displayGasReport() {
  if (gasTracker.length === 0) {
    console.log("\nNo gas data collected.");
    return;
  }

  console.log("\n========== Gas Usage Report ==========");

  const groupedByFunction = new Map<string, bigint[]>();

  for (const { operation, gasUsed } of gasTracker) {
    const functionName = operation.split("(")[0];
    if (!groupedByFunction.has(functionName)) {
      groupedByFunction.set(functionName, []);
    }
    groupedByFunction.get(functionName)!.push(gasUsed);
  }

  const reportData = Array.from(groupedByFunction.entries()).map(
    ([functionName, gasValues]) => {
      const count = gasValues.length;
      const total = gasValues.reduce((sum, val) => sum + val, 0n);
      const avg = total / BigInt(count);
      const min = gasValues.reduce(
        (min, val) => (val < min ? val : min),
        gasValues[0],
      );
      const max = gasValues.reduce(
        (max, val) => (val > max ? val : max),
        gasValues[0],
      );

      return {
        Function: functionName,
        Calls: count,
        "Avg Gas": avg.toString(),
        "Min Gas": min.toString(),
        "Max Gas": max.toString(),
        "Total Gas": total.toString(),
      };
    },
  );

  console.table(reportData);

  const totalGas = gasTracker.reduce((sum, { gasUsed }) => sum + gasUsed, 0n);
  const totalCostWei = gasTracker.reduce(
    (sum, { totalCost }) => sum + (totalCost || 0n),
    0n,
  );

  console.log(`\nTotal Gas Used: ${totalGas.toString()}`);
  console.log(`Total Cost: ${totalCostWei.toString()} wei`);
  console.log(`Total Transactions: ${gasTracker.length}`);
  console.log("======================================\n");
}

function resetGasTracker() {
  gasTracker.length = 0;
}

// ========== Helper Functions ==========

/**
 * Parse an ENS name into its components
 */
function parseName(name: string): {
  label: string;
  parentName: string;
  parts: string[];
  isSecondLevel: boolean;
  tld: string;
} {
  const parts = name.split(".");
  const tld = parts[parts.length - 1];

  if (tld !== "eth") {
    throw new Error(`Name must end with .eth, got: ${name}`);
  }

  return {
    label: parts[0],
    parentName: parts.slice(1).join("."),
    parts,
    isSecondLevel: parts.length === 2,
    tld,
  };
}

/**
 * Create a UserRegistry contract instance
 */
function getRegistryContract(
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
 * Deploy a resolver and set default records
 */
async function deployResolverWithRecords(
  env: DevnetEnvironment,
  account: any,
  name: string,
  records: {
    description?: string;
    address?: Address;
  },
  shouldTrackGas: boolean = false,
) {
  const resolver = await env.deployment.deployOwnedResolver({ account });
  const node = namehash(name);

  if (shouldTrackGas) {
    await trackGas("deployResolver", resolver.deploymentReceipt);
  }

  // Set ETH address (coin type 60)
  if (records.address) {
    const { receipt } = await env.waitFor(
      resolver.write.setAddr([node, 60n, records.address], { account }),
    );
    if (shouldTrackGas) await trackGas(`setAddr(${name})`, receipt);
  }

  // Set description text record
  if (records.description) {
    const { receipt } = await env.waitFor(
      resolver.write.setText([node, "description", records.description], {
        account,
      }),
    );
    if (shouldTrackGas) await trackGas(`setText(${name})`, receipt);
  }

  return resolver;
}

/**
 * Get parent name data and validate it has a subregistry
 */
async function getParentWithSubregistry(
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

async function traverseRegistry(
  env: DevnetEnvironment,
  name: string,
): Promise<{
  owner?: `0x${string}`;
  expiry?: bigint;
  resolver?: `0x${string}`;
  subregistry?: `0x${string}`;
  registry?: `0x${string}`;
} | null> {
  const nameParts = name.split(".");

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

// ========== Main Functions ==========

// Display name information
export async function showName(env: DevnetEnvironment, names: string[]) {
  await env.sync();

  const nameData = [];

  for (const name of names) {
    const nameHash = namehash(name);

    const { label } = parseName(name);

    let owner: `0x${string}` | undefined = undefined;
    let expiryDate: string = "N/A";
    let registryAddress: `0x${string}` | undefined = undefined;

    const data = await traverseRegistry(env, name);
    if (data?.owner && data.owner !== zeroAddress) {
      owner = data.owner;
      registryAddress = data.registry;
      if (data.expiry) {
        const expiryTimestamp = Number(data.expiry);
        if (data.expiry === MAX_EXPIRY || expiryTimestamp === 0) {
          expiryDate = "Never";
        } else {
          expiryDate = new Date(expiryTimestamp * 1000).toISOString();
        }
      }
    }

    const actualResolver = data?.resolver;

    // Batch addr and text resolution using resolver multicall
    const resolverCalls = [
      encodeFunctionData({
        abi: OwnedResolverAbi,
        functionName: "addr",
        args: [nameHash],
      }),
      encodeFunctionData({
        abi: OwnedResolverAbi,
        functionName: "text",
        args: [nameHash, "description"],
      }),
    ];

    const multicallData = encodeFunctionData({
      abi: OwnedResolverAbi,
      functionName: "multicall",
      args: [resolverCalls],
    });

    // Single UniversalResolver call with multicall
    const [result] =
      await env.deployment.contracts.UniversalResolverV2.read.resolve([
        dnsEncodeName(name),
        multicallData,
      ]);

    // Decode the multicall result - returns array of bytes directly
    const results =
      result && result !== "0x"
        ? (decodeFunctionResult({
            abi: OwnedResolverAbi,
            functionName: "multicall",
            data: result,
          }) as readonly `0x${string}`[])
        : [];

    // Decode individual results
    const ethAddress =
      results[0] && results[0] !== "0x"
        ? (decodeFunctionResult({
            abi: OwnedResolverAbi,
            functionName: "addr",
            data: results[0],
          }) as string)
        : undefined;

    const description =
      results[1] && results[1] !== "0x"
        ? (decodeFunctionResult({
            abi: OwnedResolverAbi,
            functionName: "text",
            data: results[1],
          }) as string)
        : undefined;

    const truncateAddress = (addr: string | undefined) => {
      if (!addr || addr === "0x") return "-";
      return addr.slice(0, 7);
    };

    nameData.push({
      Name: name,
      Registry: truncateAddress(registryAddress),
      Owner: truncateAddress(owner),
      Expiry: expiryDate === "Never" ? "Never" : expiryDate.split("T")[0],
      Resolver: truncateAddress(actualResolver),
      Address: truncateAddress(ethAddress),
      Description: description || "-",
    });
  }

  console.log(`\nName Information:`);
  console.table(nameData);
}

// Create a subname (and all parent names if they don't exist)
export async function createSubname(
  env: DevnetEnvironment,
  fullName: string,
  account = env.namedAccounts.owner,
): Promise<string[]> {
  const createdNames: string[] = [];

  // Parse the name
  const { parts } = parseName(fullName);

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

  // Parse and validate source name
  const {
    label: sourceLabel,
    parentName: sourceParentName,
    isSecondLevel,
  } = parseName(sourceName);

  if (isSecondLevel) {
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

// Renew a name
export async function renewName(
  env: DevnetEnvironment,
  name: string,
  durationInDays: number,
  account = env.namedAccounts.owner,
) {
  const { label } = parseName(name);

  const expiry = await env.deployment.contracts.ETHRegistry.read.getExpiry([
    idFromLabel(label),
  ]);

  console.log(`\nRenewing ${name}...`);
  if (expiry === MAX_EXPIRY) {
    console.log(`Current expiry: Never (MAX_EXPIRY)`);
  } else {
    const currentExpiry = Number(expiry);
    console.log(
      `Current expiry: ${new Date(currentExpiry * 1000).toISOString()}`,
    );
  }
  console.log(`Extending by: ${durationInDays} days`);

  const duration = BigInt(durationInDays * ONE_DAY_SECONDS);
  const paymentToken = env.deployment.contracts.MockUSDC.address;
  const referrer =
    "0x0000000000000000000000000000000000000000000000000000000000000000";

  const [price] = await env.deployment.contracts.ETHRegistrar.read.rentPrice([
    label,
    account.address,
    duration,
    paymentToken,
  ]);

  console.log(`Renewal price: ${price}`);

  const balance = await env.deployment.contracts.MockUSDC.read.balanceOf([
    account.address,
  ]);
  console.log(`Current balance: ${balance}`);

  if (balance < price) {
    const amountToMint = price - balance + 1000000n;
    console.log(`Minting ${amountToMint} tokens...`);
    await env.deployment.contracts.MockUSDC.write.mint(
      [account.address, amountToMint],
      { account },
    );
  }

  await env.deployment.contracts.MockUSDC.write.approve(
    [env.deployment.contracts.ETHRegistrar.address, price],
    { account },
  );

  const { receipt } = await env.waitFor(
    env.deployment.contracts.ETHRegistrar.write.renew(
      [label, duration, paymentToken, referrer],
      { account },
    ),
  );

  const newExpiry = Number(
    await env.deployment.contracts.ETHRegistry.read.getExpiry([
      idFromLabel(label),
    ]),
  );
  console.log(`New expiry: ${new Date(newExpiry * 1000).toISOString()}`);
  console.log(`✓ Renewal completed`);

  return receipt;
}

// Transfer a name to a new owner
export async function transferName(
  env: DevnetEnvironment,
  name: string,
  newOwner: `0x${string}`,
  account = env.namedAccounts.owner,
) {
  const { label } = parseName(name);

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

// Change roles for a name
export async function changeRole(
  env: DevnetEnvironment,
  name: string,
  targetAccount: `0x${string}`,
  rolesToGrant: bigint,
  rolesToRevoke: bigint,
  account = env.namedAccounts.owner,
) {
  const { label } = parseName(name);

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

// Register default test names
export async function registerTestNames(
  env: DevnetEnvironment,
  labels: string[],
  options: {
    account?: any;
    expiry?: bigint;
    registrarAccount?: any;
    trackGas?: boolean;
  } = {},
) {
  const account = options.account ?? env.namedAccounts.owner;
  const registrarAccount =
    options.registrarAccount ?? env.namedAccounts.deployer;
  const shouldTrackGas = options.trackGas ?? false;
  const currentTimestamp = await env.deployment.client
    .getBlock()
    .then((b) => b.timestamp);

  for (const label of labels) {
    const resolver = await env.deployment.deployOwnedResolver({ account });

    if (shouldTrackGas)
      await trackGas("deployOwnedResolver", resolver.deploymentReceipt);

    let expiry: bigint;
    if (options.expiry !== undefined) {
      expiry = options.expiry;
    } else {
      expiry = currentTimestamp + BigInt(ONE_DAY_SECONDS);
    }

    const registerTx = await env.waitFor(
      env.deployment.contracts.ETHRegistry.write.register(
        [
          label,
          account.address,
          zeroAddress,
          resolver.address,
          ROLES.ALL,
          expiry,
        ],
        { account: registrarAccount },
      ),
    );

    if (shouldTrackGas) {
      await trackGas(`register(${label})`, registerTx.receipt);
    }

    const node = namehash(`${label}.eth`);
    const setAddrTx = await env.waitFor(
      resolver.write.setAddr(
        [
          node,
          60n, // ETH coin type
          account.address,
        ],
        { account },
      ),
    );

    if (shouldTrackGas) {
      await trackGas(`setAddr(${label})`, setAddrTx.receipt);
    }

    const setTextTx = await env.waitFor(
      resolver.write.setText([node, "description", `${label}.eth`], {
        account,
      }),
    );

    if (shouldTrackGas) {
      await trackGas(`setText(${label})`, setTextTx.receipt);
    }
  }
}

// Test re-registration of an expired name
export async function reregisterName(
  env: DevnetEnvironment,
  label: string,
  account = env.namedAccounts.owner,
) {
  console.log(
    `\n=== Testing Re-registration of Expired Name: ${label}.eth ===`,
  );

  const initialExpiry =
    await env.deployment.contracts.ETHRegistry.read.getExpiry([
      idFromLabel(label),
    ]);
  console.log(
    `Initial expiry: ${new Date(Number(initialExpiry) * 1000).toISOString()}`,
  );

  // Time warp past expiry
  const warpSeconds = ONE_DAY_SECONDS + 1;
  console.log(`\nTime warping ${warpSeconds} seconds...`);
  await env.sync({ warpSec: warpSeconds });

  console.log(
    `\nCurrent onchain timestamp: ${new Date(Number(await env.deployment.client.getBlock().then((b) => b.timestamp)) * 1000).toISOString()}`,
  );
  console.log(
    `\nCurrent onchain expiry: ${new Date(Number(initialExpiry) * 1000).toISOString()}`,
  );

  // Verify name is available for re-registration
  const isAvailable =
    await env.deployment.contracts.ETHRegistrar.read.isAvailable([label]);
  console.log(`Name available for re-registration: ${isAvailable}`);

  if (!isAvailable) {
    throw new Error(`${label}.eth should be available after expiry`);
  }

  // Re-register with proper expiry based on blockchain time
  console.log(`\nRe-registering ${label}.eth...`);

  const currentBlock = await env.deployment.client.getBlock();
  const newExpiry = currentBlock.timestamp + BigInt(ONE_DAY_SECONDS);

  await registerTestNames(env, [label], {
    account,
    expiry: newExpiry,
  });

  // Verify re-registration succeeded
  const reregisteredExpiry = Number(
    await env.deployment.contracts.ETHRegistry.read.getExpiry([
      idFromLabel(label),
    ]),
  );
  console.log(
    `New expiry: ${new Date(reregisteredExpiry * 1000).toISOString()}`,
  );

  if (reregisteredExpiry <= initialExpiry) {
    throw new Error(
      `Re-registration failed: new expiry (${reregisteredExpiry}) should be greater than initial expiry (${initialExpiry})`,
    );
  }

  console.log(
    `✓ Re-registration successful! Expiry extended from ${initialExpiry} to ${reregisteredExpiry}`,
  );
}

/**
 * Set up test names with various states and configurations for development/testing
 */
export async function testNames(env: DevnetEnvironment) {
  resetGasTracker();

  console.log("\n========== Starting testNames with Gas Tracking ==========\n");

  // Register reregister
  await registerTestNames(env, ["reregister"], { trackGas: true });
  // Re-register reregister (with time warp, do first to avoid expiring other names)
  await reregisterName(env, "reregister");

  // Register all other test names with default 1 day expiry
  await registerTestNames(
    env,
    ["test", "example", "demo", "newowner", "renew", "parent", "changerole"],
    { trackGas: true },
  );

  // Transfer newowner.eth to user
  const transferReceipt = await transferName(
    env,
    "newowner.eth",
    env.namedAccounts.user.address,
  );
  await trackGas("transfer(newowner)", transferReceipt);

  // Renew renew.eth for 365 days
  const renewReceipt = await renewName(env, "renew.eth", 365);
  await trackGas("renew(renew)", renewReceipt);

  // Register alias.eth pointing to test.eth's resolver, then set alias
  console.log("\nCreating alias: alias.eth → test.eth");
  const testNameData = await traverseRegistry(env, "test.eth");
  if (!testNameData?.resolver || testNameData.resolver === zeroAddress) {
    throw new Error("test.eth has no resolver set");
  }
  const currentTimestamp = await env.deployment.client
    .getBlock()
    .then((b) => b.timestamp);
  const aliasExpiry = currentTimestamp + BigInt(ONE_DAY_SECONDS);
  const aliasRegisterTx = await env.waitFor(
    env.deployment.contracts.ETHRegistry.write.register(
      [
        "alias",
        env.namedAccounts.owner.address,
        zeroAddress,
        testNameData.resolver,
        ROLES.ALL,
        aliasExpiry,
      ],
      { account: env.namedAccounts.deployer },
    ),
  );
  await trackGas("register(alias)", aliasRegisterTx.receipt);

  const testResolver = getContract({
    address: testNameData.resolver,
    abi: OwnedResolverAbi,
    client: env.deployment.client,
  });
  const aliasTx = await env.waitFor(
    testResolver.write.setAlias(
      [dnsEncodeName("alias.eth"), dnsEncodeName("test.eth")],
      { account: env.namedAccounts.owner },
    ),
  );
  await trackGas("setAlias(alias→test)", aliasTx.receipt);
  console.log("✓ alias.eth → test.eth alias created");

  // Set records for sub.test.eth on test.eth's resolver so sub.alias.eth resolves via alias
  console.log(
    "\nSetting records for sub.test.eth (for sub.alias.eth alias resolution)",
  );
  const subTestNode = namehash("sub.test.eth");
  const setSubAddrTx = await env.waitFor(
    testResolver.write.setAddr(
      [subTestNode, 60n, env.namedAccounts.owner.address],
      { account: env.namedAccounts.owner },
    ),
  );
  await trackGas("setAddr(sub.test.eth)", setSubAddrTx.receipt);
  const setSubTextTx = await env.waitFor(
    testResolver.write.setText(
      [subTestNode, "description", "sub.test.eth (via alias)"],
      { account: env.namedAccounts.owner },
    ),
  );
  await trackGas("setText(sub.test.eth)", setSubTextTx.receipt);
  console.log(
    "✓ sub.test.eth records set — sub.alias.eth should resolve via alias",
  );

  // Create subnames
  const createdSubnames = await createSubname(
    env,
    "wallet.sub1.sub2.parent.eth",
  );

  // Link sub1.sub2.parent.eth to parent.eth with different label (creates linked.parent.eth with shared children)
  // Now wallet.linked.parent.eth and wallet.sub1.sub2.parent.eth will be the same token
  await linkName(env, "sub1.sub2.parent.eth", "parent.eth", "linked");

  // With OwnedResolver (node-keyed), children of linked names need an alias so
  // that wallet.linked.parent.eth resolves to the same records as wallet.sub1.sub2.parent.eth
  const walletData = await traverseRegistry(env, "wallet.sub1.sub2.parent.eth");
  if (walletData?.resolver && walletData.resolver !== zeroAddress) {
    const walletResolver = getContract({
      address: walletData.resolver,
      abi: OwnedResolverAbi,
      client: env.deployment.client,
    });
    await walletResolver.write.setAlias(
      [
        dnsEncodeName("linked.parent.eth"),
        dnsEncodeName("sub1.sub2.parent.eth"),
      ],
      { account: env.namedAccounts.owner },
    );
    console.log(
      "✓ Set alias on wallet resolver: linked.parent.eth → sub1.sub2.parent.eth",
    );
  }

  // Change roles on changerole.eth
  const roleReceipts = await changeRole(
    env,
    "changerole.eth",
    env.namedAccounts.user.address,
    ROLES.REGISTRY.SET_RESOLVER,
    ROLES.REGISTRY.SET_SUBREGISTRY,
  );
  for (const receipt of roleReceipts) {
    await trackGas("changeRole(changerole)", receipt);
  }

  const allNames = [
    "test.eth",
    "example.eth",
    "demo.eth",
    "newowner.eth",
    "renew.eth",
    "reregister.eth",
    "parent.eth",
    "changerole.eth",
    "alias.eth",
    "sub.alias.eth",
    ...createdSubnames,
    "linked.parent.eth",
    "wallet.linked.parent.eth",
  ];

  await showName(env, allNames);

  // Verify all names are properly registered
  await verifyNames(env, allNames);

  // Display gas report at the end
  displayGasReport();
}

// ========== Verification ==========

async function verifyNames(env: DevnetEnvironment, names: string[]) {
  console.log("\n========== Verifying Names ==========\n");

  const errors: string[] = [];

  // Names that resolve only via alias (not directly registered in registry)
  const aliasOnlyNames = new Set(["sub.alias.eth"]);

  for (const name of names) {
    if (aliasOnlyNames.has(name)) {
      // Verify alias resolution via UniversalResolver
      try {
        const addrCall = encodeFunctionData({
          abi: OwnedResolverAbi,
          functionName: "addr",
          args: [namehash(name)],
        });
        const [result] =
          await env.deployment.contracts.UniversalResolverV2.read.resolve([
            dnsEncodeName(name),
            addrCall,
          ]);
        if (!result || result === "0x") {
          errors.push(`${name}: alias resolution returned empty result`);
        }
      } catch (e) {
        errors.push(`${name}: alias resolution failed — ${e}`);
      }
      continue;
    }

    const data = await traverseRegistry(env, name);

    if (!data || !data.owner || data.owner === zeroAddress) {
      errors.push(`${name}: not registered (no owner)`);
      continue;
    }

    if (!data.resolver || data.resolver === zeroAddress) {
      errors.push(`${name}: no resolver set`);
    }

    // Check expiry is in the future
    if (data.expiry && data.expiry !== MAX_EXPIRY) {
      const currentTimestamp = await env.deployment.client
        .getBlock()
        .then((b) => b.timestamp);
      if (data.expiry <= currentTimestamp) {
        errors.push(
          `${name}: expired (expiry=${data.expiry}, now=${currentTimestamp})`,
        );
      }
    }
  }

  // Verify specific ownership expectations
  const newownerData = await traverseRegistry(env, "newowner.eth");
  if (
    newownerData?.owner &&
    newownerData.owner !== env.namedAccounts.user.address
  ) {
    errors.push(
      `newowner.eth: expected owner ${env.namedAccounts.user.address}, got ${newownerData.owner}`,
    );
  }

  if (errors.length > 0) {
    console.error("Verification FAILED:");
    for (const err of errors) {
      console.error(`  ✗ ${err}`);
    }
    throw new Error(`Name verification failed with ${errors.length} error(s)`);
  }

  console.log(`✓ All ${names.length} names verified successfully`);
}
