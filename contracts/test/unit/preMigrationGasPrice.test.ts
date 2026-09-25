import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { InvalidArgumentError } from "commander";
import { type FeeHistory, parseGwei } from "viem";
import { mainnet, sepolia } from "viem/chains";

import {
  blockGasPrices,
  currentGasPrice,
  DEFAULT_MAX_GAS_PRICE,
  GAS_PRICE_MAX_READ_FAILURES,
  parseMaxGasPrice,
  resolveMaxGasPrice,
  waitForGasPriceAtOrBelow,
} from "../../script/preMigration.js";

// A fee history over blocks with these base fees and median tips. Like a node's, its
// base fees run one entry past the last block, to the next block's.
function feeHistory(baseFees: bigint[], tips: bigint[]): FeeHistory {
  return {
    oldestBlock: 1n,
    baseFeePerGas: [...baseFees, 1_000_000n],
    gasUsedRatio: baseFees.map(() => 0.5),
    reward: tips.map((tip) => [tip]),
  };
}

// A client whose gas price reads return each outcome in turn: a price every recent
// block paid, or an error.
function fakeClient(outcomes: Array<bigint | Error>) {
  const client = {
    reads: 0,
    async getFeeHistory(): Promise<FeeHistory> {
      const outcome = outcomes[client.reads++];
      if (outcome === undefined) throw new Error("no more reads scripted");
      if (outcome instanceof Error) throw outcome;
      const blocks = Array.from({ length: 5 }, () => outcome);
      return feeHistory(
        blocks,
        blocks.map(() => 0n),
      );
    },
  };
  return client;
}

const LIMIT = parseGwei("1");
const ABOVE = parseGwei("3");

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

  it("has no limit when turned off", () => {
    expect(resolveMaxGasPrice(false, mainnet.id)).toBeNull();
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
    expect(blockGasPrices(feeHistory([10n, 20n], [1n, 2n]))).toEqual([
      11n,
      22n,
    ]);
  });
});

describe("currentGasPrice", () => {
  it("takes the median over the last few blocks, so one spike does not decide it", async () => {
    const client = {
      requests: [] as unknown[],
      async getFeeHistory(request: unknown) {
        client.requests.push(request);
        return feeHistory([1n, 500n, 3n, 9n, 7n], [1n, 1n, 1n, 1n, 1n]);
      },
    };
    expect(await currentGasPrice(client)).toBe(8n);
    expect(client.requests).toEqual([
      { blockCount: 5, blockTag: "latest", rewardPercentiles: [50] },
    ]);
  });

  it("refuses a fee history without rewards", async () => {
    const client = {
      async getFeeHistory() {
        return { ...feeHistory([1n], [1n]), reward: undefined };
      },
    };
    await expect(currentGasPrice(client)).rejects.toThrow("no block rewards");
  });
});

describe("waitForGasPriceAtOrBelow", () => {
  it("reads nothing when there is no limit", async () => {
    const client = fakeClient([]);
    await waitForGasPriceAtOrBelow(client, null, 0);
    expect(client.reads).toBe(0);
  });

  it("returns at once when the price is at the limit", async () => {
    const client = fakeClient([LIMIT]);
    await waitForGasPriceAtOrBelow(client, LIMIT, 0);
    expect(client.reads).toBe(1);
  });

  it("waits while the price is above the limit", async () => {
    const client = fakeClient([ABOVE, ABOVE, LIMIT - 1n]);
    await waitForGasPriceAtOrBelow(client, LIMIT, 0);
    expect(client.reads).toBe(3);
  });

  it("keeps waiting through a failed read", async () => {
    const client = fakeClient([new Error("timeout"), ABOVE, LIMIT]);
    await waitForGasPriceAtOrBelow(client, LIMIT, 0);
    expect(client.reads).toBe(3);
  });

  it("counts only failures in a row", async () => {
    const failures = Array.from(
      { length: GAS_PRICE_MAX_READ_FAILURES - 1 },
      () => new Error("timeout"),
    );
    const client = fakeClient([...failures, ABOVE, ...failures, LIMIT]);
    await waitForGasPriceAtOrBelow(client, LIMIT, 0);
    expect(client.reads).toBe(2 * failures.length + 2);
  });

  it("stops the run when reads keep failing", async () => {
    const client = fakeClient(
      Array.from(
        { length: GAS_PRICE_MAX_READ_FAILURES },
        () => new Error("timeout"),
      ),
    );
    await expect(waitForGasPriceAtOrBelow(client, LIMIT, 0)).rejects.toThrow(
      `could not read the gas price ${GAS_PRICE_MAX_READ_FAILURES} times in a row`,
    );
    expect(client.reads).toBe(GAS_PRICE_MAX_READ_FAILURES);
  });
});
