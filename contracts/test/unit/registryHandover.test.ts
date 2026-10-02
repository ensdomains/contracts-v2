import { describe, expect, it } from "bun:test";
import { getAddress } from "viem";

import { DEPLOYMENT_ROLES, ROLES } from "../../script/deploy-constants.js";
import {
  planRegistryHandover,
  rootEmancipationRoles,
  type RegistryHandoverState,
} from "../../script/migrations/registryHandover.js";

const DEPLOYER = getAddress("0x00000000000000000000000000000000000000d1");
const OWNER = getAddress("0x00000000000000000000000000000000000000a1");
const ETH_RESOURCE = 123n;

// The registries as the deploy leaves them.
const deployed: RegistryHandoverState = {
  deployer: DEPLOYER,
  owner: OWNER,
  ethResource: ETH_RESOURCE,
  ownerRootRoles: DEPLOYMENT_ROLES.ROOT_REGISTRY_MANAGER,
  deployerRootRoles: DEPLOYMENT_ROLES.ROOT_REGISTRY_ROOT,
  deployerEthEntryRoles: DEPLOYMENT_ROLES.ETH_TOKEN,
  deployerEthRegistryRoles: DEPLOYMENT_ROLES.ETH_REGISTRY_ROOT,
};

describe("planRegistryHandover", () => {
  it("grants the owner the root roles before the deployer drops everything", () => {
    expect(planRegistryHandover(deployed)).toEqual([
      {
        registry: "RootRegistry",
        functionName: "grantRootRoles",
        args: [
          DEPLOYMENT_ROLES.ROOT_REGISTRY_ROOT &
            ~DEPLOYMENT_ROLES.ROOT_REGISTRY_MANAGER,
          OWNER,
        ],
        label: expect.stringContaining("grant the owner"),
      },
      {
        registry: "RootRegistry",
        functionName: "revokeRootRoles",
        args: [DEPLOYMENT_ROLES.ROOT_REGISTRY_ROOT, DEPLOYER],
        label: expect.any(String),
      },
      {
        registry: "RootRegistry",
        functionName: "revokeRoles",
        args: [ETH_RESOURCE, DEPLOYMENT_ROLES.ETH_TOKEN, DEPLOYER],
        label: expect.any(String),
      },
      {
        registry: "ETHRegistry",
        functionName: "revokeRootRoles",
        args: [DEPLOYMENT_ROLES.ETH_REGISTRY_ROOT, DEPLOYER],
        label: expect.any(String),
      },
    ]);
  });

  it("revokes whatever the deployer holds, not only what the deploy granted", () => {
    const extra = ROLES.REGISTRY.REGISTRAR;
    const [, , , ethRegistry] = planRegistryHandover({
      ...deployed,
      deployerEthRegistryRoles: DEPLOYMENT_ROLES.ETH_REGISTRY_ROOT | extra,
    });
    expect(ethRegistry.args).toEqual([
      DEPLOYMENT_ROLES.ETH_REGISTRY_ROOT | extra,
      DEPLOYER,
    ]);
  });

  it("sends only what is missing on a re-run", () => {
    const calls = planRegistryHandover({
      ...deployed,
      ownerRootRoles: DEPLOYMENT_ROLES.ROOT_REGISTRY_ROOT,
      deployerRootRoles: 0n,
    });
    expect(calls.map((call) => call.functionName)).toEqual([
      "revokeRoles",
      "revokeRootRoles",
    ]);
  });

  it("plans nothing once handed over", () => {
    expect(
      planRegistryHandover({
        ...deployed,
        ownerRootRoles: DEPLOYMENT_ROLES.ROOT_REGISTRY_ROOT,
        deployerRootRoles: 0n,
        deployerEthEntryRoles: 0n,
        deployerEthRegistryRoles: 0n,
      }),
    ).toEqual([]);
  });

  it("refuses to hand the registries from the deployer to itself", () => {
    expect(() =>
      planRegistryHandover({
        ...deployed,
        owner: getAddress(DEPLOYER.toLowerCase()),
      }),
    ).toThrow(/no one to hand the registries to/);
  });
});

describe("rootEmancipationRoles", () => {
  it("drops every root role but the regular naming and metadata roles", () => {
    const dropped = rootEmancipationRoles(DEPLOYMENT_ROLES.ROOT_REGISTRY_ROOT);
    expect(dropped & DEPLOYMENT_ROLES.ROOT_REGISTRY_MANAGER).toBe(0n);
    expect(dropped | DEPLOYMENT_ROLES.ROOT_REGISTRY_MANAGER).toBe(
      DEPLOYMENT_ROLES.ROOT_REGISTRY_ROOT,
    );
    expect(dropped & ROLES.ADMIN.REGISTRY.CAN_NAME).not.toBe(0n);
  });

  it("is nothing once the owner holds only naming and metadata", () => {
    expect(rootEmancipationRoles(DEPLOYMENT_ROLES.ROOT_REGISTRY_MANAGER)).toBe(
      0n,
    );
  });
});
