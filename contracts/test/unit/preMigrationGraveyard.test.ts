import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { InvalidArgumentError } from "commander";
import {
  type Address,
  ContractFunctionRevertedError,
  ContractFunctionZeroDataError,
  getAddress,
} from "viem";

import { deploymentGraveyards } from "../../script/migrate.js";
import {
  assertGraveyards,
  graveyardSet,
  isClaimableOnV1,
  MAX_UINT64,
  parseGraveyardAddresses,
  readV1Registrants,
  readV1Registrations,
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

// Stands in for a viem client: answers each multicall with the next scripted
// outcomes, and records the calls so a test can check what was asked.
function multicallClient(outcomes: Outcome[]) {
  const calls: Array<{ functionName: string; args: unknown[] }[]> = [];
  return {
    calls,
    async multicall(request: {
      allowFailure: boolean;
      contracts: { functionName: string; args: unknown[] }[];
    }) {
      expect(request.allowFailure).toBe(true);
      calls.push(request.contracts);
      return outcomes.slice(0, request.contracts.length);
    },
  };
}

const BASE_REGISTRAR = getAddress("0x57f1887a8bf19b14fc0df6fd9b2acc9af147ea85");

describe("readV1Registrations", () => {
  it("reads each name's expiry and registrant in one multicall", async () => {
    const client = multicallClient([
      { status: "success", result: NOW },
      { status: "success", result: HOLDER.toLowerCase() },
    ]);
    const [registration] = await readV1Registrations(client, BASE_REGISTRAR, [
      7n,
    ]);
    expect(registration).toEqual({ expiry: NOW, registrant: HOLDER });
    expect(client.calls).toHaveLength(1);
    expect(client.calls[0].map((call) => call.functionName)).toEqual([
      "nameExpires",
      "ownerOf",
    ]);
  });

  it("reads a reverting ownerOf as no live registrant", async () => {
    const client = multicallClient([
      { status: "success", result: NOW - 1n },
      { status: "failure", error: REVERT },
    ]);
    const [registration] = await readV1Registrations(client, BASE_REGISTRAR, [
      7n,
    ]);
    expect(registration).toEqual({ expiry: NOW - 1n, registrant: null });
  });

  it("reports an ownerOf failure that is not a revert", async () => {
    // A registrar address with no code answers nothing, which says nothing about
    // who holds the name.
    const client = multicallClient([
      { status: "success", result: NOW },
      {
        status: "failure",
        error: new ContractFunctionZeroDataError({ functionName: "ownerOf" }),
      },
    ]);
    const [registration] = await readV1Registrations(client, BASE_REGISTRAR, [
      7n,
    ]);
    expect(registration).toHaveProperty("error");
    expect((registration as { error: string }).error).toContain("ownerOf");
  });

  it("reports a failed expiry read", async () => {
    const client = multicallClient([
      { status: "failure", error: new Error("rate limited") },
      { status: "success", result: HOLDER },
    ]);
    const [registration] = await readV1Registrations(client, BASE_REGISTRAR, [
      7n,
    ]);
    expect((registration as { error: string }).error).toContain("nameExpires");
  });

  it("asks nothing for no names", async () => {
    const client = multicallClient([]);
    expect(await readV1Registrations(client, BASE_REGISTRAR, [])).toEqual([]);
    expect(client.calls).toHaveLength(0);
  });
});

describe("readV1Registrants", () => {
  it("reads only ownerOf, with the same reading of a revert", async () => {
    const client = multicallClient([
      { status: "success", result: GRAVEYARD },
      { status: "failure", error: REVERT },
      { status: "failure", error: new Error("timeout") },
    ]);
    const registrants = await readV1Registrants(client, BASE_REGISTRAR, [
      1n,
      2n,
      3n,
    ]);
    expect(registrants[0]).toEqual({ registrant: GRAVEYARD });
    expect(registrants[1]).toEqual({ registrant: null });
    expect(registrants[2]).toHaveProperty("error");
    expect(client.calls[0].map((call) => call.functionName)).toEqual([
      "ownerOf",
      "ownerOf",
      "ownerOf",
    ]);
  });
});

describe("assertGraveyards", () => {
  function probeClient(graveyards: ReadonlySet<Address>) {
    return {
      async readContract({ address }: { address: Address }) {
        if (graveyards.has(address)) return HOLDER;
        throw new Error("returned no data");
      },
    };
  }

  it("accepts a set whose every address answers as a Graveyard", async () => {
    await assertGraveyards(probeClient(GRAVEYARDS), GRAVEYARDS);
  });

  it("names each address that does not", async () => {
    const set = graveyardSet([GRAVEYARD, HOLDER]);
    await expect(
      assertGraveyards(probeClient(graveyardSet([GRAVEYARD])), set),
    ).rejects.toThrow(new RegExp(`not a Graveyard on the v1 chain: ${HOLDER}`));
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

  function writeGraveyard(namespace: string, address: string, chainId = 1) {
    const dir = join(deploymentsDir, namespace);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, ".chain"), JSON.stringify({ chainId }));
    writeFileSync(join(dir, "Graveyard.json"), JSON.stringify({ address }));
  }

  it("takes the active Graveyard and every superseded one on this chain", () => {
    writeGraveyard("mainnet", GRAVEYARD);
    // A dated archive a fresh deploy renamed aside keeps the names it took.
    writeGraveyard("mainnet-20260101-r1", SUPERSEDED);
    // Another chain's set, and another network's, hold nothing on this one.
    writeGraveyard(
      "mainnet-elsewhere",
      "0x00000000000000000000000000000000000000a3",
      5,
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
