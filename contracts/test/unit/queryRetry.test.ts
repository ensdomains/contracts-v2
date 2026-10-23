import { describe, expect, it } from "bun:test";
import { parseAbiItem, type Address } from "viem";

import { readEventLogs } from "../../script/migrate.js";
import {
  FAILED_QUERY_LIMIT,
  QueryRetry,
} from "../../script/migrations/queryRetry.js";
import { fetchWithDeadline } from "../../script/scriptUtils.js";

// How drpc fails some queries at random: a code of its own, and no cap named.
const randomFailure = () =>
  Object.assign(
    new Error(
      "RPC Request failed.\n\nDetails: Temporary internal error. Please retry",
    ),
    { code: 19 },
  );

describe("QueryRetry", () => {
  it("gives up once the failures in a row reach the limit", async () => {
    const retry = new QueryRetry(0);
    for (let i = 0; i < FAILED_QUERY_LIMIT; i++) {
      await retry.failed(randomFailure());
    }
    await expect(retry.failed(new Error("last"))).rejects.toThrow("last");
  });

  it("starts a new run of failures after a served query", async () => {
    const retry = new QueryRetry(0);
    for (let i = 0; i < FAILED_QUERY_LIMIT; i++) {
      await retry.failed(randomFailure());
    }
    retry.served();
    await retry.failed(randomFailure());
  });
});

describe("readEventLogs", () => {
  const event = parseAbiItem(
    "event ControllerChanged(address indexed controller, bool enabled)",
  );
  const address: Address = "0x00000000000000000000000000000000000000c0";
  // One log every thousand blocks.
  const blocks = Array.from({ length: 100 }, (_, i) => BigInt(i * 1_000 + 7));

  // A chain whose `getLogs` fails where `fail` says, recording the ranges it served.
  function chainOf(fail: (call: number) => boolean) {
    const served: Array<[bigint, bigint]> = [];
    let calls = 0;
    const client = {
      getLogs: async ({
        fromBlock,
        toBlock,
      }: {
        fromBlock: bigint;
        toBlock: bigint;
      }) => {
        if (fail(calls++)) throw randomFailure();
        served.push([fromBlock, toBlock]);
        return blocks
          .filter((block) => block >= fromBlock && block <= toBlock)
          .map((blockNumber) => ({
            args: {},
            blockNumber,
            logIndex: 0,
            transactionHash: "0x00",
          }));
      },
    };
    return { client: client as never, served, calls: () => calls };
  }

  it("asks again after random failures, reading each block once", async () => {
    const chain = chainOf((call) => call % 2 === 0);
    const logs = await readEventLogs(
      chain.client,
      { address, event, fromBlock: 0n, toBlock: 99_999n },
      new QueryRetry(0),
    );
    expect(logs.map((log) => log.blockNumber)).toEqual(blocks);
    let next = 0n;
    for (const [from, to] of chain.served) {
      expect(from).toBe(next);
      next = to + 1n;
    }
    expect(next).toBe(100_000n);
  });

  it("asks again for the same range at the smallest span", async () => {
    const chain = chainOf((call) => call === 0);
    const logs = await readEventLogs(
      chain.client,
      { address, event, fromBlock: 0n, toBlock: 999n },
      new QueryRetry(0),
    );
    expect(logs.map((log) => log.blockNumber)).toEqual([7n]);
    expect(chain.served).toEqual([[0n, 999n]]);
  });

  it("gives up after too many failures in a row", async () => {
    const chain = chainOf(() => true);
    await expect(
      readEventLogs(
        chain.client,
        { address, event, fromBlock: 0n, toBlock: 999n },
        new QueryRetry(0),
      ),
    ).rejects.toThrow("Temporary internal error");
    expect(chain.calls()).toBe(FAILED_QUERY_LIMIT + 1);
  });
});

describe("fetchWithDeadline", () => {
  it("fails a reply that stops partway once the deadline passes", async () => {
    // Sends the headers and the start of a body, then nothing more.
    const server = Bun.serve({
      port: 0,
      fetch: () =>
        new Response(
          new ReadableStream({
            start: (stream) =>
              stream.enqueue(new TextEncoder().encode('{"result":[')),
          }),
          { headers: { "content-type": "application/json" } },
        ),
    });
    try {
      const response = await fetchWithDeadline(200)(
        `http://localhost:${server.port}`,
      );
      await expect(response.json()).rejects.toThrow();
    } finally {
      server.stop(true);
    }
  });
});
