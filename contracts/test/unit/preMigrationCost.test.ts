import { describe, expect, it } from "bun:test";
import {
  type AbiEvent,
  type Address,
  encodeAbiParameters,
  encodeEventTopics,
  type FeeHistory,
  getAddress,
  type Hex,
  keccak256,
  parseGwei,
  stringToBytes,
} from "viem";

import {
  blockAtOrAfter,
  CONTROLLER_LABEL_EVENTS,
  crossCheckScan,
  fetchBlockGasPrices,
  formatReport,
  measureSample,
  pickEvenly,
  projectCost,
  type RawLog,
  REGISTRAR_EVENTS,
  type RegistrationScan,
  scanRegistrations,
  summariseFees,
  summariseScan,
} from "../../script/preMigrationCost.js";
import {
  DEFAULT_MAX_GAS_PRICE,
  V1_GRACE_PERIOD_SECONDS,
} from "../../script/preMigration.js";

const REGISTRAR = getAddress("0x57f1887a8BF19b14fC0dF6Fd9B2acc9Af147eA85");
const CONTROLLER = getAddress("0x253553366Da8546fC250F225fe3d25d0C782303b");
const GRAVEYARD = getAddress("0x00000000000000000000000000000000000000ae");
const HOLDER = getAddress("0x00000000000000000000000000000000000000b0");

const [NAME_REGISTERED, NAME_RENEWED] = REGISTRAR_EVENTS;

const idOf = (label: string) => BigInt(keccak256(stringToBytes(label)));

// A log of `event` as a node returns it: indexed arguments in the topics, the rest
// ABI-encoded in the data.
function logOf(
  address: Address,
  event: AbiEvent,
  args: Record<string, unknown>,
): RawLog {
  const topics = encodeEventTopics({
    abi: [event],
    args: Object.fromEntries(
      event.inputs
        .filter((input) => input.indexed)
        .map((input) => [input.name, args[input.name as string]]),
    ),
  } as never) as Hex[];
  const unindexed = event.inputs.filter((input) => !input.indexed);
  const data = encodeAbiParameters(
    unindexed,
    unindexed.map((input) => args[input.name as string]),
  );
  return { address, topics, data };
}

const registered = (label: string, expires: bigint, owner = HOLDER) =>
  logOf(REGISTRAR, NAME_REGISTERED, { id: idOf(label), owner, expires });
const renewed = (label: string, expires: bigint) =>
  logOf(REGISTRAR, NAME_RENEWED, { id: idOf(label), expires });

// A controller event of the given shape, carrying `label` beside `labelhash`.
function controllerLog(
  shape: number,
  label: string,
  labelhash: Hex = keccak256(stringToBytes(label)),
): RawLog {
  return logOf(CONTROLLER, CONTROLLER_LABEL_EVENTS[shape] as AbiEvent, {
    label,
    labelhash,
    owner: HOLDER,
    cost: 1n,
    baseCost: 1n,
    premium: 0n,
    expires: 1n,
    referrer: `0x${"00".repeat(32)}`,
  });
}

// A chain whose logs sit at the given blocks, served oldest first like a node.
function chainOf(entries: Array<[bigint, RawLog]>) {
  const requests: Array<[bigint, bigint]> = [];
  return {
    requests,
    read: async (fromBlock: bigint, toBlock: bigint) => {
      requests.push([fromBlock, toBlock]);
      return entries
        .filter(([block]) => block >= fromBlock && block <= toBlock)
        .map(([, log]) => log);
    },
  };
}

const scanOf = (
  read: (fromBlock: bigint, toBlock: bigint) => Promise<RawLog[]>,
  overrides: Partial<Parameters<typeof scanRegistrations>[1]> = {},
) =>
  scanRegistrations(read, {
    registrar: REGISTRAR,
    graveyards: new Set([GRAVEYARD]),
    fromBlock: 1n,
    toBlock: 100n,
    initialSpan: 10n,
    ...overrides,
  });

// How Tenderly refuses a query that matches too many logs: a generic message, with
// the reason only in the error's data.
class TooManyResults extends Error {
  data =
    "Query returned more than 20000 results. Try with this block range [0x1, 0x2].";
  constructor() {
    super("Invalid parameters were provided to the RPC method.");
  }
}

describe("scanRegistrations", () => {
  it("keeps each name's newest expiry", async () => {
    const { read } = chainOf([
      [1n, registered("alice", 100n)],
      [20n, renewed("alice", 200n)],
      [30n, registered("bob", 300n)],
      [90n, registered("alice", 900n)],
    ]);
    const scan = await scanOf(read);
    expect(scan.expiries.get(idOf("alice"))).toBe(900n);
    expect(scan.expiries.get(idOf("bob"))).toBe(300n);
    expect(scan.logs).toBe(4);
  });

  it("marks a name registered to a Graveyard until someone else registers it", async () => {
    const { read } = chainOf([
      [1n, registered("cleared", 100n, GRAVEYARD)],
      [2n, registered("returned", 100n, GRAVEYARD)],
      [3n, registered("returned", 200n)],
      [4n, renewed("cleared", 300n)],
    ]);
    const scan = await scanOf(read);
    expect(scan.graveyardHeld.has(idOf("cleared"))).toBe(true);
    expect(scan.graveyardHeld.has(idOf("returned"))).toBe(false);
  });

  it("reads the label from every controller event shape", async () => {
    const labels = ["zero", "one", "two", "three", "four"];
    const { read } = chainOf(
      labels.map((label, shape) => [
        BigInt(shape + 1),
        controllerLog(shape, label),
      ]),
    );
    const scan = await scanOf(read);
    for (const label of labels) {
      expect(scan.labels.get(idOf(label))).toBe(label);
    }
  });

  it("drops a label that does not hash to the logged labelhash", async () => {
    const { read } = chainOf([
      [1n, controllerLog(1, "forged", keccak256(stringToBytes("real")))],
    ]);
    const scan = await scanOf(read);
    expect(scan.labels.size).toBe(0);
  });

  it("stops on a registrar event it cannot read", async () => {
    const { read } = chainOf([
      [1n, { ...registered("alice", 100n), data: "0x" }],
    ]);
    await expect(scanOf(read)).rejects.toThrow("undecodable registrar log");
  });

  it("ignores the registrar's other events", async () => {
    const transfer: RawLog = {
      address: REGISTRAR,
      topics: [keccak256(stringToBytes("Transfer(address,address,uint256)"))],
      data: "0x",
    };
    const { read } = chainOf([[1n, transfer]]);
    const scan = await scanOf(read);
    expect(scan.expiries.size).toBe(0);
  });

  it("narrows a refused range and widens again, covering each block once", async () => {
    const chain = chainOf([[57n, registered("alice", 100n)]]);
    const read = async (fromBlock: bigint, toBlock: bigint) => {
      if (toBlock - fromBlock + 1n > 8n) throw new TooManyResults();
      return chain.read(fromBlock, toBlock);
    };
    const scan = await scanOf(read, { initialSpan: 32n, maxSpan: 32n });
    expect(scan.expiries.get(idOf("alice"))).toBe(100n);
    // Every block from 1 to 100 exactly once, in order.
    let next = 1n;
    for (const [from, to] of chain.requests) {
      expect(from).toBe(next);
      next = to + 1n;
    }
    expect(next).toBe(101n);
  });

  it("stops on an error that is not about the range", async () => {
    const read = async () => {
      throw new Error("rate limit exceeded");
    };
    await expect(scanOf(read)).rejects.toThrow("rate limit exceeded");
  });
});

describe("summariseScan", () => {
  const now = 1_000_000_000n;
  const scan = (): RegistrationScan => ({
    expiries: new Map([
      [idOf("live"), now + 1n],
      [idOf("in-grace"), now - V1_GRACE_PERIOD_SECONDS + 1n],
      [idOf("past-grace"), now - V1_GRACE_PERIOD_SECONDS],
      [idOf("cleared"), now + 1000n],
      [idOf("unlabelled"), now + 1n],
      [idOf("bracketed"), now + 1n],
    ]),
    graveyardHeld: new Set([idOf("cleared")]),
    labels: new Map([
      [idOf("live"), "live"],
      [idOf("in-grace"), "in-grace"],
      [idOf("bracketed"), `[${"ab".repeat(32)}]`],
    ]),
    logs: 0,
  });

  it("counts the names pre-migration reserves, in labelhash order", () => {
    const summary = summariseScan(scan(), now);
    expect(summary.distinct).toBe(6);
    expect(summary.claimable).toEqual(
      [
        idOf("live"),
        idOf("in-grace"),
        idOf("unlabelled"),
        idOf("bracketed"),
      ].sort((a, b) => (a < b ? -1 : 1)),
    );
    expect(summary.graveyardHeld).toBe(1);
  });

  it("samples only labels pre-migration accepts", () => {
    const summary = summariseScan(scan(), now);
    expect(new Set(summary.labelled)).toEqual(
      new Set([idOf("live"), idOf("in-grace")]),
    );
  });
});

describe("pickEvenly", () => {
  it("spreads the pick over the whole list", () => {
    expect(pickEvenly([0, 1, 2, 3, 4, 5, 6, 7, 8, 9], 5)).toEqual([
      0, 2, 4, 6, 8,
    ]);
    expect(pickEvenly([1, 2], 5)).toEqual([1, 2]);
    expect(pickEvenly([1, 2], 0)).toEqual([]);
  });
});

describe("crossCheckScan", () => {
  const now = 1_000_000_000n;
  const scan: RegistrationScan = {
    expiries: new Map([
      [1n, now + 10n],
      [2n, now + 20n],
      [3n, now - V1_GRACE_PERIOD_SECONDS - 1n],
      [4n, now + 30n],
    ]),
    graveyardHeld: new Set([4n]),
    labels: new Map(),
    logs: 0,
  };
  const graveyards = new Set([GRAVEYARD]);
  // The chain as the scan saw it.
  const chain = (id: bigint) => ({
    expiry: scan.expiries.get(id) as bigint,
    registrant: id === 4n ? GRAVEYARD : HOLDER,
  });

  it("passes when the chain agrees, reading from both sides of the count", async () => {
    const read: bigint[] = [];
    const checked = await crossCheckScan(
      async (ids) => {
        read.push(...ids);
        return ids.map(chain);
      },
      scan,
      { now, graveyards, sample: 4 },
    );
    expect(checked).toBe(4);
    expect(new Set(read)).toEqual(new Set([1n, 2n, 3n, 4n]));
  });

  it("fails when an expiry disagrees", async () => {
    await expect(
      crossCheckScan(
        async (ids) =>
          ids.map((id) => ({
            ...chain(id),
            expiry: id === 2n ? 5n : chain(id).expiry,
          })),
        scan,
        { now, graveyards, sample: 4 },
      ),
    ).rejects.toThrow("disagree with the chain for 1 of 4");
  });

  it("fails when the chain says a Graveyard holds a counted name", async () => {
    await expect(
      crossCheckScan(
        async (ids) =>
          ids.map((id) => ({ ...chain(id), registrant: GRAVEYARD })),
        scan,
        { now, graveyards, sample: 4 },
      ),
    ).rejects.toThrow("disagree with the chain for 2 of 4");
  });

  it("fails when a read fails", async () => {
    await expect(
      crossCheckScan(
        async (ids) => ids.map(() => ({ error: "reverted" })),
        scan,
        { now, graveyards, sample: 2 },
      ),
    ).rejects.toThrow("could not read v1 state");
  });
});

describe("measureSample", () => {
  const names = Array.from({ length: 5 }, (_, i) => ({
    label: `name${i}`,
    expiry: 100n + BigInt(i),
  }));

  it("sends in batches and measures each transaction", async () => {
    const sent: string[][] = [];
    const measurement = await measureSample(names, {
      batchSize: 2,
      submit: async (labels, expires) => {
        sent.push(labels);
        expect(expires).toHaveLength(labels.length);
        return {
          succeeded: labels.map((label) => ({ label, txHash: `0x${label}` })),
          failed: [],
        };
      },
      gasUsed: async (hash) => BigInt(hash.length) * 1000n,
    });
    expect(sent).toEqual([["name0", "name1"], ["name2", "name3"], ["name4"]]);
    expect(measurement.sampled).toBe(5);
    expect(measurement.batches).toHaveLength(5);
    expect(measurement.failed).toEqual([]);
  });

  it("measures each part of a split batch, and keeps the names that failed", async () => {
    const measurement = await measureSample(names.slice(0, 4), {
      batchSize: 4,
      submit: async (labels) => ({
        succeeded: [
          { label: labels[0], txHash: "0xa" },
          { label: labels[1], txHash: "0xa" },
          { label: labels[2], txHash: "0xb" },
        ],
        failed: [{ label: labels[3], error: "reverted" }],
      }),
      gasUsed: async (hash) => (hash === "0xa" ? 200_000n : 90_000n),
    });
    expect(measurement.batches).toEqual([
      { names: 2, gasUsed: 200_000n },
      { names: 1, gasUsed: 90_000n },
    ]);
    expect(measurement.failed).toEqual([{ label: "name3", error: "reverted" }]);
  });
});

describe("fee history", () => {
  // Blocks 0..head, twelve seconds apart, with the price of each block being its
  // number: base fee and tip each half of it.
  function feeChain(head: bigint, maxPage: bigint) {
    return {
      getBlock: async ({ blockNumber }: { blockNumber: bigint }) => ({
        timestamp: blockNumber * 12n,
      }),
      getFeeHistory: async ({
        blockCount,
        blockNumber,
      }: {
        blockCount: number;
        blockNumber: bigint;
      }): Promise<FeeHistory> => {
        expect(blockNumber).toBeLessThanOrEqual(head);
        const count =
          BigInt(blockCount) < maxPage ? BigInt(blockCount) : maxPage;
        const oldest = blockNumber - count + 1n;
        const blocks = Array.from(
          { length: Number(count) },
          (_, i) => oldest + BigInt(i),
        );
        return {
          oldestBlock: oldest,
          baseFeePerGas: [...blocks.map((b) => b), blockNumber + 1n],
          reward: blocks.map((b) => [b]),
          gasUsedRatio: blocks.map(() => 0.5),
        };
      },
    };
  }

  it("finds the first block at or after a time", async () => {
    const chain = feeChain(1000n, 1024n);
    expect(await blockAtOrAfter(chain, 120n, 1000n)).toBe(10n);
    expect(await blockAtOrAfter(chain, 121n, 1000n)).toBe(11n);
  });

  it("reads every block of the window oldest first, across short pages", async () => {
    const head = 20_000n;
    const days = 1;
    const prices = await fetchBlockGasPrices(feeChain(head, 700n), {
      toBlock: head,
      days,
    });
    const first = head - (86_400n / 12n) * BigInt(days);
    expect(prices).toHaveLength(Number(head - first + 1n));
    expect(prices[0]).toBe(first * 2n);
    expect(prices[prices.length - 1]).toBe(head * 2n);
  });

  it("summarises the prices by mean and median", () => {
    expect(summariseFees([1n, 2n, 3n, 10n])).toEqual({
      blocks: 4,
      mean: 4n,
      median: 2n,
    });
    expect(() => summariseFees([])).toThrow();
  });
});

describe("projectCost", () => {
  const fees = { blocks: 10, mean: parseGwei("0.3"), median: parseGwei("0.1") };
  const measurement = {
    sampled: 100,
    batches: [
      { names: 50, gasUsed: 3_000_000n },
      { names: 50, gasUsed: 3_200_000n },
    ],
    failed: [],
  };

  it("scales the sample's gas to every name and prices it", () => {
    const estimate = projectCost({
      names: 1_000_001,
      measurement,
      fees,
      batchSize: 50,
      limit: DEFAULT_MAX_GAS_PRICE,
    });
    expect(estimate.gasPerName).toBe(62_000n);
    expect(estimate.projectedGas).toBe(62_000_062_000n);
    expect(estimate.projectedTxs).toBe(20_001);
    expect(estimate.costAtMean).toBe(62_000_062_000n * parseGwei("0.3"));
    expect(estimate.costAtMedian).toBe(62_000_062_000n * parseGwei("0.1"));
    expect(estimate.costAtLimit).toBe(62_000_062_000n * DEFAULT_MAX_GAS_PRICE);
    // Two transactions at 60,000 and 64,000 per name.
    expect(estimate.gasPerNameMargin).toBe(3920n);
  });

  it("has no margin from a single transaction, and refuses an empty sample", () => {
    const one = projectCost({
      names: 10,
      measurement: { ...measurement, batches: measurement.batches.slice(0, 1) },
      fees,
      batchSize: 50,
      limit: DEFAULT_MAX_GAS_PRICE,
    });
    expect(one.gasPerNameMargin).toBeNull();
    expect(() =>
      projectCost({
        names: 10,
        measurement: { ...measurement, batches: [] },
        fees,
        batchSize: 50,
        limit: DEFAULT_MAX_GAS_PRICE,
      }),
    ).toThrow("no sampled name was reserved");
  });

  it("reports the figures", () => {
    const estimate = projectCost({
      names: 1_000_001,
      measurement,
      fees,
      batchSize: 50,
      limit: DEFAULT_MAX_GAS_PRICE,
    });
    const report = formatReport(estimate, {
      block: 26_000_000n,
      blockTime: 1_790_000_000n,
      distinct: 3_500_000,
      graveyardHeld: 0,
      labelled: 900_000,
      batchSize: 50,
      feeDays: 14,
    });
    expect(report).toContain(
      "| Names to reserve | 1,000,001 claimable of 3,500,000 ever registered |",
    );
    expect(report).toContain("mean 0.3 gwei, median 0.1 gwei over 10 blocks");
    expect(report).toContain(
      "**18.6 ETH** at the mean price (6.2 ETH at the median)",
    );
    expect(report).toContain(
      "above 0.146 gwei, so the run pays at most 9.052 ETH",
    );
  });
});
