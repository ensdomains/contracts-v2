import { loadDeploymentsFromFiles } from "@rocketh/node";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

const DEFAULT_DOCS_DIR = resolve(
  new URL(import.meta.url).pathname,
  "../..",
  "docs",
  "addresses",
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
  /// Line telling a reader how the file is produced. Defaults to the canonical
  /// docs command; a deploy that writes its own table names itself instead.
  generatedBy?: string;
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
/// `<outDir>/<docName>.md`. Returns the written file path.
export async function generateAddressMarkdown(
  opts: GenerateAddressMarkdownOptions,
): Promise<string> {
  const deploymentsDir = resolve(opts.deploymentsDir);
  const docName = opts.docName ?? opts.namespace;
  const outDir = resolve(opts.outDir ?? DEFAULT_DOCS_DIR);

  const { deployments } = await loadDeploymentsFromFiles(
    deploymentsDir,
    opts.namespace,
    false,
  );
  const contracts = loadContractEntries(deployments);

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

  // Contracts deployed one at a time beside this deployment get their own
  // section. They stay apart from the main table because the same name can
  // appear in both at different addresses, and the main table is what the
  // migration tooling resolves.
  const adhoc = adhocNamespace(opts.namespace);
  const adhocTable = existsSync(join(deploymentsDir, adhoc))
    ? await namespaceTable(deploymentsDir, adhoc, chainId)
    : null;
  if (adhocTable) {
    sections.push(
      "",
      "## Ad-hoc deployments",
      "",
      `Contracts deployed one at a time outside the migration, recorded under \`${adhoc}\`. A name here can also appear in the table above at a different address.`,
      "",
      adhocTable,
    );
  }

  const body = [
    title,
    "",
    `> Auto-generated by ${opts.generatedBy ?? "`bun run docs:addresses`"}. Do not edit by hand.`,
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
export function writeNamespaceAddressTable(opts: {
  deploymentsDir: string;
  namespace: string;
  extraSections?: GenerateAddressMarkdownOptions["extraSections"];
}): Promise<string> {
  return generateAddressMarkdown({
    deploymentsDir: opts.deploymentsDir,
    namespace: opts.namespace,
    outDir: join(opts.deploymentsDir, opts.namespace),
    fileName: "addresses",
    generatedBy: "the migration deploy and `bun run deploy:contract`",
    extraSections: opts.extraSections,
  });
}

/// Rewrite both address pages of a network that has a published page: the page
/// under the docs directory and the table beside the network's records. A
/// network without a published page is left alone, so a rehearsal or test
/// namespace never overwrites real pages. Returns the written file paths.
export async function refreshNetworkAddressDocs(opts: {
  deploymentsDir: string;
  network: string;
}): Promise<string[]> {
  if (!existsSync(join(DEFAULT_DOCS_DIR, `${opts.network}.md`))) return [];
  return [
    await generateAddressMarkdown({
      deploymentsDir: opts.deploymentsDir,
      namespace: opts.network,
    }),
    await writeNamespaceAddressTable({
      deploymentsDir: opts.deploymentsDir,
      namespace: opts.network,
    }),
  ];
}

function capitalize(s: string): string {
  return s.length === 0 ? s : s[0].toUpperCase() + s.slice(1);
}
