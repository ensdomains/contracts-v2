import type { Account, Address } from "viem";
import { V1_GRACE_PERIOD_SECONDS } from "../../script/preMigration.js";
import type { DevnetEnvironment } from "../../script/setup.js";
import { dnsEncodeName, idFromLabel } from "./utils.js";

// Pre-migration helpers shared with the devnet runner live in script/ so
// production code doesn't import from test/. Re-exported here for tests.
export {
  DEPLOYER_PRIVATE_KEY,
  createCSVFile,
  buildMainArgs,
  verifyV2State,
} from "../../script/preMigrationUtils.js";

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

/// Registers `label` briefly, moves the chain past its v1 grace period, and has the
/// Graveyard reclaim it with `clear`, which is how an expired name leaves circulation.
/// Returns the v1 expiry the reclaim leaves behind.
export async function reclaimThroughGraveyard(
  env: DevnetEnvironment,
  label: string,
  ownerAddress: Address,
): Promise<bigint> {
  const expiry = await registerV1Name(env, label, ownerAddress, 1);
  await env.client.setNextBlockTimestamp({
    timestamp: expiry + V1_GRACE_PERIOD_SECONDS + 1n,
  });
  await env.client.mine({ blocks: 1 });
  // Phase 4 grants the Graveyard its registrar controller role; the devnet leaves
  // that to the caller.
  await env.v1.RegistrarSecurityController.write.addRegistrarController(
    [env.v2.Graveyard.address],
    { account: env.namedAccounts.owner },
  );
  await env.v2.Graveyard.write.clear([[dnsEncodeName(`${label}.eth`)]]);
  return env.v1.BaseRegistrar.read.nameExpires([idFromLabel(label)]);
}

/// Hands a v1 name's token to the Graveyard, as a migration does once it has moved
/// the name to v2.
export async function handToGraveyard(
  env: DevnetEnvironment,
  label: string,
  owner: Account,
) {
  await env.v1.BaseRegistrar.write.transferFrom(
    [owner.address, env.v2.Graveyard.address, idFromLabel(label)],
    { account: owner },
  );
}
