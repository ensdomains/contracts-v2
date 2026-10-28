import { afterAll, afterEach, beforeAll, describe, expect, it } from "bun:test";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { anvil as createAnvil } from "prool/instances";
import {
  createPublicClient,
  http,
  parseAbi,
  type Abi,
  type Address,
} from "viem";

import {
  coerceConstructorArgs,
  deployContract,
  planVerification,
  resolveArtifact,
} from "../../script/deployContract.js";

// The first account of anvil's default mnemonic.
const DEPLOYER_KEY =
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
const MOCK_ERC20 = "test/mocks/MockERC20.sol:MockERC20";
const ERC20_ABI = parseAbi([
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
]);

function constructorAbi(inputs: readonly object[]): Abi {
  return [
    { type: "constructor", stateMutability: "nonpayable", inputs },
  ] as Abi;
}

async function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address() as { port: number };
      server.close(() => resolve(port));
    });
  });
}

describe("coerceConstructorArgs", () => {
  it("converts integers from numbers and strings", () => {
    const abi = constructorAbi([
      { name: "small", type: "uint8" },
      { name: "large", type: "uint256" },
      { name: "signed", type: "int64" },
    ]);
    expect(
      coerceConstructorArgs(abi, [6, "123456789012345678901234567890", "-5"]),
    ).toEqual([6n, 123456789012345678901234567890n, -5n]);
  });

  it("refuses integers a JSON number cannot hold exactly", () => {
    const abi = constructorAbi([{ name: "large", type: "uint256" }]);
    expect(() => coerceConstructorArgs(abi, [2 ** 60])).toThrow(
      "pass large integers as strings",
    );
  });

  it("converts booleans and passes other types through", () => {
    const abi = constructorAbi([
      { name: "flag", type: "bool" },
      { name: "other", type: "bool" },
      { name: "who", type: "address" },
      { name: "label", type: "string" },
    ]);
    const who = "0x0000000000000000000000000000000000000001";
    expect(coerceConstructorArgs(abi, [true, "false", who, "eth"])).toEqual([
      true,
      false,
      who,
      "eth",
    ]);
  });

  it("converts tuples given as arrays or objects, and nested arrays", () => {
    const abi = constructorAbi([
      {
        name: "config",
        type: "tuple",
        components: [
          { name: "count", type: "uint32" },
          { name: "enabled", type: "bool" },
        ],
      },
      {
        name: "configs",
        type: "tuple[]",
        components: [
          { name: "count", type: "uint32" },
          { name: "enabled", type: "bool" },
        ],
      },
      { name: "grid", type: "uint16[2][]" },
    ]);
    expect(
      coerceConstructorArgs(abi, [
        { count: 1, enabled: "true" },
        [[2, false]],
        [
          [1, "2"],
          [3, 4],
        ],
      ]),
    ).toEqual([
      { count: 1n, enabled: true },
      [[2n, false]],
      [
        [1n, 2n],
        [3n, 4n],
      ],
    ]);
  });

  it("refuses the wrong number of arguments", () => {
    const abi = constructorAbi([
      { name: "symbol", type: "string" },
      { name: "decimals", type: "uint8" },
    ]);
    expect(() => coerceConstructorArgs(abi, ["TST"])).toThrow(
      "the constructor takes 2 argument(s) (string symbol, uint8 decimals), got 1",
    );
  });

  it("refuses a value of the wrong kind", () => {
    const abi = constructorAbi([{ name: "values", type: "uint8[]" }]);
    expect(() => coerceConstructorArgs(abi, [5])).toThrow(
      "uint8[] values: expected an array",
    );
  });

  it("takes no arguments for a contract without a constructor", () => {
    expect(coerceConstructorArgs([] as Abi, [])).toEqual([]);
  });
});

describe("resolveArtifact", () => {
  it("finds a contract with a unique name by its bare name or full path", async () => {
    const bare = await resolveArtifact("DNSTXTResolver");
    const qualified = await resolveArtifact(
      "src/dns/DNSTXTResolver.sol:DNSTXTResolver",
    );
    expect(bare.sourceName).toBe("src/dns/DNSTXTResolver.sol");
    expect(qualified).toBe(bare);
  });

  it("finds a contract whose name is not unique by its full path", async () => {
    const artifact = await resolveArtifact(MOCK_ERC20);
    expect(artifact.sourceName).toBe("test/mocks/MockERC20.sol");
  });

  it("lists the full paths of a name that is not unique", async () => {
    const error = await resolveArtifact("MockERC20").catch((e) => e);
    expect(error.message).toContain(MOCK_ERC20);
    expect(error.message).toContain(
      "lib/ens-contracts/contracts/test/mocks/MockERC20.sol:MockERC20",
    );
  });

  it("refuses an interface", async () => {
    await expect(resolveArtifact("IContractNamer")).rejects.toThrow(
      "it is an interface or an abstract contract",
    );
  });

  it("refuses a name that is not in the build", async () => {
    await expect(resolveArtifact("NoSuchContract")).rejects.toThrow(
      'no contract named "NoSuchContract" in the build',
    );
  });
});

describe("planVerification", () => {
  const RPC_URL = "https://rpc.example";
  const originalFetch = globalThis.fetch;
  const originalKey = process.env.ETHERSCAN_API_KEY;

  afterEach(() => {
    globalThis.fetch = originalFetch;
    if (originalKey === undefined) delete process.env.ETHERSCAN_API_KEY;
    else process.env.ETHERSCAN_API_KEY = originalKey;
  });

  /// Answers the RPC and both services' chain lists without the network.
  function fakeNetwork({
    chainId = 1,
    clientVersion = "Geth/v1.16.0",
    etherscanChains = [1],
    sourcifyChains = [1],
  }: {
    chainId?: number;
    clientVersion?: string;
    etherscanChains?: number[];
    sourcifyChains?: number[];
  }) {
    globalThis.fetch = (async (
      input: string | URL | Request,
      init?: RequestInit,
    ) => {
      const url = String(input instanceof Request ? input.url : input);
      const reply = (body: unknown) =>
        new Response(JSON.stringify(body), {
          headers: { "content-type": "application/json" },
        });
      if (url.includes("etherscan.io/v2/chainlist")) {
        return reply({
          result: etherscanChains.map((id) => ({
            chainid: String(id),
            status: 1,
          })),
        });
      }
      if (url.endsWith("/chains")) {
        return reply(
          sourcifyChains.map((id) => ({ chainId: id, supported: true })),
        );
      }
      const { id, method } = JSON.parse(String(init?.body));
      const result =
        method === "eth_chainId" ? `0x${chainId.toString(16)}` : clientVersion;
      return reply({ jsonrpc: "2.0", id, result });
    }) as typeof fetch;
  }

  it("skips a node on this machine without asking it anything", async () => {
    globalThis.fetch = (() => {
      throw new Error("unexpected request");
    }) as unknown as typeof fetch;
    const plan = await planVerification("http://127.0.0.1:8545", [
      "etherscan",
      "sourcify",
    ]);
    expect(plan.backends).toEqual([]);
    expect(plan.skipped).toContain("local node");
  });

  it("skips a development node", async () => {
    fakeNetwork({ clientVersion: "anvil/v1.5.1" });
    const plan = await planVerification(RPC_URL, ["etherscan", "sourcify"]);
    expect(plan.backends).toEqual([]);
    expect(plan.skipped).toContain("anvil/v1.5.1");
  });

  it("uses every service that supports the chain", async () => {
    fakeNetwork({});
    process.env.ETHERSCAN_API_KEY = "key";
    const plan = await planVerification(RPC_URL, ["etherscan", "sourcify"]);
    expect(plan).toEqual({ backends: ["etherscan", "sourcify"] });
  });

  it("drops a service that does not support the chain", async () => {
    fakeNetwork({ chainId: 42, etherscanChains: [1], sourcifyChains: [42] });
    delete process.env.ETHERSCAN_API_KEY;
    const plan = await planVerification(RPC_URL, ["etherscan", "sourcify"]);
    expect(plan).toEqual({ backends: ["sourcify"] });
  });

  it("skips a chain that no service supports", async () => {
    fakeNetwork({ chainId: 42, etherscanChains: [1], sourcifyChains: [1] });
    const plan = await planVerification(RPC_URL, ["etherscan", "sourcify"]);
    expect(plan.backends).toEqual([]);
    expect(plan.skipped).toContain("chain 42");
  });

  it("refuses Etherscan verification without an API key", async () => {
    fakeNetwork({});
    delete process.env.ETHERSCAN_API_KEY;
    await expect(
      planVerification(RPC_URL, ["etherscan", "sourcify"]),
    ).rejects.toThrow("ETHERSCAN_API_KEY");
  });

  it("needs no API key for Sourcify alone", async () => {
    fakeNetwork({});
    delete process.env.ETHERSCAN_API_KEY;
    const plan = await planVerification(RPC_URL, ["sourcify"]);
    expect(plan).toEqual({ backends: ["sourcify"] });
  });
});

describe("deployContract", () => {
  let anvil: ReturnType<typeof createAnvil>;
  let rpcUrl: string;
  let tempRoot: string;
  let publicClient: ReturnType<typeof createPublicClient>;

  beforeAll(async () => {
    const port = await freePort();
    anvil = createAnvil({ port });
    await anvil.start();
    rpcUrl = `http://127.0.0.1:${port}`;
    publicClient = createPublicClient({ transport: http(rpcUrl) });
    tempRoot = mkdtempSync(join(tmpdir(), "deploy-contract-"));
  });

  afterAll(async () => {
    await anvil.stop();
    rmSync(tempRoot, { recursive: true, force: true });
  });

  const deploy = (overrides: Partial<Parameters<typeof deployContract>[0]>) =>
    deployContract({
      contract: MOCK_ERC20,
      args: ["TST", 6],
      rpcUrl,
      privateKey: DEPLOYER_KEY,
      namespace: "local-adhoc",
      deploymentsDir: join(tempRoot, "deployments"),
      ...overrides,
    });

  async function readToken(address: Address) {
    const [symbol, decimals] = await Promise.all([
      publicClient.readContract({
        address,
        abi: ERC20_ABI,
        functionName: "symbol",
      }),
      publicClient.readContract({
        address,
        abi: ERC20_ABI,
        functionName: "decimals",
      }),
    ]);
    return { symbol, decimals };
  }

  it("deploys the contract and records it with its build info", async () => {
    const result = await deploy({});
    expect(result?.newlyDeployed).toBe(true);
    expect(await readToken(result!.address)).toEqual({
      symbol: "TST",
      decimals: 6,
    });

    const namespaceDir = join(tempRoot, "deployments", "local-adhoc");
    expect(result!.recordFile).toBe(join(namespaceDir, "MockERC20.json"));
    const record = JSON.parse(readFileSync(result!.recordFile, "utf8"));
    expect(record.address.toLowerCase()).toBe(result!.address.toLowerCase());
    expect(existsSync(join(namespaceDir, ".chain"))).toBe(true);
    expect(
      existsSync(
        join(namespaceDir, "build-info", `${record.buildInfoId}.json`),
      ),
    ).toBe(true);
  });

  it("reuses the record when the code and arguments are unchanged", async () => {
    const blockBefore = await publicClient.getBlockNumber();
    const first = await deploy({});
    expect(first?.newlyDeployed).toBe(false);
    expect(await publicClient.getBlockNumber()).toBe(blockBefore);
  });

  it("deploys another copy under another record name", async () => {
    const original = await deploy({});
    const copy = await deploy({ name: "MockERC20Copy" });
    expect(copy?.newlyDeployed).toBe(true);
    expect(copy!.address).not.toBe(original!.address);
    expect(copy!.recordFile).toEndWith("MockERC20Copy.json");
  });

  it("replaces the record when the arguments change", async () => {
    const original = await deploy({});
    const replaced = await deploy({ args: ["NEW", 18] });
    expect(replaced?.newlyDeployed).toBe(true);
    expect(replaced!.replacedAddress).toBe(original!.address);
    expect(await readToken(replaced!.address)).toEqual({
      symbol: "NEW",
      decimals: 18,
    });
  });

  it("sends nothing when the confirmation is declined", async () => {
    const blockBefore = await publicClient.getBlockNumber();
    let summary: any;
    const result = await deploy({
      name: "Declined",
      confirm: async (s) => {
        summary = s;
        return false;
      },
    });
    expect(result).toBeUndefined();
    expect(summary.chainId).toBe(31337);
    expect(summary.args).toEqual(["TST", 6n]);
    expect(summary.estimatedCost).toBeGreaterThan(0n);
    expect(await publicClient.getBlockNumber()).toBe(blockBefore);
  });

  it("refuses records from a chain with another genesis block and keeps them", async () => {
    const namespaceDir = join(tempRoot, "deployments", "other-chain");
    mkdirSync(namespaceDir, { recursive: true });
    const chainFile = join(namespaceDir, ".chain");
    const recordFile = join(namespaceDir, "Existing.json");
    writeFileSync(
      chainFile,
      JSON.stringify({ chainId: "31337", genesisHash: `0x${"ab".repeat(32)}` }),
    );
    writeFileSync(recordFile, JSON.stringify({ address: "0x01" }));

    await expect(deploy({ namespace: "other-chain" })).rejects.toThrow(
      "belong to a chain with genesis block",
    );
    expect(existsSync(chainFile)).toBe(true);
    expect(existsSync(recordFile)).toBe(true);
  });
});
