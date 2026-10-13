/// Replacing the v2 root registry under a live namespace.
///
/// The root registry is baked into every contract that takes it at construction, so
/// replacing it means redeploying those contracts too, while everything else, the
/// `.eth` registry and its reservations above all, is reused. The deploy tool reuses
/// a record when its creation bytecode (less the metadata hash) and constructor
/// arguments match the current build, and redeploys it otherwise. Moving the
/// replaced records out of the namespace therefore makes a resumed deploy rebuild
/// exactly those, provided nothing else has drifted from the build; this module
/// checks that, moves the records, and compares the namespace before and after.

import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  renameSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";

import type { Address } from "viem";

import { sameAddress } from "./plumbing.js";

/// The deployments a root registry redeploy replaces: the root itself, every
/// contract holding it as an immutable, and the contracts built on one of those;
/// and the HCA session validator, whose current build differs from the deployed
/// one, with the HCA implementation built over it, and the v2 registrar and the v1
/// renewer, whose payment recipient differs from the deployed ones. No account uses
/// any of them until the DAO approves the HCA implementation and authorizes the
/// renewer, and phase 6 authorizes the registrar.
export const REPLACED_DEPLOYMENTS = [
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
] as const;

/// The deploy script that only ever runs once per namespace and builds the
/// Universal Resolver implementation over the root; it is forgotten so it runs again.
export const UR_IMPLEMENTATION_SCRIPT_ID =
  "universal-resolver:deploy-universal-resolver-implementation:v1";

type DeploymentRecord = {
  address?: Address;
  contractName?: string;
  bytecode?: `0x${string}`;
  transaction?: unknown;
  receipt?: unknown;
};

/// Creation bytecode less its trailing metadata, the part the deploy tool compares.
/// The last two bytes give the metadata's length.
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

/// Records outside the replaced set whose creation bytecode differs from the
/// current build, and would therefore be redeployed rather than reused.
/// `currentBytecode` returns the build's creation bytecode for a contract name, or
/// undefined when the build has no such contract.
export function driftedReusedRecords(
  records: Map<string, DeploymentRecord>,
  currentBytecode: (contractName: string) => string | undefined,
): string[] {
  const replacedSet = new Set<string>(REPLACED_DEPLOYMENTS);
  const problems: string[] = [];
  for (const [name, record] of records) {
    if (replacedSet.has(name)) continue;
    // An adopted address has no deploy transaction here and is never redeployed.
    if (!record.transaction && !record.receipt) continue;
    if (!record.bytecode || !record.contractName) {
      problems.push(
        `${name}: the record carries no creation bytecode to compare`,
      );
      continue;
    }
    const built = currentBytecode(record.contractName);
    if (built === undefined) {
      problems.push(
        `${name}: the build has no ${record.contractName} to compare against`,
      );
      continue;
    }
    const length = Number.parseInt(record.bytecode.slice(-4), 16);
    if (
      bytecodeWithoutMetadata(record.bytecode, length) !==
      bytecodeWithoutMetadata(built, length)
    ) {
      problems.push(
        `${name}: its ${record.contractName} bytecode differs from the current build, so a deploy would replace it`,
      );
    }
  }
  return problems;
}

/// The archive namespace holding the records a root redeploy replaced, if one
/// exists: the newest `<namespace>-root-*` directory with a `RootRegistry` record.
export function findRootArchive(
  deploymentsDir: string,
  namespace: string,
): string | undefined {
  if (!existsSync(deploymentsDir)) return undefined;
  return readdirSync(deploymentsDir, { withFileTypes: true })
    .filter(
      (entry) =>
        entry.isDirectory() &&
        entry.name.startsWith(`${namespace}-root-`) &&
        existsSync(join(deploymentsDir, entry.name, "RootRegistry.json")),
    )
    .map((entry) => entry.name)
    .sort()
    .at(-1);
}

/// Moves the records a root redeploy replaces into a new archive namespace beside the active one,
/// and forgets the once-only Universal Resolver implementation script, so a resumed
/// deploy rebuilds them. The archive is a sibling namespace, so the deployment
/// check flags any record still pointing at an archived address. Returns the
/// archive's name.
export function archiveReplacedRecords(
  deploymentsDir: string,
  namespace: string,
  date: Date,
): string {
  const stamp = date.toISOString().slice(0, 10).replace(/-/g, "");
  let archive = `${namespace}-root-${stamp}`;
  for (
    let revision = 2;
    existsSync(join(deploymentsDir, archive));
    revision++
  ) {
    archive = `${namespace}-root-${stamp}-r${revision}`;
  }
  const source = join(deploymentsDir, namespace);
  const target = join(deploymentsDir, archive);
  mkdirSync(target, { recursive: true });
  for (const name of REPLACED_DEPLOYMENTS) {
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
    delete migrations[UR_IMPLEMENTATION_SCRIPT_ID];
    writeFileSync(migrationsFile, JSON.stringify(migrations));
  }
  return archive;
}

/// The namespace as it stood before a root redeploy: the archived originals of the
/// replaced deployments, which an interrupted run may already have replaced in the
/// namespace, and the namespace's own records for everything else.
export function namespaceBeforeRedeploy(
  active: Map<string, DeploymentRecord>,
  archived: Map<string, DeploymentRecord>,
): Map<string, DeploymentRecord> {
  const before = new Map(active);
  for (const name of REPLACED_DEPLOYMENTS) {
    const record = archived.get(name);
    if (record) before.set(name, record);
  }
  return before;
}

/// Compares the namespace after a root redeploy with the records before it: every
/// replaced deployment the namespace had must be at a new address, and every other
/// one where it was.
export function rootRedeployDiff(
  before: Map<string, DeploymentRecord>,
  after: Map<string, DeploymentRecord>,
): { replaced: string[]; problems: string[] } {
  const replacedSet = new Set<string>(REPLACED_DEPLOYMENTS);
  const replaced: string[] = [];
  const problems: string[] = [];
  for (const name of REPLACED_DEPLOYMENTS) {
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
