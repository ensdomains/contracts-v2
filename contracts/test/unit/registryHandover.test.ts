import { describe, expect, it } from "bun:test";
import { getAddress, zeroAddress } from "viem";

import {
  DANGEROUS_ROOT_ROLES,
  DEPLOYMENT_ROLES,
  ROLES,
} from "../../script/deploy-constants.js";
import {
  type ArchivedRootState,
  planRegistryHandover,
  type RegistryHandoverState,
} from "../../script/migrations/registryHandover.js";

const DEPLOYER = getAddress("0x00000000000000000000000000000000000000d1");
const OWNER = getAddress("0x00000000000000000000000000000000000000a1");
const NAME_OWNER = getAddress("0x00000000000000000000000000000000000000e1");
const ETH_TOKEN_ID = 123n;
const REVERSE_TOKEN_ID = 456n;
const ETH_ID = 789n;
const REVERSE_ID = 1011n;
const ARCHIVE = "mainnet-root-20261013";

// The roles the deployer keeps on a root's eth entry once its token cannot move.
const ARCHIVED_ETH_ROLES =
  ROLES.REGISTRY.SET_SUBREGISTRY |
  ROLES.ADMIN.REGISTRY.SET_SUBREGISTRY |
  ROLES.REGISTRY.SET_RESOLVER |
  ROLES.ADMIN.REGISTRY.SET_RESOLVER;

// A root registry a root replacement set aside, as the deployer left it.
const archivedRoot: ArchivedRootState = {
  archive: ARCHIVE,
  nameRoles: [
    { label: "eth", id: ETH_ID, roles: ARCHIVED_ETH_ROLES },
    { label: "reverse", id: REVERSE_ID, roles: 0n },
  ],
  deployerRootRoles: DEPLOYMENT_ROLES.ROOT_REGISTRY_ROOT,
  batchRegistrarOwner: DEPLOYER,
};

// The same root once the deployer has dropped everything on it.
const clearedArchivedRoot: ArchivedRootState = {
  ...archivedRoot,
  nameRoles: archivedRoot.nameRoles.map((name) => ({ ...name, roles: 0n })),
  deployerRootRoles: 0n,
  batchRegistrarOwner: zeroAddress,
};

// The registries as the deploy leaves them.
const deployed: RegistryHandoverState = {
  deployer: DEPLOYER,
  owner: OWNER,
  nameOwner: NAME_OWNER,
  rootNameTokens: [
    { label: "eth", tokenId: ETH_TOKEN_ID, holder: DEPLOYER },
    { label: "reverse", tokenId: REVERSE_TOKEN_ID, holder: DEPLOYER },
  ],
  batchRegistrars: [
    { contract: "BatchRegistrar", owner: DEPLOYER },
    { contract: "RootBatchRegistrar", owner: DEPLOYER },
  ],
  ownerRootRoles: DEPLOYMENT_ROLES.ROOT_REGISTRY_MANAGER,
  deployerRootRoles: DEPLOYMENT_ROLES.ROOT_REGISTRY_ROOT,
  ownerEthRegistryRoles: DEPLOYMENT_ROLES.ETH_REGISTRY_MANAGER,
  deployerEthRegistryRoles: DEPLOYMENT_ROLES.ETH_REGISTRY_ROOT,
  archivedRoots: [],
};

// The registries once handed over.
const handedOver: RegistryHandoverState = {
  ...deployed,
  rootNameTokens: [
    { label: "eth", tokenId: ETH_TOKEN_ID, holder: NAME_OWNER },
    { label: "reverse", tokenId: REVERSE_TOKEN_ID, holder: NAME_OWNER },
  ],
  batchRegistrars: [
    { contract: "BatchRegistrar", owner: zeroAddress },
    { contract: "RootBatchRegistrar", owner: zeroAddress },
  ],
  ownerRootRoles: DEPLOYMENT_ROLES.REGISTRY_OWNER_ROOT,
  deployerRootRoles: 0n,
  ownerEthRegistryRoles: DEPLOYMENT_ROLES.REGISTRY_OWNER_ROOT,
  deployerEthRegistryRoles: 0n,
};

describe("planRegistryHandover", () => {
  it("moves the eth and reverse tokens first, grants the owner its roles before the deployer drops everything, then renounces the batch registrars", () => {
    expect(planRegistryHandover(deployed)).toEqual([
      {
        contract: "RootRegistry",
        functionName: "safeTransferFrom",
        args: [DEPLOYER, NAME_OWNER, ETH_TOKEN_ID, 1n, "0x"],
        label: expect.stringContaining("eth token"),
      },
      {
        contract: "RootRegistry",
        functionName: "safeTransferFrom",
        args: [DEPLOYER, NAME_OWNER, REVERSE_TOKEN_ID, 1n, "0x"],
        label: expect.stringContaining("reverse token"),
      },
      {
        contract: "RootRegistry",
        functionName: "grantRootRoles",
        args: [
          DEPLOYMENT_ROLES.REGISTRY_OWNER_ROOT &
            ~DEPLOYMENT_ROLES.ROOT_REGISTRY_MANAGER,
          OWNER,
        ],
        label: expect.stringContaining("grant the owner"),
      },
      {
        contract: "ETHRegistry",
        functionName: "grantRootRoles",
        args: [
          DEPLOYMENT_ROLES.REGISTRY_OWNER_ROOT &
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

  it("registers the root names with every role and admin role", () => {
    expect(DEPLOYMENT_ROLES.ROOT_NAME_TOKEN).toBe(ROLES.ALL);
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

  it("refuses a token held by neither the deployer nor the name owner", () => {
    expect(() =>
      planRegistryHandover({
        ...deployed,
        rootNameTokens: [
          { label: "eth", tokenId: ETH_TOKEN_ID, holder: DEPLOYER },
          { label: "reverse", tokenId: REVERSE_TOKEN_ID, holder: OWNER },
        ],
      }),
    ).toThrow(/reverse token is held by/);
  });

  it("refuses a batch registrar owned by someone other than the deployer", () => {
    expect(() =>
      planRegistryHandover({
        ...deployed,
        batchRegistrars: [{ contract: "BatchRegistrar", owner: OWNER }],
      }),
    ).toThrow(/BatchRegistrar is owned by/);
  });

  it("refuses to hand the root names from the deployer to itself", () => {
    expect(() =>
      planRegistryHandover({ ...deployed, nameOwner: DEPLOYER }),
    ).toThrow(/no one to hand the root names to/);
  });

  it("hands the owner every root role but the dangerous ones, each with its admin role", () => {
    const registryRoles = Object.values(ROLES.REGISTRY).reduce(
      (all, role) => all | role,
      0n,
    );
    // Granted at registration only, or with no regular role behind it.
    const ungrantable =
      ROLES.REGISTRY.WAS_RESERVED |
      ROLES.ADMIN.REGISTRY.WAS_RESERVED |
      ROLES.REGISTRY.CAN_TRANSFER;
    const grantable = (registryRoles | (registryRoles << 128n)) & ~ungrantable;
    expect(DEPLOYMENT_ROLES.REGISTRY_OWNER_ROOT & DANGEROUS_ROOT_ROLES).toBe(
      0n,
    );
    expect(DEPLOYMENT_ROLES.REGISTRY_OWNER_ROOT | DANGEROUS_ROOT_ROLES).toBe(
      grantable,
    );
  });

  it("plans nothing once handed over", () => {
    expect(planRegistryHandover(handedOver)).toEqual([]);
  });

  it("clears the deployer from an archived root last: its names' roles, then its root roles, then its batch registrar", () => {
    const calls = planRegistryHandover({
      ...deployed,
      archivedRoots: [archivedRoot],
    });
    expect(calls.slice(0, -3)).toEqual(planRegistryHandover(deployed));
    expect(calls.slice(-3)).toEqual([
      {
        contract: "RootRegistry",
        archive: ARCHIVE,
        functionName: "revokeRoles",
        args: [ETH_ID, ARCHIVED_ETH_ROLES, DEPLOYER],
        label: expect.stringContaining(
          `eth entry of the root registry archived in ${ARCHIVE}`,
        ),
      },
      {
        contract: "RootRegistry",
        archive: ARCHIVE,
        functionName: "revokeRootRoles",
        args: [DEPLOYMENT_ROLES.ROOT_REGISTRY_ROOT, DEPLOYER],
        label: expect.stringContaining(ARCHIVE),
      },
      {
        contract: "RootBatchRegistrar",
        archive: ARCHIVE,
        functionName: "renounceOwnership",
        args: [],
        label: expect.stringContaining(ARCHIVE),
      },
    ]);
  });

  it("plans nothing on an archived root the deployer holds nothing on", () => {
    expect(
      planRegistryHandover({
        ...handedOver,
        archivedRoots: [clearedArchivedRoot],
      }),
    ).toEqual([]);
  });

  it("refuses an archived batch registrar owned by someone other than the deployer", () => {
    expect(() =>
      planRegistryHandover({
        ...handedOver,
        archivedRoots: [{ ...clearedArchivedRoot, batchRegistrarOwner: OWNER }],
      }),
    ).toThrow(
      new RegExp(`RootBatchRegistrar archived in ${ARCHIVE} is owned by`),
    );
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
