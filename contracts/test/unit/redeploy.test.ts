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
  buildBytecodes,
  bytecodeWithoutMetadata,
  CONTRACT_REDEPLOY_KIND,
  driftedRecords,
  driftedReusedRecords,
  findRedeployArchive,
  isInterruptedRedeploy,
  namespaceBeforeRedeploy,
  readNamespaceRecords,
  redeployDiff,
  ROOT_REDEPLOY,
  UR_IMPLEMENTATION_SCRIPT_ID,
  UR_V1_SCRIPT_ID,
  withDependents,
} from "../../script/migrations/redeploy.js";

const REPLACED_DEPLOYMENTS = ROOT_REDEPLOY.replaced;

const address = (n: number) =>
  `0x${n.toString(16).padStart(40, "0")}` as `0x${string}`;

// A solc metadata trailer, its IPFS hash filled with one repeated hex digit.
const metadataTrailer = (fill: string) =>
  `a264697066735822${fill.repeat(68)}64736f6c6343000819` + "0033";

// Creation bytecode ending in a metadata trailer, then any data the constructor
// reads, which solc places after it.
const withMetadata = (
  code: string,
  fill: string,
  dataAfter = "",
): `0x${string}` => `0x${code}${metadataTrailer(fill)}${dataAfter}`;

function namespace(records: Record<string, object>) {
  const root = mkdtempSync(join(tmpdir(), "redeploy-"));
  const dir = join(root, "mainnet");
  mkdirSync(dir);
  for (const [name, record] of Object.entries(records)) {
    writeFileSync(join(dir, `${name}.json`), JSON.stringify(record));
  }
  writeFileSync(
    join(dir, ".migrations.json"),
    JSON.stringify({
      [UR_IMPLEMENTATION_SCRIPT_ID]: 1,
      [UR_V1_SCRIPT_ID]: 3,
      other: 2,
    }),
  );
  return root;
}

const deployed = (
  n: number,
  contractName = "PermissionedRegistry",
  argsData: `0x${string}` = "0x",
) => ({
  address: address(n),
  contractName,
  bytecode: withMetadata("6080", "a"),
  argsData,
  transaction: { hash: "0x01" },
});

// Constructor arguments holding the given addresses, one ABI word each.
const argsHolding = (...addresses: `0x${string}`[]): `0x${string}` =>
  `0x${addresses.map((a) => a.slice(2).padStart(64, "0")).join("")}`;

describe("bytecodeWithoutMetadata", () => {
  it("drops the metadata trailer the last two bytes measure", () => {
    expect(bytecodeWithoutMetadata("0x6080aabb0004")).toBe("0x6080");
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
      driftedReusedRecords(
        records,
        () => withMetadata("6080", "b"),
        REPLACED_DEPLOYMENTS,
      ),
    ).toEqual([]);
  });

  it("flags a reused record whose code differs, but not a root-bound one", () => {
    const problems = driftedReusedRecords(
      records,
      () => withMetadata("6081", "a"),
      REPLACED_DEPLOYMENTS,
    );
    expect(problems).toHaveLength(1);
    expect(problems[0]).toContain("ETHRegistry");
  });

  it("flags a reused record the build cannot compare", () => {
    expect(
      driftedReusedRecords(records, () => undefined, REPLACED_DEPLOYMENTS)[0],
    ).toContain("the build has no PermissionedRegistry");
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
      ROOT_REDEPLOY,
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
    ).toEqual({ [UR_V1_SCRIPT_ID]: 3, other: 2 });
    expect(findRedeployArchive(root, "mainnet", ROOT_REDEPLOY)).toBe(archive);

    // A second archive on the same day gets its own name.
    writeFileSync(
      join(root, "mainnet", "RootRegistry.json"),
      JSON.stringify(deployed(9)),
    );
    expect(
      archiveReplacedRecords(
        root,
        "mainnet",
        new Date("2026-10-12T00:00:00Z"),
        ROOT_REDEPLOY,
      ),
    ).toBe("mainnet-root-20261012-r2");
    expect(existsSync(join(root, "mainnet", "RootRegistry.json"))).toBe(false);
  });
});

describe("redeployDiff", () => {
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
    const { replaced: moved, problems } = redeployDiff(
      before,
      replaced,
      REPLACED_DEPLOYMENTS,
    );
    expect(problems).toEqual([]);
    expect(moved).toHaveLength(REPLACED_DEPLOYMENTS.length);
  });

  it("flags a replaced contract left in place and a reused one moved", () => {
    const after = new Map(replaced);
    after.set("RootRegistry", { address: address(100) });
    after.set("ETHRegistry", { address: address(7) });
    const { problems } = redeployDiff(before, after, REPLACED_DEPLOYMENTS);
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
    const { replaced: moved, problems } = redeployDiff(
      withoutHca(before),
      withoutHca(replaced),
      REPLACED_DEPLOYMENTS,
    );
    expect(problems).toEqual([]);
    expect(moved).toHaveLength(REPLACED_DEPLOYMENTS.length - 2);
  });
});

describe("isInterruptedRedeploy", () => {
  const archived = new Map([
    ["LockedMigrationController", { address: address(2) }],
    ["MigrationHelper", { address: address(3) }],
  ]);

  it("finds a completed archive finished, so a new run starts from the namespace", () => {
    const active = new Map([
      ["LockedMigrationController", { address: address(12) }],
      ["MigrationHelper", { address: address(13) }],
    ]);
    expect(isInterruptedRedeploy(active, archived)).toBe(false);
    expect(isInterruptedRedeploy(active, new Map())).toBe(false);
  });

  it("finds an archive interrupted where a record has no replacement or kept its address", () => {
    const missing = new Map([
      ["LockedMigrationController", { address: address(12) }],
    ]);
    const unchanged = new Map([
      ["LockedMigrationController", { address: address(12) }],
      ["MigrationHelper", { address: address(3) }],
    ]);
    expect(isInterruptedRedeploy(missing, archived)).toBe(true);
    expect(isInterruptedRedeploy(unchanged, archived)).toBe(true);
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
    const before = namespaceBeforeRedeploy(
      active,
      archived,
      REPLACED_DEPLOYMENTS,
    );
    expect(before.get("RootRegistry")?.address).toBe(address(2));
    expect(before.get("ETHRegistry")?.address).toBe(address(1));
    expect(
      redeployDiff(before, active, REPLACED_DEPLOYMENTS).problems,
    ).not.toContain(`RootRegistry: still at ${address(9)}, not redeployed`);
  });
});

describe("driftedRecords", () => {
  it("tells a change only inside an embedded metadata trailer from a code change", () => {
    const factoryCode = (fill: string) =>
      withMetadata(`6080${metadataTrailer(fill)}6001`, "a");
    const records = new Map(
      Object.entries({
        Factory: { ...deployed(1, "Factory"), bytecode: factoryCode("1") },
      }),
    );
    expect(driftedRecords(records, () => factoryCode("2"))).toEqual({
      drifted: [],
      metadataOnly: ["Factory"],
      uncomparable: [],
    });
    expect(
      driftedReusedRecords(records, () => factoryCode("2"), []),
    ).toHaveLength(1);
  });

  it("names the records whose code differs and those the build cannot compare", () => {
    const records = new Map(
      Object.entries({
        Same: deployed(1, "Same"),
        Changed: deployed(2, "Changed"),
        Missing: deployed(3, "Missing"),
        Adopted: { address: address(4), contractName: "Changed" },
      }),
    );
    const builds: Record<string, `0x${string}`> = {
      Same: withMetadata("6080", "b"),
      Changed: withMetadata("6081", "a"),
    };
    const { drifted, metadataOnly, uncomparable } = driftedRecords(
      records,
      (name) => builds[name],
    );
    expect(drifted).toEqual(["Changed"]);
    expect(metadataOnly).toEqual([]);
    expect(uncomparable).toEqual([
      {
        name: "Missing",
        reason: "the build has no Missing to compare against",
      },
    ]);
  });

  // A constructor that reads a constant leaves it after the trailer, so the last
  // two bytes are not the trailer's length and the deploy tool's slice is empty.
  const constructorData = "88".repeat(64);

  it("sees a code change when constructor data follows the trailer", () => {
    const records = new Map(
      Object.entries({
        Registry: {
          ...deployed(1, "Registry"),
          bytecode: withMetadata("6080", "a", constructorData),
        },
      }),
    );
    const built = withMetadata("6081", "a", constructorData);
    expect(bytecodeWithoutMetadata(records.get("Registry")!.bytecode)).toBe(
      bytecodeWithoutMetadata(built),
    );
    expect(driftedRecords(records, () => built).drifted).toEqual(["Registry"]);
    expect(driftedReusedRecords(records, () => built, [])[0]).toContain(
      "Registry",
    );
  });

  it("passes such a contract when only its trailer differs", () => {
    const records = new Map(
      Object.entries({
        Registry: {
          ...deployed(1, "Registry"),
          bytecode: withMetadata("6080", "a", constructorData),
        },
      }),
    );
    expect(
      driftedRecords(records, () => withMetadata("6080", "b", constructorData)),
    ).toEqual({ drifted: [], metadataOnly: [], uncomparable: [] });
  });

  it("compares a record with the build of the same source only", () => {
    const records = new Map(
      Object.entries({
        Proxy: {
          ...deployed(1, "ERC1967Proxy"),
          sourceName: "solc_0.8/proxy/ERC1967Proxy.sol",
        },
      }),
    );
    const builds: Record<string, `0x${string}`> = {
      "solc_0.8/proxy/ERC1967Proxy.sol": withMetadata("6080", "b"),
      "lib/proxy/ERC1967Proxy.sol": withMetadata("6081", "b"),
    };
    expect(
      driftedRecords(records, (_, sourceName) => builds[sourceName!]),
    ).toEqual({ drifted: [], metadataOnly: [], uncomparable: [] });
  });
});

describe("buildBytecodes", () => {
  // Generated artifacts export `Artifact_<name>`; the deploy tool's bundled proxy
  // artifacts export the artifact as default.
  function artifactDirs() {
    const root = mkdtempSync(join(tmpdir(), "artifacts-"));
    const generated = join(root, "generated");
    const proxyArtifacts = join(root, "proxy");
    mkdirSync(join(generated, "src/Thing.sol"), { recursive: true });
    mkdirSync(proxyArtifacts);
    const artifact = (sourceName: string, bytecode: string) =>
      JSON.stringify({ sourceName, bytecode });
    writeFileSync(
      join(generated, "ERC1967Proxy.ts"),
      `export const Artifact_ERC1967Proxy = ${artifact("lib/proxy/ERC1967Proxy.sol", "0x01")};`,
    );
    writeFileSync(
      join(generated, "Thing.ts"),
      `export const Artifact_Thing = ${artifact("src/Other.sol", "0x02")};`,
    );
    writeFileSync(
      join(generated, "src/Thing.sol/Thing.ts"),
      `export const Artifact_Thing = ${artifact("src/Thing.sol", "0x03")};`,
    );
    writeFileSync(
      join(proxyArtifacts, "ERC1967Proxy.js"),
      `export default ${artifact("solc_0.8/proxy/ERC1967Proxy.sol", "0x04")};`,
    );
    return { generated, proxyArtifacts };
  }

  const record = (contractName: string, sourceName: string) => ({
    ...deployed(1, contractName),
    sourceName,
  });

  it("reads each record's contract from the artifact of its own source", async () => {
    const bytecodes = await buildBytecodes(
      new Map(
        Object.entries({
          OurProxy: record("ERC1967Proxy", "lib/proxy/ERC1967Proxy.sol"),
          ToolProxy: record("ERC1967Proxy", "solc_0.8/proxy/ERC1967Proxy.sol"),
          Thing: record("Thing", "src/Thing.sol"),
        }),
      ),
      artifactDirs(),
    );
    expect(bytecodes("ERC1967Proxy", "lib/proxy/ERC1967Proxy.sol")).toBe(
      "0x01",
    );
    expect(bytecodes("ERC1967Proxy", "solc_0.8/proxy/ERC1967Proxy.sol")).toBe(
      "0x04",
    );
    expect(bytecodes("Thing", "src/Thing.sol")).toBe("0x03");
  });

  it("has nothing for a source the build does not hold", async () => {
    const bytecodes = await buildBytecodes(
      new Map(Object.entries({ Thing: record("Thing", "src/Gone.sol") })),
      artifactDirs(),
    );
    expect(bytecodes("Thing", "src/Gone.sol")).toBeUndefined();
  });
});

describe("withDependents", () => {
  const records = new Map(
    Object.entries({
      Resolver: deployed(1, "Resolver"),
      Kept: deployed(2, "Kept"),
      Wrapper: deployed(3, "Wrapper", argsHolding(address(1), address(2))),
      Controller: deployed(4, "Controller", argsHolding(address(3))),
      Helper: deployed(5, "Helper", argsHolding(address(4))),
      Unrelated: deployed(6, "Unrelated", argsHolding(address(9))),
      Adopted: { address: address(7), argsData: argsHolding(address(1)) },
    }),
  );

  it("adds every record built over a replaced one, transitively", () => {
    expect(withDependents(records, ["Resolver"])).toEqual([
      "Controller",
      "Helper",
      "Resolver",
      "Wrapper",
    ]);
  });

  it("never adds a kept record or an adopted one", () => {
    const kept = new Map(records);
    kept.set("Kept", deployed(2, "Kept", argsHolding(address(1))));
    expect(withDependents(kept, ["Resolver"], ["Kept"])).not.toContain("Kept");
    expect(withDependents(records, ["Resolver"])).not.toContain("Adopted");
  });

  it("adds nothing when nothing is replaced", () => {
    expect(withDependents(records, [])).toEqual([]);
  });
});

describe("contract redeploy archives", () => {
  it("archives the set under its own kind and forgets the once-only scripts it rebuilds", () => {
    const root = namespace({
      ETHRegistry: deployed(1),
      UniversalResolverV1: deployed(2, "UniversalResolverV1"),
      UniversalResolverV2: deployed(3, "UniversalResolverV2"),
    });
    const set = {
      kind: CONTRACT_REDEPLOY_KIND,
      replaced: ["UniversalResolverV1", "UniversalResolverV2"],
    };
    const archive = archiveReplacedRecords(
      root,
      "mainnet",
      new Date("2026-10-16T00:00:00Z"),
      set,
    );
    expect(archive).toBe("mainnet-redeploy-20261016");
    expect(findRedeployArchive(root, "mainnet", set)).toBe(archive);
    expect(findRedeployArchive(root, "mainnet", ROOT_REDEPLOY)).toBeUndefined();
    expect(
      JSON.parse(
        readFileSync(join(root, "mainnet", ".migrations.json"), "utf8"),
      ),
    ).toEqual({ other: 2 });
  });
});
