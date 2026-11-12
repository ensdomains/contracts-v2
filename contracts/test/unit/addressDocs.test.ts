import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { getAddress } from "viem";
import {
  adhocNamespace,
  baseNamespace,
  generateAddressMarkdown,
  loadLatestAddresses,
  refreshNetworkAddressDocs,
  rpcBlockTimes,
  writeNamespaceAddressTable,
} from "../../script/addressDocs.js";

const address = (digit: string) => `0x${digit.repeat(40)}`;

/// Block times one day apart from the start of 2026, so each block's time is
/// easy to work out.
const START_OF_2026 = 1767225600n;
const blockTimes = async (block: bigint) => START_OF_2026 + block * 86_400n;

let root: string;
let deploymentsDir: string;
let outDir: string;

/// Writes records into a namespace: each name maps to its address and the block
/// its deploy was mined in.
function writeRecords(
  namespace: string,
  records: Record<string, [address: string, block: number]>,
  chain: object | null = { chainId: "1" },
) {
  const dir = join(deploymentsDir, namespace);
  mkdirSync(dir, { recursive: true });
  if (chain) writeFileSync(join(dir, ".chain"), JSON.stringify(chain));
  for (const [name, [addr, block]] of Object.entries(records)) {
    writeFileSync(
      join(dir, `${name}.json`),
      JSON.stringify({
        address: addr,
        abi: [],
        receipt: { blockNumber: `0x${block.toString(16)}` },
      }),
    );
  }
}

async function render(): Promise<{ table: string; changelog: string }> {
  const path = await generateAddressMarkdown({
    deploymentsDir,
    namespace: "mainnet",
    outDir,
    blockTimes,
  });
  const [table, changelog = ""] = (await Bun.file(path).text()).split(
    "## Changelog",
  );
  return { table, changelog };
}

/// The changelog row of an address, or `undefined` when it is not listed.
function changelogRow(changelog: string, addr: string): string | undefined {
  return changelog.split("\n").find((line) => line.includes(`[${addr}]`));
}

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "address-docs-"));
  deploymentsDir = join(root, "deployments");
  outDir = join(root, "docs");
  writeRecords("mainnet", {
    Registry: [address("1"), 100],
    Resolver: [address("2"), 101],
  });
});

afterEach(() => rmSync(root, { recursive: true, force: true }));

describe("address pages", () => {
  it("has no changelog while no contract was replaced or deployed ad hoc", async () => {
    const { table, changelog } = await render();
    expect(table).toContain(address("1"));
    expect(table).toContain(address("2"));
    expect(changelog).toBe("");
  });

  it("puts the newest ad-hoc deployment in the table and every address of the contract in the changelog", async () => {
    writeRecords(adhocNamespace("mainnet"), {
      Resolver: [address("3"), 200],
      Registrar: [address("4"), 201],
    });
    const { table, changelog } = await render();
    expect(table).toContain(address("3"));
    expect(table).not.toContain(address("2"));
    expect(table).toContain(address("4"));
    expect(changelogRow(changelog, address("3"))).toBeDefined();
    expect(changelogRow(changelog, address("2"))).toBeDefined();
    expect(changelogRow(changelog, address("4"))).toBeDefined();
    expect(changelogRow(changelog, address("1"))).toBeUndefined();
  });

  it("gives the deploy time of each changelog row, linked to its block", async () => {
    writeRecords(adhocNamespace("mainnet"), {
      Resolver: [address("3"), 2],
    });
    const { changelog } = await render();
    expect(changelog).toContain("| Deployed (UTC) |");
    expect(changelogRow(changelog, address("3"))).toContain(
      "[2026-01-03 00:00:00](https://etherscan.io/block/2)",
    );
  });

  it("refuses to write a changelog without block times", async () => {
    writeRecords(adhocNamespace("mainnet"), {
      Resolver: [address("3"), 200],
    });
    await expect(
      generateAddressMarkdown({ deploymentsDir, namespace: "mainnet", outDir }),
    ).rejects.toThrow("deploy times are read from the chain");
  });

  it("keeps the migration's record when an ad-hoc one is older", async () => {
    writeRecords(adhocNamespace("mainnet"), {
      Resolver: [address("3"), 50],
    });
    const { table, changelog } = await render();
    expect(table).toContain(address("2"));
    expect(table).not.toContain(address("3"));
    expect(changelogRow(changelog, address("3"))).toBeDefined();
  });

  it("lists archived records in the changelog, newest first", async () => {
    writeRecords("mainnet-redeploy-20261001", {
      Resolver: [address("5"), 90],
    });
    writeRecords(`${adhocNamespace("mainnet")}-redeploy-20261101`, {
      Resolver: [address("6"), 300],
    });
    const { table, changelog } = await render();
    expect(table).toContain(address("2"));
    expect(table).not.toContain(address("5"));
    expect(table).not.toContain(address("6"));
    const rows = [address("6"), address("2"), address("5")].map((addr) =>
      changelog.indexOf(`[${addr}]`),
    );
    expect(rows.every((index) => index > 0)).toBe(true);
    expect(rows).toEqual([...rows].sort((a, b) => a - b));
    expect(changelogRow(changelog, address("6"))).toBeDefined();
    expect(changelogRow(changelog, address("5"))).toBeDefined();
  });

  it("leaves out an archive of a whole earlier deployment", async () => {
    writeRecords("mainnet-20260901-r1", { Resolver: [address("7"), 10] });
    const { table, changelog } = await render();
    expect(table).not.toContain(address("7"));
    expect(changelog).toBe("");
  });

  it("leaves out the archives of other namespaces that share the prefix", async () => {
    writeRecords("mainnet-fork-20261101-r1", { Resolver: [address("7"), 10] });
    writeRecords("mainnet-adhoc-20261101-r1", { Resolver: [address("8"), 11] });
    const { changelog } = await render();
    expect(changelog).toBe("");
  });

  it("keeps the migration's record when an ad-hoc one is from the same block", async () => {
    writeRecords(adhocNamespace("mainnet"), { Resolver: [address("3"), 101] });
    const { table } = await render();
    expect(table).toContain(address("2"));
    expect(table).not.toContain(address("3"));
  });

  it("names an archive that has no .chain file", async () => {
    writeRecords(
      "mainnet-redeploy-20261001",
      { Resolver: [address("5"), 90] },
      null,
    );
    await expect(render()).rejects.toThrow(
      "mainnet-redeploy-20261001 has no .chain file",
    );
  });

  it("refuses records of another chain beside the deployment", async () => {
    const genesis = (digit: string) => `0x${digit.repeat(64)}`;
    writeRecords(
      "mainnet",
      { Registry: [address("1"), 100] },
      { chainId: "1", genesisHash: genesis("a") },
    );
    writeRecords(
      adhocNamespace("mainnet"),
      { Resolver: [address("3"), 200] },
      { chainId: "1", genesisHash: genesis("b") },
    );
    await expect(render()).rejects.toThrow("records of another chain");
  });

  it("writes the same tables beside the records", async () => {
    writeRecords(adhocNamespace("mainnet"), {
      Resolver: [address("3"), 200],
    });
    const path = await writeNamespaceAddressTable({
      deploymentsDir,
      namespace: "mainnet",
      blockTimes,
    });
    expect(path).toBe(join(deploymentsDir, "mainnet", "addresses.md"));
    const [, changelog = ""] = (await Bun.file(path).text()).split(
      "## Changelog",
    );
    expect(changelogRow(changelog, address("3"))).toBeDefined();
  });
});

describe("refreshNetworkAddressDocs", () => {
  it("rewrites both pages of a network with a published page, and leaves others alone", async () => {
    mkdirSync(outDir, { recursive: true });
    expect(
      await refreshNetworkAddressDocs({
        deploymentsDir,
        network: "mainnet",
        blockTimes,
        docsDir: outDir,
      }),
    ).toEqual([]);
    expect(existsSync(join(outDir, "mainnet.md"))).toBe(false);

    writeFileSync(join(outDir, "mainnet.md"), "");
    expect(
      await refreshNetworkAddressDocs({
        deploymentsDir,
        network: "mainnet",
        blockTimes,
        docsDir: outDir,
      }),
    ).toEqual([
      join(outDir, "mainnet.md"),
      join(deploymentsDir, "mainnet", "addresses.md"),
    ]);
    expect(await Bun.file(join(outDir, "mainnet.md")).text()).toContain(
      address("1"),
    );
  });
});

describe("rpcBlockTimes", () => {
  it("reads each block once, and refuses a block the RPC does not have", async () => {
    const requests: unknown[] = [];
    const lookup = rpcBlockTimes({
      request: async (args: { method: string; params?: unknown }) => {
        requests.push(args);
        const [block] = args.params as [string];
        return block === "0x2" ? null : { timestamp: "0x10" };
      },
    } as any);
    expect(await lookup(1n)).toBe(16n);
    expect(await lookup(1n)).toBe(16n);
    expect(requests).toEqual([
      { method: "eth_getBlockByNumber", params: ["0x1", false] },
    ]);
    await expect(lookup(2n)).rejects.toThrow("the RPC has no block 2");
  });
});

describe("loadLatestAddresses", () => {
  it("returns the addresses of the main table, keyed by contract name", async () => {
    writeRecords(adhocNamespace("mainnet"), {
      Resolver: [address("3"), 200],
      Registrar: [address("4"), 201],
    });
    writeRecords("mainnet-redeploy-20261001", {
      Registry: [address("5"), 300],
    });
    expect(await loadLatestAddresses(deploymentsDir, "mainnet")).toEqual({
      Registrar: getAddress(address("4")),
      Registry: getAddress(address("1")),
      Resolver: getAddress(address("3")),
    });
  });
});

describe("baseNamespace", () => {
  it("strips the ad-hoc suffix and keeps any other namespace", () => {
    expect(baseNamespace(adhocNamespace("sepolia"))).toBe("sepolia");
    expect(baseNamespace("sepolia-fork")).toBe("sepolia-fork");
  });
});
