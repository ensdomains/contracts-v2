import { describe, expect, it } from "bun:test";
import { createRequire } from "node:module";
import {
  keccak256,
  parseTransaction,
  toHex,
  type Address,
  type Hex,
} from "viem";
import { sepolia } from "viem/chains";

import { resolveDeployProviderAndChain } from "../../script/migrate.js";
import { privateKeyRpcProvider } from "../../script/migrations/rpc.js";

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

describe("the provider a deploy given only an RPC URL runs through", () => {
  // The provider rocketh would build for itself, loaded the way rocketh loads it.
  const { JSONRPCHTTPProvider } = createRequire(
    import.meta.resolve("rocketh"),
  )("eip-1193-jsonrpc-provider");

  // A node that gives every request the same JSON-RPC body.
  async function withNode(
    body: object,
    run: (url: string) => Promise<void>,
  ): Promise<void> {
    const server = Bun.serve({
      port: 0,
      fetch: async (req) => {
        const { id } = (await req.json()) as { id: number };
        return Response.json({ jsonrpc: "2.0", id, ...body });
      },
    });
    try {
      await run(`http://127.0.0.1:${server.port}`);
    } finally {
      server.stop(true);
    }
  }

  // rocketh looks a transaction up right after sending it, and stops on an error.
  const lookup = (provider: { request: (args: any) => Promise<unknown> }) =>
    provider.request({
      method: "eth_getTransactionByHash",
      params: [`0x${"ab".repeat(32)}`],
    });
  const deployProvider = async (url: string) =>
    (await resolveDeployProviderAndChain({ network: "mainnet", rpcUrl: url }))
      .provider;

  it("is not rocketh's own, which reports a transaction the node has not seen yet as an error", async () => {
    await withNode({ result: null }, async (url) => {
      await expect(lookup(new JSONRPCHTTPProvider(url))).rejects.toEqual({
        code: 5000,
        message: "No Result",
      });
    });
  });

  it("returns null for a transaction the node has not seen yet", async () => {
    await withNode({ result: null }, async (url) => {
      expect(await lookup(await deployProvider(url))).toBeNull();
    });
  });

  it("still throws the error a node returns", async () => {
    await withNode(
      { error: { code: -32000, message: "header not found" } },
      async (url) => {
        await expect(lookup(await deployProvider(url))).rejects.toThrow(
          "header not found",
        );
      },
    );
  });

  it("keeps the network's chain id without asking the node", async () => {
    const { chainId } = await resolveDeployProviderAndChain({
      network: "mainnet",
      rpcUrl: "http://127.0.0.1:1",
    });
    expect(chainId).toBe(1);
  });
});
