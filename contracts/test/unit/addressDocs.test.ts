import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  adhocNamespace,
  baseNamespace,
  generateAddressMarkdown,
  writeNamespaceAddressTable,
} from "../../script/addressDocs.js";

const MAIN = "0x1111111111111111111111111111111111111111";
const ADHOC = "0x2222222222222222222222222222222222222222";
const ARCHIVED = "0x3333333333333333333333333333333333333333";

let root: string;
let deploymentsDir: string;
let outDir: string;

function writeRecords(namespace: string, records: Record<string, string>) {
  const dir = join(deploymentsDir, namespace);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, ".chain"), JSON.stringify({ chainId: "1" }));
  for (const [name, address] of Object.entries(records)) {
    writeFileSync(
      join(dir, `${name}.json`),
      JSON.stringify({ address, abi: [] }),
    );
  }
}

async function render(): Promise<string> {
  const path = await generateAddressMarkdown({
    deploymentsDir,
    namespace: "mainnet",
    outDir,
  });
  return Bun.file(path).text();
}

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "address-docs-"));
  deploymentsDir = join(root, "deployments");
  outDir = join(root, "docs");
  writeRecords("mainnet", { Resolver: MAIN });
});

afterEach(() => rmSync(root, { recursive: true, force: true }));

describe("ad-hoc deployments in the address pages", () => {
  it("lists the ad-hoc namespace in its own section after the main table", async () => {
    writeRecords(adhocNamespace("mainnet"), { Resolver: ADHOC });
    const doc = await render();
    const section = doc.indexOf("## Ad-hoc deployments");
    expect(section).toBeGreaterThan(doc.indexOf(MAIN));
    expect(doc.indexOf(ADHOC)).toBeGreaterThan(section);
    expect(doc).toContain(`https://etherscan.io/address/${ADHOC}`);
  });

  it("leaves the section out when there is no ad-hoc namespace", async () => {
    expect(await render()).not.toContain("Ad-hoc deployments");
  });

  it("leaves out an archive of replaced ad-hoc records", async () => {
    writeRecords(`${adhocNamespace("mainnet")}-redeploy-20261101`, {
      Resolver: ARCHIVED,
    });
    const doc = await render();
    expect(doc).not.toContain("Ad-hoc deployments");
    expect(doc).not.toContain(ARCHIVED);
  });

  it("includes the section in the table beside the records", async () => {
    writeRecords(adhocNamespace("mainnet"), { Resolver: ADHOC });
    const path = await writeNamespaceAddressTable({
      deploymentsDir,
      namespace: "mainnet",
    });
    expect(path).toBe(join(deploymentsDir, "mainnet", "addresses.md"));
    expect(await Bun.file(path).text()).toContain(ADHOC);
  });
});

describe("baseNamespace", () => {
  it("strips the ad-hoc suffix and keeps any other namespace", () => {
    expect(baseNamespace(adhocNamespace("sepolia"))).toBe("sepolia");
    expect(baseNamespace("sepolia-fork")).toBe("sepolia-fork");
  });
});
