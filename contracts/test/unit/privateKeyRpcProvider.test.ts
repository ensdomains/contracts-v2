import { describe, expect, it } from "bun:test";
import {
  keccak256,
  parseTransaction,
  toHex,
  type Address,
  type Hex,
} from "viem";
import { sepolia } from "viem/chains";

import {
  answerLookup,
  privateKeyRpcProvider,
} from "../../script/migrations/rpc.js";

const KEY =
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d" as const;
const TARGET = "0x00000000000000000000000000000000000000aa" as Address;
const MINED_IN = 0x10n;
const BLOCK_HASH = `0x${"22".repeat(32)}` as Hex;

/// A node that answers what signing and sending ask of it, mines every
/// transaction into one block, and can be told to refuse estimates pinned to a
/// block it has not reached yet — what a lagging backend behind a load balancer
/// does.
function node(opts: { refusePinnedEstimates?: number } = {}) {
  let refusals = opts.refusePinnedEstimates ?? 0;
  const estimates: (string | undefined)[] = [];
  const sent: { nonce: number; gas: bigint }[] = [];
  const server = Bun.serve({
    port: 0,
    async fetch(request) {
      const { id, method, params } = (await request.json()) as {
        id: number;
        method: string;
        params: any[];
      };
      const answer = (body: object) =>
        Response.json({ jsonrpc: "2.0", id, ...body });
      switch (method) {
        case "eth_chainId":
          return answer({ result: toHex(sepolia.id) });
        // Stale: never counts the transactions already sent.
        case "eth_getTransactionCount":
          return answer({ result: "0x0" });
        case "eth_maxPriorityFeePerGas":
        case "eth_gasPrice":
          return answer({ result: "0x1" });
        case "eth_blockNumber":
          return answer({ result: toHex(MINED_IN + 1n) });
        case "eth_getBlockByNumber":
          return answer({
            result: {
              number: toHex(MINED_IN),
              hash: BLOCK_HASH,
              baseFeePerGas: "0x1",
              gasLimit: "0x1c9c380",
              gasUsed: "0x0",
              timestamp: "0x1",
              transactions: [],
            },
          });
        case "eth_estimateGas": {
          const blockTag = params[1] as string | undefined;
          estimates.push(blockTag);
          if (blockTag?.startsWith("0x") && refusals > 0) {
            refusals--;
            return answer({
              error: { code: -32000, message: "header not found" },
            });
          }
          return answer({ result: "0x5208" });
        }
        case "eth_sendRawTransaction": {
          const tx = parseTransaction(params[0]);
          sent.push({ nonce: tx.nonce!, gas: tx.gas! });
          return answer({ result: keccak256(params[0]) });
        }
        case "eth_getTransactionReceipt":
          return answer({
            result: {
              transactionHash: params[0],
              transactionIndex: "0x0",
              blockHash: BLOCK_HASH,
              blockNumber: toHex(MINED_IN),
              from: TARGET,
              to: TARGET,
              cumulativeGasUsed: "0x5208",
              gasUsed: "0x5208",
              effectiveGasPrice: "0x1",
              contractAddress: null,
              logs: [],
              logsBloom: `0x${"00".repeat(256)}`,
              status: "0x1",
              type: "0x2",
            },
          });
        default:
          return answer({ error: { code: -32601, message: method } });
      }
    },
  });
  const provider = privateKeyRpcProvider({
    rpcUrl: server.url.href,
    chain: sepolia,
    privateKey: KEY,
  });
  const send = () =>
    provider.request({
      method: "eth_sendTransaction",
      params: [{ to: TARGET, data: "0x12345678" }],
    } as never);
  return { send, estimates, sent, stop: () => server.stop(true) };
}

describe("a deploy signer on a load-balanced endpoint", () => {
  it("prices the next transaction against the block that mined the previous one", async () => {
    const { send, estimates, stop } = node();
    try {
      await send();
      await send();
    } finally {
      stop();
    }
    // The first send has nothing to wait for; the second is pinned.
    expect(estimates[0]).toBeUndefined();
    expect(estimates[1]).toBe(toHex(MINED_IN));
  });

  it("asks again while a lagging node refuses the pinned block", async () => {
    const { send, estimates, sent, stop } = node({ refusePinnedEstimates: 1 });
    try {
      await send();
      await send();
    } finally {
      stop();
    }
    expect(estimates.slice(1)).toEqual([toHex(MINED_IN), toHex(MINED_IN)]);
    expect(sent).toHaveLength(2);
  }, 20_000);

  it("never reuses a nonce when the node's count is stale", async () => {
    const { send, sent, stop } = node();
    try {
      await send();
      await send();
    } finally {
      stop();
    }
    expect(sent.map((tx) => tx.nonce)).toEqual([0, 1]);
  });

  it("pads the estimate it sends with", async () => {
    const { send, sent, stop } = node();
    try {
      await send();
    } finally {
      stop();
    }
    expect(sent[0].gas).toBe((21_000n * 130n) / 100n);
  });
});

describe("a transaction lookup on a load-balanced endpoint", () => {
  const request = {
    jsonrpc: "2.0",
    id: 7,
    method: "eth_getTransactionByHash",
    params: [`0x${"ab".repeat(32)}`],
  };
  const reply = (body: object) =>
    new Response(JSON.stringify({ jsonrpc: "2.0", id: 7, ...body }));
  const noResult = () => reply({ error: { code: 5000, message: "No Result" } });
  const found = () => reply({ result: { hash: request.params[0] } });

  // A node that answers each request in turn from the given replies.
  function node(...replies: Array<() => Response>) {
    let calls = 0;
    const fetch = (async () => replies[Math.min(calls++, replies.length - 1)]()) as never;
    return { fetch, calls: () => calls };
  }

  const answer = async (first: Response, fake: ReturnType<typeof node>) =>
    (await (
      await answerLookup(fake.fetch, "rpc", {}, request, first, 0)
    ).json()) as {
      jsonrpc: string;
      id: number;
      result?: unknown;
      error?: unknown;
    };

  it("passes an answer through untouched", async () => {
    const fake = node(found);
    expect((await answer(found(), fake)).result).toEqual({
      hash: request.params[0],
    });
    expect(fake.calls()).toBe(0);
  });

  it("asks again when a node has not indexed the transaction yet", async () => {
    const fake = node(noResult, found);
    expect((await answer(noResult(), fake)).result).toEqual({
      hash: request.params[0],
    });
    expect(fake.calls()).toBe(2);
  });

  it("answers as not found once the lookup keeps failing", async () => {
    const fake = node(noResult);
    const body = await answer(noResult(), fake);
    expect(body).toEqual({ jsonrpc: "2.0", id: 7, result: null });
    expect(fake.calls()).toBe(4);
  });
});
