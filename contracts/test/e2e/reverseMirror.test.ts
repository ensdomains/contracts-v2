import { describe, expect, it } from "bun:test";
import { zeroAddress, type Address } from "viem";

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

  it("leaves the owner operating it with no admin role held by anyone", async () => {
    const root = env.v2.RootRegistry;
    const { deployer, owner } = env.namedAccounts;
    const id = idFromLabel("reverse");
    const resource = await root.read.getResource([id]);

    expect((await root.read.getState([id])).latestOwner).toBe(deployer.address);
    expect(await root.read.roles([resource, owner.address])).toBe(
      DEPLOYMENT_ROLES.REVERSE_REGISTRY_OPERATOR,
    );
    expect(await root.read.roles([resource, deployer.address])).toBe(0n);

    await root.write.setResolver([id, RESOLVER], { account: owner });
    expect(await root.read.getResolver(["reverse"])).toBe(RESOLVER);
    await expect(
      root.write.setResolver([id, zeroAddress], { account: deployer }),
    ).rejects.toThrow("EACUnauthorizedAccountRoles");
    // Holding the token without its admin roles moves nothing, so control cannot
    // be taken back by moving the token either.
    await expect(
      root.write.grantRoles(
        [resource, ROLES.REGISTRY.SET_RESOLVER, deployer.address],
        { account: deployer },
      ),
    ).rejects.toThrow("EACCannotGrantRoles");
  });

  it("hands a name to an owner that cannot receive its token", async () => {
    // The mainnet owner is a DAO timelock with no ERC-1155 receiver, so it can never
    // hold a name's token. Code that reverts every call stands in for it, as the
    // timelock reverts the receiver callback it does not implement.
    const root = env.v2.RootRegistry;
    const { deployer } = env.namedAccounts;
    const dao = "0x000000000000000000000000000000000000da00" as Address;
    await env.client.setCode({ address: dao, bytecode: "0x5f5ffd" });
    await env.client.setBalance({ address: dao, value: 10n ** 18n });
    await env.client.impersonateAccount({ address: dao });

    await expect(
      root.write.register(
        [
          "handoff",
          dao,
          zeroAddress,
          zeroAddress,
          DEPLOYMENT_ROLES.REVERSE_REGISTRY_ROOT,
          MAX_EXPIRY,
        ],
        { account: deployer },
      ),
    ).rejects.toThrow("ERC1155InvalidReceiver");

    await root.write.register(
      [
        "handoff",
        deployer.address,
        zeroAddress,
        zeroAddress,
        DEPLOYMENT_ROLES.REVERSE_REGISTRY_ROOT,
        MAX_EXPIRY,
      ],
      { account: deployer },
    );
    const id = idFromLabel("handoff");
    const resource = await root.read.getResource([id]);
    // Admin roles on a name cannot be granted at all, only the regular ones.
    await expect(
      root.write.grantRoles(
        [resource, DEPLOYMENT_ROLES.REVERSE_REGISTRY_ROOT, dao],
        { account: deployer },
      ),
    ).rejects.toThrow("EACCannotGrantRoles");
    await root.write.grantRoles(
      [resource, DEPLOYMENT_ROLES.REVERSE_REGISTRY_OPERATOR, dao],
      { account: deployer },
    );
    await root.write.revokeRoles(
      [resource, DEPLOYMENT_ROLES.REVERSE_REGISTRY_ROOT, deployer.address],
      { account: deployer },
    );

    await root.write.setResolver([id, RESOLVER], { account: dao });
    expect(await root.read.getResolver(["handoff"])).toBe(RESOLVER);
    await expect(
      root.write.setResolver([id, zeroAddress], { account: deployer }),
    ).rejects.toThrow("EACUnauthorizedAccountRoles");
    const { tokenId } = await root.read.getState([id]);
    await expect(
      root.write.safeTransferFrom([deployer.address, dao, tokenId, 1n, "0x"], {
        account: deployer,
      }),
    ).rejects.toThrow("TransferDisallowed");
  });
});
