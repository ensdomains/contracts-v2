import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { getAddress } from "viem";
import {
  adhocNamespace,
  baseNamespace,
  generateAddressMarkdown,
  loadCurrentAddresses,
  writeNamespaceAddressTable,
} from "../../script/addressDocs.js";

const address = (digit: string) => `0x${digit.repeat(40)}`;

let root: string;
let deploymentsDir: string;
let outDir: string;

/// Writes records into a namespace: each name maps to its address and the block
/// its deploy was mined in.
function writeRecords(
  namespace: string,
  records: Record<string, [address: string, block: number]>,
) {
  const dir = join(deploymentsDir, namespace);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, ".chain"), JSON.stringify({ chainId: "1" }));
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
    expect(table).not.toContain("changelog below");
    expect(changelog).toBe("");
  });

  it("lists the newest ad-hoc deployment as current and the replaced one in the changelog", async () => {
    writeRecords(adhocNamespace("mainnet"), {
      Resolver: [address("3"), 200],
      Registrar: [address("4"), 201],
    });
    const { table, changelog } = await render();
    expect(table).toContain(address("3"));
    expect(table).not.toContain(address("2"));
    expect(table).toContain(address("4"));
    expect(changelogRow(changelog, address("3"))).toContain("Current");
    expect(changelogRow(changelog, address("2"))).toContain("Replaced");
    expect(changelogRow(changelog, address("4"))).toContain("Current");
    expect(changelogRow(changelog, address("1"))).toBeUndefined();
  });

  it("keeps the migration's record when an ad-hoc one is older", async () => {
    writeRecords(adhocNamespace("mainnet"), {
      Resolver: [address("3"), 50],
    });
    const { table, changelog } = await render();
    expect(table).toContain(address("2"));
    expect(table).not.toContain(address("3"));
    expect(changelogRow(changelog, address("3"))).toContain("Replaced");
  });

  it("lists archived records as replaced, newest first", async () => {
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
    expect(changelogRow(changelog, address("6"))).toContain("Replaced");
    expect(changelogRow(changelog, address("5"))).toContain("Replaced");
  });

  it("leaves out an archive of a whole earlier deployment", async () => {
    writeRecords("mainnet-20260901-r1", { Resolver: [address("7"), 10] });
    const { table, changelog } = await render();
    expect(table).not.toContain(address("7"));
    expect(changelog).toBe("");
  });

  it("writes the same tables beside the records", async () => {
    writeRecords(adhocNamespace("mainnet"), {
      Resolver: [address("3"), 200],
    });
    const path = await writeNamespaceAddressTable({
      deploymentsDir,
      namespace: "mainnet",
    });
    expect(path).toBe(join(deploymentsDir, "mainnet", "addresses.md"));
    const [, changelog = ""] = (await Bun.file(path).text()).split(
      "## Changelog",
    );
    expect(changelogRow(changelog, address("3"))).toContain("Current");
  });
});

describe("loadCurrentAddresses", () => {
  it("returns the addresses of the main table, keyed by contract name", async () => {
    writeRecords(adhocNamespace("mainnet"), {
      Resolver: [address("3"), 200],
      Registrar: [address("4"), 201],
    });
    writeRecords("mainnet-redeploy-20261001", {
      Registry: [address("5"), 300],
    });
    expect(await loadCurrentAddresses(deploymentsDir, "mainnet")).toEqual({
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
