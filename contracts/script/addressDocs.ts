import { loadDeploymentsFromFiles } from "@rocketh/node";
import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { type Address, getAddress, numberToHex } from "viem";
import type { RpcProvider } from "./migrations/plumbing.js";
import { isRecordArchiveOf } from "./migrations/redeploy.js";

const DEFAULT_DOCS_DIR = fileURLToPath(
  new URL("../docs/addresses", import.meta.url),
);

/// Block explorer base URLs keyed by chain id. Chains absent from this map
/// render plain (unlinked) addresses.
const EXPLORER_BASE: Record<number, string> = {
  1: "https://etherscan.io",
  11155111: "https://sepolia.etherscan.io",
};

export interface ContractEntry {
  name: string;
  address: string;
}

/// True for `<Base>_Implementation` / `<Base>_Proxy` artifacts whose `<Base>`
/// deployment also exists, so the proxy chain collapses to its canonical entry.
export function isProxyArtifact(name: string, names: Set<string>): boolean {
  for (const suffix of ["_Implementation", "_Proxy"]) {
    if (name.endsWith(suffix) && names.has(name.slice(0, -suffix.length))) {
      return true;
    }
  }
  return false;
}

/// Build the canonical, sorted list of contracts for a deployment namespace:
/// proxy implementation/proxy artifacts and entries without an address are
/// dropped, the remainder sorted alphabetically by name.
export function loadContractEntries(
  deployments: Record<string, unknown>,
): ContractEntry[] {
  const names = new Set(Object.keys(deployments));
  return Object.entries(deployments)
    .map(([name, deployment]) => ({
      name,
      address: (deployment as { address?: string }).address ?? "",
    }))
    .filter(({ name, address }) => address && !isProxyArtifact(name, names))
    .sort((a, b) => a.name.localeCompare(b.name));
}

/// Etherscan address URL for a chain, or `null` when the chain is unknown.
export function explorerUrl(chainId: number, address: string): string | null {
  const base = EXPLORER_BASE[chainId];
  return base ? `${base}/address/${address}` : null;
}

/// Looks up the time a block was mined, in seconds since the Unix epoch.
export type BlockTimeLookup = (block: bigint) => Promise<bigint>;

/// Block times read from a chain through its RPC. Each block is read once, so
/// the lookup can be shared by every page written from the same records.
export function rpcBlockTimes(provider: RpcProvider): BlockTimeLookup {
  const times = new Map<bigint, Promise<bigint>>();
  const read = async (block: bigint) => {
    const result = (await provider.request({
      method: "eth_getBlockByNumber",
      params: [numberToHex(block), false],
    })) as { timestamp?: string } | null;
    if (!result?.timestamp) throw new Error(`the RPC has no block ${block}`);
    return BigInt(result.timestamp);
  };
  return (block) => {
    let time = times.get(block);
    if (!time) {
      time = read(block);
      times.set(block, time);
    }
    return time;
  };
}

/// Markdown deploy-time cell: the UTC time the block was mined, linked to the
/// block on the explorer when the chain is known, or a dash when the record
/// carries no block.
function deployedCell(
  chainId: number | undefined,
  block: bigint | undefined,
  time: bigint | undefined,
) {
  if (block === undefined || time === undefined) return "—";
  const text = new Date(Number(time) * 1000)
    .toISOString()
    .replace("T", " ")
    .replace(/\.\d{3}Z$/, "");
  const base = chainId === undefined ? undefined : EXPLORER_BASE[chainId];
  return base ? `[${text}](${base}/block/${block})` : text;
}

/// Markdown address cell: an explorer link when the chain is known, otherwise
/// the plain address.
function addressCell(chainId: number | undefined, address: string): string {
  const url = chainId === undefined ? null : explorerUrl(chainId, address);
  return url ? `[${address}](${url})` : address;
}

/// Render rows as a markdown table. The first row is the header; the separator
/// is supplied here so callers pass content only.
export function markdownTable(rows: string[][]): string {
  const [header, ...body] = rows;
  return [header, header.map(() => "---"), ...body]
    .map((row) => `| ${row.join(" | ")} |`)
    .join("\n");
}

function formatTable(
  contracts: ContractEntry[],
  chainId: number | undefined,
): string {
  return markdownTable([
    ["Contract", "Address"],
    ...contracts.map(({ name, address }) => [
      name,
      addressCell(chainId, address),
    ]),
  ]);
}

/// Table of one namespace's contracts, or `null` when the namespace holds no
/// records.
async function namespaceTable(
  deploymentsDir: string,
  namespace: string,
  chainId: number | undefined,
): Promise<string | null> {
  const loaded = await loadDeploymentsFromFiles(
    deploymentsDir,
    namespace,
    false,
  ).catch(() => null);
  const contracts = loaded ? loadContractEntries(loaded.deployments) : [];
  return contracts.length ? formatTable(contracts, chainId) : null;
}

const ADHOC_SUFFIX = "-adhoc";

/// Namespace that holds the contracts deployed one at a time beside a
/// deployment, outside the migration.
export function adhocNamespace(namespace: string): string {
  return `${namespace}${ADHOC_SUFFIX}`;
}

/// The deployment namespace an ad-hoc namespace sits beside; any other
/// namespace is returned as it is.
export function baseNamespace(namespace: string): string {
  return namespace.endsWith(ADHOC_SUFFIX)
    ? namespace.slice(0, -ADHOC_SUFFIX.length)
    : namespace;
}

/// One record of a contract in one folder of a deployment's history.
interface RecordedContract extends ContractEntry {
  /// Block the record's deploy was mined in, when the record carries a receipt.
  block?: bigint;
  /// Folder the record is kept in.
  folder: string;
  /// True for a folder whose records are not archived, false for an archive of
  /// replaced records.
  active: boolean;
  /// True for a contract deployed one at a time, outside the migration.
  adhoc: boolean;
}

/// Archive folders that hold the records replaced in `namespace`. A whole
/// earlier deployment, archived as `<namespace>-<YYYYMMDD>-r<N>`, is a separate
/// deployment rather than part of this one's history, and does not match.
function archiveFolders(deploymentsDir: string, namespace: string): string[] {
  return readdirSync(deploymentsDir, { withFileTypes: true })
    .filter(
      (entry) =>
        entry.isDirectory() && isRecordArchiveOf(namespace, entry.name),
    )
    .map((entry) => entry.name)
    .sort();
}

/// The chain a folder of records belongs to, from its `.chain` file.
function readChain(
  deploymentsDir: string,
  folder: string,
): { chainId?: string | number; genesisHash?: string } | null {
  return readJson(join(deploymentsDir, folder, ".chain"));
}

async function loadFolder(
  deploymentsDir: string,
  folder: string,
  flags: { active: boolean; adhoc: boolean },
): Promise<RecordedContract[]> {
  const { deployments } = await loadDeploymentsFromFiles(
    deploymentsDir,
    folder,
    false,
  );
  return Object.entries(deployments).flatMap(([name, deployment]) => {
    const { address, receipt } = deployment as {
      address?: string;
      receipt?: { blockNumber?: string | number };
    };
    if (!address) return [];
    const block =
      receipt?.blockNumber === undefined
        ? undefined
        : BigInt(receipt.blockNumber);
    return [{ name, address, block, folder, ...flags }];
  });
}

/// Every record a deployment has held: the records in its namespace and in the
/// namespace of its ad-hoc deployments, then those in the archives of either.
/// Proxy and implementation artifacts collapse into their canonical entry. Each
/// folder must carry a `.chain` file of the deployment's chain, so records of
/// another chain never mix into the deployment's history.
async function loadDeploymentHistory(
  deploymentsDir: string,
  namespace: string,
): Promise<RecordedContract[]> {
  const adhoc = adhocNamespace(namespace);
  const sources = [
    { folder: namespace, adhoc: false },
    { folder: adhoc, adhoc: true },
  ];
  const folders = [
    { folder: namespace, adhoc: false, active: true },
    ...(existsSync(join(deploymentsDir, adhoc))
      ? [{ folder: adhoc, adhoc: true, active: true }]
      : []),
    ...sources.flatMap((source) =>
      archiveFolders(deploymentsDir, source.folder).map((folder) => ({
        folder,
        adhoc: source.adhoc,
        active: false,
      })),
    ),
  ];
  const chain = readChain(deploymentsDir, namespace);
  for (const { folder } of folders.slice(1)) {
    const folderChain = readChain(deploymentsDir, folder);
    if (!folderChain) {
      throw new Error(
        `${join(deploymentsDir, folder)} has no .chain file; copy the one in ${namespace} into it`,
      );
    }
    if (
      chain?.genesisHash &&
      folderChain.genesisHash &&
      chain.genesisHash.toLowerCase() !== folderChain.genesisHash.toLowerCase()
    ) {
      throw new Error(
        `${join(deploymentsDir, folder)} holds records of another chain than ${namespace} (genesis block ${folderChain.genesisHash}, not ${chain.genesisHash})`,
      );
    }
  }
  const records = (
    await Promise.all(
      folders.map(({ folder, ...flags }) =>
        loadFolder(deploymentsDir, folder, flags),
      ),
    )
  ).flat();
  const names = new Set(records.map((record) => record.name));
  return records.filter((record) => !isProxyArtifact(record.name, names));
}

/// Orders records newest first. A record without a block counts as the oldest,
/// and records from the same block keep their order.
function newestFirst(a: RecordedContract, b: RecordedContract): number {
  const blockA = a.block ?? -1n;
  const blockB = b.block ?? -1n;
  return blockA === blockB ? 0 : blockA > blockB ? -1 : 1;
}

/// The latest record of each contract among the records that are not archived,
/// sorted by name. The migration's record wins a tie with an ad-hoc one.
function latestContracts(records: RecordedContract[]): RecordedContract[] {
  const latest = new Map<string, RecordedContract>();
  const newestMigrationFirst = (a: RecordedContract, b: RecordedContract) =>
    newestFirst(a, b) || Number(a.adhoc) - Number(b.adhoc);
  for (const record of records
    .filter((r) => r.active)
    .sort(newestMigrationFirst)) {
    if (!latest.has(record.name)) latest.set(record.name, record);
  }
  return [...latest.values()].sort((a, b) => a.name.localeCompare(b.name));
}

/// The latest deployed address of each contract in a deployment, keyed by
/// contract name. A latest deployment is not necessarily in use yet.
/// These are the addresses in the main table of the address pages: the records
/// of the deployment and of its ad-hoc deployments are reconciled, and the
/// newest record of each contract wins.
export async function loadLatestAddresses(
  deploymentsDir: string,
  namespace: string,
): Promise<Record<string, Address>> {
  const history = await loadDeploymentHistory(
    resolve(deploymentsDir),
    namespace,
  );
  return Object.fromEntries(
    latestContracts(history).map(({ name, address }) => [
      name,
      getAddress(address),
    ]),
  );
}

/// The changelog, newest first: every address held by a contract that has had
/// more than one, or that was deployed outside the migration. An address kept in
/// more than one folder is listed once, under the first folder that holds it;
/// the folders in use load before the archives, so that is one in use when there
/// is one.
/// Each row gives the time its block was mined, so a changelog needs a lookup of
/// block times.
async function changelog(
  records: RecordedContract[],
  chainId: number | undefined,
  blockTimes: BlockTimeLookup | undefined,
): Promise<string | null> {
  const unique = new Map<string, RecordedContract>();
  for (const record of records) {
    const key = `${record.name}:${record.address.toLowerCase()}`;
    if (!unique.has(key)) unique.set(key, record);
  }
  const addressCount = new Map<string, number>();
  for (const { name } of unique.values()) {
    addressCount.set(name, (addressCount.get(name) ?? 0) + 1);
  }
  const rows = [...unique.values()]
    .filter((r) => r.adhoc || (addressCount.get(r.name) ?? 0) > 1)
    .sort((a, b) => newestFirst(a, b) || a.name.localeCompare(b.name));
  if (rows.length === 0) return null;
  const blocks = [
    ...new Set(rows.flatMap((r) => (r.block === undefined ? [] : [r.block]))),
  ];
  if (blocks.length > 0 && !blockTimes) {
    throw new Error(
      "the address page has a changelog, whose deploy times are read from the chain; pass an RPC (for `bun run docs:addresses`, pass --rpc-url or set <NETWORK>_RPC_URL)",
    );
  }
  const times = new Map(
    await Promise.all(
      blocks.map(async (block) => [block, await blockTimes!(block)] as const),
    ),
  );
  return markdownTable([
    ["Deployed (UTC)", "Contract", "Address", "Recorded in"],
    ...rows.map((r) => [
      deployedCell(
        chainId,
        r.block,
        r.block === undefined ? undefined : times.get(r.block),
      ),
      r.name,
      addressCell(chainId, r.address),
      `\`${r.folder}\``,
    ]),
  ]);
}

function readJson<T>(path: string): T | null {
  try {
    return JSON.parse(readFileSync(path, "utf-8")) as T;
  } catch {
    return null;
  }
}

export interface GenerateAddressMarkdownOptions {
  /// Root deployments directory containing the namespace subdirectory.
  deploymentsDir: string;
  /// Namespace subdirectory to read artifacts from (e.g. `sepolia`).
  namespace: string;
  /// Canonical network name used for the output filename and heading (e.g.
  /// `sepolia`). Defaults to `namespace`.
  docName?: string;
  /// Output directory for the generated markdown. Defaults to
  /// `contracts/docs/addresses`.
  outDir?: string;
  /// Basename of the generated file, without the extension. Defaults to
  /// `docName`, which is what the canonical per-network docs use; a deployment
  /// that carries its own table alongside its artifacts sets this instead, so
  /// the file is found by a fixed name while the heading still names the
  /// network.
  fileName?: string;
  /// Reads the times blocks were mined, for the changelog. A page that has a
  /// changelog cannot be written without it.
  blockTimes?: BlockTimeLookup;
  /// Further namespaces to tabulate under their own headings, after the main
  /// one. A clean testnet deploys its own v1 stack into a separate tree, and
  /// those addresses are as much a part of the deployment as the v2 ones — a
  /// reader given only the v2 table cannot reach the registry the names live in.
  extraSections?: {
    /// Heading for the section.
    title: string;
    /// Root deployments directory holding `namespace`. Defaults to the main one.
    deploymentsDir?: string;
    /// Namespace subdirectory to read.
    namespace: string;
  }[];
}

/// Generate a markdown address table for a deployment namespace and write it to
/// `<outDir>/<fileName or docName>.md`. Returns the written file path.
export async function generateAddressMarkdown(
  opts: GenerateAddressMarkdownOptions,
): Promise<string> {
  const deploymentsDir = resolve(opts.deploymentsDir);
  const docName = opts.docName ?? opts.namespace;
  const outDir = resolve(opts.outDir ?? DEFAULT_DOCS_DIR);

  const history = await loadDeploymentHistory(deploymentsDir, opts.namespace);
  const contracts = latestContracts(history);

  const namespaceDir = join(deploymentsDir, opts.namespace);
  const chain = readJson<{ chainId?: string | number }>(
    join(namespaceDir, ".chain"),
  );
  const deployment = readJson<{ deployedAt?: string; updatedAt?: string }>(
    join(namespaceDir, ".deployment.json"),
  );
  // The latest deploy that changed the namespace, with the first one beside it
  // when they differ.
  const lastDeployedAt = deployment?.updatedAt ?? deployment?.deployedAt;
  const chainId =
    chain?.chainId !== undefined ? Number(chain.chainId) : undefined;

  const title = `# ENSv2 ${capitalize(docName)} Deployment Addresses`;
  const meta = [
    `- **Network:** ${docName}`,
    chainId !== undefined ? `- **Chain ID:** ${chainId}` : null,
    lastDeployedAt ? `- **Deployed at:** ${lastDeployedAt}` : null,
    deployment?.deployedAt && deployment.deployedAt !== lastDeployedAt
      ? `- **First deployed at:** ${deployment.deployedAt}`
      : null,
  ].filter(Boolean) as string[];

  const log = await changelog(history, chainId, opts.blockTimes);
  const sections: string[] = [formatTable(contracts, chainId)];
  for (const extra of opts.extraSections ?? []) {
    const table = await namespaceTable(
      resolve(extra.deploymentsDir ?? opts.deploymentsDir),
      extra.namespace,
      chainId,
    );
    // A namespace that was never written is reported rather than omitted, so a
    // missing section reads as a fact about the deployment instead of looking
    // like the table simply forgot it.
    sections.push(
      "",
      `## ${extra.title}`,
      "",
      table ?? `_No deployments found under \`${extra.namespace}\`._`,
    );
  }

  if (log) {
    sections.push(
      "",
      "## Changelog",
      "",
      "Every address of each contract that was deployed more than once, or deployed outside the migration, newest first.",
      "",
      log,
    );
  }

  const body = [
    title,
    "",
    "> Auto-generated by `bun run docs:addresses`. Do not edit by hand.",
    "",
    ...meta,
    "",
    ...sections,
    "",
  ].join("\n");

  mkdirSync(outDir, { recursive: true });
  const outPath = join(outDir, `${opts.fileName ?? docName}.md`);
  writeFileSync(outPath, body);
  return outPath;
}

/// Write `<deploymentsDir>/<namespace>/addresses.md`, the address table kept
/// beside a namespace's own records. Returns the written file path.
export function writeNamespaceAddressTable(
  opts: Pick<
    GenerateAddressMarkdownOptions,
    "deploymentsDir" | "namespace" | "blockTimes" | "extraSections"
  >,
): Promise<string> {
  return generateAddressMarkdown({
    ...opts,
    outDir: join(opts.deploymentsDir, opts.namespace),
    fileName: "addresses",
  });
}

/// True when a network has a page in the docs directory.
export function hasPublishedPage(
  network: string,
  docsDir = DEFAULT_DOCS_DIR,
): boolean {
  return existsSync(join(docsDir, `${network}.md`));
}

/// Write both address pages of a network: the page in the docs directory and the
/// table beside the network's records. Returns the written file paths.
export async function writeNetworkAddressPages(opts: {
  deploymentsDir: string;
  network: string;
  blockTimes?: BlockTimeLookup;
  docsDir?: string;
}): Promise<string[]> {
  const page = {
    deploymentsDir: opts.deploymentsDir,
    namespace: opts.network,
    blockTimes: opts.blockTimes,
  };
  return [
    await generateAddressMarkdown({ ...page, outDir: opts.docsDir }),
    await writeNamespaceAddressTable(page),
  ];
}

/// Rewrite both address pages of a network that already has a published page,
/// and return their paths. A network without one is left alone and gives no
/// paths. Whether the records may reach the published pages at all, rather than
/// being a rehearsal's, is for the caller to decide.
export async function refreshNetworkAddressDocs(opts: {
  deploymentsDir: string;
  network: string;
  blockTimes: BlockTimeLookup;
  docsDir?: string;
}): Promise<string[]> {
  if (!hasPublishedPage(opts.network, opts.docsDir)) return [];
  return writeNetworkAddressPages(opts);
}

function capitalize(s: string): string {
  return s.length === 0 ? s : s[0].toUpperCase() + s.slice(1);
}
