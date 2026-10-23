import { Artifact_BatchRegistrar } from "generated/artifacts/BatchRegistrar.js";
import { Artifact_Graveyard } from "generated/artifacts/Graveyard.js";
import { Artifact_PermissionedRegistry } from "generated/artifacts/PermissionedRegistry.js";
import {
  type Abi,
  type Account,
  type Address,
  encodeAbiParameters,
  type Hex,
  namehash,
  zeroAddress,
} from "viem";
import { DEPLOYMENT_ROLES, FUSES } from "../../script/deploy-constants.js";
import { migrationDataComponents } from "../../script/migrate.js";
import { V1_GRACE_PERIOD_SECONDS } from "../../script/preMigration.js";
import { buildMainArgs as buildDevnetMainArgs } from "../../script/preMigrationUtils.js";
import type { DevnetEnvironment } from "../../script/setup.js";
import { dnsEncodeName, idFromLabel } from "./utils.js";
import { waitForSuccessfulTransactionReceipt } from "./waitForSuccessfulTransactionReceipt.js";

// Pre-migration helpers shared with the devnet runner live in script/ so
// production code doesn't import from test/. Re-exported here for tests.
export {
  DEPLOYER_PRIVATE_KEY,
  createCSVFile,
  verifyV2State,
} from "../../script/preMigrationUtils.js";

// The test devnet reports mainnet's chain id, so a run on it takes the mainnet gas
// price limit, which the devnet's own gas prices sit far above. The devnet also mines
// only when a transaction arrives, so a paused run would never resume. Tests that are
// not about the limit therefore run with one that no devnet block reaches.
const TEST_MAX_GAS_PRICE = "1000";

/// Pre-migration arguments for the test devnet; see `buildDevnetMainArgs`.
export function buildMainArgs(
  ...[env, csvFilePath, overrides = {}]: Parameters<typeof buildDevnetMainArgs>
): string[] {
  return buildDevnetMainArgs(env, csvFilePath, {
    maxGasPrice: TEST_MAX_GAS_PRICE,
    ...overrides,
  });
}

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

/// Moves the chain to `timestamp` and mines a block there.
export async function warpTo(env: DevnetEnvironment, timestamp: bigint) {
  await env.client.setNextBlockTimestamp({ timestamp });
  await env.client.mine({ blocks: 1 });
}

/// Has the Graveyard reclaim an expired v1 name with `clear`, which is how an expired
/// name leaves circulation. Returns the v1 expiry the reclaim leaves behind.
export async function clearThroughGraveyard(
  env: DevnetEnvironment,
  label: string,
): Promise<bigint> {
  // Phase 4 grants the Graveyard its registrar controller role; the devnet leaves
  // that to the caller.
  await env.v1.RegistrarSecurityController.write.addRegistrarController(
    [env.v2.Graveyard.address],
    { account: env.namedAccounts.owner },
  );
  await env.v2.Graveyard.write.clear([[dnsEncodeName(`${label}.eth`)]]);
  return env.v1.BaseRegistrar.read.nameExpires([idFromLabel(label)]);
}

/// Registers `label` briefly, moves the chain past its v1 grace period, and has the
/// Graveyard reclaim it. Returns the v1 expiry the reclaim leaves behind.
export async function reclaimThroughGraveyard(
  env: DevnetEnvironment,
  label: string,
  ownerAddress: Address,
): Promise<bigint> {
  const expiry = await registerV1Name(env, label, ownerAddress, 1);
  await warpTo(env, expiry + V1_GRACE_PERIOD_SECONDS + 1n);
  return clearThroughGraveyard(env, label);
}

/// Leaves a v1 name the way an unwrapped migration does once it has moved the name to
/// v2: the registry node and the registrar token both with the Graveyard.
export async function handToGraveyard(
  env: DevnetEnvironment,
  label: string,
  owner: Account,
) {
  const id = idFromLabel(label);
  await env.v1.BaseRegistrar.write.reclaim([id, env.v2.Graveyard.address], {
    account: owner,
  });
  await env.v1.BaseRegistrar.write.transferFrom(
    [owner.address, env.v2.Graveyard.address, id],
    { account: owner },
  );
}

/// Wraps a registered v1 name for its owner, burning `fuses`.
export async function wrapV1Name(
  env: DevnetEnvironment,
  label: string,
  owner: Account,
  fuses = 0,
) {
  await env.v1.BaseRegistrar.write.safeTransferFrom(
    [
      owner.address,
      env.v1.NameWrapper.address,
      idFromLabel(label),
      encodeAbiParameters(
        [
          { name: "label", type: "string" },
          { name: "owner", type: "address" },
          { name: "fuses", type: "uint16" },
          { name: "resolver", type: "address" },
        ],
        [label, owner.address, fuses, zeroAddress],
      ),
    ],
    { account: owner },
  );
}

function migrationData(label: string, owner: Address): Hex {
  return encodeAbiParameters(
    [{ type: "tuple", components: migrationDataComponents }],
    [{ label, owner, subregistry: zeroAddress, resolver: zeroAddress }],
  );
}

/// Migrates a reserved, unwrapped v1 name through `UnlockedMigrationController`.
export async function migrateUnwrapped(
  env: DevnetEnvironment,
  label: string,
  owner: Account,
) {
  await env.v1.BaseRegistrar.write.safeTransferFrom(
    [
      owner.address,
      env.v2.UnlockedMigrationController.address,
      idFromLabel(label),
      migrationData(label, owner.address),
    ],
    { account: owner },
  );
}

/// Wraps a reserved v1 name locked and migrates it through
/// `LockedMigrationController`, which hands the wrapper token to the Graveyard.
export async function migrateLocked(
  env: DevnetEnvironment,
  label: string,
  owner: Account,
) {
  await wrapV1Name(env, label, owner, FUSES.CANNOT_UNWRAP);
  await env.v1.NameWrapper.write.safeTransferFrom(
    [
      owner.address,
      env.v2.LockedMigrationController.address,
      BigInt(namehash(`${label}.eth`)),
      1n,
      migrationData(label, owner.address),
    ],
    { account: owner },
  );
}

/// Deploys an empty `.eth` registry with its own `BatchRegistrar`, the state a fresh
/// v2 deployment leaves on a chain an earlier deployment already migrated.
export async function deployFreshEthRegistry(env: DevnetEnvironment) {
  const deploy = async (
    artifact: { abi: readonly unknown[]; bytecode: Hex },
    args: readonly unknown[],
  ) => {
    const { contractAddress } = await waitForSuccessfulTransactionReceipt(
      env.client,
      {
        hash: await env.client.deployContract({
          abi: artifact.abi as Abi,
          bytecode: artifact.bytecode,
          args,
        }),
        ensureDeployment: true,
      },
    );
    return contractAddress;
  };
  const deployer = env.namedAccounts.deployer.address;
  const registry = await deploy(Artifact_PermissionedRegistry, [
    env.v2.LabelStore.address,
    deployer,
    DEPLOYMENT_ROLES.ETH_REGISTRY_ROOT,
  ]);
  const batchRegistrar = await deploy(Artifact_BatchRegistrar, [
    registry,
    deployer,
  ]);
  await waitForSuccessfulTransactionReceipt(env.client, {
    hash: await env.client.writeContract({
      address: registry,
      abi: Artifact_PermissionedRegistry.abi,
      functionName: "grantRootRoles",
      args: [DEPLOYMENT_ROLES.ETH_REGISTRAR_ROOT, batchRegistrar],
    }),
  });
  return { registry, batchRegistrar };
}

/// Deploys another Graveyard on the devnet's v1, one that holds no names.
export async function deployGraveyard(env: DevnetEnvironment) {
  const { contractAddress } = await waitForSuccessfulTransactionReceipt(
    env.client,
    {
      hash: await env.client.deployContract({
        abi: Artifact_Graveyard.abi,
        bytecode: Artifact_Graveyard.bytecode,
        args: [env.v1.NameWrapper.address, env.v2.ContractNamer.address],
      }),
      ensureDeployment: true,
    },
  );
  return contractAddress;
}
