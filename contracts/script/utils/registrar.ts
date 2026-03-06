import { namehash, zeroAddress } from "viem";

import { ROLES } from "../deploy-constants.js";
import { idFromLabel } from "../../test/utils/utils.js";
import type { DevnetEnvironment } from "../setup.js";
import { trackGas } from "./gas.js";

const ONE_DAY_SECONDS = 86400;

/**
 * Register names in the ETHRegistry with default resolver records
 */
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
    const resolver = await env.deployment.deployPermissionedResolver({
      account,
    });

    if (shouldTrackGas)
      await trackGas("deployPermissionedResolver", resolver.deploymentReceipt);

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
