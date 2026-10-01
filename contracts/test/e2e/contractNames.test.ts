import { describe, it } from "bun:test";
import { type Address, parseEventLogs, zeroAddress } from "viem";
import { STATUS, MAX_EXPIRY, ROLES } from "../../script/deploy-constants.js";
import { expect } from "../utils/expectVar.js";
import { idFromLabel } from "../utils/utils.js";
import {
  type NamingInfo,
  createDeployResolverTx,
  createMigrationTx,
  expectedResolverAddress,
} from "../../script/contractNames.js";

describe("Contract Names", () => {
  const { env, setupEnv } = process.TEST_GLOBALS!;

  const v1 = toAddresses(env.v1);
  v1.BaseRegistrarImplementation = v1.BaseRegistrar; // devnet renames this
  const v2 = toAddresses(env.v2);
  const { owner } = env.namedAccounts;

  const info: NamingInfo = {
    label: "ensv2", // devnet already does setupEnsDotEth()
    v1Owner: owner.address,
    isWrapped: false,
    v2Owner: owner.address,
    resolverSaltVersion: 1n, // devnet already deploys a PermissionedResolver for "owner"
    managers: [env.namedAccounts.user.address],
  };

  setupEnv({
    resetOnEach: true,
    async initialize() {
      // hack: add controller so we can register() directly
      await env.v1.RegistrarSecurityController.write.addRegistrarController(
        [env.namedAccounts.deployer.address],
        { account: env.namedAccounts.owner },
      );

      // register in v1
      await env.v1.BaseRegistrar.write.register([
        idFromLabel(info.label),
        info.v1Owner,
        MAX_EXPIRY,
      ]);
      await env.v2.ETHRegistry.write.register([
        info.label,
        zeroAddress,
        zeroAddress,
        env.v2.ENSV1Resolver.address,
        0n,
        MAX_EXPIRY,
      ]);
    },
  });

  it("createDeployResolverTx()", async () => {
    const tr = createDeployResolverTx({ info, v2 });
    const receipt = await env.waitFor(
      env.createClient(owner).sendTransaction(tr),
    );

    const [log] = parseEventLogs({
      abi: env.v2.VerifiableFactory.abi,
      eventName: "ProxyDeployed",
      logs: receipt.logs,
    });
    const resolver = env.castPermissionedResolver(log.args.proxyAddress);

    expect(resolver.address).toEqualAddress(
      expectedResolverAddress({ info, v2 }),
    );
    await expect(
      resolver.read.roles([0n, info.v2Owner]),
    ).resolves.toStrictEqual(ROLES.ALL);
  });

  it("createMigrationTx()", async () => {
    const tr = createMigrationTx({ info, v1, v2 });
    await env.waitFor(env.createClient(owner).sendTransaction(tr));

    await expect(
      env.v2.ETHRegistry.read.getState([idFromLabel(info.label)]),
    ).resolves.toMatchObject({
      status: STATUS.REGISTERED,
      latestOwner: owner.address,
    });
    await expect(
      env.v2.ETHRegistry.read.getResolver([info.label]),
    ).resolves.toEqualAddress(expectedResolverAddress({ info, v2 }));
  });
});

function toAddresses(contracts: Record<string, { address: Address }>) {
  return Object.fromEntries(
    Object.entries(contracts).map(([k, v]) => [k, v.address]),
  );
}
