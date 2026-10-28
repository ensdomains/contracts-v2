import { describe, expect, it } from "bun:test";
import { getAddress, zeroAddress } from "viem";

import { ROLES, STATUS } from "../../script/deploy-constants.js";
import {
  directRegistrationStanding,
  type ResolvedDirectRegistration,
} from "../../script/migrations/directRegistrations.js";
import {
  DIRECT_REGISTRATIONS,
  NETWORKS,
} from "../../script/migrations/plumbing.js";

const OWNER = getAddress("0x00000000000000000000000000000000000000e1");
const RESOLVER = getAddress("0x00000000000000000000000000000000000000f1");
const EXPIRY = 2_088_583_991n;

const entry: ResolvedDirectRegistration = {
  label: "on",
  owner: OWNER,
  resolver: RESOLVER,
  expiry: EXPIRY,
};

const registered = {
  status: STATUS.REGISTERED,
  latestOwner: OWNER,
  resolver: RESOLVER,
  expiry: EXPIRY,
};

describe("DIRECT_REGISTRATIONS", () => {
  it("registers on.eth to the mainnet name owner with its v1 resolver and expiry", () => {
    expect(DIRECT_REGISTRATIONS.mainnet).toEqual([
      {
        label: "on",
        owner: NETWORKS.mainnet.defaultNameOwner!,
        resolver: "v1",
        expiry: "v1",
      },
    ]);
    expect(DIRECT_REGISTRATIONS.sepolia).toBeUndefined();
  });
});

describe("directRegistrationStanding", () => {
  it("accepts a name registered as the table says", () => {
    expect(directRegistrationStanding(entry, registered)).toEqual({
      kind: "registered",
    });
  });

  it("registers an available name through the registrar role", () => {
    expect(
      directRegistrationStanding(entry, {
        status: STATUS.AVAILABLE,
        latestOwner: zeroAddress,
        resolver: zeroAddress,
        expiry: 0n,
      }),
    ).toEqual({ kind: "pending", role: ROLES.REGISTRY.REGISTRAR });
  });

  it("registers a reserved name through the register-reserved role", () => {
    expect(
      directRegistrationStanding(entry, {
        status: STATUS.RESERVED,
        latestOwner: zeroAddress,
        resolver: zeroAddress,
        expiry: EXPIRY + 62n * 86400n,
      }),
    ).toEqual({ kind: "pending", role: ROLES.REGISTRY.REGISTER_RESERVED });
  });

  it("refuses a name registered any other way, naming each difference", () => {
    const standing = directRegistrationStanding(entry, {
      ...registered,
      latestOwner: zeroAddress,
      expiry: EXPIRY + 1n,
    });
    expect(standing.kind).toBe("conflict");
    expect(standing.kind === "conflict" && standing.reason).toBe(
      `on.eth is registered with owner ${zeroAddress}, not ${OWNER}, expiry ${EXPIRY + 1n}, not ${EXPIRY}`,
    );
  });
});
