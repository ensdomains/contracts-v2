import { describe, expect, it } from "bun:test";
import { getAddress, zeroAddress } from "viem";

import { DEPLOYMENT_ROLES, ROLES } from "../../script/deploy-constants.js";
import {
  EMANCIPATED_OWNER_ROOT_ROLES,
  planRegistryHandover,
  rootEmancipationRoles,
  type RegistryHandoverState,
} from "../../script/migrations/registryHandover.js";

const DEPLOYER = getAddress("0x00000000000000000000000000000000000000d1");
const OWNER = getAddress("0x00000000000000000000000000000000000000a1");
const ENDOWMENT = getAddress("0x00000000000000000000000000000000000000e1");
const ETH_TOKEN_ID = 123n;

// The registries as the deploy leaves them.
const deployed: RegistryHandoverState = {
  deployer: DEPLOYER,
  owner: OWNER,
  endowment: ENDOWMENT,
  ethTokenId: ETH_TOKEN_ID,
  ethTokenHolder: DEPLOYER,
  batchRegistrars: [
    { contract: "BatchRegistrar", owner: DEPLOYER },
    { contract: "RootBatchRegistrar", owner: DEPLOYER },
  ],
  ownerRootRoles: DEPLOYMENT_ROLES.ROOT_REGISTRY_MANAGER,
  deployerRootRoles: DEPLOYMENT_ROLES.ROOT_REGISTRY_ROOT,
  ownerEthRegistryRoles: DEPLOYMENT_ROLES.ETH_REGISTRY_MANAGER,
  deployerEthRegistryRoles: DEPLOYMENT_ROLES.ETH_REGISTRY_ROOT,
};

// The registries once handed over.
const handedOver: RegistryHandoverState = {
  ...deployed,
  ethTokenHolder: ENDOWMENT,
  batchRegistrars: [
    { contract: "BatchRegistrar", owner: zeroAddress },
    { contract: "RootBatchRegistrar", owner: zeroAddress },
  ],
  ownerRootRoles: DEPLOYMENT_ROLES.ROOT_REGISTRY_ROOT,
  deployerRootRoles: 0n,
  ownerEthRegistryRoles: DEPLOYMENT_ROLES.ETH_REGISTRY_ROOT,
  deployerEthRegistryRoles: 0n,
};

describe("planRegistryHandover", () => {
  it("moves the eth token first, grants the owner its roles before the deployer drops everything, then renounces the batch registrars", () => {
    expect(planRegistryHandover(deployed)).toEqual([
      {
        contract: "RootRegistry",
        functionName: "safeTransferFrom",
        args: [DEPLOYER, ENDOWMENT, ETH_TOKEN_ID, 1n, "0x"],
        label: expect.stringContaining("endowment"),
      },
      {
        contract: "RootRegistry",
        functionName: "grantRootRoles",
        args: [
          DEPLOYMENT_ROLES.ROOT_REGISTRY_ROOT &
            ~DEPLOYMENT_ROLES.ROOT_REGISTRY_MANAGER,
          OWNER,
        ],
        label: expect.stringContaining("grant the owner"),
      },
      {
        contract: "ETHRegistry",
        functionName: "grantRootRoles",
        args: [
          DEPLOYMENT_ROLES.ETH_REGISTRY_ROOT &
            ~DEPLOYMENT_ROLES.ETH_REGISTRY_MANAGER,
          OWNER,
        ],
        label: expect.stringContaining(".eth registry"),
      },
      {
        contract: "RootRegistry",
        functionName: "revokeRootRoles",
        args: [DEPLOYMENT_ROLES.ROOT_REGISTRY_ROOT, DEPLOYER],
        label: expect.any(String),
      },
      {
        contract: "ETHRegistry",
        functionName: "revokeRootRoles",
        args: [DEPLOYMENT_ROLES.ETH_REGISTRY_ROOT, DEPLOYER],
        label: expect.any(String),
      },
      {
        contract: "BatchRegistrar",
        functionName: "renounceOwnership",
        args: [],
        label: expect.any(String),
      },
      {
        contract: "RootBatchRegistrar",
        functionName: "renounceOwnership",
        args: [],
        label: expect.any(String),
      },
    ]);
  });

  it("registers eth transferable, with no role that could remove it", () => {
    expect(
      DEPLOYMENT_ROLES.ETH_TOKEN & ROLES.ADMIN.REGISTRY.CAN_TRANSFER,
    ).not.toBe(0n);
    expect(
      DEPLOYMENT_ROLES.ETH_TOKEN &
        (ROLES.REGISTRY.UNREGISTER | ROLES.ADMIN.REGISTRY.UNREGISTER),
    ).toBe(0n);
  });

  it("revokes whatever the deployer holds, not only what the deploy granted", () => {
    const extra = ROLES.REGISTRY.REGISTRAR;
    const ethRegistry = planRegistryHandover({
      ...deployed,
      deployerEthRegistryRoles: DEPLOYMENT_ROLES.ETH_REGISTRY_ROOT | extra,
    }).find(
      (call) =>
        call.contract === "ETHRegistry" &&
        call.functionName === "revokeRootRoles",
    )!;
    expect(ethRegistry.args).toEqual([
      DEPLOYMENT_ROLES.ETH_REGISTRY_ROOT | extra,
      DEPLOYER,
    ]);
  });

  it("sends only what is missing on a re-run", () => {
    const calls = planRegistryHandover({
      ...handedOver,
      deployerEthRegistryRoles: DEPLOYMENT_ROLES.ETH_REGISTRY_ROOT,
      batchRegistrars: [
        { contract: "BatchRegistrar", owner: zeroAddress },
        { contract: "RootBatchRegistrar", owner: DEPLOYER },
      ],
    });
    expect(calls.map((call) => [call.contract, call.functionName])).toEqual([
      ["ETHRegistry", "revokeRootRoles"],
      ["RootBatchRegistrar", "renounceOwnership"],
    ]);
  });

  it("refuses a token held by neither the deployer nor the endowment", () => {
    expect(() =>
      planRegistryHandover({ ...deployed, ethTokenHolder: OWNER }),
    ).toThrow(/eth token is held by/);
  });

  it("refuses a batch registrar owned by someone other than the deployer", () => {
    expect(() =>
      planRegistryHandover({
        ...deployed,
        batchRegistrars: [{ contract: "BatchRegistrar", owner: OWNER }],
      }),
    ).toThrow(/BatchRegistrar is owned by/);
  });

  it("refuses to hand the eth token from the deployer to itself", () => {
    expect(() =>
      planRegistryHandover({ ...deployed, endowment: DEPLOYER }),
    ).toThrow(/no one to hand the eth token to/);
  });

  it("hands the owner no .eth registry role that reaches a name", () => {
    // The roles the registry counts against emancipation: any of them at the root
    // reaches every name, and blocks safe transfers of .eth names.
    const unemancipated =
      ROLES.ADMIN.REGISTRY.CAN_TRANSFER |
      ROLES.REGISTRY.SET_SUBREGISTRY |
      ROLES.ADMIN.REGISTRY.SET_SUBREGISTRY |
      ROLES.REGISTRY.SET_RESOLVER |
      ROLES.ADMIN.REGISTRY.SET_RESOLVER |
      ROLES.REGISTRY.UNREGISTER |
      ROLES.ADMIN.REGISTRY.UNREGISTER |
      ROLES.REGISTRY.UPGRADE |
      ROLES.ADMIN.REGISTRY.UPGRADE;
    expect(DEPLOYMENT_ROLES.ETH_REGISTRY_ROOT & unemancipated).toBe(0n);
    expect(
      DEPLOYMENT_ROLES.ETH_REGISTRY_ROOT &
        (ROLES.ADMIN.REGISTRY.REGISTRAR |
          ROLES.ADMIN.REGISTRY.REGISTER_RESERVED),
    ).toBe(
      ROLES.ADMIN.REGISTRY.REGISTRAR | ROLES.ADMIN.REGISTRY.REGISTER_RESERVED,
    );
  });

  it("plans nothing once handed over", () => {
    expect(planRegistryHandover(handedOver)).toEqual([]);
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
  it("drops every root role but naming, metadata, and adding and assigning top-level names", () => {
    const dropped = rootEmancipationRoles(DEPLOYMENT_ROLES.ROOT_REGISTRY_ROOT);
    expect(dropped & EMANCIPATED_OWNER_ROOT_ROLES).toBe(0n);
    expect(dropped | EMANCIPATED_OWNER_ROOT_ROLES).toBe(
      DEPLOYMENT_ROLES.ROOT_REGISTRY_ROOT,
    );
    expect(dropped & ROLES.ADMIN.REGISTRY.CAN_NAME).not.toBe(0n);
    expect(dropped & ROLES.ADMIN.REGISTRY.REGISTRAR).toBe(0n);
    expect(dropped & ROLES.ADMIN.REGISTRY.REGISTER_RESERVED).toBe(0n);
  });

  it("keeps no root role that reaches a registered name", () => {
    expect(
      EMANCIPATED_OWNER_ROOT_ROLES &
        (ROLES.ADMIN.REGISTRY.CAN_TRANSFER |
          ROLES.REGISTRY.SET_SUBREGISTRY |
          ROLES.ADMIN.REGISTRY.SET_SUBREGISTRY |
          ROLES.REGISTRY.SET_RESOLVER |
          ROLES.ADMIN.REGISTRY.SET_RESOLVER |
          ROLES.REGISTRY.UNREGISTER |
          ROLES.ADMIN.REGISTRY.UNREGISTER |
          ROLES.REGISTRY.UPGRADE |
          ROLES.ADMIN.REGISTRY.UPGRADE |
          ROLES.REGISTRY.RENEW |
          ROLES.ADMIN.REGISTRY.RENEW),
    ).toBe(0n);
  });

  it("is nothing once the owner holds only the roles it keeps", () => {
    expect(rootEmancipationRoles(EMANCIPATED_OWNER_ROOT_ROLES)).toBe(0n);
  });
});
