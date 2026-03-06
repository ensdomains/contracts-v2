import { namehash, zeroAddress } from "viem";

import { ROLES } from "../deploy-constants.js";
import { idFromLabel } from "../../test/utils/utils.js";
import type { DevnetEnvironment } from "../setup.js";
import { trackGas } from "./gas.js";

const ONE_DAY_SECONDS = 86400;

/**
 * Register names via the ETHRegistrar commit-reveal flow with batched commits.
 * Commits all names, does one time warp, then registers all.
 */
export async function registerTestNames(
  env: DevnetEnvironment,
  labels: string[],
  options: {
    account?: any;
    durationInDays?: number;
    trackGas?: boolean;
  } = {},
) {
  const account = options.account ?? env.namedAccounts.owner;
  const shouldTrackGas = options.trackGas ?? false;
  const durationInDays = options.durationInDays ?? 28;
  const duration = BigInt(durationInDays * ONE_DAY_SECONDS);
  const paymentToken = env.deployment.contracts.MockUSDC.address;
  const referrer =
    "0x0000000000000000000000000000000000000000000000000000000000000000" as `0x${string}`;

  // Deploy resolvers for all names
  const resolvers = [];
  for (const label of labels) {
    const resolver = await env.deployment.deployPermissionedResolver({
      account,
    });
    if (shouldTrackGas)
      await trackGas("deployPermissionedResolver", resolver.deploymentReceipt);
    resolvers.push(resolver);
  }

  // Step 1: Commit all names
  const secrets = labels.map(
    (_, i) =>
      `0x${(i + 1).toString(16).padStart(64, "0")}` as `0x${string}`,
  );

  for (let i = 0; i < labels.length; i++) {
    const commitment =
      await env.deployment.contracts.ETHRegistrar.read.makeCommitment([
        labels[i],
        account.address,
        secrets[i],
        zeroAddress,
        resolvers[i].address,
        duration,
        referrer,
      ]);

    const { receipt } = await env.waitFor(
      env.deployment.contracts.ETHRegistrar.write.commit([commitment], {
        account,
      }),
    );
    if (shouldTrackGas) await trackGas(`commit(${labels[i]})`, receipt);
  }

  // Step 2: Single time warp past minCommitmentAge
  const minAge =
    await env.deployment.contracts.ETHRegistrar.read.MIN_COMMITMENT_AGE();
  await env.sync({ warpSec: Number(minAge) + 1 });

  // Step 3: Approve total payment
  let totalPrice = 0n;
  for (const label of labels) {
    const [base, premium] =
      await env.deployment.contracts.ETHRegistrar.read.rentPrice([
        label,
        account.address,
        duration,
        paymentToken,
      ]);
    totalPrice += base + premium;
  }

  const balance = await env.deployment.contracts.MockUSDC.read.balanceOf([
    account.address,
  ]);
  if (balance < totalPrice) {
    await env.deployment.contracts.MockUSDC.write.mint(
      [account.address, totalPrice - balance + 1000000n],
      { account },
    );
  }
  await env.deployment.contracts.MockUSDC.write.approve(
    [env.deployment.contracts.ETHRegistrar.address, totalPrice],
    { account },
  );

  // Step 4: Register all names
  for (let i = 0; i < labels.length; i++) {
    const { receipt } = await env.waitFor(
      env.deployment.contracts.ETHRegistrar.write.register(
        [
          labels[i],
          account.address,
          secrets[i],
          zeroAddress,
          resolvers[i].address,
          duration,
          paymentToken,
          referrer,
        ],
        { account },
      ),
    );
    if (shouldTrackGas) await trackGas(`register(${labels[i]})`, receipt);

    // Set resolver records
    const node = namehash(`${labels[i]}.eth`);
    const setAddrTx = await env.waitFor(
      resolvers[i].write.setAddr([node, 60n, account.address], { account }),
    );
    if (shouldTrackGas) await trackGas(`setAddr(${labels[i]})`, setAddrTx.receipt);

    const setTextTx = await env.waitFor(
      resolvers[i].write.setText(
        [node, "description", `${labels[i]}.eth`],
        { account },
      ),
    );
    if (shouldTrackGas) await trackGas(`setText(${labels[i]})`, setTextTx.receipt);
  }
}

/**
 * Re-register a name after it has expired (includes time warp)
 */
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

  // Time warp past expiry (must exceed the registration duration, default 28 days)
  const warpSeconds = 28 * ONE_DAY_SECONDS + 1;
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

  // Re-register via commit-reveal
  console.log(`\nRe-registering ${label}.eth...`);

  await registerTestNames(env, [label], {
    account,
    durationInDays: 28,
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
 * Renew a name via the ETHRegistrar
 */
export async function renewName(
  env: DevnetEnvironment,
  name: string,
  durationInDays: number,
  account = env.namedAccounts.owner,
) {
  const label = name.split(".")[0];
  const { MAX_EXPIRY } = await import("../deploy-constants.js");

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

