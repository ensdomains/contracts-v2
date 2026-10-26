/// Replacing deployed v2 contracts under a live namespace.
///
/// The deploy tool reuses a record when its creation bytecode (less the metadata
/// hash) and constructor arguments match the current build, and redeploys it
/// otherwise. It cannot see a code change in a contract whose constructor leaves
/// data after the metadata, and keeps such a record whatever its code. Moving the
/// replaced records out of the namespace therefore makes a resumed deploy rebuild
/// exactly those, provided nothing else has drifted from the build; this module
/// works out and checks that set, moves the records, and compares the namespace
/// before and after.
///
/// Two kinds of redeploy share it. A root registry redeploy replaces the root and
/// every contract built over it, a fixed set. A contract redeploy replaces whatever
/// the build has changed, with every contract that holds one of those as a
/// constructor argument.

import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  renameSync,
  writeFileSync,
} from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import type { Address } from "viem";

import { isProxyArtifact } from "../addressDocs.js";
import { sameAddress } from "./plumbing.js";

/// The deploy script that only ever runs once per namespace and builds the
/// Universal Resolver implementation over the root.
export const UR_IMPLEMENTATION_SCRIPT_ID =
  "universal-resolver:deploy-universal-resolver-implementation:v1";

/// The deploy script that only ever runs once per namespace and builds the
/// standalone Universal Resolver over the v1 registry.
export const UR_V1_SCRIPT_ID =
  "universal-resolver:deploy-universal-resolver-v1:v1";

/// Deployments built by a once-only deploy script, with that script's id. A
/// redeploy that replaces one must forget the script so it runs again.
export const ONCE_ONLY_SCRIPT_IDS: Readonly<Record<string, string>> = {
  UniversalResolverV2: UR_IMPLEMENTATION_SCRIPT_ID,
  UniversalResolverV1: UR_V1_SCRIPT_ID,
};

/// What one redeploy replaces, and where it archives the replaced records: a
/// `<namespace>-<kind>-<date>` namespace beside the active one. `marker` is a
/// record every archive of this kind holds, which tells it apart from other
/// directories with the same prefix.
export type RedeploySet = {
  kind: string;
  replaced: readonly string[];
  marker?: string;
};

/// The deployments a root registry redeploy replaces: the root itself, every
/// contract holding it as an immutable, and the contracts built on one of those;
/// and the HCA session validator, whose build differed from the deployed one when
/// the root was first replaced, with the HCA implementation built over it, and the
/// v2 registrar and the v1 renewer, whose payment recipient differed from the
/// deployed ones. No account uses any of them until the DAO approves the HCA
/// implementation and authorizes the renewer, and phase 6 authorizes the registrar.
export const ROOT_REDEPLOY: RedeploySet = {
  kind: "root",
  marker: "RootRegistry",
  replaced: [
    "RootRegistry",
    "RootBatchRegistrar",
    "ENSV2Resolver",
    "UniversalResolverV2",
    "UniversalHelper",
    "DNSTLDResolver",
    "DNSAliasResolver",
    "PublicResolverV2",
    "WrapperRegistryImpl",
    "LockedMigrationController",
    "MigrationHelper",
    "HCAOwnerAndSessionValidator",
    "StandaloneHCAImplementation",
    "ETHRegistrar",
    "ETHRenewerV1",
  ],
};

/// The archive kind of a contract redeploy.
export const CONTRACT_REDEPLOY_KIND = "redeploy";

type DeploymentRecord = {
  address?: Address;
  contractName?: string;
  sourceName?: string;
  bytecode?: `0x${string}`;
  argsData?: `0x${string}`;
  transaction?: unknown;
  receipt?: unknown;
};

/// Creation bytecode less its trailing metadata, the part the deploy tool compares.
/// The last two bytes give the metadata's length. A constructor that reads a
/// constant leaves that constant after the trailer, so for such a contract the
/// length is meaningless: the slice leaves nothing on either side, and the deploy
/// tool keeps the record whatever its code.
export function bytecodeWithoutMetadata(
  bytecode: string,
  metadataLength = Number.parseInt(bytecode.slice(-4), 16),
): string {
  return bytecode.slice(0, -metadataLength * 2);
}

/// The record files of a namespace, by deployment name.
export function readNamespaceRecords(
  deploymentsDir: string,
  namespace: string,
): Map<string, DeploymentRecord> {
  const dir = join(deploymentsDir, namespace);
  const records = new Map<string, DeploymentRecord>();
  if (!existsSync(dir)) return records;
  for (const file of readdirSync(dir)) {
    if (!file.endsWith(".json") || file.startsWith(".")) continue;
    records.set(
      file.slice(0, -".json".length),
      JSON.parse(readFileSync(join(dir, file), "utf8")) as DeploymentRecord,
    );
  }
  return records;
}

// A solc metadata trailer: the CBOR map of the IPFS hash and the compiler version,
// then its two-byte length. Code that creates other contracts embeds theirs too.
const METADATA_TRAILER =
  /a264697066735822[0-9a-f]{68}64736f6c6343[0-9a-f]{6}0033/gi;

/// Bytecode with every embedded metadata trailer removed, not only the last.
export function bytecodeWithoutAnyMetadata(bytecode: string): string {
  return bytecode.replace(METADATA_TRAILER, "");
}

// An adopted address has no deploy transaction here and is never redeployed.
const isAdopted = (record: DeploymentRecord) =>
  !record.transaction && !record.receipt;

/// Looks up the build's creation bytecode for a contract, by its name and the
/// source file that defines it.
export type BuildBytecodes = (
  contractName: string,
  sourceName?: string,
) => string | undefined;

/// Where the build's creation bytecode is read from: the generated artifacts, and
/// the proxy code the deploy tool bundles and deploys for `deployViaProxy`.
export type ArtifactDirs = { generated: string; proxyArtifacts: string };

/// The artifact directories of this checkout.
export function defaultArtifactDirs(): ArtifactDirs {
  return {
    generated: resolve(import.meta.dirname, "../../generated/artifacts"),
    proxyArtifacts: join(
      dirname(fileURLToPath(import.meta.resolve("@rocketh/proxy"))),
      "hardhat-deploy-v1-artifacts",
    ),
  };
}

/// The build's creation bytecode for every contract the records name. An artifact
/// counts only when it comes from the record's source file, since two sources can
/// define contracts of the same name: the deploy tool's own proxy and the one in
/// our build are both `ERC1967Proxy`. A contract neither directory has from that
/// source has no bytecode.
export async function buildBytecodes(
  records: Map<string, DeploymentRecord>,
  dirs: ArtifactDirs = defaultArtifactDirs(),
): Promise<BuildBytecodes> {
  const key = (contractName: string, sourceName?: string) =>
    `${sourceName ?? ""}:${contractName}`;
  const builds = new Map<string, string | undefined>();
  for (const { contractName, sourceName } of records.values()) {
    if (!contractName || builds.has(key(contractName, sourceName))) continue;
    const generated = (...path: string[]) => ({
      file: join(dirs.generated, ...path, `${contractName}.ts`),
      exportName: `Artifact_${contractName}`,
    });
    const candidates = [
      ...(sourceName ? [generated(sourceName)] : []),
      generated(),
      {
        file: join(dirs.proxyArtifacts, `${contractName}.js`),
        exportName: "default",
      },
    ];
    let bytecode: string | undefined;
    for (const { file, exportName } of candidates) {
      if (!existsSync(file)) continue;
      const artifact = (await import(file))[exportName] as
        | { sourceName?: string; bytecode?: string }
        | undefined;
      if (
        artifact?.bytecode &&
        (!sourceName || artifact.sourceName === sourceName)
      ) {
        bytecode = artifact.bytecode;
        break;
      }
    }
    builds.set(key(contractName, sourceName), bytecode);
  }
  return (contractName, sourceName) =>
    builds.get(key(contractName, sourceName));
}

/// The deployed records whose code differs from the current build, and those the
/// deploy tool would redeploy although their code is the same. A record has
/// `drifted` when its creation bytecode differs from the build with every metadata
/// trailer removed, wherever each sits. It is `metadataOnly` when the code is the
/// same but the deploy tool's own comparison, which measures the last trailer from
/// the end, still finds a difference: an embedded trailer differs, such as that of
/// a contract the code creates, which a build changes whenever its compiler
/// settings do. Also the records the build cannot compare, each with the reason.
export function driftedRecords(
  records: Map<string, DeploymentRecord>,
  currentBytecode: BuildBytecodes,
): {
  drifted: string[];
  metadataOnly: string[];
  uncomparable: Array<{ name: string; reason: string }>;
} {
  const drifted: string[] = [];
  const metadataOnly: string[] = [];
  const uncomparable: Array<{ name: string; reason: string }> = [];
  for (const [name, record] of records) {
    if (isAdopted(record)) continue;
    if (!record.bytecode || !record.contractName) {
      uncomparable.push({
        name,
        reason: "the record carries no creation bytecode to compare",
      });
      continue;
    }
    const built = currentBytecode(record.contractName, record.sourceName);
    if (built === undefined) {
      uncomparable.push({
        name,
        reason: `the build has no ${record.contractName} to compare against`,
      });
      continue;
    }
    if (
      bytecodeWithoutAnyMetadata(record.bytecode) !==
      bytecodeWithoutAnyMetadata(built)
    ) {
      drifted.push(name);
      continue;
    }
    // The deploy tool slices the build by the record's trailer length.
    const length = Number.parseInt(record.bytecode.slice(-4), 16);
    if (
      bytecodeWithoutMetadata(record.bytecode, length) !==
      bytecodeWithoutMetadata(built, length)
    ) {
      metadataOnly.push(name);
    }
  }
  return { drifted, metadataOnly, uncomparable };
}

/// Records outside `replaced` that a deploy would not leave matching the current
/// build: those whose code differs, which it may replace or, when it cannot see the
/// change, keep as they are, and those it would replace although only a metadata
/// trailer differs.
export function driftedReusedRecords(
  records: Map<string, DeploymentRecord>,
  currentBytecode: BuildBytecodes,
  replaced: readonly string[],
): string[] {
  const replacedSet = new Set(replaced);
  const { drifted, metadataOnly, uncomparable } = driftedRecords(
    records,
    currentBytecode,
  );
  return [
    ...uncomparable
      .filter(({ name }) => !replacedSet.has(name))
      .map(({ name, reason }) => `${name}: ${reason}`),
    ...drifted
      .filter((name) => !replacedSet.has(name))
      .map(
        (name) =>
          `${name}: its ${records.get(name)?.contractName} code differs from the current build`,
      ),
    ...metadataOnly
      .filter((name) => !replacedSet.has(name))
      .map(
        (name) =>
          `${name}: its ${records.get(name)?.contractName} bytecode differs from the current build only in a metadata trailer, yet a deploy would replace it`,
      ),
  ];
}

/// `replaced` grown by every deployed record whose constructor arguments name the
/// address of a record in the set, until no more join: the deploy tool redeploys
/// a contract whose arguments change. Records in `keep` never join, since their
/// deploy scripts reuse what is recorded.
export function withDependents(
  records: Map<string, DeploymentRecord>,
  replaced: Iterable<string>,
  keep: Iterable<string> = [],
): string[] {
  const set = new Set(replaced);
  const kept = new Set(keep);
  for (let grew = true; grew; ) {
    grew = false;
    const addresses = [...set].flatMap((name) => {
      const address = records.get(name)?.address;
      return address ? [address.slice(2).toLowerCase()] : [];
    });
    for (const [name, record] of records) {
      if (set.has(name) || kept.has(name) || isAdopted(record)) continue;
      const args = record.argsData?.toLowerCase() ?? "";
      if (addresses.some((address) => args.includes(address))) {
        set.add(name);
        grew = true;
      }
    }
  }
  return [...set].sort();
}

/// The newest archive namespace of `kind`, if one exists.
export function findRedeployArchive(
  deploymentsDir: string,
  namespace: string,
  set: Pick<RedeploySet, "kind" | "marker">,
): string | undefined {
  return findRedeployArchives(deploymentsDir, namespace, set).at(-1);
}

/// Every archive namespace of `kind`, oldest first: each `<namespace>-<kind>-*`
/// directory holding the kind's marker record, or any record when the kind has none.
export function findRedeployArchives(
  deploymentsDir: string,
  namespace: string,
  set: Pick<RedeploySet, "kind" | "marker">,
): string[] {
  if (!existsSync(deploymentsDir)) return [];
  const holdsRecords = (dir: string) =>
    set.marker
      ? existsSync(join(dir, `${set.marker}.json`))
      : readdirSync(dir).some(
          (file) => file.endsWith(".json") && !file.startsWith("."),
        );
  return readdirSync(deploymentsDir, { withFileTypes: true })
    .filter(
      (entry) =>
        entry.isDirectory() &&
        entry.name.startsWith(`${namespace}-${set.kind}-`) &&
        holdsRecords(join(deploymentsDir, entry.name)),
    )
    .map((entry) => entry.name)
    .sort();
}

/// Moves the records `set` replaces into a new archive namespace beside the active
/// one, and forgets the once-only deploy scripts that built any of them, so a
/// resumed deploy rebuilds them. The archive is a sibling namespace, so the
/// deployment check flags any record still pointing at an archived address.
/// Returns the archive's name.
export function archiveReplacedRecords(
  deploymentsDir: string,
  namespace: string,
  date: Date,
  set: RedeploySet,
): string {
  const stamp = date.toISOString().slice(0, 10).replace(/-/g, "");
  let archive = `${namespace}-${set.kind}-${stamp}`;
  for (
    let revision = 2;
    existsSync(join(deploymentsDir, archive));
    revision++
  ) {
    archive = `${namespace}-${set.kind}-${stamp}-r${revision}`;
  }
  const source = join(deploymentsDir, namespace);
  const target = join(deploymentsDir, archive);
  mkdirSync(target, { recursive: true });
  for (const name of set.replaced) {
    const file = `${name}.json`;
    if (existsSync(join(source, file))) {
      renameSync(join(source, file), join(target, file));
    }
  }
  const chainFile = join(source, ".chain");
  if (existsSync(chainFile)) {
    writeFileSync(join(target, ".chain"), readFileSync(chainFile));
  }
  const migrationsFile = join(source, ".migrations.json");
  if (existsSync(migrationsFile)) {
    const migrations = JSON.parse(
      readFileSync(migrationsFile, "utf8"),
    ) as Record<string, number>;
    for (const name of set.replaced) {
      const id = ONCE_ONLY_SCRIPT_IDS[name];
      if (id) delete migrations[id];
    }
    writeFileSync(migrationsFile, JSON.stringify(migrations));
  }
  return archive;
}

/// Whether an archive holds a redeploy that stopped part way: one of its records
/// has no replacement at a new address in the namespace. A completed archive holds
/// what an earlier run replaced.
export function isInterruptedRedeploy(
  active: Map<string, DeploymentRecord>,
  archived: Map<string, DeploymentRecord>,
): boolean {
  return [...archived].some(([name, record]) => {
    const now = active.get(name)?.address;
    return !now || (!!record.address && sameAddress(now, record.address));
  });
}

/// The namespace as it stood before a redeploy: the archived originals of the
/// replaced deployments, which an interrupted run may already have replaced in the
/// namespace, and the namespace's own records for everything else.
export function namespaceBeforeRedeploy(
  active: Map<string, DeploymentRecord>,
  archived: Map<string, DeploymentRecord>,
  replaced: readonly string[],
): Map<string, DeploymentRecord> {
  const before = new Map(active);
  for (const name of replaced) {
    const record = archived.get(name);
    if (record) before.set(name, record);
  }
  return before;
}

/// Compares the namespace after a redeploy with the records before it: every
/// replaced deployment the namespace had must be at a new address, and every other
/// one where it was. A replaced deployment that is now behind a proxy brings its
/// proxy and implementation records, which count as replaced with it.
export function redeployDiff(
  before: Map<string, DeploymentRecord>,
  after: Map<string, DeploymentRecord>,
  replacedNames: readonly string[],
): { replaced: string[]; problems: string[] } {
  const replacedSet = new Set(replacedNames);
  const replaced: string[] = [];
  const problems: string[] = [];
  for (const name of replacedNames) {
    const old = before.get(name)?.address;
    const now = after.get(name)?.address;
    if (!old && !now) continue;
    if (!now) {
      problems.push(`${name}: no record after the redeploy`);
    } else if (old && sameAddress(old, now)) {
      problems.push(`${name}: still at ${now}, not redeployed`);
    } else {
      replaced.push(`${name}: ${old ?? "(none)"} -> ${now}`);
    }
  }
  for (const [name, record] of after) {
    if (replacedSet.has(name)) continue;
    const old = before.get(name)?.address;
    if (isProxyArtifact(name, replacedSet)) {
      if (!old || !record.address || !sameAddress(old, record.address)) {
        replaced.push(`${name}: ${old ?? "(none)"} -> ${record.address}`);
      }
      continue;
    }
    if (!old) {
      problems.push(`${name}: new record at ${record.address}`);
    } else if (!record.address || !sameAddress(old, record.address)) {
      problems.push(`${name}: moved from ${old} to ${record.address}`);
    }
  }
  for (const name of before.keys()) {
    if (!replacedSet.has(name) && !after.has(name)) {
      problems.push(`${name}: record missing after the redeploy`);
    }
  }
  return { replaced, problems };
}
