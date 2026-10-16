import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { InvalidArgumentError } from "commander";
import {
  type Address,
  ContractFunctionRevertedError,
  ContractFunctionZeroDataError,
  encodeAbiParameters,
  encodeFunctionData,
  getAddress,
  type Hex,
  labelhash,
  namehash,
  zeroAddress,
} from "viem";

import { deploymentGraveyards } from "../../script/migrate.js";
import { Graveyard } from "../../script/migrations/abis.js";
import {
  ethNameNode,
  graveyardSet,
  isClaimableOnV1,
  MAX_UINT64,
  parseGraveyardAddresses,
  readV1Registrations,
  resolveV1Contracts,
  type V1Contracts,
  V1_GRACE_PERIOD_SECONDS,
  v1Eligibility,
} from "../../script/preMigration.js";

const NOW = 1_800_000_000n;
const GRAVEYARD = getAddress("0x950b93885b33ce4c7e8571be2c88a1aa93d82f49");
const SUPERSEDED = getAddress("0xf83fe2658f702a072f3c7b0dc4a0ab8c7b044750");
const HOLDER = getAddress("0x00000000000000000000000000000000000000b0");
const GRAVEYARDS = graveyardSet([GRAVEYARD, SUPERSEDED]);

// What `Graveyard.clear` leaves on v1: the largest duration the registrar accepts,
// which lands the expiry the grace period short of the uint64 ceiling.
const RECLAIM_EXPIRY = MAX_UINT64 - V1_GRACE_PERIOD_SECONDS;

describe("v1Eligibility", () => {
  it("accepts a live name its owner holds", () => {
    expect(
      v1Eligibility({ expiry: NOW + 1n, registrant: HOLDER }, NOW, GRAVEYARDS),
    ).toBe("claimable");
  });

  it("accepts a name in grace, whose registrant v1 no longer reports", () => {
    expect(
      v1Eligibility({ expiry: NOW - 1n, registrant: null }, NOW, GRAVEYARDS),
    ).toBe("claimable");
  });

  it("rejects a name a Graveyard reclaimed, although its expiry reads as live", () => {
    // `--web.eth` on Sepolia: reclaimed by a superseded deployment's Graveyard.
    expect(isClaimableOnV1(RECLAIM_EXPIRY, NOW)).toBe(true);
    expect(
      v1Eligibility(
        { expiry: RECLAIM_EXPIRY, registrant: SUPERSEDED },
        NOW,
        GRAVEYARDS,
      ),
    ).toBe("graveyard");
  });

  it("rejects a name a migration handed to the Graveyard", () => {
    expect(
      v1Eligibility(
        { expiry: NOW + 86_400n, registrant: GRAVEYARD },
        NOW,
        GRAVEYARDS,
      ),
    ).toBe("graveyard");
  });

  it("matches a registrant however its address is cased", () => {
    const lower = GRAVEYARD.toLowerCase() as Address;
    expect(
      v1Eligibility({ expiry: NOW + 1n, registrant: lower }, NOW, GRAVEYARDS),
    ).toBe("graveyard");
  });

  it("reports the expiry reasons before the registrant", () => {
    expect(
      v1Eligibility({ expiry: 0n, registrant: null }, NOW, GRAVEYARDS),
    ).toBe("never-registered");
    expect(
      v1Eligibility(
        { expiry: NOW - V1_GRACE_PERIOD_SECONDS, registrant: GRAVEYARD },
        NOW,
        GRAVEYARDS,
      ),
    ).toBe("past-grace");
  });
});

describe("graveyardSet", () => {
  it("checksums, trims and deduplicates", () => {
    const set = graveyardSet([
      ` ${GRAVEYARD.toLowerCase()} `,
      GRAVEYARD,
      "",
      SUPERSEDED,
    ]);
    expect([...set]).toEqual([GRAVEYARD, SUPERSEDED]);
  });

  it("refuses an empty set rather than filtering nothing", () => {
    expect(() => graveyardSet([])).toThrow(/no Graveyard address given/);
    expect(() => graveyardSet(["", " "])).toThrow(/no Graveyard address given/);
  });

  it("refuses a value that is not an address", () => {
    expect(() => graveyardSet(["0x1234"])).toThrow(/not an address/);
  });
});

describe("parseGraveyardAddresses", () => {
  it("reads a comma-separated list", () => {
    expect(parseGraveyardAddresses(`${GRAVEYARD},${SUPERSEDED}`)).toEqual([
      GRAVEYARD,
      SUPERSEDED,
    ]);
  });

  it("reports a bad value as a command-line argument error", () => {
    expect(() => parseGraveyardAddresses("nope")).toThrow(InvalidArgumentError);
    expect(() => parseGraveyardAddresses(",")).toThrow(InvalidArgumentError);
  });
});

type Outcome =
  | { status: "success"; result: unknown }
  | { status: "failure"; error: unknown };

const REVERT = new ContractFunctionRevertedError({
  abi: [],
  functionName: "ownerOf",
});

const BASE_REGISTRAR = getAddress("0x57f1887a8bf19b14fc0df6fd9b2acc9af147ea85");
const REGISTRY = getAddress("0x00000000000c2e074ec69a0dfb2997ba6c7d2e1e");
const WRAPPER = getAddress("0xd4416b13d2b3a9abae7acd5d6c2bbdbe25686401");
const V1: V1Contracts = {
  baseRegistrar: BASE_REGISTRAR,
  registry: REGISTRY,
  nameWrapper: WRAPPER,
};

const ok = (result: unknown): Outcome => ({ status: "success", result });
const failed = (error: unknown): Outcome => ({ status: "failure", error });

// The four reads a name takes, in the order the reader asks for them. Unset owners
// read as the zero address, which is what the registry and the wrapper answer for a
// node nobody holds.
function reads({
  expiry = ok(NOW + 86_400n),
  ownerOf = ok(HOLDER),
  nodeOwner = ok(zeroAddress),
  wrapperOwner = ok(zeroAddress),
}: {
  expiry?: Outcome;
  ownerOf?: Outcome;
  nodeOwner?: Outcome;
  wrapperOwner?: Outcome;
} = {}): Outcome[] {
  return [expiry, ownerOf, nodeOwner, wrapperOwner];
}

type Call = { address: Address; functionName: string; args: unknown[] };

// Stands in for a viem client: answers a multicall with the scripted outcomes, and
// records the calls so a test can check what was asked.
function multicallClient(outcomes: Outcome[]) {
  const calls: Call[][] = [];
  return {
    calls,
    async multicall(request: { allowFailure: boolean; contracts: Call[] }) {
      expect(request.allowFailure).toBe(true);
      calls.push(request.contracts);
      return outcomes.slice(0, request.contracts.length);
    },
  };
}

async function registrantOf(outcomes: Outcome[]) {
  const [registration] = await readV1Registrations(
    multicallClient(outcomes),
    V1,
    [BigInt(labelhash("alpha"))],
  );
  return registration;
}

describe("ethNameNode", () => {
  it("is the namehash of the .eth name, from the labelhash alone", () => {
    expect(ethNameNode(BigInt(labelhash("alpha")))).toBe(namehash("alpha.eth"));
  });
});

describe("readV1Registrations", () => {
  it("reads the expiry and the three owners in one multicall", async () => {
    const client = multicallClient(reads());
    const id = BigInt(labelhash("alpha"));
    const [registration] = await readV1Registrations(client, V1, [id]);

    expect(registration).toEqual({ expiry: NOW + 86_400n, registrant: HOLDER });
    expect(client.calls).toHaveLength(1);
    const node = namehash("alpha.eth");
    expect(
      client.calls[0].map(({ address, functionName, args }) => [
        address,
        functionName,
        args[0],
      ]),
    ).toEqual([
      [BASE_REGISTRAR, "nameExpires", id],
      [BASE_REGISTRAR, "ownerOf", id],
      [REGISTRY, "owner", node],
      [WRAPPER, "ownerOf", BigInt(node)],
    ]);
  });

  it("keeps a live token holder over the registry's node owner", async () => {
    // The holder can reclaim the node whenever they like, so the node owner is
    // not what decides who holds the name.
    expect(
      await registrantOf(
        reads({ ownerOf: ok(HOLDER), nodeOwner: ok(GRAVEYARD) }),
      ),
    ).toEqual({ expiry: NOW + 86_400n, registrant: HOLDER });
  });

  it("falls back to the registry's node owner once ownerOf reverts", async () => {
    // A migrated unwrapped name in v1 grace: the token has expired, but the migration
    // pointed the node at the Graveyard.
    expect(
      await registrantOf(
        reads({
          expiry: ok(NOW - 1n),
          ownerOf: failed(REVERT),
          nodeOwner: ok(GRAVEYARD),
        }),
      ),
    ).toEqual({ expiry: NOW - 1n, registrant: GRAVEYARD });
  });

  it("follows a wrapped name to the owner the NameWrapper names", async () => {
    // A locked migration hands the wrapper token to the Graveyard, while the
    // registrar token stays with the wrapper.
    expect(
      await registrantOf(
        reads({ ownerOf: ok(WRAPPER), wrapperOwner: ok(GRAVEYARD) }),
      ),
    ).toEqual({ expiry: NOW + 86_400n, registrant: GRAVEYARD });
  });

  it("follows the wrapper from the registry's node owner in grace too", async () => {
    expect(
      await registrantOf(
        reads({
          expiry: ok(NOW - 1n),
          ownerOf: failed(REVERT),
          nodeOwner: ok(WRAPPER),
          wrapperOwner: ok(GRAVEYARD),
        }),
      ),
    ).toEqual({ expiry: NOW - 1n, registrant: GRAVEYARD });
  });

  it("reads nobody holding the name as no registrant", async () => {
    expect(
      await registrantOf(reads({ expiry: ok(0n), ownerOf: failed(REVERT) })),
    ).toEqual({ expiry: 0n, registrant: null });
    expect(await registrantOf(reads({ ownerOf: ok(WRAPPER) }))).toEqual({
      expiry: NOW + 86_400n,
      registrant: null,
    });
  });

  it("reports a failed read that the registrant depends on", async () => {
    // A registrar address with no code answers nothing, which says nothing about
    // who holds the name.
    const noData = new ContractFunctionZeroDataError({
      functionName: "ownerOf",
    });
    const errorOf = async (outcomes: Outcome[]) =>
      ((await registrantOf(outcomes)) as { error: string }).error;

    expect(
      await errorOf(reads({ expiry: failed(new Error("limit")) })),
    ).toContain("nameExpires");
    expect(await errorOf(reads({ ownerOf: failed(noData) }))).toContain(
      "ownerOf",
    );
    expect(
      await errorOf(
        reads({ ownerOf: failed(REVERT), nodeOwner: failed(noData) }),
      ),
    ).toContain("registry owner");
    expect(
      await errorOf(
        reads({ ownerOf: ok(WRAPPER), wrapperOwner: failed(noData) }),
      ),
    ).toContain("NameWrapper ownerOf");
  });

  it("ignores a failed read that the registrant does not depend on", async () => {
    const noData = new ContractFunctionZeroDataError({ functionName: "owner" });
    expect(
      await registrantOf(
        reads({ nodeOwner: failed(noData), wrapperOwner: failed(noData) }),
      ),
    ).toEqual({ expiry: NOW + 86_400n, registrant: HOLDER });
  });

  it("asks nothing for no names", async () => {
    const client = multicallClient([]);
    expect(await readV1Registrations(client, V1, [])).toEqual([]);
    expect(client.calls).toHaveLength(0);
  });
});

describe("resolveV1Contracts", () => {
  const CONTROLLER = getAddress("0x00000000000000000000000000000000000000c0");
  const OTHER_WRAPPER = getAddress(
    "0x00000000000000000000000000000000000000d0",
  );

  // A v1 chain with the Graveyards, a migration controller that shares their
  // `NAME_WRAPPER()` getter but has no `clear`, and the wrappers they point at.
  function chainClient({
    wrapperOf = new Map<Address, Address>([
      [GRAVEYARD, WRAPPER],
      [SUPERSEDED, WRAPPER],
      [CONTROLLER, WRAPPER],
    ]),
    clears = new Set<Address>([GRAVEYARD, SUPERSEDED]),
    registrarOf = new Map<Address, Address>([
      [WRAPPER, BASE_REGISTRAR],
      [OTHER_WRAPPER, HOLDER],
    ]),
  } = {}) {
    return {
      async readContract({
        address,
        functionName,
      }: {
        address: Address;
        functionName: string;
      }) {
        if (functionName === "NAME_WRAPPER" && wrapperOf.has(address)) {
          return wrapperOf.get(address);
        }
        if (functionName === "registrar" && registrarOf.has(address)) {
          return registrarOf.get(address);
        }
        if (functionName === "ens") return REGISTRY;
        throw new Error("returned no data");
      },
      async call({ to, data }: { to: Address; data: Hex }) {
        expect(data).toBe(
          encodeFunctionData({
            abi: Graveyard.clear,
            functionName: "clear",
            args: [[]],
          }),
        );
        if (!clears.has(to)) throw new Error("execution reverted");
        return { data: "0x" };
      },
    };
  }

  it("returns the v1 contracts the Graveyards are bound to", async () => {
    expect(
      await resolveV1Contracts(chainClient(), GRAVEYARDS, BASE_REGISTRAR),
    ).toEqual(V1);
  });

  it("refuses a migration controller, which answers NAME_WRAPPER() but has no clear", async () => {
    await expect(
      resolveV1Contracts(
        chainClient(),
        graveyardSet([GRAVEYARD, CONTROLLER]),
        BASE_REGISTRAR,
      ),
    ).rejects.toThrow(
      new RegExp(`not a Graveyard on the v1 chain: ${CONTROLLER}`),
    );
  });

  it("refuses an account that answers neither", async () => {
    await expect(
      resolveV1Contracts(
        chainClient(),
        graveyardSet([GRAVEYARD, HOLDER]),
        BASE_REGISTRAR,
      ),
    ).rejects.toThrow(new RegExp(`not a Graveyard on the v1 chain: ${HOLDER}`));
  });

  it("refuses Graveyards bound to different NameWrappers", async () => {
    const client = chainClient({
      wrapperOf: new Map([
        [GRAVEYARD, WRAPPER],
        [SUPERSEDED, OTHER_WRAPPER],
      ]),
    });
    await expect(
      resolveV1Contracts(client, GRAVEYARDS, BASE_REGISTRAR),
    ).rejects.toThrow(/report different NameWrappers/);
  });

  it("refuses Graveyards whose NameWrapper serves another BaseRegistrar", async () => {
    const client = chainClient({
      wrapperOf: new Map([
        [GRAVEYARD, OTHER_WRAPPER],
        [SUPERSEDED, OTHER_WRAPPER],
      ]),
    });
    await expect(
      resolveV1Contracts(client, GRAVEYARDS, BASE_REGISTRAR),
    ).rejects.toThrow(/belong to another v1/);
  });
});

describe("deploymentGraveyards", () => {
  let deploymentsDir: string;

  beforeEach(() => {
    deploymentsDir = mkdtempSync(join(tmpdir(), "graveyards-"));
  });

  afterEach(() => {
    rmSync(deploymentsDir, { recursive: true, force: true });
  });

  // The constructor as the Graveyard artifact records it, whose first argument is
  // the NameWrapper the Graveyard serves.
  const GRAVEYARD_CONSTRUCTOR = {
    type: "constructor",
    inputs: [
      { name: "nameWrapper", type: "address" },
      { name: "contractNamer", type: "address" },
    ],
  } as const;

  function writeGraveyard(
    namespace: string,
    address: string,
    {
      chainId = 1,
      nameWrapper,
    }: { chainId?: number; nameWrapper?: Address } = {},
  ) {
    const dir = join(deploymentsDir, namespace);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, ".chain"), JSON.stringify({ chainId }));
    writeFileSync(
      join(dir, "Graveyard.json"),
      JSON.stringify(
        nameWrapper
          ? {
              address,
              abi: [GRAVEYARD_CONSTRUCTOR],
              argsData: encodeAbiParameters(GRAVEYARD_CONSTRUCTOR.inputs, [
                nameWrapper,
                HOLDER,
              ]),
            }
          : { address, abi: [] },
      ),
    );
  }

  it("takes the active Graveyard and every superseded one on this chain", () => {
    writeGraveyard("mainnet", GRAVEYARD);
    // A dated archive a fresh deploy renamed aside keeps the names it took.
    writeGraveyard("mainnet-20260101-r1", SUPERSEDED);
    // Another chain's set, and another network's, hold nothing on this one.
    writeGraveyard(
      "mainnet-elsewhere",
      "0x00000000000000000000000000000000000000a3",
      { chainId: 5 },
    );
    writeGraveyard("sepolia", "0x00000000000000000000000000000000000000a4");

    expect(
      deploymentGraveyards({ network: "mainnet", deploymentsDir }),
    ).toEqual([GRAVEYARD, SUPERSEDED]);
  });

  it("scans the archives named after a custom active namespace", () => {
    writeGraveyard("staging", GRAVEYARD);
    writeGraveyard("staging-20260101-r1", SUPERSEDED);

    expect(
      deploymentGraveyards({
        network: "mainnet",
        deploymentsDir,
        deploymentNetwork: "staging",
      }),
    ).toEqual([GRAVEYARD, SUPERSEDED]);
  });

  it("leaves out a superseded Graveyard deployed against another NameWrapper", () => {
    // A clean-testnet run deploys its own v1 beside the network's real one; its
    // Graveyard holds none of the real v1's names.
    writeGraveyard("mainnet", GRAVEYARD, { nameWrapper: WRAPPER });
    writeGraveyard("mainnet-20260101-r1", SUPERSEDED, { nameWrapper: WRAPPER });
    writeGraveyard(
      "mainnet-clean-abc",
      "0x00000000000000000000000000000000000000a5",
      { nameWrapper: HOLDER },
    );
    // Without recorded arguments the binding is unknown, so the on-chain check
    // decides.
    writeGraveyard(
      "mainnet-20250101-r1",
      "0x00000000000000000000000000000000000000a6",
    );

    expect(
      deploymentGraveyards({ network: "mainnet", deploymentsDir }),
    ).toEqual([
      GRAVEYARD,
      getAddress("0x00000000000000000000000000000000000000a6"),
      SUPERSEDED,
    ]);
  });

  it("refuses when the active namespace records no Graveyard", () => {
    // A superseded set alone cannot be shown complete: the live Graveyard is the one
    // taking names now.
    writeGraveyard("mainnet-20260101-r1", SUPERSEDED);
    mkdirSync(join(deploymentsDir, "mainnet"), { recursive: true });

    expect(() =>
      deploymentGraveyards({ network: "mainnet", deploymentsDir }),
    ).toThrow(/no Graveyard artifact/);
  });
});
