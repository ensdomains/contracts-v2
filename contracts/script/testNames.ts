import {
  encodeFunctionData,
  getContract,
  namehash,
  zeroAddress,
} from "viem";

import { artifacts } from "@rocketh";
import { MAX_EXPIRY, ROLES, STATUS } from "./deploy-constants.js";
import { dnsEncodeName, idFromLabel } from "../test/utils/utils.js";
import type { DevnetEnvironment } from "./setup.js";
import { trackGas, displayGasReport, resetGasTracker } from "./utils/gas.js";
import {
  traverseRegistry,
  createSubname,
  linkName,
  transferName,
  changeRole,
  reserveName,
  unregisterName,
} from "./utils/registry.js";
import {
  registerTestNames,
  reregisterName,
  renewName,
} from "./utils/registrar.js";
import { showName, showAlias } from "./utils/display.js";

// Re-export all utilities for external consumers
export {
  showName,
  showAlias,
  createSubname,
  linkName,
  renewName,
  transferName,
  changeRole,
  registerTestNames,
  reregisterName,
  reserveName,
  unregisterName,
};

const ONE_DAY_SECONDS = 86400;
const PermissionedResolverAbi = artifacts.PermissionedResolver.abi;

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
    abi: PermissionedResolverAbi,
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

  // With PermissionedResolver (node-keyed), children of linked names need an alias so
  // that wallet.linked.parent.eth resolves to the same records as wallet.sub1.sub2.parent.eth
  const walletData = await traverseRegistry(env, "wallet.sub1.sub2.parent.eth");
  if (walletData?.resolver && walletData.resolver !== zeroAddress) {
    const walletResolver = getContract({
      address: walletData.resolver,
      abi: PermissionedResolverAbi,
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

  // Reserve a name (no owner, no token minted)
  const reserveReceipt = await reserveName(env, "reserved.eth");
  await trackGas("reserve(reserved)", reserveReceipt);

  // Register then unregister a name
  await registerTestNames(env, ["unregistered"], { trackGas: true });
  const unregisterReceipt = await unregisterName(env, "unregistered.eth");
  await trackGas("unregister(unregistered)", unregisterReceipt);

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
    "reserved.eth",
    "unregistered.eth",
    ...createdSubnames,
    "linked.parent.eth",
    "wallet.linked.parent.eth",
  ];

  await showName(env, allNames);

  // Show alias mappings for names that may have aliases
  const aliasCandidates = [
    "alias.eth",
    "sub.alias.eth",
    "linked.parent.eth",
    "wallet.linked.parent.eth",
  ];
  await showAlias(env, aliasCandidates);

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
  // Names that are reserved (no owner, no token)
  const reservedNames = new Set(["reserved.eth"]);
  // Names that were unregistered (back to AVAILABLE)
  const unregisteredNames = new Set(["unregistered.eth"]);

  for (const name of names) {
    if (reservedNames.has(name)) {
      const label = name.split(".")[0];
      const state = await env.deployment.contracts.ETHRegistry.read.getState([
        idFromLabel(label),
      ]);
      if (state.status !== STATUS.RESERVED) {
        errors.push(
          `${name}: expected RESERVED status (${STATUS.RESERVED}), got ${state.status}`,
        );
      }
      continue;
    }

    if (unregisteredNames.has(name)) {
      const label = name.split(".")[0];
      const state = await env.deployment.contracts.ETHRegistry.read.getState([
        idFromLabel(label),
      ]);
      if (state.status !== STATUS.AVAILABLE) {
        errors.push(
          `${name}: expected AVAILABLE status (${STATUS.AVAILABLE}), got ${state.status}`,
        );
      }
      continue;
    }

    if (aliasOnlyNames.has(name)) {
      // Verify alias resolution via UniversalResolver
      try {
        const addrCall = encodeFunctionData({
          abi: PermissionedResolverAbi,
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
