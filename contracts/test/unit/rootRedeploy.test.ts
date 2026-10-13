import { describe, expect, it } from "bun:test";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  archiveReplacedRecords,
  bytecodeWithoutMetadata,
  driftedReusedRecords,
  findRootArchive,
  namespaceBeforeRedeploy,
  readNamespaceRecords,
  REPLACED_DEPLOYMENTS,
  rootRedeployDiff,
  UR_IMPLEMENTATION_SCRIPT_ID,
} from "../../script/migrations/rootRedeploy.js";

const address = (n: number) =>
  `0x${n.toString(16).padStart(40, "0")}` as `0x${string}`;

// Creation bytecode with a metadata trailer whose last two bytes give the length
// the deploy tool strips: the metadata and those two bytes.
const withMetadata = (code: string, metadata: string): `0x${string}` =>
  `0x${code}${metadata}${(metadata.length / 2 + 2).toString(16).padStart(4, "0")}`;

function namespace(records: Record<string, object>) {
  const root = mkdtempSync(join(tmpdir(), "root-redeploy-"));
  const dir = join(root, "mainnet");
  mkdirSync(dir);
  for (const [name, record] of Object.entries(records)) {
    writeFileSync(join(dir, `${name}.json`), JSON.stringify(record));
  }
  writeFileSync(
    join(dir, ".migrations.json"),
    JSON.stringify({ [UR_IMPLEMENTATION_SCRIPT_ID]: 1, other: 2 }),
  );
  return root;
}

const deployed = (n: number, contractName = "PermissionedRegistry") => ({
  address: address(n),
  contractName,
  bytecode: withMetadata("6080", "aa"),
  transaction: { hash: "0x01" },
});

describe("bytecodeWithoutMetadata", () => {
  it("drops the metadata trailer the last two bytes measure", () => {
    expect(bytecodeWithoutMetadata(withMetadata("6080", "aabb"))).toBe(
      "0x6080",
    );
  });
});

describe("driftedReusedRecords", () => {
  const records = new Map(
    Object.entries({
      ETHRegistry: deployed(1),
      RootRegistry: deployed(2),
      Adopted: { address: address(3), contractName: "Other" },
    }),
  );

  it("passes a reused record that matches the build apart from metadata", () => {
    expect(
      driftedReusedRecords(records, () => withMetadata("6080", "bb")),
    ).toEqual([]);
  });

  it("flags a reused record whose code differs, but not a root-bound one", () => {
    const problems = driftedReusedRecords(records, () =>
      withMetadata("6081", "aa"),
    );
    expect(problems).toHaveLength(1);
    expect(problems[0]).toContain("ETHRegistry");
  });

  it("flags a reused record the build cannot compare", () => {
    expect(driftedReusedRecords(records, () => undefined)[0]).toContain(
      "the build has no PermissionedRegistry",
    );
  });
});

describe("archiveReplacedRecords", () => {
  it("moves only the root-bound records and forgets the resolver implementation script", () => {
    const root = namespace({
      ETHRegistry: deployed(1),
      RootRegistry: deployed(2),
      ENSV2Resolver: deployed(3, "ENSV2Resolver"),
    });
    const archive = archiveReplacedRecords(
      root,
      "mainnet",
      new Date("2026-10-12T00:00:00Z"),
    );
    expect(archive).toBe("mainnet-root-20261012");
    expect([...readNamespaceRecords(root, "mainnet").keys()]).toEqual([
      "ETHRegistry",
    ]);
    expect([...readNamespaceRecords(root, archive).keys()].sort()).toEqual([
      "ENSV2Resolver",
      "RootRegistry",
    ]);
    expect(
      JSON.parse(
        readFileSync(join(root, "mainnet", ".migrations.json"), "utf8"),
      ),
    ).toEqual({ other: 2 });
    expect(findRootArchive(root, "mainnet")).toBe(archive);

    // A second archive on the same day gets its own name.
    writeFileSync(
      join(root, "mainnet", "RootRegistry.json"),
      JSON.stringify(deployed(9)),
    );
    expect(
      archiveReplacedRecords(root, "mainnet", new Date("2026-10-12T00:00:00Z")),
    ).toBe("mainnet-root-20261012-r2");
    expect(existsSync(join(root, "mainnet", "RootRegistry.json"))).toBe(false);
  });
});

describe("rootRedeployDiff", () => {
  const before = new Map<string, { address?: `0x${string}` }>([
    ["ETHRegistry", { address: address(1) }],
    ...REPLACED_DEPLOYMENTS.map(
      (name, i) => [name, { address: address(100 + i) }] as const,
    ),
  ]);
  const replaced = new Map<string, { address?: `0x${string}` }>([
    ["ETHRegistry", { address: address(1) }],
    ...REPLACED_DEPLOYMENTS.map(
      (name, i) => [name, { address: address(200 + i) }] as const,
    ),
  ]);

  it("accepts every replaced contract at a new address and the rest kept", () => {
    const { replaced: moved, problems } = rootRedeployDiff(before, replaced);
    expect(problems).toEqual([]);
    expect(moved).toHaveLength(REPLACED_DEPLOYMENTS.length);
  });

  it("flags a replaced contract left in place and a reused one moved", () => {
    const after = new Map(replaced);
    after.set("RootRegistry", { address: address(100) });
    after.set("ETHRegistry", { address: address(7) });
    const { problems } = rootRedeployDiff(before, after);
    expect(problems).toEqual([
      `RootRegistry: still at ${address(100)}, not redeployed`,
      `ETHRegistry: moved from ${address(1)} to ${address(7)}`,
    ]);
  });

  it("expects nothing of a replaced contract the namespace never had", () => {
    const withoutHca = (records: typeof before) =>
      new Map(
        [...records].filter(
          ([name]) =>
            name !== "HCAOwnerAndSessionValidator" &&
            name !== "StandaloneHCAImplementation",
        ),
      );
    const { replaced: moved, problems } = rootRedeployDiff(
      withoutHca(before),
      withoutHca(replaced),
    );
    expect(problems).toEqual([]);
    expect(moved).toHaveLength(REPLACED_DEPLOYMENTS.length - 2);
  });
});

describe("namespaceBeforeRedeploy", () => {
  it("takes the replaced originals from the archive, even where an interrupted run replaced them", () => {
    const active = new Map([
      ["ETHRegistry", { address: address(1) }],
      // Already redeployed by an interrupted run.
      ["RootRegistry", { address: address(9) }],
    ]);
    const archived = new Map([["RootRegistry", { address: address(2) }]]);
    const before = namespaceBeforeRedeploy(active, archived);
    expect(before.get("RootRegistry")?.address).toBe(address(2));
    expect(before.get("ETHRegistry")?.address).toBe(address(1));
    expect(rootRedeployDiff(before, active).problems).not.toContain(
      `RootRegistry: still at ${address(9)}, not redeployed`,
    );
  });
});
