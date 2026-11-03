import { describe, expect, it } from "bun:test";
import { getAddress, zeroAddress, type Address } from "viem";

import {
  DEPLOYMENT_ROLES,
  MAX_EXPIRY,
  ROLES,
} from "../../script/deploy-constants.js";
import { idFromLabel } from "../utils/utils.js";

const RESOLVER = "0x000000000000000000000000000000000000b0b0" as Address;

describe("reverse in the root registry", () => {
  const { env, setupEnv } = process.TEST_GLOBALS!;
  setupEnv({ resetOnEach: true });

  it("leaves the deployer holding the token with every role and admin role until the handover", async () => {
    const root = env.v2.RootRegistry;
    const { deployer, owner } = env.namedAccounts;
    const id = idFromLabel("reverse");
    const resource = await root.read.getResource([id]);

    expect((await root.read.getState([id])).latestOwner).toBe(deployer.address);
    expect(await root.read.getResolver(["reverse"])).toBe(
      getAddress(env.v2.ENSV1Resolver.address),
    );
    expect(await root.read.roles([resource, deployer.address])).toBe(
      DEPLOYMENT_ROLES.ROOT_NAME_TOKEN,
    );
    expect(await root.read.roles([resource, owner.address])).toBe(0n);

    await root.write.setResolver([id, RESOLVER], { account: deployer });
    expect(await root.read.getResolver(["reverse"])).toBe(RESOLVER);
  });

  it("is registered to the deployer because an owner without an ERC-1155 receiver cannot take it", async () => {
    // The mainnet owner is a DAO timelock with no ERC-1155 receiver, so it can never
    // hold a name's token. Code that reverts every call stands in for it, as the
    // timelock reverts the receiver callback it does not implement.
    const root = env.v2.RootRegistry;
    const { deployer } = env.namedAccounts;
    const dao = "0x000000000000000000000000000000000000da00" as Address;
    await env.client.setCode({ address: dao, bytecode: "0x5f5ffd" });

    await expect(
      root.write.register(
        [
          "handoff",
          dao,
          zeroAddress,
          zeroAddress,
          DEPLOYMENT_ROLES.ROOT_NAME_TOKEN,
          MAX_EXPIRY,
        ],
        { account: deployer },
      ),
    ).rejects.toThrow("ERC1155InvalidReceiver");

    // Admin roles on a name cannot be granted after registration, so only the
    // token's holder can ever pass them on, by transferring the token.
    await root.write.register(
      [
        "handoff",
        deployer.address,
        zeroAddress,
        zeroAddress,
        ROLES.REGISTRY.SET_RESOLVER,
        MAX_EXPIRY,
      ],
      { account: deployer },
    );
    const resource = await root.read.getResource([idFromLabel("handoff")]);
    await expect(
      root.write.grantRoles(
        [resource, ROLES.ADMIN.REGISTRY.SET_RESOLVER, deployer.address],
        { account: deployer },
      ),
    ).rejects.toThrow("EACCannotGrantRoles");
  });
});
