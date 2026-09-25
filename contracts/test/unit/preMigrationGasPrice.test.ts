import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { InvalidArgumentError } from "commander";
import {
  BaseError,
  FeeCapTooLowError,
  type FeeHistory,
  type Hex,
  parseGwei,
  TransactionNotFoundError,
  TransactionReceiptNotFoundError,
  WaitForTransactionReceiptTimeoutError,
  zeroAddress,
} from "viem";
import { mainnet, sepolia } from "viem/chains";

import {
  type BatchSender,
  blockGasPrices,
  DEFAULT_MAX_GAS_PRICE,
  parseMaxGasPrice,
  readGasPrice,
  resolveMaxGasPrice,
  submitBatchWithBinaryFallback,
  waitForGasPriceAtOrBelow,
  waitForInclusion,
} from "../../script/preMigration.js";
import { whileMiningBlocks } from "../../script/migrations/rpc.js";

// A fee history over blocks with these base fees and median tips. Like a node's, its
// base fees run one entry past the last block, to the next block's.
function feeHistory(
  baseFees: bigint[],
  tips: bigint[],
  nextBaseFee = 0n,
): FeeHistory {
  return {
    oldestBlock: 1n,
    baseFeePerGas: [...baseFees, nextBaseFee],
    gasUsedRatio: baseFees.map(() => 0.5),
    reward: tips.map((tip) => [tip]),
  };
}

const LIMIT = parseGwei("1");
const ABOVE = parseGwei("3");
const TIP = parseGwei("0.01");

// Gas price reads that return each outcome in turn: a price every recent block paid,
// tip included, or an error. Once the outcomes run out, every read is at the limit.
function gasPriceReads(outcomes: Array<bigint | Error> = []) {
  const reads = {
    count: 0,
    async getFeeHistory(): Promise<FeeHistory> {
      const outcome = outcomes[reads.count++] ?? LIMIT;
      if (outcome instanceof Error) throw outcome;
      const blocks = Array.from({ length: 5 }, () => outcome - TIP);
      return feeHistory(
        blocks,
        blocks.map(() => TIP),
      );
    },
  };
  return reads;
}

// The wait logs to files in the working directory, so it runs somewhere disposable.
let workDir: string;
let previousCwd: string;

beforeAll(() => {
  previousCwd = process.cwd();
  workDir = mkdtempSync(join(tmpdir(), "premigration-gas-price-"));
  process.chdir(workDir);
});

afterAll(() => {
  process.chdir(previousCwd);
  rmSync(workDir, { recursive: true, force: true });
});

describe("parseMaxGasPrice", () => {
  it("reads a limit in gwei", () => {
    expect(parseMaxGasPrice("0.146")).toBe(146_000_000n);
    expect(parseMaxGasPrice("2")).toBe(2_000_000_000n);
  });

  it("refuses a limit no block could meet, or that is not a number", () => {
    for (const value of ["0", "-1", "", "0.0000000001", "abc", "1e3"]) {
      expect(() => parseMaxGasPrice(value)).toThrow(InvalidArgumentError);
    }
  });
});

describe("resolveMaxGasPrice", () => {
  const explicit = parseGwei("0.5");

  it("applies a limit that was set on any chain", () => {
    expect(resolveMaxGasPrice(explicit, mainnet.id)).toBe(explicit);
    expect(resolveMaxGasPrice(explicit, sepolia.id)).toBe(explicit);
  });

  it("defaults to the mainnet median on mainnet only", () => {
    expect(resolveMaxGasPrice(undefined, mainnet.id)).toBe(
      DEFAULT_MAX_GAS_PRICE,
    );
    expect(resolveMaxGasPrice(undefined, sepolia.id)).toBeNull();
  });
});

describe("blockGasPrices", () => {
  it("adds each block's tip to its base fee and leaves out the next block's base fee", () => {
    expect(blockGasPrices(feeHistory([10n, 20n], [1n, 2n], 30n))).toEqual([
      11n,
      22n,
    ]);
  });
});

describe("readGasPrice", () => {
  it("takes the median tip, so one unusual block does not decide it", async () => {
    const client = {
      requests: [] as unknown[],
      async getFeeHistory(request: unknown) {
        client.requests.push(request);
        return feeHistory([1n, 2n, 3n, 4n, 7n], [1n, 500n, 2n, 1n, 1n], 6n);
      },
    };
    expect(await readGasPrice(client)).toEqual({ price: 8n, tip: 1n });
    expect(client.requests).toEqual([
      { blockCount: 5, blockTag: "latest", rewardPercentiles: [50] },
    ]);
  });

  it("uses the next block's base fee when it is the higher", async () => {
    const client = {
      async getFeeHistory() {
        return feeHistory([1n, 2n, 3n, 4n, 7n], [1n, 1n, 1n, 1n, 1n], 9n);
      },
    };
    expect(await readGasPrice(client)).toEqual({ price: 10n, tip: 1n });
  });

  it("refuses a fee history without rewards", async () => {
    const client = {
      async getFeeHistory() {
        return { ...feeHistory([1n], [1n]), reward: undefined };
      },
    };
    await expect(readGasPrice(client)).rejects.toThrow("no block rewards");
  });
});

describe("waitForGasPriceAtOrBelow", () => {
  const capped = { maxFeePerGas: LIMIT, maxPriorityFeePerGas: TIP };

  it("reads nothing and leaves the fees to viem when there is no limit", async () => {
    const client = gasPriceReads();
    expect(await waitForGasPriceAtOrBelow(client, null, 0)).toEqual({});
    expect(client.count).toBe(0);
  });

  it("caps the fee at the limit and pays the market tip", async () => {
    const client = gasPriceReads([LIMIT]);
    expect(await waitForGasPriceAtOrBelow(client, LIMIT, 0)).toEqual(capped);
    expect(client.count).toBe(1);
  });

  it("waits while the price is above the limit", async () => {
    const client = gasPriceReads([ABOVE, ABOVE, LIMIT - 1n]);
    expect(await waitForGasPriceAtOrBelow(client, LIMIT, 0)).toEqual(capped);
    expect(client.count).toBe(3);
  });

  it("keeps waiting through any number of failed reads", async () => {
    const failures = Array.from({ length: 12 }, () => new Error("timeout"));
    const client = gasPriceReads([...failures, ABOVE, LIMIT]);
    expect(await waitForGasPriceAtOrBelow(client, LIMIT, 0)).toEqual(capped);
    expect(client.count).toBe(14);
  });
});

describe("waitForInclusion", () => {
  const EARLIER = "0x01" as Hex;
  const LATEST = "0x02" as Hex;
  const timedOut = () =>
    new WaitForTransactionReceiptTimeoutError({ hash: LATEST });

  // A node on which each wait for the latest send plays out the next outcome in turn.
  // `held` is whether it still holds the latest send, and `mined` lists the sends it
  // has a receipt for.
  function node(
    outcomes: Array<"mined" | Error>,
    { held = true, mined = [] as Hex[] } = {},
  ) {
    const client = {
      waits: [] as unknown[],
      async waitForTransactionReceipt(request: { hash: Hex }) {
        client.waits.push(request);
        const outcome = outcomes[client.waits.length - 1];
        if (outcome instanceof Error) throw outcome;
        return { status: "success", transactionHash: request.hash };
      },
      async getTransactionReceipt({ hash }: { hash: Hex }) {
        if (!mined.includes(hash)) {
          throw new TransactionReceiptNotFoundError({ hash });
        }
        return { status: "success", transactionHash: hash };
      },
      async getTransaction({ hash }: { hash: Hex }) {
        if (!held) throw new TransactionNotFoundError({ hash });
        return { hash };
      },
    };
    return client;
  }

  it("returns the receipt of a mined transaction", async () => {
    const receipt = await waitForInclusion(node(["mined"]), [LATEST], 0);
    expect(receipt?.transactionHash).toBe(LATEST);
  });

  it("waits with no time limit and no replacement check of viem's own", async () => {
    const client = node(["mined"]);
    await waitForInclusion(client, [LATEST], 0);
    expect(client.waits).toEqual([
      { hash: LATEST, checkReplacement: false, timeout: 5 * 60_000 },
    ]);
  });

  it("keeps waiting while the node still holds the latest send", async () => {
    const client = node([timedOut(), timedOut(), "mined"]);
    const receipt = await waitForInclusion(client, [LATEST], 0);
    expect(receipt?.transactionHash).toBe(LATEST);
    expect(client.waits).toHaveLength(3);
  });

  it("returns nothing when the latest send was dropped", async () => {
    const client = node([timedOut()], { held: false });
    expect(await waitForInclusion(client, [EARLIER, LATEST], 0)).toBeNull();
  });

  it("returns an earlier send of the batch that was mined instead", async () => {
    const client = node([timedOut()], { held: false, mined: [EARLIER] });
    const receipt = await waitForInclusion(client, [EARLIER, LATEST], 0);
    expect(receipt?.transactionHash).toBe(EARLIER);
  });

  it("keeps trying through any number of failed reads", async () => {
    const failures = Array.from({ length: 12 }, () => new Error("rpc down"));
    const client = node([...failures, "mined"]);
    const receipt = await waitForInclusion(client, [LATEST], 0);
    expect(receipt?.transactionHash).toBe(LATEST);
    expect(client.waits).toHaveLength(13);
  });
});

describe("submitBatchWithBinaryFallback", () => {
  // A sender whose send attempts play out each outcome in turn (none means the send
  // goes through), whose first `drops` transactions are dropped from the node's pool,
  // and whose other transactions are mined with the status `statusOf` gives them.
  // Every gas price read is at the limit.
  function fakeSender(
    maxGasPrice: bigint | null,
    {
      sendOutcomes = [] as Array<Error | undefined>,
      drops = 0,
      statusOf = (_labels: string[]): "success" | "reverted" => "success",
    } = {},
  ) {
    const sent: Array<{ labels: string[]; fees: unknown }> = [];
    const statuses = new Map<Hex, "success" | "reverted">();
    const dropped = new Set<Hex>();
    let attempts = 0;
    const client = {
      ...gasPriceReads(),
      async waitForTransactionReceipt({ hash }: { hash: Hex }) {
        if (dropped.has(hash)) {
          throw new WaitForTransactionReceiptTimeoutError({ hash });
        }
        return { status: statuses.get(hash), transactionHash: hash };
      },
      async getTransactionReceipt({ hash }: { hash: Hex }) {
        if (dropped.has(hash))
          throw new TransactionReceiptNotFoundError({ hash });
        return { status: statuses.get(hash), transactionHash: hash };
      },
      async getTransaction({ hash }: { hash: Hex }) {
        if (dropped.has(hash)) throw new TransactionNotFoundError({ hash });
        return { hash };
      },
    };
    const batchRegistrar = {
      write: {
        async batchRegister(args: unknown[], fees: unknown) {
          const outcome = sendOutcomes[attempts++];
          if (outcome) throw outcome;
          const labels = args[2] as string[];
          const hash = `0x${sent.length + 1}` as Hex;
          if (sent.length < drops) dropped.add(hash);
          sent.push({ labels, fees });
          statuses.set(hash, statusOf(labels));
          return hash;
        },
      },
    };
    const sender: BatchSender = {
      batchRegistrar,
      client,
      resolver: zeroAddress,
      maxGas: 0n,
      maxGasPrice,
    };
    return { sender, sent };
  }

  it("caps each send's fee at the limit", async () => {
    const { sender, sent } = fakeSender(LIMIT);
    const result = await submitBatchWithBinaryFallback(
      sender,
      ["a", "b"],
      [1n, 2n],
    );
    expect(sent).toEqual([
      {
        labels: ["a", "b"],
        fees: { maxFeePerGas: LIMIT, maxPriorityFeePerGas: TIP },
      },
    ]);
    expect(result.succeeded.map(({ label }) => label)).toEqual(["a", "b"]);
  });

  it("leaves the fees to viem when there is no limit", async () => {
    const { sender, sent } = fakeSender(null);
    await submitBatchWithBinaryFallback(sender, ["a"], [1n]);
    expect(sent[0].fees).toEqual({});
  });

  it("waits and sends the same batch again when the base fee rose past the cap", async () => {
    const feeCapTooLow = new BaseError("send failed", {
      cause: new FeeCapTooLowError(),
    });
    const { sender, sent } = fakeSender(LIMIT, {
      sendOutcomes: [feeCapTooLow],
    });
    const result = await submitBatchWithBinaryFallback(
      sender,
      ["a", "b"],
      [1n, 2n],
    );
    expect(sent.map(({ labels }) => labels)).toEqual([["a", "b"]]);
    expect(result.failed).toEqual([]);
  });

  it("splits a batch whose transaction reverted", async () => {
    const { sender, sent } = fakeSender(LIMIT, {
      statusOf: (labels) => (labels.length > 1 ? "reverted" : "success"),
    });
    const result = await submitBatchWithBinaryFallback(
      sender,
      ["a", "b"],
      [1n, 2n],
    );
    expect(sent.map(({ labels }) => labels)).toEqual([
      ["a", "b"],
      ["a"],
      ["b"],
    ]);
    expect(result.succeeded.map(({ label }) => label)).toEqual(["a", "b"]);
  });

  it("sends the whole batch again when its transaction was dropped", async () => {
    const { sender, sent } = fakeSender(LIMIT, { drops: 1 });
    const result = await submitBatchWithBinaryFallback(
      sender,
      ["a", "b"],
      [1n, 2n],
    );
    expect(sent.map(({ labels }) => labels)).toEqual([
      ["a", "b"],
      ["a", "b"],
    ]);
    expect(result.succeeded).toEqual([
      { label: "a", txHash: "0x2" },
      { label: "b", txHash: "0x2" },
    ]);
  });

  it("goes back to waiting, without splitting, when sending again is refused", async () => {
    const { sender, sent } = fakeSender(LIMIT, {
      sendOutcomes: [
        undefined,
        new Error("replacement transaction underpriced"),
      ],
      drops: 1,
    });
    const result = await submitBatchWithBinaryFallback(
      sender,
      ["a", "b"],
      [1n, 2n],
    );
    expect(sent.map(({ labels }) => labels)).toEqual([
      ["a", "b"],
      ["a", "b"],
    ]);
    expect(result.failed).toEqual([]);
  });
});

describe("whileMiningBlocks", () => {
  // A node that records each mining request, and refuses them all when `refuses`.
  function localNode(refuses = false) {
    const node = {
      mined: [] as string[],
      async request({ method }: { method: string }) {
        if (refuses) throw new Error(`${method} is not supported`);
        node.mined.push(method);
        return null;
      },
    };
    return node;
  }

  const pause = (ms: number) =>
    new Promise((resolve) => setTimeout(resolve, ms));

  it("mines empty blocks while the work runs, and returns what it returns", async () => {
    const node = localNode();
    const result = await whileMiningBlocks(
      node,
      async () => {
        await pause(60);
        return "done";
      },
      10,
    );
    expect(result).toBe("done");
    expect(node.mined.length).toBeGreaterThan(1);
    expect(new Set(node.mined)).toEqual(new Set(["anvil_mine"]));
  });

  it("stops mining once the work settles, even when it fails", async () => {
    const node = localNode();
    await expect(
      whileMiningBlocks(
        node,
        async () => {
          await pause(30);
          throw new Error("run failed");
        },
        10,
      ),
    ).rejects.toThrow("run failed");
    const minedWhileRunning = node.mined.length;
    await pause(50);
    expect(node.mined.length).toBe(minedWhileRunning);
  });

  it("leaves a chain that will not mine on request alone", async () => {
    const node = localNode(true);
    expect(
      await whileMiningBlocks(
        node,
        async () => {
          await pause(40);
          return "done";
        },
        10,
      ),
    ).toBe("done");
    expect(node.mined).toEqual([]);
  });
});
